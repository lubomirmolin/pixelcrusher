use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use pixelcrusher_core::format::detect_format;
use pixelcrusher_core::model::{ProcessingOptions, TransformOptions};
use serde::Deserialize;
use tauri::Emitter;
use uuid::Uuid;

use crate::constants::MAX_RECENT_RESULTS;
use crate::models::{
    BackgroundRemovalEventPayload, BackgroundRemovalModelStatusSnapshot,
    BackgroundRemovalSuitabilitySnapshot, JobResultEntry,
};
use crate::state::{AppState, RuntimeState};

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct BackgroundRemovalFocusRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub(crate) struct BackgroundRemovalRun {
    pub output_path: PathBuf,
    pub input_bytes: u64,
    pub output_bytes: u64,
    pub stages_run: Vec<String>,
    pub duration_ms: u128,
}

#[derive(Debug, Clone, Copy)]
struct ModelSpec {
    id: &'static str,
    display_name: &'static str,
    short_label: &'static str,
    detail: &'static str,
    filename: &'static str,
    url: &'static str,
    expected_bytes: u64,
}

#[derive(Debug, Deserialize)]
struct RmbgFinishedPayload {
    success: bool,
    output_path: Option<String>,
    output_bytes: Option<u64>,
    error: Option<String>,
}

const MODEL_SPECS: [ModelSpec; 2] = [
    ModelSpec {
        id: "fast",
        display_name: "Fast",
        short_label: "Quantized",
        detail:
            "Quantized RMBG-1.4 ONNX. Smaller download, lower memory use, slightly softer edges.",
        filename: "model_quantized.onnx",
        url: "https://huggingface.co/briaai/RMBG-1.4/resolve/main/onnx/model_quantized.onnx",
        expected_bytes: 44_403_226,
    },
    ModelSpec {
        id: "highQuality",
        display_name: "High Quality",
        short_label: "Full",
        detail: "Full RMBG-1.4 ONNX. Larger download, heavier RAM use, better edge fidelity.",
        filename: "model.onnx",
        url: "https://huggingface.co/briaai/RMBG-1.4/resolve/main/onnx/model.onnx",
        expected_bytes: 176_153_355,
    },
];

#[tauri::command]
pub fn background_removal_statuses(
    state: tauri::State<'_, AppState>,
) -> Vec<BackgroundRemovalModelStatusSnapshot> {
    MODEL_SPECS
        .iter()
        .map(|spec| status_for(&state.runtime, spec))
        .collect()
}

#[tauri::command]
pub async fn download_background_removal_model(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    model: String,
) -> Result<BackgroundRemovalModelStatusSnapshot, String> {
    let runtime = state.runtime.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let spec = model_spec(&model)?;
        emit_progress(
            &app,
            "download",
            &format!("Downloading {} RMBG model", spec.display_name),
        );
        download_model(&runtime, &spec)?;
        emit_progress(
            &app,
            "install",
            &format!("Installed {} RMBG model", spec.display_name),
        );
        Ok(status_for(&runtime, &spec))
    })
    .await
    .map_err(|error| format!("background model download task failed: {error}"))?
}

#[tauri::command]
pub async fn remove_background(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    input_path: String,
    model: String,
    focus_rect: Option<BackgroundRemovalFocusRect>,
    options: Option<ProcessingOptions>,
) -> Result<JobResultEntry, String> {
    let runtime = state.runtime.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let input = PathBuf::from(input_path.trim());
        let run = run_background_removal(
            &runtime,
            &input,
            None,
            &model,
            focus_rect,
            options.as_ref(),
            |phase, message| emit_progress(&app, phase, message),
        )?;

        let entry = job_entry_from_run(Uuid::new_v4().to_string(), &input, &run);
        {
            let mut recent = runtime.recent_results.lock().unwrap();
            recent.insert(0, entry.clone());
            if recent.len() > MAX_RECENT_RESULTS {
                recent.truncate(MAX_RECENT_RESULTS);
            }
        }

        Ok(entry)
    })
    .await
    .map_err(|error| format!("background removal task failed: {error}"))?
}

