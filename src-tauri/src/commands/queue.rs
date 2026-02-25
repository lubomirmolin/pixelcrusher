use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use pixelcrusher_core::model::ProcessingOptions;
use pixelcrusher_core::queue::{JobEvent, JobState};
use tauri::Emitter;
use uuid::Uuid;

use crate::constants::MAX_RECENT_RESULTS;
use crate::models::{JobResultEntry, JobSnapshot, QueueEventPayload};
use crate::path_utils::is_supported_image_path;
use crate::state::{AppState, RuntimeState};

#[tauri::command]
pub fn enqueue_paths(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    paths: Vec<String>,
    options: ProcessingOptions,
) -> Result<Vec<JobSnapshot>, String> {
    let runtime = state.runtime.clone();
    let enqueue_candidates = normalize_input_paths(paths)?;

    log::info!(
        "enqueue_paths received request with {} files",
        enqueue_candidates.len()
    );

    let mut created = vec![];

    for input_path in enqueue_candidates {
        let already_active = {
            let jobs = runtime.jobs.lock().unwrap();
            jobs.values().any(|job| {
                job.input_path == input_path
                    && job.status != JobState::Completed.as_str()
                    && job.status != JobState::Failed.as_str()
            })
        };

        if already_active {
            log::info!("Skipped duplicate active enqueue for {}", input_path);
            continue;
        }

        let id = Uuid::new_v4().to_string();

        let snapshot = JobSnapshot {
            id: id.clone(),
            input_path: input_path.clone(),
            status: JobState::Queued.as_str().to_string(),
            progress: 0,
            message: "Queued".to_string(),
        };

        runtime.queue_machine.lock().unwrap().enqueue(id.clone());
        runtime
            .jobs
            .lock()
            .unwrap()
            .insert(id.clone(), snapshot.clone());

        log::info!("Queued job {} for {}", id, snapshot.input_path);

        let _ = app.emit(
            "queue://event",
            QueueEventPayload {
                job: snapshot.clone(),
                result: None,
            },
        );

        created.push(snapshot.clone());

        let app_handle = app.clone();
        let state_clone = runtime.clone();
        let options_clone = options.clone();

        tauri::async_runtime::spawn_blocking(move || {
            process_job(app_handle, state_clone, id, &input_path, &options_clone);
        });
    }

    Ok(created)
}

fn process_job(
    app: tauri::AppHandle,
    state: Arc<RuntimeState>,
    id: String,
    input_path: &str,
    options: &ProcessingOptions,
) {
    let output_dir = state.output_dir.clone();

    log::info!(
        "Starting processing pipeline for job {} ({})",
        id,
        input_path
    );

    if let Err(err) = transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartDiagnostics,
        10,
        "Running diagnostics",
        None,
    ) {
        log::error!("job {} failed to enter diagnostics state: {}", id, err);
        return;
    }

    if let Err(err) = transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartProcessing,
        40,
        "Processing image",
        None,
    ) {
        log::error!("job {} failed to enter processing state: {}", id, err);
        return;
    }

    if let Err(err) = transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartOptimizing,
        70,
        "Optimizing output",
        None,
    ) {
        log::error!("job {} failed to enter optimizing state: {}", id, err);
        return;
    }

    let process_result =
        pixelcrusher_core::processing::process_asset(Path::new(input_path), &output_dir, options);

    match process_result {
        Ok(result) => {
            let delta = if result.input_bytes == 0 {
                0.0
            } else {
                ((result.output_bytes as f64 - result.input_bytes as f64)
                    / result.input_bytes as f64)
                    * 100.0
            };

            let entry = JobResultEntry {
                id: id.clone(),
                input_path: result.source_path.clone(),
                output_path: result.destination_path.clone(),
                status: JobState::Completed.as_str().to_string(),
                input_size: result.input_bytes,
                output_size: result.output_bytes,
                size_delta_percent: delta,
                stages_run: result.applied_stages,
                duration_ms: result.elapsed_ms,
            };

            let _ = transition_and_emit(
                &app,
                &state,
                &id,
                JobEvent::Complete,
                100,
                "Done",
                Some(entry.clone()),
            );

            state.recent_results.lock().unwrap().insert(0, entry);
            trim_recent(&state);
        }
        Err(err) => {
            log::error!("job {} failed while processing {}: {}", id, input_path, err);
            let _ = transition_and_emit(
                &app,
                &state,
                &id,
                JobEvent::Fail,
                100,
                &format!("Failed: {err}"),
                None,
            );
        }
    }
}

