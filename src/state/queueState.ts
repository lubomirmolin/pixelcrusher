export type JobSnapshot = {
  id: string;
  input_path: string;
  status: string;
  progress: number;
  message: string;
};

export type JobResultEntry = {
  id: string;
  input_path: string;
  output_path: string;
  status: string;
  input_size: number;
  output_size: number;
  size_delta_percent: number;
  stages_run: string[];
  duration_ms: number;
};

export type QueueEventPayload = {
  job: JobSnapshot;
  result?: JobResultEntry | null;
};

export type QueueState = {
  jobs: Record<string, JobSnapshot>;
  recent: JobResultEntry[];
  lastError: string | null;
};

export const initialQueueState: QueueState = {
  jobs: {},
  recent: [],
  lastError: null,
};

type QueueAction =
  | { type: 'UPSERT_JOB'; payload: JobSnapshot }
  | { type: 'INGEST_EVENT'; payload: QueueEventPayload }
  | { type: 'SET_RECENT'; payload: JobResultEntry[] }
  | { type: 'QUEUE_ERROR'; payload: string }
  | { type: 'CLEAR_QUEUE_ERROR' };

export function queueReducer(state: QueueState, action: QueueAction): QueueState {
  switch (action.type) {
    case 'UPSERT_JOB':
      return {
        ...state,
        jobs: {
          ...state.jobs,
          [action.payload.id]: action.payload,
        },
      };
    case 'INGEST_EVENT': {
      const isFailure = action.payload.job.status === 'failed';

      const next = {
        ...state,
        jobs: {
          ...state.jobs,
          [action.payload.job.id]: action.payload.job,
        },
        lastError: isFailure
          ? action.payload.job.message || `Processing failed for ${action.payload.job.input_path}`
          : state.lastError,
      };

      if (!action.payload.result) {
        return next;
      }

      const withoutCurrent = next.recent.filter((item) => item.id !== action.payload.result!.id);
      return {
        ...next,
        recent: [action.payload.result, ...withoutCurrent].slice(0, 20),
      };
    }
    case 'SET_RECENT':
      return {
        ...state,
        recent: action.payload,
      };
    case 'QUEUE_ERROR':
      return {
        ...state,
        lastError: action.payload,
      };
    case 'CLEAR_QUEUE_ERROR':
      return {
        ...state,
        lastError: null,
      };
    default:
      return state;
  }
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}
