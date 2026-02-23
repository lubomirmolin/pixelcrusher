use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompressionOptions {
    pub quality: u8,
    pub png_quant_quality_min: u8,
    pub png_quant_quality_max: u8,
    pub run_zopfli: bool,
    pub run_pngout: bool,
}

impl Default for CompressionOptions {
    fn default() -> Self {
        Self {
            quality: 82,
            png_quant_quality_min: 60,
            png_quant_quality_max: 90,
            run_zopfli: false,
            run_pngout: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DimensionsOptions {
    pub crop_width: Option<u32>,
    pub crop_height: Option<u32>,
    pub resize_width: Option<u32>,
    pub resize_height: Option<u32>,
}

impl Default for DimensionsOptions {
    fn default() -> Self {
        Self {
            crop_width: None,
            crop_height: None,
            resize_width: None,
            resize_height: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
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
}
