use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use pixelcrusher_core::queue::{JobEvent, JobState, QueueMachine};
use pixelcrusher_core::types::{ProcessOptions, ToolStatus};
use serde::Serialize;
use tauri::{Emitter, Manager};
use uuid::Uuid;

#[derive(Default)]
struct RuntimeState {
    queue_machine: Mutex<QueueMachine>,
    jobs: Mutex<HashMap<String, JobSnapshot>>,
    recent_results: Mutex<Vec<JobResultEntry>>,
    diagnostics: Vec<ToolStatus>,
    output_dir: PathBuf,
}

#[derive(Clone)]
struct AppState {
    runtime: Arc<RuntimeState>,
}

#[derive(Debug, Clone, Serialize)]
struct JobSnapshot {
    id: String,
    input_path: String,
    status: String,
    progress: u8,
    message: String,
}

#[derive(Debug, Clone, Serialize)]
struct JobResultEntry {
    id: String,
    input_path: String,
    output_path: String,
    status: String,
    input_size: u64,
    output_size: u64,
    size_delta_percent: f64,
    stages_run: Vec<String>,
    duration_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
struct QueueEventPayload {
    job: JobSnapshot,
    result: Option<JobResultEntry>,
}

#[tauri::command]
fn startup_diagnostics(state: tauri::State<'_, AppState>) -> Vec<ToolStatus> {
    state.runtime.diagnostics.clone()
}

#[tauri::command]
fn recent_results(state: tauri::State<'_, AppState>) -> Vec<JobResultEntry> {
    state.runtime.recent_results.lock().unwrap().clone()
}

#[tauri::command]
fn enqueue_paths(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    paths: Vec<String>,
    options: ProcessOptions,
) -> Result<Vec<JobSnapshot>, String> {
    let state = state.runtime.clone();
    let mut created = vec![];

    for input_path in paths.into_iter().filter(|p| !p.trim().is_empty()) {
        let id = Uuid::new_v4().to_string();

        let snapshot = JobSnapshot {
            id: id.clone(),
            input_path: input_path.clone(),
            status: JobState::Queued.as_str().to_string(),
            progress: 0,
            message: "Queued".to_string(),
        };

        state.queue_machine.lock().unwrap().enqueue(id.clone());

        state
            .jobs
            .lock()
            .unwrap()
            .insert(id.clone(), snapshot.clone());

        let _ = app.emit(
            "queue://event",
            QueueEventPayload {
                job: snapshot.clone(),
                result: None,
            },
        );

        created.push(snapshot.clone());

        let app_handle = app.clone();
        let state_clone = state.clone();
        let options_clone = options.clone();

        tauri::async_runtime::spawn_blocking(move || {
            process_job(app_handle, state_clone, id, &input_path, &options_clone);
        });
    }

    Ok(created)
}

#[tauri::command]
fn reveal_in_finder(path: String) -> Result<(), String> {
    let path_obj = Path::new(&path);
    let target = if path_obj.is_file() {
        path_obj.parent().unwrap_or(path_obj)
    } else {
        path_obj
    };

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(target)
            .status()
            .map_err(|e| format!("failed to open Finder: {e}"))?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(target)
            .status()
            .map_err(|e| format!("failed to open Explorer: {e}"))?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(target)
            .status()
            .map_err(|e| format!("failed to open file manager: {e}"))?;
    }

    Ok(())
}

fn process_job(
    app: tauri::AppHandle,
    state: Arc<RuntimeState>,
    id: String,
    input_path: &str,
    options: &ProcessOptions,
) {
    let output_dir = state.output_dir.clone();

    if transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartDiagnostics,
        10,
        "Running diagnostics",
        None,
    )
    .is_err()
    {
        return;
    }

    if transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartProcessing,
        40,
        "Processing image",
        None,
    )
    .is_err()
    {
        return;
    }

    if transition_and_emit(
        &app,
        &state,
        &id,
        JobEvent::StartOptimizing,
        70,
        "Optimizing output",
        None,
    )
    .is_err()
    {
        return;
    }

    let process_result =
        pixelcrusher_core::processing::process_file(Path::new(input_path), &output_dir, options);

    match process_result {
        Ok(result) => {
            let delta = if result.input_size == 0 {
                0.0
            } else {
                ((result.output_size as f64 - result.input_size as f64) / result.input_size as f64)
                    * 100.0
            };

            let entry = JobResultEntry {
                id: id.clone(),
                input_path: result.input_path.clone(),
                output_path: result.output_path.clone(),
                status: JobState::Completed.as_str().to_string(),
                input_size: result.input_size,
                output_size: result.output_size,
                size_delta_percent: delta,
                stages_run: result.stages_run,
                duration_ms: result.duration_ms,
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
) -> Result<(), ()> {
    let status = {
        let mut machine = state.queue_machine.lock().unwrap();
        match machine.transition(id, event) {
            Ok(next) => next,
            Err(_) => return Err(()),
        }
    };

    let snapshot = JobSnapshot {
        id: id.to_string(),
        input_path: state
            .jobs
            .lock()
            .unwrap()
            .get(id)
            .map(|j| j.input_path.clone())
            .unwrap_or_default(),
        status: status.as_str().to_string(),
        progress,
        message: message.to_string(),
    };

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

fn trim_recent(state: &Arc<RuntimeState>) {
    let mut recent = state.recent_results.lock().unwrap();
    if recent.len() > 20 {
        recent.truncate(20);
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            let base_output = app
                .path()
                .download_dir()
                .unwrap_or_else(|_| std::env::temp_dir())
                .join("PixelCrusher");

            std::fs::create_dir_all(&base_output).ok();

            if let Ok(resource_dir) = app.path().resource_dir() {
                let bundled_tools_dir = resource_dir.join("BundledTools");
                if bundled_tools_dir.exists() {
                    pixelcrusher_core::optimizer::set_runtime_bundled_tools_dir(Some(
                        bundled_tools_dir,
                    ));
                }
            }

            let diagnostics = pixelcrusher_core::optimizer::diagnostics();

            #[cfg(any(target_os = "windows", target_os = "linux"))]
            {
                let ready_count = diagnostics
                    .iter()
                    .filter(|tool| tool.available && tool.source_kind.as_deref() == Some("bundled"))
                    .count();
                log::info!(
                    "Bundled optimizer diagnostics: bundled-ready {ready_count}/{} tools",
                    diagnostics.len()
                );
            }

            let state = RuntimeState {
                diagnostics,
                output_dir: base_output,
                ..Default::default()
            };

            app.manage(AppState {
                runtime: Arc::new(state),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            startup_diagnostics,
            enqueue_paths,
            recent_results,
            reveal_in_finder
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
