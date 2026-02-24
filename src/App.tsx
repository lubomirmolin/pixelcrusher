import { useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import './App.css';
import {
  formatBytes,
  initialQueueState,
  type JobResultEntry,
  queueReducer,
  type QueueEventPayload,
} from './state/queueState';
import {
  formatToolSourceLabel,
  summarizeBundledDiagnostics,
  summarizeStackSource,
  type ToolStatus,
} from './state/toolDiagnostics';

const APP_VERSION = 'v0.1.0';
const TERMINAL_JOB_STATUSES = new Set(['completed', 'failed']);

function basename(filePath: string): string {
  const parts = filePath.split(/[\\/]/).filter(Boolean);
  return parts.at(-1) ?? filePath;
}

function dirname(filePath: string): string {
  const normalized = filePath.replace(/\\/g, '/');
  const index = normalized.lastIndexOf('/');
  return index > 0 ? normalized.slice(0, index) : normalized;
}

function asOptionalDimension(value: string): number | null {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return null;
  }

  return Math.floor(num);
}

function toHumanStatus(status: string): string {
  if (!status) {
    return 'Idle';
  }

  return status
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function App() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [diagnostics, setDiagnostics] = useState<ToolStatus[]>([]);
  const [dragActive, setDragActive] = useState(false);

  const [trimTransparent, setTrimTransparent] = useState(true);
  const [cropWidth, setCropWidth] = useState('');
  const [cropHeight, setCropHeight] = useState('');
  const [resizeWidth, setResizeWidth] = useState('');
  const [resizeHeight, setResizeHeight] = useState('');
  const [quality, setQuality] = useState(82);
  const [pngQMin, setPngQMin] = useState(60);
  const [pngQMax, setPngQMax] = useState(90);
  const [runPngQuant, setRunPngQuant] = useState(false);
  const [runPngcrush, setRunPngcrush] = useState(true);
  const [runZopfli, setRunZopfli] = useState(false);
  const [runPngout, setRunPngout] = useState(false);

  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    invoke<ToolStatus[]>('startup_diagnostics').then(setDiagnostics);
    invoke<JobResultEntry[]>('recent_results').then((items) => {
      dispatch({ type: 'SET_RECENT', payload: items });
    });

    const unlistenPromise = listen<QueueEventPayload>('queue://event', (event) => {
      dispatch({ type: 'INGEST_EVENT', payload: event.payload });
    });

    return () => {
      unlistenPromise.then((off) => off());
    };
  }, []);

  const activeJobs = useMemo(
    () =>
      Object.values(queueState.jobs)
        .filter((job) => !TERMINAL_JOB_STATUSES.has(job.status))
        .sort((a, b) => b.progress - a.progress),
    [queueState.jobs],
  );

  const completedCount = useMemo(
    () => Object.values(queueState.jobs).filter((job) => job.status === 'completed').length,
    [queueState.jobs],
  );

  const currentJob = activeJobs[0] ?? null;
  const queueStateLabel = currentJob ? `${activeJobs.length} active` : 'idle';
  const queueMessage = currentJob ? currentJob.message || toHumanStatus(currentJob.status) : 'Queue is idle';
  const statusReady = useMemo(() => summarizeBundledDiagnostics(diagnostics), [diagnostics]);
  const stackSource = useMemo(() => summarizeStackSource(diagnostics), [diagnostics]);

  const recentOutputFolder = useMemo(() => {
    const latest = queueState.recent[0];
    return latest ? dirname(latest.output_path) : '';
  }, [queueState.recent]);

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: trimTransparent,
      dimensions: {
        crop_width: asOptionalDimension(cropWidth),
        crop_height: asOptionalDimension(cropHeight),
        resize_width: asOptionalDimension(resizeWidth),
        resize_height: asOptionalDimension(resizeHeight),
      },
      compression: {
        quality,
        png_quant_quality_min: Math.min(pngQMin, pngQMax),
        png_quant_quality_max: Math.max(pngQMin, pngQMax),
        run_png_quant: runPngQuant,
        run_pngcrush: runPngcrush,
        run_zopfli: runZopfli,
        run_pngout: runPngout,
      },
    }),
    [
      cropHeight,
      cropWidth,
      pngQMax,
      pngQMin,
      quality,
      resizeHeight,
      resizeWidth,
      runPngQuant,
      runPngcrush,
      runPngout,
      runZopfli,
      trimTransparent,
    ],
  );

  const enqueuePaths = async (paths: string[]) => {
    if (!paths.length) return;
    await invoke('enqueue_paths', { paths, options: optionsPayload });
  };

  const onDropFiles: React.DragEventHandler<HTMLDivElement> = async (event) => {
    event.preventDefault();
    setDragActive(false);
    const files = Array.from(event.dataTransfer.files ?? []);
    const paths = files
      .map((file) => (file as unknown as { path?: string }).path)
      .filter((path): path is string => !!path);

    await enqueuePaths(paths);
  };

  const onChooseFiles = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    const paths = files
      .map((file) => (file as unknown as { path?: string }).path)
      .filter((path): path is string => !!path);

    await enqueuePaths(paths);
  };

  return (
    <div className="app-shell">
      <main className="split-pane">
        <section className="left-pane">
          <header className="title-card">
            <div>
              <h1>PixelCrusher</h1>
              <p>Fast image optimization queue for production assets</p>
            </div>
            <span className="version-badge">{APP_VERSION}</span>
          </header>

          <div
            className={`drop-zone ${dragActive ? 'active' : ''}`}
            onDragEnter={() => setDragActive(true)}
            onDragOver={(event) => {
              event.preventDefault();
              setDragActive(true);
            }}
            onDragLeave={() => setDragActive(false)}
            onDrop={onDropFiles}
          >
            <div className="drop-zone-icon" aria-hidden="true">
              ⤓
            </div>
            <h2>Drop files to crush</h2>
            <p className="drop-helper">Drag images here or pick files · jpg/jpeg · png · svg · gif</p>
            <button className="primary-btn" onClick={() => fileInputRef.current?.click()}>
              Choose files
            </button>
            <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} />
          </div>

          <article className="card queue-card">
            <div className="card-header">
              <h3>Active Queue</h3>
              <span className="card-subtext">{completedCount} completed this session</span>
            </div>

            <div className="queue-main-row">
              <p className="queue-status">{queueMessage}</p>
              <span className="queue-percent">{currentJob ? `${currentJob.progress}%` : '0%'}</span>
            </div>

            <div className="progress-wrap" role="progressbar" aria-valuenow={currentJob?.progress ?? 0}>
              <div className="progress-bar" style={{ width: `${currentJob?.progress ?? 0}%` }} />
            </div>

            {currentJob ? (
              <p className="queue-file" title={currentJob.input_path}>
                {basename(currentJob.input_path)}
              </p>
            ) : (
              <p className="queue-empty">No active jobs</p>
            )}

            <div className="queue-actions">
              <button
                className="ghost-btn"
                disabled
                title="Cancellation controls are not available in this build"
              >
                Cancel queued
              </button>
              <button
                className="ghost-btn danger"
                disabled
                title="Cancellation controls are not available in this build"
              >
                Cancel all
              </button>
            </div>
          </article>

          <article className="card recent-card">
            <div className="card-header">
              <h3>Recent Results</h3>
              <button
                className="ghost-btn"
                disabled={!recentOutputFolder}
                onClick={() => {
                  if (recentOutputFolder) {
                    invoke('reveal_in_finder', { path: recentOutputFolder });
                  }
                }}
              >
                Reveal Output Folder
              </button>
            </div>

            {queueState.recent.length === 0 ? (
              <p className="empty-state">No completed jobs yet</p>
            ) : (
              <div className="results-list">
                {queueState.recent.map((item) => (
                  <article key={item.id} className="result-row">
                    <div className="result-main">
                      <strong title={item.output_path}>{basename(item.output_path)}</strong>
                      <p>
                        {item.stages_run.join(' → ') || 'copy'} · {Math.round(item.duration_ms)} ms
                      </p>
                    </div>
                    <div className="result-meta">
                      <span>
                        {formatBytes(item.input_size)} → {formatBytes(item.output_size)}
                      </span>
                      <span className={item.size_delta_percent <= 0 ? 'delta-good' : 'delta-bad'}>
                        {item.size_delta_percent.toFixed(1)}%
                      </span>
                    </div>
                  </article>
                ))}
              </div>
            )}
          </article>
        </section>

        <aside className="right-pane">
          <section className="rail-section">
            <h3>General</h3>
            <label className="checkbox-row">
              <input
                type="checkbox"
                checked={trimTransparent}
                onChange={(event) => setTrimTransparent(event.target.checked)}
              />
              <span>Trim transparent bounds (PNG)</span>
            </label>
          </section>

          <section className="rail-section">
            <h3>Dimensions</h3>
            <div className="grid-2">
              <label>
                Crop W
                <input
                  type="number"
                  inputMode="numeric"
                  value={cropWidth}
                  placeholder="Auto"
                  onChange={(event) => setCropWidth(event.target.value)}
                />
              </label>
              <label>
                Crop H
                <input
                  type="number"
                  inputMode="numeric"
                  value={cropHeight}
                  placeholder="Auto"
                  onChange={(event) => setCropHeight(event.target.value)}
                />
              </label>
              <label>
                Resize W
                <input
                  type="number"
                  inputMode="numeric"
                  value={resizeWidth}
                  placeholder="Original"
                  onChange={(event) => setResizeWidth(event.target.value)}
                />
              </label>
              <label>
                Resize H
                <input
                  type="number"
                  inputMode="numeric"
                  value={resizeHeight}
                  placeholder="Original"
                  onChange={(event) => setResizeHeight(event.target.value)}
                />
              </label>
            </div>
          </section>

          <section className="rail-section">
            <h3>Optimizers</h3>
            <div className="rail-fields">
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={runPngQuant}
                  onChange={(event) => setRunPngQuant(event.target.checked)}
                />
                <span>Run pngquant</span>
              </label>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={runPngcrush}
                  onChange={(event) => setRunPngcrush(event.target.checked)}
                />
                <span>Run pngcrush</span>
              </label>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={runZopfli}
                  onChange={(event) => setRunZopfli(event.target.checked)}
                />
                <span>Run zopflipng</span>
              </label>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={runPngout}
                  onChange={(event) => setRunPngout(event.target.checked)}
                />
                <span>Run pngout</span>
              </label>
            </div>

            <div className="grid-2">
              <label>
                pngquant min
                <input
                  type="number"
                  value={pngQMin}
                  min={0}
                  max={100}
                  onChange={(event) => setPngQMin(Number(event.target.value))}
                />
              </label>
              <label>
                pngquant max
                <input
                  type="number"
                  value={pngQMax}
                  min={0}
                  max={100}
                  onChange={(event) => setPngQMax(Number(event.target.value))}
                />
              </label>
            </div>

            <ul className="tool-status-list">
              {diagnostics.map((tool) => {
                const sourceLabel = formatToolSourceLabel(tool);

                return (
                  <li key={tool.name}>
                    <span>{tool.name}</span>
                    <span className={`source-chip ${sourceLabel}`}>{sourceLabel}</span>
                  </li>
                );
              })}
            </ul>
          </section>

          <section className="rail-section">
            <h3>JPEG quality</h3>
            <label>
              Quality {quality}
              <input
                type="range"
                min={20}
                max={100}
                value={quality}
                onChange={(event) => setQuality(Number(event.target.value))}
              />
            </label>
          </section>
        </aside>
      </main>

      <footer className="status-bar">
        <div className="status-pill">Stack: {stackSource}</div>
        <div className="status-pill">Queue: {queueStateLabel}</div>
        <div className="status-pill">
          Bundled: {statusReady.ready}/{statusReady.total}
        </div>
        <div className={`status-pill ${statusReady.allReady ? 'ready' : 'warn'}`}>
          State: {statusReady.allReady ? 'ready' : 'degraded'}
        </div>
      </footer>
    </div>
  );
}

export default App;
