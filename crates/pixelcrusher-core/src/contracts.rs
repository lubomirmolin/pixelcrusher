use serde::{Deserialize, Serialize};

use crate::model::{ProcessingOptions, ProcessingReport};

#[derive(Debug, Deserialize)]
pub struct CliProcessRequest {
    pub input_path: String,
    pub output_dir: String,
    #[serde(default)]
    pub options: ProcessingOptions,
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", content = "payload", rename_all = "snake_case")]
pub enum CliStreamEvent {
    Status(StatusPayload),
    Finished(FinishedPayload),
}

#[derive(Debug, Serialize)]
pub struct StatusPayload {
    pub phase: String,
    pub message: String,
    pub progress_percent: u8,
}

#[derive(Debug, Serialize)]
pub struct FinishedPayload {
    pub success: bool,
    pub report: Option<ProcessingReport>,
    pub error: Option<String>,
}
