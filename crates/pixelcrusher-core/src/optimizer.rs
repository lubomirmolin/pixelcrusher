use std::collections::HashMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolResolutionSource {
    EnvironmentOverride,
    Bundled,
    HostPath,
}

impl ToolResolutionSource {
    pub fn as_str(self) -> &'static str {
        match self {
            ToolResolutionSource::EnvironmentOverride => "environment_override",
            ToolResolutionSource::Bundled => "bundled",
            ToolResolutionSource::HostPath => "host_path",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedTool {
    pub executable: PathBuf,
    pub source: ToolResolutionSource,
}

#[derive(Debug, Clone)]
pub struct ToolResolver {
    environment: HashMap<String, String>,
    search_paths: Vec<PathBuf>,
    bundled_tools_dir: Option<PathBuf>,
}

impl ToolResolver {
    pub fn new(
        environment: HashMap<String, String>,
        search_paths: Vec<PathBuf>,
        bundled_tools_dir: Option<PathBuf>,
    ) -> Self {
        Self {
            environment,
            search_paths,
            bundled_tools_dir,
        }
    }

    pub fn from_process_environment() -> Self {
        let environment: HashMap<String, String> = std::env::vars().collect();
        let search_paths = environment
            .get("PATH")
            .map(|v| {
                v.split(':')
                    .filter(|segment| !segment.trim().is_empty())
                    .map(PathBuf::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let bundled_tools_dir = default_bundled_tools_dir(&environment);

        Self {
            environment,
            search_paths,
            bundled_tools_dir,
        }
    }

    pub fn detect_statuses(&self) -> Vec<ToolStatus> {
        REQUIRED_TOOLS
            .iter()
            .chain(OPTIONAL_TOOLS.iter())
            .map(|name| {
                let resolved = self.resolve_named(name);
                ToolStatus {
                    name: (*name).to_string(),
                    available: resolved.is_some(),
                    source: resolved
                        .as_ref()
                        .map(|r| r.executable.display().to_string()),
                    source_kind: resolved.map(|r| r.source.as_str().to_string()),
                }
            })
            .collect()
    }

    pub fn resolve_named(&self, tool_name: &str) -> Option<ResolvedTool> {
        if let Some(override_path) = self.environment_override(tool_name)
            && is_executable(&override_path)
        {
            return Some(ResolvedTool {
                executable: override_path,
                source: ToolResolutionSource::EnvironmentOverride,
            });
        }

        if let Some(bundled) = self.find_bundled(tool_name) {
            return Some(ResolvedTool {
                executable: bundled,
                source: ToolResolutionSource::Bundled,
            });
        }

        if let Some(host) = self.find_on_host_path(tool_name) {
            return Some(ResolvedTool {
                executable: host,
                source: ToolResolutionSource::HostPath,
            });
        }

        None
    }

    fn environment_override(&self, tool_name: &str) -> Option<PathBuf> {
        let key = format!(
            "PIXELCRUSHER_{}_PATH",
            tool_name.to_ascii_uppercase().replace('-', "_")
        );

        self.environment
            .get(&key)
            .filter(|v| !v.trim().is_empty())
            .map(PathBuf::from)
    }

    fn find_bundled(&self, tool_name: &str) -> Option<PathBuf> {
        let root = self.bundled_tools_dir.as_ref()?;
        let candidate = root.join("bin").join(tool_name);
        if is_executable(&candidate) {
            Some(candidate)
        } else {
            None
        }
    }

    fn find_on_host_path(&self, tool_name: &str) -> Option<PathBuf> {
        if let Ok(found) = which::which(tool_name) {
            return Some(found);
        }

        for dir in &self.search_paths {
            let candidate = dir.join(tool_name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }

        None
    }
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
    ToolResolver::from_process_environment().detect_statuses()
}

pub fn optimize_asset(
    format: AssetFormat,
    input_path: &Path,
    output_path: &Path,
    compression: &CompressionOptions,
) -> Result<Vec<String>> {
    let mut stages = vec![];
    let resolver = ToolResolver::from_process_environment();

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
            if let Some(cjpeg) = resolver.resolve_named("cjpeg") {
                run_command(
                    &cjpeg.executable,
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
            if compression.run_png_quant
                && let Some(pngquant) = resolver.resolve_named("pngquant")
            {
                let tmp = swap_extension(output_path, "pngquant.png");
                let quality = format!(
                    "{}-{}",
                    compression.png_quant_quality_min, compression.png_quant_quality_max
                );
                run_command(
                    &pngquant.executable,
                    &[
                        "--force",
                        "--output",
                        tmp.to_string_lossy().as_ref(),
                        "--quality",
                        &quality,
                        "--speed",
                        &compression.png_quant_speed.to_string(),
                        output_path.to_string_lossy().as_ref(),
                    ],
                )?;
                fs::rename(&tmp, output_path)?;
                stages.push("pngquant".to_string());
            }

            if compression.run_pngcrush
                && let Some(pngcrush) = resolver.resolve_named("pngcrush")
            {
                run_command(
                    &pngcrush.executable,
                    &["-ow", "-brute", output_path.to_string_lossy().as_ref()],
                )?;
                stages.push("pngcrush".to_string());
            }

            if compression.run_zopfli
                && let Some(zopflipng) = resolver.resolve_named("zopflipng")
            {
                let tmp = swap_extension(output_path, "zopfli.png");
                run_command(
                    &zopflipng.executable,
                    &[
                        "-y",
                        output_path.to_string_lossy().as_ref(),
                        tmp.to_string_lossy().as_ref(),
                    ],
                )?;
                fs::rename(&tmp, output_path)?;
                stages.push("zopflipng".to_string());
            }

            if compression.run_pngout
                && let Some(pngout) = resolver.resolve_named("pngout")
            {
                let tmp = swap_extension(output_path, "pngout.png");
                run_command(
                    &pngout.executable,
                    &[
                        output_path.to_string_lossy().as_ref(),
                        tmp.to_string_lossy().as_ref(),
                    ],
                )?;
                fs::rename(&tmp, output_path)?;
                stages.push("pngout".to_string());
            }

            if stages.is_empty() {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::Svg => {
            if let Some(svgo) = resolver.resolve_named("svgo") {
                let mut args = vec![input_path.to_string_lossy().to_string()];
                if compression.svg_multipass {
                    args.push("--multipass".to_string());
                }
                args.push("-o".to_string());
                args.push(output_path.to_string_lossy().to_string());
                let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
                run_command(&svgo.executable, &arg_refs)?;
                stages.push("svgo".to_string());
            } else {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::Gif => {
            if let Some(gifsicle) = resolver.resolve_named("gifsicle") {
                let mut args = vec![format!(
                    "--optimize={}",
                    compression.gif_optimization_level.clamp(1, 3)
                )];
                if compression.gif_lossy_level > 0 {
                    args.push(format!("--lossy={}", compression.gif_lossy_level));
                }
                args.push(input_path.to_string_lossy().to_string());
                args.push("-o".to_string());
                args.push(output_path.to_string_lossy().to_string());
                let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
                run_command(&gifsicle.executable, &arg_refs)?;
                stages.push("gifsicle".to_string());
            } else {
                stages.push("copy".to_string());
            }
        }
        PipelineKind::None => stages.push("copy".to_string()),
    }

    Ok(stages)
}

fn run_command(binary: &Path, args: &[&str]) -> Result<()> {
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

fn default_bundled_tools_dir(environment: &HashMap<String, String>) -> Option<PathBuf> {
    if let Some(override_dir) = environment.get("PIXELCRUSHER_BUNDLED_TOOLS_DIR")
        && !override_dir.trim().is_empty()
    {
        let path = PathBuf::from(override_dir);
        if path.exists() {
            return Some(path);
        }
    }

    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            let candidate = parent.join("../Resources/BundledTools");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };

    if !metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        let mode = metadata.permissions().mode();
        mode & 0o111 != 0
    }

    #[cfg(not(unix))]
    {
        true
    }
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

    #[test]
    fn resolver_prefers_bundled_over_host() {
        let temp = tempfile::tempdir().unwrap();
        let bundled_bin = temp.path().join("bundled/bin");
        let host_bin = temp.path().join("host/bin");
        fs::create_dir_all(&bundled_bin).unwrap();
        fs::create_dir_all(&host_bin).unwrap();

        let bundled_tool = bundled_bin.join("pngquant");
        let host_tool = host_bin.join("pngquant");
        make_executable(&bundled_tool);
        make_executable(&host_tool);

        let resolver = ToolResolver::new(
            HashMap::new(),
            vec![host_bin],
            Some(temp.path().join("bundled")),
        );

        let resolved = resolver.resolve_named("pngquant").unwrap();
        assert_eq!(resolved.executable, bundled_tool);
        assert_eq!(resolved.source, ToolResolutionSource::Bundled);
    }

    #[test]
    fn resolver_prefers_env_override_highest() {
        let temp = tempfile::tempdir().unwrap();
        let bundled_bin = temp.path().join("bundled/bin");
        let host_bin = temp.path().join("host/bin");
        fs::create_dir_all(&bundled_bin).unwrap();
        fs::create_dir_all(&host_bin).unwrap();

        let bundled_tool = bundled_bin.join("gifsicle");
        let host_tool = host_bin.join("gifsicle");
        let override_tool = temp.path().join("override-gifsicle");

        make_executable(&bundled_tool);
        make_executable(&host_tool);
        make_executable(&override_tool);

        let mut env = HashMap::new();
        env.insert(
            "PIXELCRUSHER_GIFSICLE_PATH".to_string(),
            override_tool.display().to_string(),
        );

        let resolver = ToolResolver::new(env, vec![host_bin], Some(temp.path().join("bundled")));

        let resolved = resolver.resolve_named("gifsicle").unwrap();
        assert_eq!(resolved.executable, override_tool);
        assert_eq!(resolved.source, ToolResolutionSource::EnvironmentOverride);
    }

    fn make_executable(path: &Path) {
        fs::write(path, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            let mut perms = fs::metadata(path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(path, perms).unwrap();
        }
    }
}
