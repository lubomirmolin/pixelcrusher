use std::fs;
use std::path::Path;
use std::time::Instant;

use anyhow::{Context, Result};
use image::{DynamicImage, GenericImageView, ImageFormat as ImgFormat};

use crate::format::{AssetFormat, detect_format};
use crate::geometry::{
    anchored_crop_box, crop_image, maybe_apply_crop_resize, trim_transparent_bounds,
};
use crate::model::{ProcessingOptions, ProcessingReport};
use crate::optimizer::optimize_asset;

pub fn process_asset(
    input_path: &Path,
    output_dir: &Path,
    options: &ProcessingOptions,
) -> Result<ProcessingReport> {
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

        let crop_box = options
            .transform
            .crop_width
            .zip(options.transform.crop_height)
            .map(|(w, h)| {
                let (src_w, src_h) = image.dimensions();
                anchored_crop_box(src_w, src_h, w, h, options.transform.crop_anchor)
            });

        let resize_dims = options
            .transform
            .resize_width
            .zip(options.transform.resize_height);

        image = maybe_apply_crop_resize(image, crop_box, resize_dims);

        save_dynamic_image(&image, &staging_path, format)?;
    } else {
        fs::copy(input_path, &staging_path)?;
    }

    let applied_stages = optimize_asset(format, &staging_path, &output_path, &options.compression)?;
    let _ = fs::remove_file(&staging_path);

    let output_meta = fs::metadata(&output_path)?;

    Ok(ProcessingReport {
        source_path: input_path.display().to_string(),
        destination_path: output_path.display().to_string(),
        asset_format: format.as_str().to_string(),
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
