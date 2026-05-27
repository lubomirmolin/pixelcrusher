use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use pixelcrusher_core::queue::QueueMachine;

use crate::models::{JobResultEntry, JobSnapshot, ToolStatusSnapshot};

pub(crate) struct RuntimeState {
    pub queue_machine: Mutex<QueueMachine>,
    pub jobs: Mutex<HashMap<String, JobSnapshot>>,
    pub recent_results: Mutex<Vec<JobResultEntry>>,
    pub diagnostics: Vec<ToolStatusSnapshot>,
    pub output_dir: PathBuf,
    pub bundled_tools_dir: Option<PathBuf>,
    pub model_root_dir: PathBuf,
}

impl RuntimeState {
    pub fn new(
        diagnostics: Vec<ToolStatusSnapshot>,
        output_dir: PathBuf,
        bundled_tools_dir: Option<PathBuf>,
        model_root_dir: PathBuf,
    ) -> Self {
        Self {
            queue_machine: Mutex::new(QueueMachine::default()),
            jobs: Mutex::new(HashMap::new()),
            recent_results: Mutex::new(Vec::new()),
            diagnostics,
            output_dir,
            bundled_tools_dir,
            model_root_dir,
        }
    }
}

#[derive(Clone)]
pub(crate) struct AppState {
    pub runtime: Arc<RuntimeState>,
}

impl AppState {
    pub fn new(runtime: RuntimeState) -> Self {
        Self {
            runtime: Arc::new(runtime),
        }
    }
}
