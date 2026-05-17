use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use image::{DynamicImage, RgbaImage};
use regex::Regex;

use crate::geometry::{anchored_crop_box, explicit_crop_box, fit_with_max_longest_side};
use crate::model::TransformOptions;

#[derive(Debug, Clone, Copy)]
pub struct SvgViewBox {
    pub min_x: f64,
    pub min_y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy)]
pub struct SvgMetrics {
    pub canvas_width: f64,
    pub canvas_height: f64,
    pub view_box: SvgViewBox,
}

#[derive(Debug, Clone)]
pub struct SvgTransformResult {
    pub document: String,
    pub output_width: u32,
    pub output_height: u32,
}

pub fn load_svg(path: &Path) -> Result<String> {
    fs::read_to_string(path).with_context(|| format!("failed to read SVG {}", path.display()))
}

pub fn metrics_from_svg(svg: &str) -> Result<SvgMetrics> {
    let opening_tag =
        svg_opening_tag(svg).ok_or_else(|| anyhow::anyhow!("missing <svg> root element"))?;
    let width = attribute_value(opening_tag, "width").and_then(|value| parse_length(&value));
    let height = attribute_value(opening_tag, "height").and_then(|value| parse_length(&value));
    let view_box = attribute_value(opening_tag, "viewBox").and_then(|value| parse_view_box(&value));

    let resolved_view_box = view_box.unwrap_or_else(|| SvgViewBox {
        min_x: 0.0,
        min_y: 0.0,
        width: width.unwrap_or(1024.0),
        height: height.unwrap_or(1024.0),
    });

    let (canvas_width, canvas_height) = match (width, height) {
        (Some(width), Some(height)) if width > 0.0 && height > 0.0 => (width, height),
        (Some(width), None)
            if width > 0.0 && resolved_view_box.width > 0.0 && resolved_view_box.height > 0.0 =>
        {
            (
                width,
                width * (resolved_view_box.height / resolved_view_box.width),
            )
        }
        (None, Some(height))
            if height > 0.0 && resolved_view_box.width > 0.0 && resolved_view_box.height > 0.0 =>
        {
            (
                height * (resolved_view_box.width / resolved_view_box.height),
                height,
            )
        }
        _ if resolved_view_box.width > 0.0 && resolved_view_box.height > 0.0 => {
            (resolved_view_box.width, resolved_view_box.height)
        }
        _ => bail!("could not determine SVG canvas size"),
    };

    Ok(SvgMetrics {
        canvas_width,
        canvas_height,
        view_box: resolved_view_box,
    })
}

pub fn transform_svg(svg: &str, transform: &TransformOptions) -> Result<SvgTransformResult> {
    let metrics = metrics_from_svg(svg)?;
    let canvas_width = round_dimension(metrics.canvas_width);
    let canvas_height = round_dimension(metrics.canvas_height);

    let crop =
        transform
            .crop_width
            .zip(transform.crop_height)
            .map(
                |(width, height)| match transform.crop_x.zip(transform.crop_y) {
                    Some((x, y)) => {
                        explicit_crop_box(canvas_width, canvas_height, width, height, x, y)
                    }
                    None => anchored_crop_box(
                        canvas_width,
                        canvas_height,
                        width,
                        height,
                        transform.crop_anchor,
                    ),
                },
            );

    let mut next_view_box = metrics.view_box;
    let mut output_width = canvas_width;
    let mut output_height = canvas_height;

    if let Some(crop) = crop {
        let scale_x = metrics.view_box.width / metrics.canvas_width.max(1.0);
        let scale_y = metrics.view_box.height / metrics.canvas_height.max(1.0);
        next_view_box = SvgViewBox {
            min_x: metrics.view_box.min_x + f64::from(crop.x) * scale_x,
            min_y: metrics.view_box.min_y + f64::from(crop.y) * scale_y,
            width: f64::from(crop.width) * scale_x,
            height: f64::from(crop.height) * scale_y,
        };
        output_width = crop.width.max(1);
        output_height = crop.height.max(1);
    }

    if let Some((resize_width, resize_height)) = transform.resize_width.zip(transform.resize_height)
    {
        output_width = resize_width.max(1);
        output_height = resize_height.max(1);
    } else if let Some(max_longest_side) = transform.resize_longest_side {
        let (next_width, next_height) =
            fit_with_max_longest_side(output_width, output_height, max_longest_side);
        output_width = next_width;
        output_height = next_height;
    }

    let opening_tag =
        svg_opening_tag(svg).ok_or_else(|| anyhow::anyhow!("missing <svg> root element"))?;
    let updated_opening_tag = set_attribute(
        &set_attribute(
            &set_attribute(opening_tag, "viewBox", &format_view_box(next_view_box)),
            "width",
            &output_width.to_string(),
        ),
        "height",
        &output_height.to_string(),
    );

    let updated_svg = replace_opening_tag(svg, &updated_opening_tag)
        .ok_or_else(|| anyhow::anyhow!("failed to replace <svg> root element"))?;

    Ok(SvgTransformResult {
        document: updated_svg,
        output_width,
        output_height,
    })
}

