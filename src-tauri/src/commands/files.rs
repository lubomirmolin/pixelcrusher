use std::path::{Path, PathBuf};

use rfd::FileDialog;

use crate::constants::MAX_PREVIEW_BYTES;
use crate::path_utils::is_supported_image_path;

#[tauri::command]
pub fn select_input_files() -> Vec<String> {
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
pub fn select_input_folder() -> Option<String> {
    FileDialog::new()
        .set_title("Select folder with images")
        .pick_folder()
        .map(|path| path.display().to_string())
}

#[tauri::command]
pub fn read_image_bytes(path: String) -> Result<Vec<u8>, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("Image path is empty.".to_string());
    }

    let image_path = PathBuf::from(trimmed);
    if !image_path.exists() || !image_path.is_file() {
        return Err("Image path does not exist or is not a file.".to_string());
    }

    if !is_supported_image_path(&image_path) {
        return Err("Unsupported image format.".to_string());
    }

    let metadata = std::fs::metadata(&image_path)
        .map_err(|error| format!("failed to read image metadata: {error}"))?;
    if metadata.len() > MAX_PREVIEW_BYTES {
        return Err("Image is too large for preview.".to_string());
    }

    std::fs::read(&image_path).map_err(|error| format!("failed to read image bytes: {error}"))
}

#[tauri::command]
pub fn reveal_in_finder(path: String) -> Result<(), String> {
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
pub fn open_external_url(url: String) -> Result<(), String> {
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
