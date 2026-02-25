use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(target_os = "linux")]
use std::os::unix::fs::PermissionsExt;

use reqwest::Url;
use sha2::{Digest, Sha256};

use crate::constants::{RELEASE_OWNER, RELEASE_REPO};
use crate::models::{DownloadedUpdatePayload, UpdateInstallResult};

#[tauri::command]
pub async fn download_verified_update(
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
pub fn install_downloaded_update(
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
                    message:
                        "MSI installer launched. PixelCrusher will close so the update can continue."
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
        .join(uuid::Uuid::new_v4().to_string());
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

#[cfg(test)]
mod tests {
    use reqwest::Url;

    use super::{is_sha256_hex, is_trusted_release_asset_url};
    use crate::constants::{RELEASE_OWNER, RELEASE_REPO};

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
