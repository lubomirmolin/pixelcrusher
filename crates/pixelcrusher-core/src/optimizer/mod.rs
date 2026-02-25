mod command;
mod resolver;

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use crate::format::AssetFormat;
use crate::model::{CompressionOptions, ToolAvailability};

use command::{pngcrush_args, run_command, swap_extension, write_ppm_from_image};
use resolver::ToolResolver;

pub use resolver::set_runtime_bundled_tools_dir;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PipelineKind {
    Jpeg,
    Png,
    Svg,
    Gif,
    Passthrough,
}

pub fn diagnostics() -> Vec<ToolAvailability> {
    ToolResolver::from_process_environment().detect_statuses()
}

pub fn optimize_asset(
    format: AssetFormat,
    input_path: &Path,
    output_path: &Path,
    compression: &CompressionOptions,
) -> Result<Vec<String>> {
    let mut applied_stages = vec![];
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
                let ppm_input = swap_extension(output_path, "cjpeg.ppm");
                write_ppm_from_image(input_path, &ppm_input)?;

                let run_result = run_command(
                    &cjpeg.executable,
                    &[
                        "-quality",
                        &compression.quality.to_string(),
                        "-outfile",
                        output_path.to_string_lossy().as_ref(),
                        ppm_input.to_string_lossy().as_ref(),
                    ],
                );

                let _ = fs::remove_file(&ppm_input);
                run_result?;
                applied_stages.push("cjpeg".to_string());
            } else {
                applied_stages.push("copy".to_string());
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
                applied_stages.push("pngquant".to_string());
            }

            if compression.run_pngcrush
                && let Some(pngcrush) = resolver.resolve_named("pngcrush")
            {
                let tmp = swap_extension(output_path, "pngcrush.png");
                let args = pngcrush_args(output_path, &tmp);
                let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
                run_command(&pngcrush.executable, &arg_refs)?;
                fs::rename(&tmp, output_path)?;
                applied_stages.push("pngcrush".to_string());
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
                applied_stages.push("zopflipng".to_string());
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
                applied_stages.push("pngout".to_string());
            }

            if applied_stages.is_empty() {
                applied_stages.push("copy".to_string());
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
                let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
                run_command(&svgo.executable, &arg_refs)?;
                applied_stages.push("svgo".to_string());
            } else {
                applied_stages.push("copy".to_string());
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
                let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
                run_command(&gifsicle.executable, &arg_refs)?;
                applied_stages.push("gifsicle".to_string());
            } else {
                applied_stages.push("copy".to_string());
            }
        }
        PipelineKind::Passthrough => applied_stages.push("copy".to_string()),
    }

    Ok(applied_stages)
}

