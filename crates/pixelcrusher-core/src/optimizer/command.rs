use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

pub fn run_command(binary: &Path, args: &[&str]) -> Result<()> {
    let mut command = Command::new(binary);
    command.args(args);

    #[cfg(windows)]
    {
        // CREATE_NO_WINDOW to avoid flashing a terminal window for each CLI tool invocation.
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }

    let output = command
        .output()
        .with_context(|| format!("failed to run {}", binary.display()))?;

    if !output.status.success() {
        anyhow::bail!(
            "{} failed: {}",
            binary.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    Ok(())
}

pub fn pngcrush_args(input_path: &Path, output_path: &Path) -> Vec<String> {
    vec![
        "-brute".to_string(),
        input_path.to_string_lossy().to_string(),
        output_path.to_string_lossy().to_string(),
    ]
}

pub fn swap_extension(path: &Path, suffix: &str) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_stem()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "output".to_string());
    parent.join(format!("{stem}.{suffix}"))
}

pub fn write_ppm_from_image(input_path: &Path, ppm_path: &Path) -> Result<()> {
    let decoded = image::open(input_path)
        .with_context(|| format!("failed to decode source for cjpeg {}", input_path.display()))?;
    let rgb = decoded.to_rgb8();
    let (width, height) = rgb.dimensions();

    let mut output = fs::File::create(ppm_path).with_context(|| {
        format!(
            "failed to create temporary cjpeg input {}",
            ppm_path.display()
        )
    })?;
    write!(output, "P6\n{} {}\n255\n", width, height)
        .with_context(|| format!("failed to write cjpeg ppm header {}", ppm_path.display()))?;
    output
        .write_all(rgb.as_raw())
        .with_context(|| format!("failed to write cjpeg ppm payload {}", ppm_path.display()))?;

    Ok(())
}
