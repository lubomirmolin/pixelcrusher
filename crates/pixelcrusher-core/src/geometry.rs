use crate::model::CropAnchor;
use image::{DynamicImage, RgbaImage, imageops::FilterType};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CropBox {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

pub fn center_crop_box(src_w: u32, src_h: u32, target_w: u32, target_h: u32) -> CropBox {
    anchored_crop_box(src_w, src_h, target_w, target_h, CropAnchor::Center)
}

pub fn anchored_crop_box(
    src_w: u32,
    src_h: u32,
    target_w: u32,
    target_h: u32,
    anchor: CropAnchor,
) -> CropBox {
    let width = target_w.min(src_w).max(1);
    let height = target_h.min(src_h).max(1);
    let x = match anchor {
        CropAnchor::Center | CropAnchor::TopLeft | CropAnchor::BottomLeft => 0,
        CropAnchor::TopRight | CropAnchor::BottomRight => src_w.saturating_sub(width),
    };
    let y = match anchor {
        CropAnchor::Center | CropAnchor::TopLeft | CropAnchor::TopRight => 0,
        CropAnchor::BottomLeft | CropAnchor::BottomRight => src_h.saturating_sub(height),
    };

    let (x, y) = if anchor == CropAnchor::Center {
        (
            (src_w.saturating_sub(width)) / 2,
            (src_h.saturating_sub(height)) / 2,
        )
    } else {
        (x, y)
    };

    CropBox {
        x,
        y,
        width,
        height,
    }
}

pub fn explicit_crop_box(
    src_w: u32,
    src_h: u32,
    target_w: u32,
    target_h: u32,
    crop_x: u32,
    crop_y: u32,
) -> CropBox {
    let width = target_w.min(src_w).max(1);
    let height = target_h.min(src_h).max(1);
    let max_x = src_w.saturating_sub(width);
    let max_y = src_h.saturating_sub(height);

    CropBox {
        x: crop_x.min(max_x),
        y: crop_y.min(max_y),
        width,
        height,
    }
}

pub fn trim_transparent_bounds(rgba: &RgbaImage) -> Option<CropBox> {
    let (w, h) = rgba.dimensions();
    let mut min_x = w;
    let mut min_y = h;
    let mut max_x = 0;
    let mut max_y = 0;
    let mut found = false;

    for y in 0..h {
        for x in 0..w {
            let pixel = rgba.get_pixel(x, y);
            if pixel.0[3] > 0 {
                found = true;
                min_x = min_x.min(x);
                min_y = min_y.min(y);
                max_x = max_x.max(x);
                max_y = max_y.max(y);
            }
        }
    }

    if !found {
        return None;
    }

    Some(CropBox {
        x: min_x,
        y: min_y,
        width: max_x - min_x + 1,
        height: max_y - min_y + 1,
    })
}

pub fn crop_image(img: DynamicImage, crop: CropBox) -> DynamicImage {
    img.crop_imm(crop.x, crop.y, crop.width, crop.height)
}

pub fn resize_image(img: DynamicImage, width: u32, height: u32) -> DynamicImage {
    img.resize_exact(width.max(1), height.max(1), FilterType::Lanczos3)
}

pub fn fit_with_max_longest_side(width: u32, height: u32, max_longest_side: u32) -> (u32, u32) {
    let width = width.max(1);
    let height = height.max(1);
    let max_longest_side = max_longest_side.max(1);
    let current_longest = width.max(height);

    if current_longest <= max_longest_side {
        return (width, height);
    }

    let scale = f64::from(max_longest_side) / f64::from(current_longest);
    let next_width = (f64::from(width) * scale).round().max(1.0) as u32;
    let next_height = (f64::from(height) * scale).round().max(1.0) as u32;
    (next_width, next_height)
}

pub fn maybe_apply_crop_resize(
    mut image: DynamicImage,
    crop_box: Option<CropBox>,
    resize_dims: Option<(u32, u32)>,
    resize_longest_side: Option<u32>,
) -> DynamicImage {
    if let Some(crop) = crop_box {
        image = crop_image(image, crop);
    }

    if let Some((resize_w, resize_h)) = resize_dims {
        image = resize_image(image, resize_w, resize_h);
    } else if let Some(max_longest_side) = resize_longest_side {
        let (next_width, next_height) =
            fit_with_max_longest_side(image.width(), image.height(), max_longest_side);
        image = resize_image(image, next_width, next_height);
    }

    image
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    #[test]
    fn center_crop_math_is_correct() {
        let crop = center_crop_box(1000, 500, 400, 300);
        assert_eq!(
            crop,
            CropBox {
                x: 300,
                y: 100,
                width: 400,
                height: 300
            }
        );
    }

    #[test]
    fn anchored_crop_honors_corner_anchor() {
        let crop = anchored_crop_box(1000, 500, 400, 300, CropAnchor::BottomRight);
        assert_eq!(
            crop,
            CropBox {
                x: 600,
                y: 200,
                width: 400,
                height: 300
            }
        );
    }

    #[test]
    fn explicit_crop_box_is_clamped_to_bounds() {
        let crop = explicit_crop_box(1000, 500, 400, 300, 900, 450);
        assert_eq!(
            crop,
            CropBox {
                x: 600,
                y: 200,
                width: 400,
                height: 300
            }
        );
    }

    #[test]
    fn transparent_trim_finds_bounds() {
        let mut img = RgbaImage::from_pixel(6, 6, Rgba([0, 0, 0, 0]));
        img.put_pixel(2, 1, Rgba([255, 0, 0, 255]));
        img.put_pixel(4, 4, Rgba([255, 0, 0, 255]));
        let bounds = trim_transparent_bounds(&img).unwrap();
        assert_eq!(
            bounds,
            CropBox {
                x: 2,
                y: 1,
                width: 3,
                height: 4
            }
        );
    }
}
