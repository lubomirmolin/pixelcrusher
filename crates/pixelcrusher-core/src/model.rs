use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CompressionOptions {
    pub quality: u8,
    pub png_quant_quality_min: u8,
    pub png_quant_quality_max: u8,
    pub run_png_quant: bool,
    pub png_quant_speed: u8,
    pub run_pngcrush: bool,
    pub run_zopfli: bool,
    pub run_pngout: bool,
    pub svg_multipass: bool,
    pub gif_optimization_level: u8,
    pub gif_lossy_level: u16,
}

impl Default for CompressionOptions {
    fn default() -> Self {
        Self {
            quality: 82,
            png_quant_quality_min: 60,
            png_quant_quality_max: 90,
            run_png_quant: false,
            png_quant_speed: 3,
            run_pngcrush: true,
            run_zopfli: false,
            run_pngout: false,
            svg_multipass: true,
            gif_optimization_level: 3,
            gif_lossy_level: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct TransformOptions {
    pub crop_width: Option<u32>,
    pub crop_height: Option<u32>,
    pub crop_x: Option<u32>,
    pub crop_y: Option<u32>,
    pub crop_anchor: CropAnchor,
    pub resize_width: Option<u32>,
    pub resize_height: Option<u32>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum CropAnchor {
    #[default]
    Center,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ProcessingOptions {
    pub trim_transparent: bool,
    pub transform: TransformOptions,
    pub output_format: Option<String>,
    pub compression: CompressionOptions,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessingReport {
    pub source_path: String,
    pub destination_path: String,
    pub asset_format: String,
    pub input_bytes: u64,
    pub output_bytes: u64,
    pub elapsed_ms: u128,
    pub applied_stages: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolResolutionKind {
    EnvironmentOverride,
    Bundled,
    HostPath,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolAvailability {
    pub tool: String,
    pub is_available: bool,
    pub resolved_path: Option<String>,
    pub resolution: Option<ToolResolutionKind>,
}
