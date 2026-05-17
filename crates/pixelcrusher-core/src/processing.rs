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
use crate::svg::{load_svg, rasterize_svg, transform_svg};

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

    if has_format_conversion
        && source_format != AssetFormat::Svg
        && (!source_format.is_raster() || !output_format.is_raster())
    {
        bail!(
            "format conversion supports only PNG/JPG/GIF/WEBP sources and targets (from {} to {})",
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
        .is_some()
        || options.transform.resize_longest_side.is_some();
    let should_try_transparent_trim = source_format == AssetFormat::Png && options.trim_transparent;

    if source_format == AssetFormat::Svg {
        process_svg_asset(input_path, &staging_path, output_format, options)?;
    } else if source_format.is_raster()
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
        let resize_longest_side = options.transform.resize_longest_side;

        image = maybe_apply_crop_resize(image, crop_box, resize_dims, resize_longest_side);

        save_dynamic_image(&image, &staging_path, output_format)?;
    } else {
        fs::copy(input_path, &staging_path)?;
    }

    let mut compression = options.compression.clone();
    if source_format == AssetFormat::Jpeg && output_format == AssetFormat::Png {
        // Keep JPG->PNG conversion visually faithful; lossy palette quantization can introduce
        // matte/background artifacts on some inputs.
        compression.run_png_quant = false;
    }

    let applied_stages = optimize_asset(output_format, &staging_path, &output_path, &compression)?;
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
        AssetFormat::Jpeg => {
            flatten_alpha_on_white(image).save_with_format(path, ImgFormat::Jpeg)?
        }
        AssetFormat::Gif => image.save_with_format(path, ImgFormat::Gif)?,
        AssetFormat::Webp => image.save_with_format(path, ImgFormat::WebP)?,
        AssetFormat::Svg | AssetFormat::Unknown => image.save(path)?,
    }
    Ok(())
}

fn flatten_alpha_on_white(image: &DynamicImage) -> DynamicImage {
    if !image.color().has_alpha() {
        return image.clone();
    }

    let rgba = image.to_rgba8();
    let (width, height) = rgba.dimensions();
    let mut rgb = image::RgbImage::new(width, height);

    for (x, y, pixel) in rgba.enumerate_pixels() {
        let alpha = u16::from(pixel[3]);
        let red = flatten_channel_on_white(pixel[0], alpha);
        let green = flatten_channel_on_white(pixel[1], alpha);
        let blue = flatten_channel_on_white(pixel[2], alpha);
        rgb.put_pixel(x, y, image::Rgb([red, green, blue]));
    }

    DynamicImage::ImageRgb8(rgb)
}

fn flatten_channel_on_white(channel: u8, alpha: u16) -> u8 {
    let foreground = u16::from(channel) * alpha;
    let background = u16::from(u8::MAX) * (u16::from(u8::MAX) - alpha);
    ((foreground + background + 127) / u16::from(u8::MAX)) as u8
}

