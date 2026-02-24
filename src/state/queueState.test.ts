import { describe, expect, it } from 'vitest';
import { initialQueueState, queueReducer } from './queueState';

describe('queueReducer', () => {
  it('upserts jobs', () => {
    const next = queueReducer(initialQueueState, {
      type: 'UPSERT_JOB',
      payload: {
        id: '1',
        input_path: '/tmp/a.png',
        status: 'queued',
        progress: 0,
        message: 'Queued',
      },
    });

    expect(next.jobs['1']?.status).toBe('queued');
  });

  it('ingests queue events and prepends result history', () => {
    const withJob = queueReducer(initialQueueState, {
      type: 'INGEST_EVENT',
      payload: {
        job: {
          id: '2',
          input_path: '/tmp/b.png',
          status: 'completed',
          progress: 100,
          message: 'Done',
        },
        result: {
          id: '2',
          input_path: '/tmp/b.png',
          output_path: '/tmp/out/b_pixelcrusher.png',
          status: 'completed',
          input_size: 1000,
          output_size: 500,
          size_delta_percent: -50,
          stages_run: ['pngquant', 'pngcrush'],
          duration_ms: 150,
        },
      },
    });

    expect(withJob.recent).toHaveLength(1);
    expect(withJob.recent[0].id).toBe('2');
  });

  it('stores queue errors from failed jobs for explicit UI reporting', () => {
    const failed = queueReducer(initialQueueState, {
      type: 'INGEST_EVENT',
      payload: {
        job: {
          id: '3',
          input_path: 'C:\\images\\broken.png',
          status: 'failed',
          progress: 100,
          message: 'Failed: missing optimizer binary',
        },
      },
    });

    expect(failed.lastError).toBe('Failed: missing optimizer binary');
  });

  it('allows setting and clearing enqueue/invoke errors', () => {
    const withError = queueReducer(initialQueueState, {
      type: 'QUEUE_ERROR',
      payload: 'No valid file paths were provided by the UI.',
    });

    expect(withError.lastError).toContain('No valid file paths');

    const cleared = queueReducer(withError, { type: 'CLEAR_QUEUE_ERROR' });
    expect(cleared.lastError).toBeNull();
  });
});