pub fn rasterize_svg(
    svg: &str,
    output_width: u32,
    output_height: u32,
    source_path: &Path,
) -> Result<DynamicImage> {
    let mut options = usvg::Options {
        resources_dir: fs::canonicalize(source_path)
            .ok()
            .and_then(|path| path.parent().map(Path::to_path_buf)),
        ..usvg::Options::default()
    };
    options.fontdb_mut().load_system_fonts();

    let tree = usvg::Tree::from_data(svg.as_bytes(), &options)
        .with_context(|| format!("failed to parse SVG {}", source_path.display()))?;

    let tree_size = tree.size().to_int_size();
    let transform = tiny_skia::Transform::from_scale(
        output_width as f32 / tree_size.width().max(1) as f32,
        output_height as f32 / tree_size.height().max(1) as f32,
    );

    let mut pixmap = tiny_skia::Pixmap::new(output_width.max(1), output_height.max(1))
        .ok_or_else(|| anyhow::anyhow!("failed to allocate SVG raster surface"))?;
    resvg::render(&tree, transform, &mut pixmap.as_mut());

    let image = RgbaImage::from_raw(pixmap.width(), pixmap.height(), pixmap.take())
        .ok_or_else(|| anyhow::anyhow!("failed to decode SVG raster output"))?;
    Ok(DynamicImage::ImageRgba8(image))
}

fn round_dimension(value: f64) -> u32 {
    value.round().clamp(1.0, f64::from(u32::MAX)) as u32
}

fn svg_opening_tag(svg: &str) -> Option<&str> {
    let regex = Regex::new(r"(?is)<svg\b[^>]*>").ok()?;
    regex.find(svg).map(|match_| &svg[match_.range()])
}

fn replace_opening_tag(svg: &str, new_tag: &str) -> Option<String> {
    let regex = Regex::new(r"(?is)<svg\b[^>]*>").ok()?;
    let mat = regex.find(svg)?;
    let mut updated = String::with_capacity(svg.len() + new_tag.len());
    updated.push_str(&svg[..mat.start()]);
    updated.push_str(new_tag);
    updated.push_str(&svg[mat.end()..]);
    Some(updated)
}

fn attribute_value(opening_tag: &str, name: &str) -> Option<String> {
    let pattern = format!(
        r#"(?is)\b{}\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#,
        regex::escape(name)
    );
    let regex = Regex::new(&pattern).ok()?;
    let captures = regex.captures(opening_tag)?;
    captures
        .get(1)
        .or_else(|| captures.get(2))
        .map(|value| value.as_str().to_string())
}

