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

    let bundled_tools_dir = bundled_tools_dir(app);
    if let Some(directory) = &bundled_tools_dir {
        pixelcrusher_core::optimizer::set_runtime_bundled_tools_dir(Some(directory.clone()));
    }

    let model_root_dir = default_model_root_dir(app);

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

    app.manage(AppState::new(RuntimeState::new(
        diagnostics,
        base_output,
        bundled_tools_dir,
        model_root_dir,
    )));
    Ok(())
}

fn bundled_tools_dir(app: &tauri::App) -> Option<std::path::PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("BundledTools"));
        candidates.push(resource_dir.join("resources").join("BundledTools"));
    }

    #[cfg(debug_assertions)]
    candidates.push(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("BundledTools"),
    );

    candidates.into_iter().find(|candidate| candidate.is_dir())
}

fn default_model_root_dir(app: &tauri::App) -> std::path::PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return std::path::PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("PixelCrusher")
                .join("Models")
                .join("rmbg-1.4");
        }
    }

    app.path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("PixelCrusher"))
        .join("Models")
        .join("rmbg-1.4")
}