pub(crate) fn run_background_removal<F>(
    runtime: &RuntimeState,
    input_path: &Path,
    output_dir: Option<&Path>,
    model: &str,
    focus_rect: Option<BackgroundRemovalFocusRect>,
    compression_options: Option<&ProcessingOptions>,
    mut progress: F,
) -> Result<BackgroundRemovalRun, String>
where
    F: FnMut(&str, &str),
{
    let started = Instant::now();
    if !supports_input_file(input_path) {
        return Err("Background removal supports PNG and JPEG only.".to_string());
    }

    let spec = model_spec(model)?;
    let tool = remove_tool_path(runtime)
        .ok_or_else(|| "Bundled background-removal runtime is missing.".to_string())?;
    let model_path = model_path(runtime, &spec);
    if !model_path.is_file() {
        return Err(format!(
            "{} RMBG model is not installed yet. Download it first.",
            spec.display_name
        ));
    }

    let output_path = make_output_path(input_path, output_dir)?;
    let input_bytes = file_size(input_path);
    progress(
        "prepare",
        &format!("Preparing {} background removal", spec.display_name),
    );

    let mut command = Command::new(&tool);
    command
        .arg("--model")
        .arg(&model_path)
        .arg("--input")
        .arg(input_path)
        .arg("--output")
        .arg(&output_path);

    if let Some(rect) = focus_rect {
        command.arg("--roi").arg(format!(
            "{},{},{},{}",
            rect.x, rect.y, rect.width, rect.height
        ));
    }

    let output = command
        .output()
        .map_err(|error| format!("failed to launch background removal runtime: {error}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let final_payload = parse_rmbg_stdout(&stdout, &mut progress)?;

    if !output.status.success() {
        return Err(if stderr.trim().is_empty() {
            "Background removal failed.".to_string()
        } else {
            stderr.trim().to_string()
        });
    }

    let payload =
        final_payload.ok_or_else(|| "Background removal did not return a result.".to_string())?;
    if !payload.success {
        return Err(payload
            .error
            .unwrap_or_else(|| "Background removal failed.".to_string()));
    }

    let mut final_output = payload
        .output_path
        .map(PathBuf::from)
        .unwrap_or(output_path);
    let mut final_output_bytes = payload
        .output_bytes
        .unwrap_or_else(|| file_size(&final_output));
    let mut stages_run = vec!["background-removal".to_string()];

    if let Some(options) = compression_options {
        progress("compress", "Compressing transparent PNG");
        let compressed = compress_removed_background(&final_output, options)?;
        stages_run.extend(compressed.stages_run);
        final_output_bytes = compressed.output_bytes;
        final_output = compressed.output_path;
    }

    Ok(BackgroundRemovalRun {
        output_bytes: final_output_bytes,
        output_path: final_output,
        input_bytes,
        stages_run,
        duration_ms: started.elapsed().as_millis(),
    })
}

pub(crate) fn job_entry_from_run(
    id: String,
    input_path: &Path,
    run: &BackgroundRemovalRun,
) -> JobResultEntry {
    let delta = if run.input_bytes == 0 {
        0.0
    } else {
        ((run.output_bytes as f64 - run.input_bytes as f64) / run.input_bytes as f64) * 100.0
    };

    JobResultEntry {
        id,
        input_path: input_path.display().to_string(),
        output_path: run.output_path.display().to_string(),
        status: "completed".to_string(),
        input_size: run.input_bytes,
        output_size: run.output_bytes,
        size_delta_percent: delta,
        stages_run: run.stages_run.clone(),
        duration_ms: run.duration_ms,
    }
}

fn status_for(runtime: &RuntimeState, spec: &ModelSpec) -> BackgroundRemovalModelStatusSnapshot {
    let model_path = model_path(runtime, spec);
    let is_installed = model_path.is_file();
    let installed_bytes = if is_installed {
        Some(file_size(&model_path))
    } else {
        None
    };
    let tool_available = remove_tool_path(runtime).is_some();
    let suitability = if tool_available {
        BackgroundRemovalSuitabilitySnapshot {
            level: "ready".to_string(),
            message: format!(
                "{} RMBG is available for manual install.",
                spec.display_name
            ),
            is_available: true,
        }
    } else {
        BackgroundRemovalSuitabilitySnapshot {
            level: "unavailable".to_string(),
            message: "Bundled background-removal runtime is missing.".to_string(),
            is_available: false,
        }
    };

    BackgroundRemovalModelStatusSnapshot {
        model: spec.id.to_string(),
        display_name: spec.display_name.to_string(),
        short_label: spec.short_label.to_string(),
        detail: spec.detail.to_string(),
        is_installed,
        model_path: model_path.display().to_string(),
        installed_bytes,
        download_bytes: spec.expected_bytes,
        suitability,
    }
}

fn model_spec(model: &str) -> Result<ModelSpec, String> {
    let normalized = model.trim();
    MODEL_SPECS
        .iter()
        .find(|spec| spec.id == normalized)
        .copied()
        .ok_or_else(|| format!("Unsupported background removal model: {normalized}"))
}

fn download_model(runtime: &RuntimeState, spec: &ModelSpec) -> Result<PathBuf, String> {
    if !status_for(runtime, spec).suitability.is_available {
        return Err("Bundled background-removal runtime is missing.".to_string());
    }

    fs::create_dir_all(&runtime.model_root_dir)
        .map_err(|error| format!("failed to create model directory: {error}"))?;

    let installed_path = model_path(runtime, spec);
    if installed_path.is_file() {
        return Ok(installed_path);
    }

    let temporary_path = runtime
        .model_root_dir
        .join(format!("{}.download", spec.filename));
    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .map_err(|error| format!("failed to create model download client: {error}"))?;
    let mut response = client
        .get(spec.url)
        .header("User-Agent", "PixelCrusher-RMBG-ModelInstaller")
        .send()
        .map_err(|error| format!("failed to download RMBG model: {error}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "Model download failed with HTTP {}",
            response.status()
        ));
    }

    let expected_length = response.content_length().unwrap_or(0);
    let mut file = fs::File::create(&temporary_path)
        .map_err(|error| format!("failed to create temporary model file: {error}"))?;
    let bytes = response
        .copy_to(&mut file)
        .map_err(|error| format!("failed while writing RMBG model: {error}"))?;
    if bytes == 0 {
        let _ = fs::remove_file(&temporary_path);
        return Err("Model download produced an empty file.".to_string());
    }

    if expected_length > 0 && expected_length != bytes {
        let _ = fs::remove_file(&temporary_path);
        return Err("Model download appears truncated.".to_string());
    }

    let _ = fs::remove_file(&installed_path);
    fs::rename(&temporary_path, &installed_path)
        .map_err(|error| format!("failed to install RMBG model: {error}"))?;
    Ok(installed_path)
}

fn remove_tool_path(runtime: &RuntimeState) -> Option<PathBuf> {
    if let Ok(override_path) = std::env::var("PIXELCRUSHER_RMBG_REMOVE_PATH") {
        let candidate = PathBuf::from(override_path);
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }

    let bundled_tools_dir = runtime.bundled_tools_dir.as_ref()?;
    let tool_name = if cfg!(target_os = "windows") {
        "rmbg-remove.cmd"
    } else {
        "rmbg-remove"
    };
    let candidate = bundled_tools_dir.join("bin").join(tool_name);
    is_executable_file(&candidate).then_some(candidate)
}

fn is_executable_file(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }

    #[cfg(not(unix))]
    {
        true
    }
}