fn pipeline_for_format(format: AssetFormat) -> PipelineKind {
    match format {
        AssetFormat::Jpeg => PipelineKind::Jpeg,
        AssetFormat::Png => PipelineKind::Png,
        AssetFormat::Svg => PipelineKind::Svg,
        AssetFormat::Gif => PipelineKind::Gif,
        AssetFormat::Unknown => PipelineKind::Passthrough,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ToolResolutionKind;
    use image::{ImageFormat, Rgb, RgbImage, Rgba, RgbaImage};
    use std::collections::HashMap;
    use std::path::Path;
    use std::sync::{Mutex, OnceLock};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn pipeline_selection_is_correct() {
        assert_eq!(pipeline_for_format(AssetFormat::Jpeg), PipelineKind::Jpeg);
        assert_eq!(pipeline_for_format(AssetFormat::Png), PipelineKind::Png);
        assert_eq!(pipeline_for_format(AssetFormat::Svg), PipelineKind::Svg);
        assert_eq!(pipeline_for_format(AssetFormat::Gif), PipelineKind::Gif);
        assert_eq!(
            pipeline_for_format(AssetFormat::Unknown),
            PipelineKind::Passthrough
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
        assert_eq!(resolved.source, ToolResolutionKind::Bundled);
    }

    #[test]
    fn resolver_falls_back_to_host_path_when_bundled_missing() {
        let temp = tempfile::tempdir().unwrap();
        let host_bin = temp.path().join("host/bin");
        fs::create_dir_all(&host_bin).unwrap();

        let tool_name = "pixelcrusher-host-test-tool";
        let host_tool = host_bin.join(tool_name);
        make_executable(&host_tool);

        let resolver = ToolResolver::new(HashMap::new(), vec![host_bin], None);

        let resolved = resolver.resolve_named(tool_name).unwrap();
        assert_eq!(resolved.executable, host_tool);
        assert_eq!(resolved.source, ToolResolutionKind::HostPath);
    }

    #[cfg(windows)]
    #[test]
    fn resolver_finds_windows_bundled_exe() {
        let temp = tempfile::tempdir().unwrap();
        let bundled_bin = temp.path().join("bundled/bin");
        fs::create_dir_all(&bundled_bin).unwrap();

        let bundled_tool = bundled_bin.join("pngquant.exe");
        make_executable(&bundled_tool);

        let resolver = ToolResolver::new(HashMap::new(), vec![], Some(temp.path().join("bundled")));

        let resolved = resolver.resolve_named("pngquant").unwrap();
        assert_eq!(resolved.executable, bundled_tool);
        assert_eq!(resolved.source, ToolResolutionKind::Bundled);
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
        assert_eq!(resolved.source, ToolResolutionKind::EnvironmentOverride);
    }

    #[test]
    fn pngcrush_builder_uses_explicit_output_destination() {
        let input = Path::new("/tmp/in.png");
        let output = Path::new("/tmp/out.png");

        let args = pngcrush_args(input, output);

        assert_eq!(args[0], "-brute");
        assert_eq!(args[1], "/tmp/in.png");
        assert_eq!(args[2], "/tmp/out.png");
        let output_name = Path::new(&args[2])
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap();
        assert_ne!(output_name, "pngout.png");
    }

    #[test]
    fn png_pipeline_with_pngcrush_stage_writes_explicit_output_and_succeeds() {
        let temp = tempfile::tempdir().unwrap();

        let input_png = temp.path().join("input.png");
        let output_png = temp.path().join("output.png");
        let fake_pngcrush = temp.path().join("fake-pngcrush");

        let image = RgbaImage::from_pixel(2, 2, Rgba([255, 0, 0, 255]));
        image
            .save_with_format(&input_png, ImageFormat::Png)
            .unwrap();

        fs::write(
            &fake_pngcrush,
            format!(
                "#!/bin/sh
set -eu
last=\"\"
for arg in \"$@\"; do
  last=\"$arg\"
done
if [ \"$last\" = \"pngout.png\" ] || [ \"$(basename \"$last\")\" = \"pngout.png\" ]; then
  echo \"unexpected default pngout target\" >&2
  exit 1
fi
if [ \"$#\" -ne 3 ]; then
  echo \"unexpected arg count: $#\" >&2
  exit 1
fi
if [ \"$1\" != \"-brute\" ]; then
  echo \"missing -brute\" >&2
  exit 1
fi
if [ \"$3\" != \"{}\" ]; then
  echo \"unexpected output path: $3\" >&2
  exit 1
fi
cp \"$2\" \"$3\"
",
                swap_extension(&output_png, "pngcrush.png").display(),
            ),
        )
        .unwrap();

        #[cfg(unix)]
        {
            let mut perms = fs::metadata(&fake_pngcrush).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&fake_pngcrush, perms).unwrap();
        }

        let env_lock = env_lock().lock().unwrap();
        let previous = std::env::var("PIXELCRUSHER_PNGCRUSH_PATH").ok();
        unsafe {
            std::env::set_var("PIXELCRUSHER_PNGCRUSH_PATH", &fake_pngcrush);
        }

        let mut compression = CompressionOptions::default();
        compression.run_png_quant = false;
        compression.run_pngcrush = true;
        compression.run_zopfli = false;
        compression.run_pngout = false;

        let stages =
            optimize_asset(AssetFormat::Png, &input_png, &output_png, &compression).unwrap();

        match previous {
            Some(value) => unsafe {
                std::env::set_var("PIXELCRUSHER_PNGCRUSH_PATH", value);
            },
            None => unsafe {
                std::env::remove_var("PIXELCRUSHER_PNGCRUSH_PATH");
            },
        }
        drop(env_lock);

        assert_eq!(stages, vec!["pngcrush".to_string()]);
        assert!(output_png.exists());
        assert!(fs::metadata(&output_png).unwrap().len() > 0);
    }

    #[cfg(unix)]
    #[test]
    fn jpeg_pipeline_uses_ppm_input_for_cjpeg() {
        let temp = tempfile::tempdir().unwrap();

        let input_jpeg = temp.path().join("input.jpg");
        let output_jpeg = temp.path().join("output.jpg");
        let fake_cjpeg = temp.path().join("fake-cjpeg");

        let image = RgbImage::from_pixel(2, 2, Rgb([12, 140, 220]));
        image
            .save_with_format(&input_jpeg, ImageFormat::Jpeg)
            .unwrap();

        fs::write(
            &fake_cjpeg,
            "#!/bin/sh
set -eu
out=\"\"
input=\"\"
while [ \"$#\" -gt 0 ]; do
  if [ \"$1\" = \"-outfile\" ]; then
    shift
    out=\"$1\"
  else
    input=\"$1\"
  fi
  shift
done
case \"$input\" in
  *.ppm) ;;
  *) echo \"expected ppm input, got: $input\" >&2; exit 1 ;;
esac
header=\"$(head -c 2 \"$input\")\"
if [ \"$header\" != \"P6\" ]; then
  echo \"missing ppm header\" >&2
  exit 1
fi
cp \"$input\" \"$out\"
",
        )
        .unwrap();

        let mut perms = fs::metadata(&fake_cjpeg).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&fake_cjpeg, perms).unwrap();

        let env_lock = env_lock().lock().unwrap();
        let previous = std::env::var("PIXELCRUSHER_CJPEG_PATH").ok();
        unsafe {
            std::env::set_var("PIXELCRUSHER_CJPEG_PATH", &fake_cjpeg);
        }

        let compression = CompressionOptions::default();
        let stages =
            optimize_asset(AssetFormat::Jpeg, &input_jpeg, &output_jpeg, &compression).unwrap();

        match previous {
            Some(value) => unsafe {
                std::env::set_var("PIXELCRUSHER_CJPEG_PATH", value);
            },
            None => unsafe {
                std::env::remove_var("PIXELCRUSHER_CJPEG_PATH");
            },
        }
        drop(env_lock);

        assert_eq!(stages, vec!["cjpeg".to_string()]);
        assert!(output_jpeg.exists());
        assert!(fs::metadata(&output_jpeg).unwrap().len() > 0);
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
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
