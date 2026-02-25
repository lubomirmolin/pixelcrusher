use crate::models::ToolStatusSnapshot;
use crate::state::{AppState, RuntimeState};
use crate::tooling::map_tool_status;
use tauri::Manager;

pub(crate) fn setup(app: &mut tauri::App) -> std::result::Result<(), Box<dyn std::error::Error>> {
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
            pixelcrusher_core::optimizer::set_runtime_bundled_tools_dir(Some(bundled_tools_dir));
        }
    }

    let diagnostics: Vec<ToolStatusSnapshot> = pixelcrusher_core::optimizer::diagnostics()
        .into_iter()
        .map(map_tool_status)
        .collect();

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

    app.manage(AppState::new(RuntimeState::new(diagnostics, base_output)));
    Ok(())
}
