mod bootstrap;
mod commands;
mod constants;
mod models;
mod path_utils;
mod state;
mod tooling;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(bootstrap::setup)
        .invoke_handler(tauri::generate_handler![
            commands::app_info::startup_diagnostics,
            commands::queue::enqueue_paths,
            commands::app_info::recent_results,
            commands::files::reveal_in_finder,
            commands::files::select_input_files,
            commands::files::select_input_folder,
            commands::files::read_image_bytes,
            commands::app_info::app_version,
            commands::app_info::runtime_platform,
            commands::files::open_external_url,
            commands::update::download_verified_update,
            commands::update::install_downloaded_update
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
