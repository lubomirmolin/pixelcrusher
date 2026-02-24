use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[cfg(target_os = "linux")]
use std::os::unix::fs::PermissionsExt;

use pixelcrusher_core::queue::{JobEvent, JobState, QueueMachine};
use pixelcrusher_core::types::{ProcessOptions, ToolStatus};
use reqwest::Url;
use rfd::FileDialog;
use serde::Serialize;
use sha2::{Digest, Sha256};
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

#[derive(Debug, Clone, Serialize)]
struct DownloadedUpdatePayload {
    path: String,
    size: u64,
    sha256: String,
}

#[derive(Debug, Clone, Serialize)]
struct UpdateInstallResult {
    mode: String,
    message: String,
    command: Option<String>,
}

const RELEASE_OWNER: &str = "lubomirmolin";
const RELEASE_REPO: &str = "pixelcrusher";

#[tauri::command]
fn startup_diagnostics(state: tauri::State<'_, AppState>) -> Vec<ToolStatus> {
    state.runtime.diagnostics.clone()
}

#[tauri::command]
fn recent_results(state: tauri::State<'_, AppState>) -> Vec<JobResultEntry> {
    state.runtime.recent_results.lock().unwrap().clone()
}

#[tauri::command]
fn app_version(app: tauri::AppHandle) -> String {
    app.package_info().version.to_string()
}

#[tauri::command]
fn runtime_platform() -> String {
    if cfg!(target_os = "windows") {
        "windows".to_string()
    } else if cfg!(target_os = "linux") {
        "linux".to_string()
    } else if cfg!(target_os = "macos") {
        "macos".to_string()
    } else {
        "unknown".to_string()
    }
}

#[tauri::command]
async fn download_verified_update(
    url: String,
    file_name: String,
    expected_sha256: String,
) -> Result<DownloadedUpdatePayload, String> {
    tauri::async_runtime::spawn_blocking(move || {
        download_verified_update_blocking(&url, &file_name, &expected_sha256)
    })
    .await
    .map_err(|error| format!("download task failed: {error}"))?
}

