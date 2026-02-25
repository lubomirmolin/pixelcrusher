use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct JobSnapshot {
    pub id: String,
    pub input_path: String,
    pub status: String,
    pub progress: u8,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ToolStatusSnapshot {
    pub name: String,
    pub available: bool,
    pub source: Option<String>,
    pub source_kind: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct JobResultEntry {
    pub id: String,
    pub input_path: String,
    pub output_path: String,
    pub status: String,
    pub input_size: u64,
    pub output_size: u64,
    pub size_delta_percent: f64,
    pub stages_run: Vec<String>,
    pub duration_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct QueueEventPayload {
    pub job: JobSnapshot,
    pub result: Option<JobResultEntry>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct DownloadedUpdatePayload {
    pub path: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct UpdateInstallResult {
    pub mode: String,
    pub message: String,
    pub command: Option<String>,
}
