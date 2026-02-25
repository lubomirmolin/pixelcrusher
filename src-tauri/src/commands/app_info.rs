use crate::models::{JobResultEntry, ToolStatusSnapshot};
use crate::state::AppState;

#[tauri::command]
pub fn startup_diagnostics(state: tauri::State<'_, AppState>) -> Vec<ToolStatusSnapshot> {
    state.runtime.diagnostics.clone()
}

#[tauri::command]
pub fn recent_results(state: tauri::State<'_, AppState>) -> Vec<JobResultEntry> {
    state.runtime.recent_results.lock().unwrap().clone()
}

#[tauri::command]
pub fn app_version(app: tauri::AppHandle) -> String {
    app.package_info().version.to_string()
}

#[tauri::command]
pub fn runtime_platform() -> String {
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
