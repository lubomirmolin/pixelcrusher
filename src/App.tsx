import { useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
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
import {
  compareSemver,
  describeUpdateState,
  normalizeReleaseVersion,
  type UpdateCheckState,
} from './state/updateState';

const TERMINAL_JOB_STATUSES = new Set(['completed', 'failed']);
const RELEASES_LATEST_URL = 'https://api.github.com/repos/lubomirmolin/pixelcrusher/releases/latest';
const RELEASES_PAGE_URL = 'https://github.com/lubomirmolin/pixelcrusher/releases';

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

function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

function App() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [diagnostics, setDiagnostics] = useState<ToolStatus[]>([]);
  const [dragActive, setDragActive] = useState(false);
  const [appVersion, setAppVersion] = useState('0.0.0');
  const [updateState, setUpdateState] = useState<UpdateCheckState>({ status: 'idle' });

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
  const optionsPayloadRef = useRef<Record<string, unknown> | null>(null);

  useEffect(() => {
    invoke<ToolStatus[]>('startup_diagnostics').then(setDiagnostics).catch(() => undefined);
    invoke<JobResultEntry[]>('recent_results')
      .then((items) => {
        dispatch({ type: 'SET_RECENT', payload: items });
      })
      .catch(() => undefined);

    invoke<string>('app_version')
      .then((version) => {
        const normalized = normalizeReleaseVersion(version);
        if (normalized) {
          setAppVersion(normalized);
        }
      })
      .catch(() => undefined);

    let unlistenQueue: (() => void) | undefined;
    let unlistenDragDrop: (() => void) | undefined;

    listen<QueueEventPayload>('queue://event', (event) => {
      dispatch({ type: 'INGEST_EVENT', payload: event.payload });
    })
      .then((off) => {
        unlistenQueue = off;
      })
      .catch(() => undefined);

    if (isTauriRuntime()) {
      getCurrentWebview()
        .onDragDropEvent((event) => {
          if (event.payload.type === 'enter' || event.payload.type === 'over') {
            setDragActive(true);
            return;
          }

          if (event.payload.type === 'leave') {
            setDragActive(false);
            return;
          }

          if (event.payload.type === 'drop') {
            setDragActive(false);
            void enqueuePaths(event.payload.paths);
          }
        })
        .then((off) => {
          unlistenDragDrop = off;
        })
        .catch(() => undefined);
    }

    return () => {
      unlistenQueue?.();
      unlistenDragDrop?.();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
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

  useEffect(() => {
    optionsPayloadRef.current = optionsPayload;
  }, [optionsPayload]);

  const enqueuePaths = async (paths: string[]) => {
    const normalized = Array.from(
      new Set(paths.map((value) => value.trim()).filter((value) => value.length > 0)),
    );

    if (!normalized.length) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'No valid file paths were provided. Choose files from the system dialog or drop files into the window.',
      });
      return;
    }

    dispatch({ type: 'CLEAR_QUEUE_ERROR' });

    try {
      await invoke('enqueue_paths', {
        paths: normalized,
        options: optionsPayloadRef.current ?? optionsPayload,
      });
    } catch (error) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: `Queue start failed: ${error instanceof Error ? error.message : String(error)}`,
      });
    }
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

  const onOpenSystemPicker = async () => {
    if (!isTauriRuntime()) {
      fileInputRef.current?.click();
      return;
    }

    try {
      const selected = await invoke<string[]>('select_input_files');
      await enqueuePaths(selected ?? []);
    } catch (error) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: `Unable to open file picker: ${error instanceof Error ? error.message : String(error)}`,
      });
    }
  };

  const onCheckForUpdates = async () => {
    setUpdateState({ status: 'checking' });

    try {
      const response = await fetch(RELEASES_LATEST_URL, {
        headers: {
          Accept: 'application/vnd.github+json',
        },
      });

      if (!response.ok) {
        throw new Error(`GitHub release check failed with HTTP ${response.status}`);
      }

      const payload = (await response.json()) as {
        tag_name?: string;
        html_url?: string;
      };

      const latestVersion = normalizeReleaseVersion(payload.tag_name ?? '');
      if (!latestVersion) {
        throw new Error('Latest release tag is not a semantic version (expected vX.Y.Z).');
      }

      if (compareSemver(latestVersion, appVersion) > 0) {
        setUpdateState({
          status: 'available',
          latestVersion,
          releaseUrl: payload.html_url || RELEASES_PAGE_URL,
        });
      } else {
        setUpdateState({ status: 'up-to-date', latestVersion });
      }
    } catch (error) {
      setUpdateState({
        status: 'error',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const openReleasePage = async (url: string) => {
    try {
      await invoke('open_external_url', { url });
    } catch {
      setUpdateState({
        status: 'error',
        reason: 'Unable to open the release page from this environment.',
      });
    }
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
            <span className="version-badge">v{appVersion}</span>
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
            <button className="primary-btn" onClick={() => void onOpenSystemPicker()}>
              Choose files
            </button>
            <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} />
          </div>

          <article className="card queue-card">
            <div className="card-header">
              <h3>Active Queue</h3>
              <span className="card-subtext">{completedCount} completed this session</span>
            </div>

            {queueState.lastError ? <p className="queue-error">{queueState.lastError}</p> : null}

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
            <div className="card-header compact-header">
              <h3>Updates</h3>
              <button
                className="ghost-btn"
                disabled={updateState.status === 'checking'}
                onClick={() => void onCheckForUpdates()}
              >
                {updateState.status === 'checking' ? 'Checking…' : 'Check for Updates'}
              </button>
            </div>
            <p className="update-status-text">{describeUpdateState(updateState, appVersion)}</p>
            {updateState.status === 'available' ? (
              <button className="ghost-btn" onClick={() => void openReleasePage(updateState.releaseUrl)}>
                Open Release Page
              </button>
            ) : null}
          </section>

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
