use std::fs;
use std::path::Path;
use std::time::Instant;

use anyhow::{Context, Result, bail};
use image::{DynamicImage, GenericImageView, ImageFormat as ImgFormat};

use crate::format::{AssetFormat, detect_format};
use crate::geometry::{
    anchored_crop_box, crop_image, explicit_crop_box, maybe_apply_crop_resize,
    trim_transparent_bounds,
};
use crate::model::{ProcessingOptions, ProcessingReport};
use crate::optimizer::optimize_asset;

pub fn process_asset(
    input_path: &Path,
    output_dir: &Path,
    options: &ProcessingOptions,
) -> Result<ProcessingReport> {
    let started = Instant::now();
    let source_format = detect_format(input_path);
    let requested_format = options
        .output_format
        .as_deref()
        .and_then(AssetFormat::from_output_format);
    let output_format = requested_format.unwrap_or(source_format);
    let has_format_conversion = source_format != output_format;

    if has_format_conversion && (!source_format.is_raster() || !output_format.is_raster()) {
        bail!(
            "format conversion supports only PNG/JPG/GIF sources and targets (from {} to {})",
            source_format.as_str(),
            output_format.as_str()
        );
    }

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
        output_format.output_extension()
    ));
    let staging_path = output_dir.join(format!(
        "{}_staging.{}",
        stem,
        output_format.output_extension()
    ));

    let has_crop_transform = options
        .transform
        .crop_width
        .zip(options.transform.crop_height)
        .is_some();
    let has_resize_transform = options
        .transform
        .resize_width
        .zip(options.transform.resize_height)
        .is_some();
    let should_try_transparent_trim = source_format == AssetFormat::Png && options.trim_transparent;

    if source_format.is_raster()
        && (has_crop_transform
            || has_resize_transform
            || should_try_transparent_trim
            || has_format_conversion)
    {
        let mut image = image::open(input_path)
            .with_context(|| format!("failed to decode image {}", input_path.display()))?;

        if should_try_transparent_trim && image.color().has_alpha() {
            let rgba = image.to_rgba8();
            if let Some(bounds) = trim_transparent_bounds(&rgba) {
                image = crop_image(DynamicImage::ImageRgba8(rgba), bounds);
            }
        }

        let crop_box = options
            .transform
            .crop_width
            .zip(options.transform.crop_height)
            .map(|(w, h)| {
                let (src_w, src_h) = image.dimensions();
                match options.transform.crop_x.zip(options.transform.crop_y) {
                    Some((x, y)) => explicit_crop_box(src_w, src_h, w, h, x, y),
                    None => anchored_crop_box(src_w, src_h, w, h, options.transform.crop_anchor),
                }
            });

        let resize_dims = options
            .transform
            .resize_width
            .zip(options.transform.resize_height);

        image = maybe_apply_crop_resize(image, crop_box, resize_dims);

        save_dynamic_image(&image, &staging_path, output_format)?;
    } else {
        fs::copy(input_path, &staging_path)?;
    }

    let applied_stages = optimize_asset(
        output_format,
        &staging_path,
        &output_path,
        &options.compression,
    )?;
    let _ = fs::remove_file(&staging_path);

    let output_meta = fs::metadata(&output_path)?;

    Ok(ProcessingReport {
        source_path: input_path.display().to_string(),
        destination_path: output_path.display().to_string(),
        asset_format: output_format.as_str().to_string(),
        input_bytes: input_meta.len(),
        output_bytes: output_meta.len(),
        elapsed_ms: started.elapsed().as_millis(),
        applied_stages,
    })
}

fn save_dynamic_image(image: &DynamicImage, path: &Path, format: AssetFormat) -> Result<()> {
    match format {
        AssetFormat::Png => image.save_with_format(path, ImgFormat::Png)?,
        AssetFormat::Jpeg => image.save_with_format(path, ImgFormat::Jpeg)?,
        AssetFormat::Gif => image.save_with_format(path, ImgFormat::Gif)?,
        AssetFormat::Svg | AssetFormat::Unknown => image.save(path)?,
    }
    Ok(())
}