fn transition_and_emit(
    app: &tauri::AppHandle,
    state: &Arc<RuntimeState>,
    id: &str,
    event: JobEvent,
    progress: u8,
    message: &str,
    result: Option<JobResultEntry>,
) -> Result<(), String> {
    let status = {
        let mut machine = state.queue_machine.lock().unwrap();
        machine
            .transition(id, event)
            .map_err(|err| format!("queue transition error for {id}: {err}"))?
    };

    let snapshot = JobSnapshot {
        id: id.to_string(),
        input_path: state
            .jobs
            .lock()
            .unwrap()
            .get(id)
            .map(|job| job.input_path.clone())
            .unwrap_or_default(),
        status: status.as_str().to_string(),
        progress,
        message: message.to_string(),
    };

    log::info!(
        "job {} transition {:?} -> {} ({}%)",
        id,
        event,
        snapshot.status,
        progress
    );

    state
        .jobs
        .lock()
        .unwrap()
        .insert(id.to_string(), snapshot.clone());

    let _ = app.emit(
        "queue://event",
        QueueEventPayload {
            job: snapshot,
            result,
        },
    );

    Ok(())
}

pub(crate) fn normalize_input_paths(paths: Vec<String>) -> Result<Vec<String>, String> {
    let mut accepted = vec![];
    let mut seen = HashSet::new();

    for raw in paths {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }

        let original = PathBuf::from(trimmed);
        if !original.exists() {
            log::warn!("Rejected enqueue path (missing): {}", trimmed);
            continue;
        }

        if original.is_file() {
            push_if_supported_file(&original, &mut accepted, &mut seen);
            continue;
        }

        if original.is_dir() {
            collect_supported_files_from_dir(&original, &mut accepted, &mut seen);
            continue;
        }

        log::warn!("Rejected enqueue path (unsupported type): {}", trimmed);
    }

    if accepted.is_empty() {
        return Err(
            "No valid file paths were provided. Drag files/folders into the app window or use the system picker."
                .to_string(),
        );
    }

    Ok(accepted)
}

fn collect_supported_files_from_dir(
    root: &Path,
    accepted: &mut Vec<String>,
    seen: &mut HashSet<String>,
) {
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => {
            log::warn!(
                "Unable to enumerate directory for enqueue {}: {}",
                root.display(),
                error
            );
            return;
        }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_supported_files_from_dir(&path, accepted, seen);
            continue;
        }

        if path.is_file() {
            push_if_supported_file(&path, accepted, seen);
        }
    }
}

fn push_if_supported_file(path: &Path, accepted: &mut Vec<String>, seen: &mut HashSet<String>) {
    if !is_supported_image_path(path) {
        log::warn!(
            "Skipped enqueue path with unsupported extension: {}",
            path.display()
        );
        return;
    }

    let normalized = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let key = normalized.to_string_lossy().to_string();

    if seen.insert(key.clone()) {
        accepted.push(key);
    }
}

fn trim_recent(state: &Arc<RuntimeState>) {
    let mut recent = state.recent_results.lock().unwrap();
    if recent.len() > MAX_RECENT_RESULTS {
        recent.truncate(MAX_RECENT_RESULTS);
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::normalize_input_paths;

    #[test]
    fn normalize_input_paths_accepts_existing_files_and_deduplicates() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("input.png");
        fs::write(&file, b"not-a-real-png").unwrap();

        let paths = vec![
            file.display().to_string(),
            file.display().to_string(),
            "   ".to_string(),
        ];

        let normalized = normalize_input_paths(paths).unwrap();
        assert_eq!(normalized.len(), 1);
        assert!(normalized[0].contains("input.png"));
    }

    #[test]
    fn normalize_input_paths_rejects_missing_payload() {
        let err = normalize_input_paths(vec![" ".to_string(), "/does/not/exist.png".to_string()])
            .unwrap_err();
        assert!(err.contains("No valid file paths"));
    }

    #[test]
    fn normalize_input_paths_expands_directories_recursively() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("root");
        let nested = root.join("nested");
        fs::create_dir_all(&nested).unwrap();

        let png = root.join("a.png");
        let jpeg = nested.join("b.jpeg");
        let txt = nested.join("notes.txt");

        fs::write(&png, b"fake-png").unwrap();
        fs::write(&jpeg, b"fake-jpeg").unwrap();
        fs::write(&txt, b"ignore-me").unwrap();

        let normalized = normalize_input_paths(vec![root.display().to_string()]).unwrap();

        assert_eq!(normalized.len(), 2);
        assert!(normalized.iter().any(|path| path.ends_with("a.png")));
        assert!(normalized.iter().any(|path| path.ends_with("b.jpeg")));
    }
}
