use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

use crate::format::AssetFormat;
use crate::types::{CompressionOptions, ToolStatus};

const REQUIRED_TOOLS: [&str; 5] = ["cjpeg", "pngquant", "pngcrush", "svgo", "gifsicle"];
const OPTIONAL_TOOLS: [&str; 2] = ["zopflipng", "pngout"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipelineKind {
    Jpeg,
    Png,
    Svg,
    Gif,
    None,
}

pub fn pipeline_for_format(format: AssetFormat) -> PipelineKind {
    match format {
        AssetFormat::Jpeg => PipelineKind::Jpeg,
        AssetFormat::Png => PipelineKind::Png,
        AssetFormat::Svg => PipelineKind::Svg,
        AssetFormat::Gif => PipelineKind::Gif,
        AssetFormat::Unknown => PipelineKind::None,
    }
}

pub fn diagnostics() -> Vec<ToolStatus> {
    REQUIRED_TOOLS
        .iter()
        .chain(OPTIONAL_TOOLS.iter())
        .map(|name| ToolStatus {
            name: (*name).to_string(),
            source: which::which(name).ok().map(|p| p.display().to_string()),
            available: which::which(name).is_ok(),
        })
        .collect()
}

pub fn optimize_asset(
    format: AssetFormat,
    input_path: &Path,
    output_path: &Path,
    compression: &CompressionOptions,
) -> Result<Vec<String>> {
    let mut stages = vec![];

    if input_path != output_path {
        fs::copy(input_path, output_path).with_context(|| {
            format!(
                "failed to copy staging file {} -> {}",
                input_path.display(),
                output_path.display()
            )
        })?;
    }

    match pipeline_for_format(format) {
        PipelineKind::Jpeg => {
            if let Some(cjpeg) = which::which("cjpeg").ok() {
                run_command(
                    &cjpeg,
                    &[
                        "-quality",
                        &compression.quality.to_string(),
                        "-outfile",
                        output_path.to_string_lossy().as_ref(),
                        input_path.to_string_lossy().as_ref(),
                    ],
                )?;
                stages.push("cjpeg".to_string());
            } else {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::Png => {
            if let Some(pngquant) = which::which("pngquant").ok() {
                let tmp = swap_extension(output_path, "pngquant.png");
                let quality = format!(
                    "{}-{}",
                    compression.png_quant_quality_min, compression.png_quant_quality_max
                );
                run_command(
                    &pngquant,
                    &[
                        "--force",
                        "--output",
                        tmp.to_string_lossy().as_ref(),
                        "--quality",
                        &quality,
                        output_path.to_string_lossy().as_ref(),
                    ],
                )?;
                fs::rename(&tmp, output_path)?;
                stages.push("pngquant".to_string());
            }

            if let Some(pngcrush) = which::which("pngcrush").ok() {
                run_command(
                    &pngcrush,
                    &["-ow", "-brute", output_path.to_string_lossy().as_ref()],
                )?;
                stages.push("pngcrush".to_string());
            }

            if compression.run_zopfli {
                if let Some(zopflipng) = which::which("zopflipng").ok() {
                    let tmp = swap_extension(output_path, "zopfli.png");
                    run_command(
                        &zopflipng,
                        &[
                            "-y",
                            output_path.to_string_lossy().as_ref(),
                            tmp.to_string_lossy().as_ref(),
                        ],
                    )?;
                    fs::rename(&tmp, output_path)?;
                    stages.push("zopflipng".to_string());
                }
            }

            if compression.run_pngout {
                if let Some(pngout) = which::which("pngout").ok() {
                    let tmp = swap_extension(output_path, "pngout.png");
                    run_command(
                        &pngout,
                        &[
                            output_path.to_string_lossy().as_ref(),
                            tmp.to_string_lossy().as_ref(),
                        ],
                    )?;
                    fs::rename(&tmp, output_path)?;
                    stages.push("pngout".to_string());
                }
            }

            if stages.is_empty() {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::Svg => {
            if let Some(svgo) = which::which("svgo").ok() {
                run_command(
                    &svgo,
                    &[
                        input_path.to_string_lossy().as_ref(),
                        "-o",
                        output_path.to_string_lossy().as_ref(),
                    ],
                )?;
                stages.push("svgo".to_string());
            } else {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::Gif => {
            if let Some(gifsicle) = which::which("gifsicle").ok() {
                run_command(
                    &gifsicle,
                    &[
                        "-O3",
                        input_path.to_string_lossy().as_ref(),
                        "-o",
                        output_path.to_string_lossy().as_ref(),
                    ],
                )?;
                stages.push("gifsicle".to_string());
            } else {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::None => stages.push("copy".to_string()),
    }

    Ok(stages)
}

fn run_command(binary: &PathBuf, args: &[&str]) -> Result<()> {
    let output = Command::new(binary)
        .args(args)
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

fn swap_extension(path: &Path, suffix: &str) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_stem()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "output".to_string());
    parent.join(format!("{stem}.{suffix}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pipeline_selection_is_correct() {
        assert_eq!(pipeline_for_format(AssetFormat::Jpeg), PipelineKind::Jpeg);
        assert_eq!(pipeline_for_format(AssetFormat::Png), PipelineKind::Png);
        assert_eq!(pipeline_for_format(AssetFormat::Svg), PipelineKind::Svg);
        assert_eq!(pipeline_for_format(AssetFormat::Gif), PipelineKind::Gif);
        assert_eq!(
            pipeline_for_format(AssetFormat::Unknown),
            PipelineKind::None
        );
    }
}