fn model_path(runtime: &RuntimeState, spec: &ModelSpec) -> PathBuf {
    if let Ok(override_dir) = std::env::var("PIXELCRUSHER_MODEL_CACHE_DIR") {
        return PathBuf::from(override_dir)
            .join("rmbg-1.4")
            .join(spec.filename);
    }

    runtime.model_root_dir.join(spec.filename)
}

fn supports_input_file(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| extension.to_ascii_lowercase())
            .as_deref(),
        Some("png" | "jpg" | "jpeg")
    )
}

fn parse_rmbg_stdout<F>(
    stdout: &str,
    progress: &mut F,
) -> Result<Option<RmbgFinishedPayload>, String>
where
    F: FnMut(&str, &str),
{
    let mut final_payload = None;

    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let value: serde_json::Value = serde_json::from_str(trimmed)
            .map_err(|error| format!("failed to parse background removal output: {error}"))?;
        let event = value
            .get("event")
            .and_then(|event| event.as_str())
            .unwrap_or_default();

        if event == "status" {
            let phase = value
                .get("phase")
                .and_then(|phase| phase.as_str())
                .unwrap_or("status");
            let message = value
                .get("message")
                .and_then(|message| message.as_str())
                .unwrap_or("Background removal is running");
            progress(phase, message);
            continue;
        }

        if event == "finished" {
            let payload = value
                .get("payload")
                .ok_or_else(|| "background removal finished without payload".to_string())?;
            final_payload =
                Some(serde_json::from_value(payload.clone()).map_err(|error| {
                    format!("failed to parse background removal result: {error}")
                })?);
        }
    }

    Ok(final_payload)
}

