use std::fs::File;
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssetFormat {
    Jpeg,
    Png,
    Svg,
    Gif,
    Webp,
    Unknown,
}

impl AssetFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            AssetFormat::Jpeg => "jpeg",
            AssetFormat::Png => "png",
            AssetFormat::Svg => "svg",
            AssetFormat::Gif => "gif",
            AssetFormat::Webp => "webp",
            AssetFormat::Unknown => "unknown",
        }
    }

    pub fn output_extension(&self) -> &'static str {
        match self {
            AssetFormat::Jpeg => "jpg",
            AssetFormat::Png => "png",
            AssetFormat::Svg => "svg",
            AssetFormat::Gif => "gif",
            AssetFormat::Webp => "webp",
            AssetFormat::Unknown => "bin",
        }
    }

    pub fn from_output_format(value: &str) -> Option<AssetFormat> {
        match value.trim().to_lowercase().as_str() {
            "jpg" | "jpeg" => Some(AssetFormat::Jpeg),
            "png" => Some(AssetFormat::Png),
            "gif" => Some(AssetFormat::Gif),
            "svg" => Some(AssetFormat::Svg),
            "webp" => Some(AssetFormat::Webp),
            _ => None,
        }
    }

    pub fn is_raster(&self) -> bool {
        matches!(
            self,
            AssetFormat::Png | AssetFormat::Jpeg | AssetFormat::Gif | AssetFormat::Webp
        )
    }
}

pub fn detect_format(path: &Path) -> AssetFormat {
    if let Some(by_ext) = detect_by_extension(path) {
        return by_ext;
    }

    let mut buf = [0_u8; 512];
    if let Ok(mut file) = File::open(path) {
        if let Ok(read) = file.read(&mut buf) {
            return detect_by_bytes(&buf[..read]);
        }
    }

    AssetFormat::Unknown
}

pub fn detect_by_extension(path: &Path) -> Option<AssetFormat> {
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => Some(AssetFormat::Jpeg),
        "png" => Some(AssetFormat::Png),
        "svg" => Some(AssetFormat::Svg),
        "gif" => Some(AssetFormat::Gif),
        "webp" => Some(AssetFormat::Webp),
        _ => None,
    }
}

pub fn detect_by_bytes(bytes: &[u8]) -> AssetFormat {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return AssetFormat::Jpeg;
    }

    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return AssetFormat::Png;
    }

    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return AssetFormat::Gif;
    }

    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return AssetFormat::Webp;
    }

    let ascii = String::from_utf8_lossy(bytes).to_lowercase();
    if ascii.contains("<svg") {
        return AssetFormat::Svg;
    }

    AssetFormat::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_jpeg_magic() {
        assert_eq!(
            detect_by_bytes(&[0xFF, 0xD8, 0xFF, 0xAA]),
            AssetFormat::Jpeg
        );
    }

    #[test]
    fn detects_svg_by_content() {
        assert_eq!(
            detect_by_bytes(br#"<?xml version='1.0'?><svg></svg>"#),
            AssetFormat::Svg
        );
    }

    #[test]
    fn parses_requested_output_format() {
        assert_eq!(
            AssetFormat::from_output_format("png"),
            Some(AssetFormat::Png)
        );
        assert_eq!(
            AssetFormat::from_output_format("JPG"),
            Some(AssetFormat::Jpeg)
        );
        assert_eq!(
            AssetFormat::from_output_format("jpeg"),
            Some(AssetFormat::Jpeg)
        );
        assert_eq!(
            AssetFormat::from_output_format("gif"),
            Some(AssetFormat::Gif)
        );
        assert_eq!(
            AssetFormat::from_output_format("svg"),
            Some(AssetFormat::Svg)
        );
        assert_eq!(
            AssetFormat::from_output_format("webp"),
            Some(AssetFormat::Webp)
        );
    }

    #[test]
    fn detects_webp_magic() {
        assert_eq!(
            detect_by_bytes(b"RIFF\x01\x02\x03\x04WEBPVP8 "),
            AssetFormat::Webp
        );
    }
}