fn set_attribute(opening_tag: &str, name: &str, value: &str) -> String {
    let pattern = format!(
        r#"(?is)\b{}\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#,
        regex::escape(name)
    );
    let replacement = format!(r#"{}="{}""#, name, value);
    let regex = Regex::new(&pattern).expect("valid SVG attribute regex");

    if regex.is_match(opening_tag) {
        regex
            .replace(opening_tag, replacement.as_str())
            .into_owned()
    } else if let Some(index) = opening_tag.rfind("/>") {
        let mut updated = String::with_capacity(opening_tag.len() + replacement.len() + 1);
        updated.push_str(&opening_tag[..index]);
        updated.push(' ');
        updated.push_str(&replacement);
        updated.push_str(&opening_tag[index..]);
        updated
    } else if let Some(index) = opening_tag.rfind('>') {
        let mut updated = String::with_capacity(opening_tag.len() + replacement.len() + 1);
        updated.push_str(&opening_tag[..index]);
        updated.push(' ');
        updated.push_str(&replacement);
        updated.push_str(&opening_tag[index..]);
        updated
    } else {
        opening_tag.to_string()
    }
}

fn parse_length(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.ends_with('%') {
        return None;
    }

    let numeric_end = trimmed
        .find(|ch: char| !(ch.is_ascii_digit() || ch == '.' || ch == '-' || ch == '+'))
        .unwrap_or(trimmed.len());
    let (number, unit) = trimmed.split_at(numeric_end);
    let value = number.parse::<f64>().ok()?;
    let scale = match unit.trim().to_ascii_lowercase().as_str() {
        "" | "px" => 1.0,
        "pt" => 96.0 / 72.0,
        "pc" => 16.0,
        "mm" => 96.0 / 25.4,
        "cm" => 96.0 / 2.54,
        "in" => 96.0,
        _ => return None,
    };

    let resolved = value * scale;
    (resolved.is_finite() && resolved > 0.0).then_some(resolved)
}

fn parse_view_box(raw: &str) -> Option<SvgViewBox> {
    let parts = raw
        .split(|ch: char| ch == ',' || ch.is_whitespace())
        .filter(|part| !part.is_empty())
        .map(str::parse::<f64>)
        .collect::<std::result::Result<Vec<_>, _>>()
        .ok()?;

    if parts.len() != 4 || parts[2] <= 0.0 || parts[3] <= 0.0 {
        return None;
    }

    Some(SvgViewBox {
        min_x: parts[0],
        min_y: parts[1],
        width: parts[2],
        height: parts[3],
    })
}

fn format_view_box(view_box: SvgViewBox) -> String {
    format!(
        "{} {} {} {}",
        trim_float(view_box.min_x),
        trim_float(view_box.min_y),
        trim_float(view_box.width),
        trim_float(view_box.height)
    )
}

fn trim_float(value: f64) -> String {
    if (value.fract()).abs() < f64::EPSILON {
        format!("{value:.0}")
    } else {
        let mut text = format!("{value:.4}");
        while text.contains('.') && text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CropAnchor, TransformOptions};
    use std::path::PathBuf;

    #[test]
    fn derives_canvas_size_from_view_box_when_dimensions_missing() {
        let svg = r#"<svg viewBox="0 0 320 180" xmlns="http://www.w3.org/2000/svg"></svg>"#;
        let metrics = metrics_from_svg(svg).unwrap();
        assert_eq!(metrics.canvas_width, 320.0);
        assert_eq!(metrics.canvas_height, 180.0);
    }

    #[test]
    fn crop_updates_view_box_and_output_dimensions() {
        let svg = r#"<svg width="200" height="100" viewBox="0 0 100 50" xmlns="http://www.w3.org/2000/svg"></svg>"#;
        let result = transform_svg(
            svg,
            &TransformOptions {
                crop_width: Some(50),
                crop_height: Some(20),
                crop_x: Some(20),
                crop_y: Some(10),
                crop_anchor: CropAnchor::Center,
                resize_width: None,
                resize_height: None,
                resize_longest_side: None,
            },
        )
        .unwrap();

        assert_eq!(result.output_width, 50);
        assert_eq!(result.output_height, 20);
        assert!(result.document.contains(r#"viewBox="10 5 25 10""#));
        assert!(result.document.contains(r#"width="50""#));
        assert!(result.document.contains(r#"height="20""#));
    }

    #[test]
    fn resize_overrides_output_dimensions() {
        let svg = r#"<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg"></svg>"#;
        let result = transform_svg(
            svg,
            &TransformOptions {
                crop_width: None,
                crop_height: None,
                crop_x: None,
                crop_y: None,
                crop_anchor: CropAnchor::Center,
                resize_width: Some(640),
                resize_height: Some(320),
                resize_longest_side: None,
            },
        )
        .unwrap();

        assert_eq!(result.output_width, 640);
        assert_eq!(result.output_height, 320);
        assert!(result.document.contains(r#"width="640""#));
        assert!(result.document.contains(r#"height="320""#));
    }

    #[test]
    fn rasterizes_svg_to_requested_size() {
        let svg = r##"
<svg width="16" height="16" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="16" height="16" fill="#ff0000" />
</svg>
"##;
        let image = rasterize_svg(svg, 32, 24, &PathBuf::from("/tmp/test.svg")).unwrap();
        assert_eq!(image.width(), 32);
        assert_eq!(image.height(), 24);
    }
}
