use std::collections::HashMap;

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Diagnosing,
    Processing,
    Optimizing,
    Completed,
    Failed,
}

impl JobState {
    pub fn as_str(&self) -> &'static str {
        match self {
            JobState::Queued => "queued",
            JobState::Diagnosing => "diagnosing",
            JobState::Processing => "processing",
            JobState::Optimizing => "optimizing",
            JobState::Completed => "completed",
            JobState::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobEvent {
    StartDiagnostics,
    StartProcessing,
    StartOptimizing,
    Complete,
    Fail,
}

#[derive(Debug, Error)]
pub enum QueueError {
    #[error("job not found: {0}")]
    JobNotFound(String),
    #[error("invalid transition: {from:?} -> {event:?}")]
    InvalidTransition { from: JobState, event: JobEvent },
}

#[derive(Default)]
pub struct QueueMachine {
    states: HashMap<String, JobState>,
}

impl QueueMachine {
    pub fn enqueue(&mut self, job_id: impl Into<String>) {
        self.states.insert(job_id.into(), JobState::Queued);
    }

    pub fn state(&self, job_id: &str) -> Option<JobState> {
        self.states.get(job_id).copied()
    }

    pub fn transition(&mut self, job_id: &str, event: JobEvent) -> Result<JobState, QueueError> {
        let current = self
            .states
            .get(job_id)
            .copied()
            .ok_or_else(|| QueueError::JobNotFound(job_id.to_string()))?;

        let next = match (current, event) {
            (JobState::Queued, JobEvent::StartDiagnostics) => JobState::Diagnosing,
            (JobState::Diagnosing, JobEvent::StartProcessing) => JobState::Processing,
            (JobState::Processing, JobEvent::StartOptimizing) => JobState::Optimizing,
            (JobState::Optimizing, JobEvent::Complete) => JobState::Completed,
            (_, JobEvent::Fail) => JobState::Failed,
            _ => {
                return Err(QueueError::InvalidTransition {
                    from: current,
                    event,
                });
            }
        };

        self.states.insert(job_id.to_string(), next);
        Ok(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_transitions_happy_path() {
        let mut queue = QueueMachine::default();
        queue.enqueue("job-1");

        assert_eq!(
            queue
                .transition("job-1", JobEvent::StartDiagnostics)
                .unwrap(),
            JobState::Diagnosing
        );
        assert_eq!(
            queue
                .transition("job-1", JobEvent::StartProcessing)
                .unwrap(),
            JobState::Processing
        );
        assert_eq!(
            queue
                .transition("job-1", JobEvent::StartOptimizing)
                .unwrap(),
            JobState::Optimizing
        );
        assert_eq!(
            queue.transition("job-1", JobEvent::Complete).unwrap(),
            JobState::Completed
        );
    }

    #[test]
    fn queue_invalid_transition_fails() {
        let mut queue = QueueMachine::default();
        queue.enqueue("job-2");

        let err = queue
            .transition("job-2", JobEvent::StartOptimizing)
            .unwrap_err();
        assert!(matches!(err, QueueError::InvalidTransition { .. }));
    }

    #[test]
    fn queue_fail_from_anywhere() {
        let mut queue = QueueMachine::default();
        queue.enqueue("job-3");
        let _ = queue.transition("job-3", JobEvent::Fail).unwrap();
        assert_eq!(queue.state("job-3").unwrap(), JobState::Failed);
    }
}