fn process_svg_asset(
    input_path: &Path,
    staging_path: &Path,
    output_format: AssetFormat,
    options: &ProcessingOptions,
) -> Result<()> {
    let svg = load_svg(input_path)?;
    let has_crop_transform = options
        .transform
        .crop_width
        .zip(options.transform.crop_height)
        .is_some();
    let has_resize_transform = options
        .transform
        .resize_width
        .zip(options.transform.resize_height)
        .is_some()
        || options.transform.resize_longest_side.is_some();
    let has_svg_transform = has_crop_transform || has_resize_transform;

    let transformed = if has_svg_transform || output_format != AssetFormat::Svg {
        Some(transform_svg(&svg, &options.transform)?)
    } else {
        None
    };

    match output_format {
        AssetFormat::Svg => {
            if let Some(transformed) = transformed {
                fs::write(staging_path, transformed.document).with_context(|| {
                    format!("failed to write transformed SVG {}", staging_path.display())
                })?;
            } else {
                fs::copy(input_path, staging_path).with_context(|| {
                    format!(
                        "failed to copy SVG staging file {} -> {}",
                        input_path.display(),
                        staging_path.display()
                    )
                })?;
            }
        }
        AssetFormat::Png | AssetFormat::Jpeg | AssetFormat::Gif | AssetFormat::Webp => {
            let (document, width, height) = if let Some(transformed) = transformed {
                (
                    transformed.document,
                    transformed.output_width,
                    transformed.output_height,
                )
            } else {
                let transformed = transform_svg(&svg, &options.transform)?;
                (
                    transformed.document,
                    transformed.output_width,
                    transformed.output_height,
                )
            };
            let image = rasterize_svg(&document, width, height, input_path)?;
            save_dynamic_image(&image, staging_path, output_format)?;
        }
        AssetFormat::Unknown => {
            fs::copy(input_path, staging_path)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CompressionOptions, CropAnchor, ProcessingOptions, TransformOptions};

    #[test]
    fn svg_crop_to_svg_updates_output_document() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("vector.svg");
        fs::write(
            &input,
            r##"<svg width="200" height="100" viewBox="0 0 100 50" xmlns="http://www.w3.org/2000/svg"><rect width="100" height="50" fill="#f00"/></svg>"##,
        )
        .unwrap();

        let options = ProcessingOptions {
            trim_transparent: false,
            transform: TransformOptions {
                crop_width: Some(50),
                crop_height: Some(20),
                crop_x: Some(20),
                crop_y: Some(10),
                crop_anchor: CropAnchor::Center,
                resize_width: None,
                resize_height: None,
                resize_longest_side: None,
            },
            output_format: None,
            compression: CompressionOptions::default(),
        };

        let report = process_asset(&input, temp.path(), &options).unwrap();
        let output = fs::read_to_string(report.destination_path).unwrap();

        assert!(output.contains(r#"viewBox="10 5 25 10""#));
        assert!(output.contains(r#"width="50""#));
        assert!(output.contains(r#"height="20""#));
    }

    #[test]
    fn svg_to_png_conversion_rasterizes() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("vector.svg");
        fs::write(
            &input,
            r##"<svg width="16" height="12" xmlns="http://www.w3.org/2000/svg"><rect width="16" height="12" fill="#00ff00"/></svg>"##,
        )
        .unwrap();

        let options = ProcessingOptions {
            trim_transparent: false,
            transform: TransformOptions::default(),
            output_format: Some("png".to_string()),
            compression: CompressionOptions {
                run_pngcrush: false,
                ..CompressionOptions::default()
            },
        };

        let report = process_asset(&input, temp.path(), &options).unwrap();
        let image = image::open(report.destination_path).unwrap();

        assert_eq!(image.width(), 16);
        assert_eq!(image.height(), 12);
    }

    #[test]
    fn png_to_webp_conversion_encodes_webp() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("input.png");
        let image = DynamicImage::new_rgba8(8, 6);
        image.save_with_format(&input, ImgFormat::Png).unwrap();

        let options = ProcessingOptions {
            trim_transparent: false,
            transform: TransformOptions::default(),
            output_format: Some("webp".to_string()),
            compression: CompressionOptions::default(),
        };

        let report = process_asset(&input, temp.path(), &options).unwrap();
        assert!(report.destination_path.ends_with(".webp"));

        let output = image::open(report.destination_path).unwrap();
        assert_eq!(output.width(), 8);
        assert_eq!(output.height(), 6);
    }

    #[test]
    fn alpha_flattening_uses_white_background_for_jpeg() {
        let mut image = image::RgbaImage::new(32, 32);
        for pixel in image.pixels_mut() {
            *pixel = image::Rgba([20, 160, 80, 255]);
        }
        for y in 0..16 {
            for x in 0..16 {
                image.put_pixel(x, y, image::Rgba([0, 0, 0, 0]));
            }
        }

        let output = flatten_alpha_on_white(&DynamicImage::ImageRgba8(image));

        let top_left = output.to_rgb8().get_pixel(8, 8).0;
        assert_eq!(top_left, [255, 255, 255]);
    }

    #[test]
    fn transparent_png_requested_as_jpeg_converts_to_jpeg() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("transparent.png");
        let mut image = image::RgbaImage::new(32, 32);
        for pixel in image.pixels_mut() {
            *pixel = image::Rgba([20, 160, 80, 0]);
        }
        image.save_with_format(&input, ImgFormat::Png).unwrap();

        let options = ProcessingOptions {
            output_format: Some("jpeg".to_string()),
            compression: CompressionOptions {
                run_pngcrush: false,
                ..CompressionOptions::default()
            },
            ..ProcessingOptions::default()
        };

        let report = process_asset(&input, temp.path(), &options).unwrap();

        assert_eq!(report.asset_format, "jpeg");
        assert!(report.destination_path.ends_with(".jpg"));
    }

    #[test]
    fn opaque_png_requested_as_jpeg_converts_to_jpeg() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("opaque.png");
        let image = image::RgbImage::from_pixel(4, 4, image::Rgb([20, 160, 80]));
        image.save_with_format(&input, ImgFormat::Png).unwrap();

        let options = ProcessingOptions {
            output_format: Some("jpeg".to_string()),
            compression: CompressionOptions::default(),
            ..ProcessingOptions::default()
        };

        let report = process_asset(&input, temp.path(), &options).unwrap();

        assert_eq!(report.asset_format, "jpeg");
        assert!(report.destination_path.ends_with(".jpg"));
    }
}