#[tauri::command]
fn install_downloaded_update(
    app: tauri::AppHandle,
    path: String,
    asset_kind: String,
) -> Result<UpdateInstallResult, String> {
    let installer_path = PathBuf::from(path.trim());
    validate_downloaded_installer_path(&installer_path)?;

    #[cfg(target_os = "windows")]
    {
        let normalized_kind = asset_kind.trim().to_lowercase();
        match normalized_kind.as_str() {
            "windows-exe" => {
                std::process::Command::new(&installer_path)
                    .arg("/S")
                    .spawn()
                    .map_err(|error| format!("failed to launch NSIS installer: {error}"))?;

                schedule_app_exit(app);

                return Ok(UpdateInstallResult {
                    mode: "launched-and-exit".to_string(),
                    message:
                        "Installer launched. PixelCrusher will close so the update can continue."
                            .to_string(),
                    command: None,
                });
            }
            "windows-msi" => {
                std::process::Command::new("msiexec")
                    .arg("/i")
                    .arg(&installer_path)
                    .arg("/passive")
                    .arg("/norestart")
                    .spawn()
                    .map_err(|error| format!("failed to launch MSI installer: {error}"))?;

                schedule_app_exit(app);

                return Ok(UpdateInstallResult {
                    mode: "launched-and-exit".to_string(),
                    message: "MSI installer launched. PixelCrusher will close so the update can continue."
                        .to_string(),
                    command: None,
                });
            }
            _ => {
                return Err(format!(
                    "Unsupported Windows asset kind: {normalized_kind}. Expected windows-exe or windows-msi."
                ));
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        let normalized_kind = asset_kind.trim().to_lowercase();
        match normalized_kind.as_str() {
            "linux-appimage" => {
                let metadata = std::fs::metadata(&installer_path)
                    .map_err(|error| format!("failed to read AppImage metadata: {error}"))?;
                let mut permissions = metadata.permissions();
                permissions.set_mode(0o755);
                std::fs::set_permissions(&installer_path, permissions)
                    .map_err(|error| format!("failed to set AppImage executable bit: {error}"))?;

                std::process::Command::new(&installer_path)
                    .spawn()
                    .map_err(|error| format!("failed to launch AppImage update: {error}"))?;

                schedule_app_exit(app);

                return Ok(UpdateInstallResult {
                    mode: "launched-and-exit".to_string(),
                    message:
                        "AppImage launched. PixelCrusher will close and relaunch from the downloaded build."
                            .to_string(),
                    command: None,
                });
            }
            "linux-deb" => {
                let _ = std::process::Command::new("xdg-open")
                    .arg(&installer_path)
                    .spawn();

                let apt_command = format!(
                    "sudo apt install '{}'",
                    shell_escape_single_quotes(&installer_path.display().to_string())
                );

                return Ok(UpdateInstallResult {
                    mode: "guidance".to_string(),
                    message: "Downloaded .deb is ready. Your package manager was opened. If it does not appear, run the command below in a terminal:"
                        .to_string(),
                    command: Some(apt_command),
                });
            }
            _ => {
                return Err(format!(
                    "Unsupported Linux asset kind: {normalized_kind}. Expected linux-appimage or linux-deb."
                ));
            }
        }
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = app;
        let _ = asset_kind;
        let _ = installer_path;
        Err(
            "In-app installer launch is not supported on this platform for the Tauri build."
                .to_string(),
        )
    }
}

#[tauri::command]
fn select_input_files() -> Vec<String> {
    FileDialog::new()
        .set_title("Select images to optimize")
        .add_filter("Images", &["png", "jpg", "jpeg", "svg", "gif"])
        .pick_files()
        .unwrap_or_default()
        .into_iter()
        .map(|path| path.display().to_string())
        .collect()
}

#[tauri::command]
fn select_input_folder() -> Option<String> {
    FileDialog::new()
        .set_title("Select folder with images")
        .pick_folder()
        .map(|path| path.display().to_string())
}

#[tauri::command]
fn enqueue_paths(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    paths: Vec<String>,
    options: ProcessOptions,
) -> Result<Vec<JobSnapshot>, String> {
    let state = state.runtime.clone();
    let enqueue_candidates = normalize_input_paths(paths)?;

    log::info!(
        "enqueue_paths received request with {} files",
        enqueue_candidates.len()
    );

    let mut created = vec![];

    for input_path in enqueue_candidates {
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

#[tauri::command]
fn open_external_url(url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("Only http(s) URLs are allowed".to_string());
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&url)
            .status()
            .map_err(|e| format!("failed to open URL: {e}"))?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(&url)
            .status()
            .map_err(|e| format!("failed to open URL: {e}"))?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(&url)
            .status()
            .map_err(|e| format!("failed to open URL: {e}"))?;
    }

    Ok(())
}

fn download_verified_update_blocking(
    url: &str,
    file_name: &str,
    expected_sha256: &str,
) -> Result<DownloadedUpdatePayload, String> {
    let parsed_url = Url::parse(url).map_err(|error| format!("invalid update URL: {error}"))?;
    if !is_trusted_release_asset_url(&parsed_url, RELEASE_OWNER, RELEASE_REPO) {
        return Err(format!(
            "Refusing to download update from untrusted URL: {}",
            parsed_url
        ));
    }

    let normalized_digest = expected_sha256.trim().to_lowercase();
    if !is_sha256_hex(&normalized_digest) {
        return Err("Expected SHA-256 digest must be a 64-character hex string.".to_string());
    }

    let safe_file_name = Path::new(file_name.trim())
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "Invalid update asset file name".to_string())?
        .to_string();

    let destination_dir = std::env::temp_dir()
        .join("pixelcrusher-updater")
        .join(Uuid::new_v4().to_string());
    std::fs::create_dir_all(&destination_dir)
        .map_err(|error| format!("failed to create update temp directory: {error}"))?;

    let destination_path = destination_dir.join(safe_file_name);

    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(10))
        .timeout(Duration::from_secs(900))
        .build()
        .map_err(|error| format!("failed to create update HTTP client: {error}"))?;

    let mut response = client
        .get(parsed_url)
        .header("Accept", "application/octet-stream")
        .header("User-Agent", "PixelCrusher-InAppUpdater")
        .send()
        .map_err(|error| format!("failed to download update asset: {error}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "Failed to download update asset: HTTP {}",
            response.status()
        ));
    }

    if !is_trusted_release_asset_url(response.url(), RELEASE_OWNER, RELEASE_REPO) {
        return Err(format!(
            "Refusing redirected update URL outside trusted GitHub release hosts: {}",
            response.url()
        ));
    }

    let mut output = std::fs::File::create(&destination_path)
        .map_err(|error| format!("failed to create update payload file: {error}"))?;

    let mut hasher = Sha256::new();
    let mut total_size = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];

    loop {
        let read_count = response
            .read(&mut buffer)
            .map_err(|error| format!("failed while reading update response stream: {error}"))?;

        if read_count == 0 {
            break;
        }

        output
            .write_all(&buffer[..read_count])
            .map_err(|error| format!("failed while writing update payload: {error}"))?;

        hasher.update(&buffer[..read_count]);
        total_size += read_count as u64;
    }

    let actual_digest = format!("{:x}", hasher.finalize());
    if actual_digest != normalized_digest {
        let _ = std::fs::remove_file(&destination_path);
        return Err(
            "Update verification failed: downloaded checksum does not match expected SHA-256."
                .to_string(),
        );
    }

    Ok(DownloadedUpdatePayload {
        path: destination_path.display().to_string(),
        size: total_size,
        sha256: actual_digest,
    })
}