fn make_output_path(input_path: &Path, output_dir: Option<&Path>) -> Result<PathBuf, String> {
    let directory = output_dir
        .map(Path::to_path_buf)
        .or_else(|| input_path.parent().map(Path::to_path_buf))
        .ok_or_else(|| "Could not determine background removal output directory.".to_string())?;
    fs::create_dir_all(&directory)
        .map_err(|error| format!("failed to create output directory: {error}"))?;

    let stem = input_path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("image");

    for index in 0..100_u16 {
        let suffix = if index == 0 {
            "_nobg".to_string()
        } else {
            format!("_nobg_{}", index + 1)
        };
        let candidate = directory.join(format!("{stem}{suffix}.png"));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }

    Err("Could not determine a unique background removal output path.".to_string())
}

fn compress_removed_background(
    output_path: &Path,
    options: &ProcessingOptions,
) -> Result<BackgroundRemovalRun, String> {
    let output_dir = output_path
        .parent()
        .ok_or_else(|| "Could not determine compression output directory.".to_string())?;
    let mut compression_options = options.clone();
    compression_options.trim_transparent = false;
    compression_options.transform = TransformOptions::default();
    compression_options.output_format = Some("png".to_string());

    let report =
        pixelcrusher_core::processing::process_asset(output_path, output_dir, &compression_options)
            .map_err(|error| format!("failed to compress background-removed image: {error}"))?;

    let compressed_path = PathBuf::from(&report.destination_path);
    if compressed_path != output_path {
        let _ = fs::remove_file(output_path);
        fs::rename(&compressed_path, output_path)
            .map_err(|error| format!("failed to finalize compressed background output: {error}"))?;
    }

    Ok(BackgroundRemovalRun {
        output_path: output_path.to_path_buf(),
        input_bytes: report.input_bytes,
        output_bytes: file_size(output_path),
        stages_run: report.applied_stages,
        duration_ms: report.elapsed_ms,
    })
}

fn file_size(path: &Path) -> u64 {
    fs::metadata(path)
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

fn emit_progress(app: &tauri::AppHandle, phase: &str, message: &str) {
    let _ = app.emit(
        "background-removal://event",
        BackgroundRemovalEventPayload {
            phase: phase.to_string(),
            message: message.to_string(),
        },
    );
}

pub(crate) fn asset_format_label(path: &Path) -> String {
    detect_format(path).as_str().to_string()
}
