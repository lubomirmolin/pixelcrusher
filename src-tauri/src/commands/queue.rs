use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use pixelcrusher_core::model::ProcessingOptions;
use pixelcrusher_core::model::ProcessingReport;
use pixelcrusher_core::queue::{JobEvent, JobState};
use serde::Deserialize;
use tauri::Emitter;
use uuid::Uuid;

use crate::commands::background_removal::{asset_format_label, run_background_removal};
use crate::constants::MAX_RECENT_RESULTS;
use crate::models::{JobResultEntry, JobSnapshot, QueueEventPayload};
use crate::path_utils::is_supported_image_path;
use crate::state::{AppState, RuntimeState};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EnqueueCandidate {
    pub input_path: String,
    pub output_dir: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct AutomationSettings {
    pub actions: Vec<String>,
    pub background_model: Option<String>,
}

#[tauri::command]
pub fn enqueue_paths(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    paths: Vec<String>,
    options: ProcessingOptions,
    automation: Option<AutomationSettings>,
) -> Result<Vec<JobSnapshot>, String> {
    let runtime = state.runtime.clone();
    let enqueue_candidates = normalize_input_paths(paths, &runtime.output_dir)?;

    log::info!(
        "enqueue_paths received request with {} files",
        enqueue_candidates.len()
    );

    let mut created = vec![];

    for candidate in enqueue_candidates {
        let input_path = candidate.input_path;
        let output_dir = candidate.output_dir;
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
        let automation_clone = automation.clone();

        tauri::async_runtime::spawn_blocking(move || {
            process_job(
                app_handle,
                state_clone,
                id,
                &input_path,
                &output_dir,
                &options_clone,
                automation_clone.as_ref(),
            );
        });
    }

    Ok(created)
}

fn process_job(
    app: tauri::AppHandle,
    state: Arc<RuntimeState>,
    id: String,
    input_path: &str,
    output_dir: &Path,
    options: &ProcessingOptions,
    automation: Option<&AutomationSettings>,
) {
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

    let process_result = if let Some(automation) = automation {
        process_automated_asset(
            &app,
            &state,
            &id,
            Path::new(input_path),
            output_dir,
            options,
            automation,
        )
    } else {
        pixelcrusher_core::processing::process_asset(Path::new(input_path), output_dir, options)
            .map_err(|error| error.to_string())
    };

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

fn process_automated_asset(
    app: &tauri::AppHandle,
    state: &Arc<RuntimeState>,
    id: &str,
    input_path: &Path,
    output_dir: &Path,
    options: &ProcessingOptions,
    automation: &AutomationSettings,
) -> Result<ProcessingReport, String> {
    let actions = normalize_automation_actions(&automation.actions);
    if !actions.iter().any(|action| action == "removeBackground") {
        let scoped_options = options_for_actions(options, &actions);
        return pixelcrusher_core::processing::process_asset(
            input_path,
            output_dir,
            &scoped_options,
        )
        .map_err(|error| error.to_string());
    }

    let started = Instant::now();
    let original_input_bytes = std::fs::metadata(input_path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let temp_dir = std::env::temp_dir().join(format!("PixelCrusherAutomation-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir)
        .map_err(|error| format!("failed to create automation temp directory: {error}"))?;

    let mut current_path = input_path.to_path_buf();
    let mut stages_run = Vec::new();
    let mut pending_actions = Vec::<String>::new();
    let model = automation
        .background_model
        .as_deref()
        .unwrap_or("fast")
        .to_string();

    for (index, action) in actions.iter().enumerate() {
        if action == "removeBackground" {
            stages_run.extend(flush_backend_actions(
                app,
                state,
                id,
                input_path,
                &temp_dir,
                output_dir,
                options,
                &mut pending_actions,
                &mut current_path,
                false,
                index,
            )?);
            let has_remaining_backend_actions = actions
                .iter()
                .skip(index + 1)
                .any(|remaining| remaining != "removeBackground");
            let destination = if has_remaining_backend_actions {
                temp_dir.as_path()
            } else {
                output_dir
            };
            emit_snapshot_update(app, state, id, 68, "Running background removal");
            let run = run_background_removal(
                state,
                &current_path,
                Some(destination),
                &model,
                None,
                None,
                |_, message| emit_snapshot_update(app, state, id, 72, message),
            )?;
            if current_path != input_path && current_path.starts_with(&temp_dir) {
                let _ = std::fs::remove_file(&current_path);
            }
            current_path = run.output_path;
            stages_run.extend(run.stages_run);
        } else {
            pending_actions.push(action.clone());
        }
    }

    stages_run.extend(flush_backend_actions(
        app,
        state,
        id,
        input_path,
        &temp_dir,
        output_dir,
        options,
        &mut pending_actions,
        &mut current_path,
        true,
        actions.len(),
    )?);

    let output_bytes = std::fs::metadata(&current_path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let _ = std::fs::remove_dir_all(&temp_dir);

    Ok(ProcessingReport {
        source_path: input_path.display().to_string(),
        destination_path: current_path.display().to_string(),
        asset_format: asset_format_label(&current_path),
        input_bytes: original_input_bytes,
        output_bytes,
        elapsed_ms: started.elapsed().as_millis(),
        applied_stages: stages_run,
    })
}

#[allow(clippy::too_many_arguments)]
fn flush_backend_actions(
    app: &tauri::AppHandle,
    state: &Arc<RuntimeState>,
    id: &str,
    input_path: &Path,
    temp_dir: &Path,
    output_dir: &Path,
    options: &ProcessingOptions,
    pending_actions: &mut Vec<String>,
    current_path: &mut PathBuf,
    is_final: bool,
    step_index: usize,
) -> Result<Vec<String>, String> {
    if pending_actions.is_empty() {
        return Ok(Vec::new());
    }

    let segment_options = options_for_actions(options, pending_actions);
    let destination = if is_final { output_dir } else { temp_dir };
    emit_snapshot_update(
        app,
        state,
        id,
        54,
        if is_final {
            "Optimizing output"
        } else {
            "Preparing automation step"
        },
    );

    let report =
        pixelcrusher_core::processing::process_asset(current_path, destination, &segment_options)
            .map_err(|error| error.to_string())?;
    if current_path != input_path && current_path.starts_with(temp_dir) {
        let _ = std::fs::remove_file(&current_path);
    }
    *current_path = PathBuf::from(&report.destination_path);
    pending_actions.clear();

    if !is_final {
        emit_snapshot_update(
            app,
            state,
            id,
            58_u8
                .saturating_add((step_index as u8).saturating_mul(6))
                .min(88),
            "Automation step complete",
        );
    }

    Ok(report.applied_stages)
}

fn normalize_automation_actions(actions: &[String]) -> Vec<String> {
    let mut normalized = Vec::<String>::new();
    for action in actions {
        if is_known_automation_action(action) && !normalized.iter().any(|item| item == action) {
            normalized.push(action.clone());
        }
    }

    if !normalized.iter().any(|action| action == "compression") {
        normalized.insert(0, "compression".to_string());
    }

    normalized
}

fn is_known_automation_action(action: &str) -> bool {
    matches!(
        action,
        "compression" | "removeBackground" | "resize" | "convertFormat" | "trimTransparentBorders"
    )
}

fn options_for_actions(base: &ProcessingOptions, actions: &[String]) -> ProcessingOptions {
    let mut options = base.clone();
    let has_action = |candidate: &str| actions.iter().any(|action| action == candidate);

    if !has_action("resize") {
        options.transform.resize_width = None;
        options.transform.resize_height = None;
        options.transform.resize_longest_side = None;
    }

    if !has_action("convertFormat") {
        options.output_format = None;
    }

    if !has_action("trimTransparentBorders") {
        options.trim_transparent = false;
    }

    options
}

fn emit_snapshot_update(
    app: &tauri::AppHandle,
    state: &Arc<RuntimeState>,
    id: &str,
    progress: u8,
    message: &str,
) {
    let snapshot = {
        let mut jobs = state.jobs.lock().unwrap();
        let Some(existing) = jobs.get(id).cloned() else {
            return;
        };
        let snapshot = JobSnapshot {
            progress,
            message: message.to_string(),
            ..existing
        };
        jobs.insert(id.to_string(), snapshot.clone());
        snapshot
    };

    let _ = app.emit(
        "queue://event",
        QueueEventPayload {
            job: snapshot,
            result: None,
        },
    );
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

pub(crate) fn normalize_input_paths(
    paths: Vec<String>,
    default_output_dir: &Path,
) -> Result<Vec<EnqueueCandidate>, String> {
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
            push_if_supported_file(&original, default_output_dir, &mut accepted, &mut seen);
            continue;
        }

        if original.is_dir() {
            let folder_root = std::fs::canonicalize(&original).unwrap_or(original.clone());
            let output_root = folder_output_root(&folder_root);
            collect_supported_files_from_dir(
                &folder_root,
                &folder_root,
                &output_root,
                &mut accepted,
                &mut seen,
            );
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
    folder_root: &Path,
    output_root: &Path,
    accepted: &mut Vec<EnqueueCandidate>,
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
            collect_supported_files_from_dir(&path, folder_root, output_root, accepted, seen);
            continue;
        }

        if path.is_file() {
            let output_dir = folder_output_directory(&path, folder_root, output_root);
            push_if_supported_file(&path, &output_dir, accepted, seen);
        }
    }
}

fn push_if_supported_file(
    path: &Path,
    output_dir: &Path,
    accepted: &mut Vec<EnqueueCandidate>,
    seen: &mut HashSet<String>,
) {
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
        accepted.push(EnqueueCandidate {
            input_path: key,
            output_dir: output_dir.to_path_buf(),
        });
    }
}

fn folder_output_root(folder_root: &Path) -> PathBuf {
    let parent = folder_root.parent().unwrap_or(folder_root);
    let folder_name = folder_root
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "folder".to_string());

    parent.join(format!("{folder_name} pixelcrusher"))
}

fn folder_output_directory(file_path: &Path, folder_root: &Path, output_root: &Path) -> PathBuf {
    let input_parent = file_path.parent().unwrap_or(folder_root);

    if input_parent == folder_root {
        return output_root.to_path_buf();
    }

    if let Ok(relative_parent) = input_parent.strip_prefix(folder_root) {
        if relative_parent.as_os_str().is_empty() {
            return output_root.to_path_buf();
        }

        return output_root.join(relative_parent);
    }

    output_root.to_path_buf()
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

    use std::path::Path;

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

        let normalized = normalize_input_paths(paths, temp.path()).unwrap();
        assert_eq!(normalized.len(), 1);
        assert!(normalized[0].input_path.contains("input.png"));
        assert_eq!(normalized[0].output_dir, temp.path());
    }

    #[test]
    fn normalize_input_paths_rejects_missing_payload() {
        let err = normalize_input_paths(
            vec![" ".to_string(), "/does/not/exist.png".to_string()],
            Path::new("/tmp"),
        )
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

        let normalized =
            normalize_input_paths(vec![root.display().to_string()], Path::new("/tmp")).unwrap();

        assert_eq!(normalized.len(), 2);
        assert!(normalized
            .iter()
            .any(|candidate| candidate.input_path.ends_with("a.png")));
        assert!(normalized
            .iter()
            .any(|candidate| candidate.input_path.ends_with("b.jpeg")));

        let canonical_root = std::fs::canonicalize(&root).unwrap();
        let output_root = canonical_root.parent().unwrap().join("root pixelcrusher");
        let png = normalized
            .iter()
            .find(|candidate| candidate.input_path.ends_with("a.png"))
            .unwrap();
        let jpeg = normalized
            .iter()
            .find(|candidate| candidate.input_path.ends_with("b.jpeg"))
            .unwrap();

        assert_eq!(png.output_dir, output_root);
        assert_eq!(jpeg.output_dir, output_root.join("nested"));
    }
}
