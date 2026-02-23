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
pub struct DimensionsOptions {
    pub crop_width: Option<u32>,
    pub crop_height: Option<u32>,
    pub resize_width: Option<u32>,
    pub resize_height: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ProcessOptions {
    pub trim_transparent: bool,
    pub dimensions: DimensionsOptions,
    pub compression: CompressionOptions,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessResult {
    pub input_path: String,
    pub output_path: String,
    pub format: String,
    pub input_size: u64,
    pub output_size: u64,
    pub duration_ms: u128,
    pub stages_run: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolStatus {
    pub name: String,
    pub available: bool,
    pub source: Option<String>,
    pub source_kind: Option<String>,
}