fn is_trusted_release_asset_url(url: &Url, owner: &str, repo: &str) -> bool {
    if url.scheme() != "https" {
        return false;
    }

    let host = match url.host_str() {
        Some(value) => value.to_lowercase(),
        None => return false,
    };

    if host == "github.com" {
        return url
            .path()
            .contains(&format!("/{owner}/{repo}/releases/download/"));
    }

    host == "objects.githubusercontent.com"
        || host == "github-releases.githubusercontent.com"
        || host == "release-assets.githubusercontent.com"
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|character| character.is_ascii_hexdigit())
}

fn validate_downloaded_installer_path(installer_path: &Path) -> Result<(), String> {
    if !installer_path.exists() || !installer_path.is_file() {
        return Err("Downloaded installer path does not exist or is not a file.".to_string());
    }

    let canonical_path = std::fs::canonicalize(installer_path)
        .map_err(|error| format!("failed to validate installer path: {error}"))?;

    let trusted_root = std::env::temp_dir().join("pixelcrusher-updater");
    if !canonical_path.starts_with(&trusted_root) {
        return Err(
            "Refusing to launch installer outside PixelCrusher updater temp directory.".to_string(),
        );
    }

    Ok(())
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn schedule_app_exit(app: tauri::AppHandle) {
    tauri::async_runtime::spawn_blocking(move || {
        std::thread::sleep(Duration::from_millis(350));
        app.exit(0);
    });
}

#[cfg(target_os = "linux")]
fn shell_escape_single_quotes(raw: &str) -> String {
    raw.replace('\'', "'\\''")
}

fn process_job(
    app: tauri::AppHandle,
    state: Arc<RuntimeState>,
    id: String,
    input_path: &str,
    options: &ProcessOptions,
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
            .map(|j| j.input_path.clone())
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

fn normalize_input_paths(paths: Vec<String>) -> Result<Vec<String>, String> {
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

fn is_supported_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "svg" | "gif"
            )
        })
        .unwrap_or(false)
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
            reveal_in_finder,
            select_input_files,
            select_input_folder,
            app_version,
            runtime_platform,
            open_external_url,
            download_verified_update,
            install_downloaded_update
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

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

    #[test]
    fn trusted_release_asset_url_allows_expected_hosts_only() {
        let trusted = Url::parse(
            "https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.3/PixelCrusher_1.2.3_x64-setup.exe",
        )
        .unwrap();
        let untrusted = Url::parse("https://example.com/PixelCrusher_1.2.3_x64-setup.exe").unwrap();

        assert!(is_trusted_release_asset_url(
            &trusted,
            RELEASE_OWNER,
            RELEASE_REPO
        ));
        assert!(!is_trusted_release_asset_url(
            &untrusted,
            RELEASE_OWNER,
            RELEASE_REPO
        ));
    }

    #[test]
    fn sha256_hex_validator_rejects_invalid_lengths_and_chars() {
        assert!(is_sha256_hex(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        ));
        assert!(!is_sha256_hex("abc"));
        assert!(!is_sha256_hex(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"
        ));
    }
}
