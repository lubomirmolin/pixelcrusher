use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result};
use image::{DynamicImage, GenericImageView, ImageFormat as ImgFormat};

use crate::format::{AssetFormat, detect_format};
use crate::geometry::{
    center_crop_box, crop_image, maybe_apply_crop_resize, trim_transparent_bounds,
};
use crate::optimizer::optimize_asset;
use crate::types::{ProcessOptions, ProcessResult};

pub fn process_file(
    input_path: &Path,
    output_dir: &Path,
    options: &ProcessOptions,
) -> Result<ProcessResult> {
    let started = Instant::now();
    let format = detect_format(input_path);

    let input_meta = fs::metadata(input_path)
        .with_context(|| format!("missing input file: {}", input_path.display()))?;

    fs::create_dir_all(output_dir)?;

    let stem = input_path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "output".to_string());

    let output_path = output_dir.join(format!(
        "{}_pixelcrusher.{}",
        stem,
        format.output_extension()
    ));
    let staging_path = output_dir.join(format!("{}_staging.{}", stem, format.output_extension()));

    if matches!(
        format,
        AssetFormat::Png | AssetFormat::Jpeg | AssetFormat::Gif
    ) {
        let mut image = image::open(input_path)
            .with_context(|| format!("failed to decode image {}", input_path.display()))?;

        if format == AssetFormat::Png && options.trim_transparent {
            let rgba = image.to_rgba8();
            if let Some(bounds) = trim_transparent_bounds(&rgba) {
                image = crop_image(DynamicImage::ImageRgba8(rgba), bounds);
            }
        }

        let crop_dims = options
            .dimensions
            .crop_width
            .zip(options.dimensions.crop_height)
            .map(|(w, h)| {
                let (src_w, src_h) = image.dimensions();
                let cb = center_crop_box(src_w, src_h, w, h);
                (cb.width, cb.height)
            });

        let resize_dims = options
            .dimensions
            .resize_width
            .zip(options.dimensions.resize_height);

        image = maybe_apply_crop_resize(image, crop_dims, resize_dims);

        save_dynamic_image(&image, &staging_path, format)?;
    } else {
        fs::copy(input_path, &staging_path)?;
    }

    let stages_run = optimize_asset(format, &staging_path, &output_path, &options.compression)?;
    let _ = fs::remove_file(&staging_path);

    let output_meta = fs::metadata(&output_path)?;

    Ok(ProcessResult {
        input_path: input_path.display().to_string(),
        output_path: output_path.display().to_string(),
        format: format.as_str().to_string(),
        input_size: input_meta.len(),
        output_size: output_meta.len(),
        duration_ms: started.elapsed().as_millis(),
        stages_run,
    })
}

fn save_dynamic_image(image: &DynamicImage, path: &PathBuf, format: AssetFormat) -> Result<()> {
    match format {
        AssetFormat::Png => image.save_with_format(path, ImgFormat::Png)?,
        AssetFormat::Jpeg => image.save_with_format(path, ImgFormat::Jpeg)?,
        AssetFormat::Gif => image.save_with_format(path, ImgFormat::Gif)?,
        AssetFormat::Svg | AssetFormat::Unknown => image.save(path)?,
    }
    Ok(())
}
