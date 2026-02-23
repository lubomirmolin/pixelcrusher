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

type ToolStatus = {
  name: string;
  available: boolean;
  source?: string | null;
  source_kind?: string | null;
};

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
        .filter((job) => !['completed', 'failed'].includes(job.status))
        .sort((a, b) => b.progress - a.progress),
    [queueState.jobs],
  );

  const bundledDiagnosticsSummary = useMemo(() => {
    const required = ['cjpeg', 'pngquant', 'pngcrush', 'svgo', 'gifsicle'];
    const requiredStatuses = required.map((name) => diagnostics.find((tool) => tool.name === name));
    const bundledReadyCount = requiredStatuses.filter(
      (tool) => tool?.available && tool.source_kind === 'bundled',
    ).length;

    return {
      total: required.length,
      ready: bundledReadyCount,
      allReady: bundledReadyCount === required.length,
    };
  }, [diagnostics]);

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: trimTransparent,
      dimensions: {
        crop_width: cropWidth ? Number(cropWidth) : null,
        crop_height: cropHeight ? Number(cropHeight) : null,
        resize_width: resizeWidth ? Number(resizeWidth) : null,
        resize_height: resizeHeight ? Number(resizeHeight) : null,
      },
      compression: {
        quality,
        png_quant_quality_min: pngQMin,
        png_quant_quality_max: pngQMax,
        run_zopfli: runZopfli,
        run_pngout: runPngout,
      },
    }),
    [cropHeight, cropWidth, pngQMax, pngQMin, quality, resizeHeight, resizeWidth, runPngout, runZopfli, trimTransparent],
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
      <header className="diagnostics-row">
        <div className={`diag-pill ${bundledDiagnosticsSummary.allReady ? 'ok' : 'missing'}`}>
          <span>bundled toolchain</span>
          <small>
            {bundledDiagnosticsSummary.ready}/{bundledDiagnosticsSummary.total} bundled-ready
          </small>
        </div>

        {diagnostics.map((tool) => (
          <div key={tool.name} className={`diag-pill ${tool.available ? 'ok' : 'missing'}`}>
            <span>{tool.name}</span>
            <small>
              {tool.available
                ? `${tool.source_kind ?? 'unknown'} · ${tool.source ?? 'PATH'}`
                : 'missing'}
            </small>
          </div>
        ))}
      </header>

      <main className="split-pane">
        <section className="left-pane">
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
            <h2>Drop files to crush</h2>
            <p>Supports jpg/jpeg, png, svg, gif</p>
            <button onClick={() => fileInputRef.current?.click()}>Choose files</button>
            <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} />
          </div>

          <div className="queue-card">
            <h3>Active queue</h3>
            {activeJobs.length === 0 ? (
              <p className="muted">No active jobs</p>
            ) : (
              activeJobs.map((job) => (
                <div key={job.id} className="job-row">
                  <div className="job-top">
                    <strong>{job.status}</strong>
                    <span>{job.progress}%</span>
                  </div>
                  <div className="progress-wrap">
                    <div className="progress-bar" style={{ width: `${job.progress}%` }} />
                  </div>
                  <small>{job.input_path}</small>
                </div>
              ))
            )}
          </div>

          <div className="recent-card">
            <h3>Recent results</h3>
            {queueState.recent.length === 0 ? (
              <p className="muted">No completed jobs yet</p>
            ) : (
              queueState.recent.map((item) => (
                <article key={item.id} className="result-row">
                  <div>
                    <strong>{item.output_path.split('/').pop()}</strong>
                    <p>{item.stages_run.join(' → ')}</p>
                  </div>
                  <div className="result-meta">
                    <span>
                      {formatBytes(item.input_size)} → {formatBytes(item.output_size)}
                    </span>
                    <span className={item.size_delta_percent <= 0 ? 'delta-good' : 'delta-bad'}>
                      {item.size_delta_percent.toFixed(1)}%
                    </span>
                    <button onClick={() => invoke('reveal_in_finder', { path: item.output_path })}>Reveal</button>
                  </div>
                </article>
              ))
            )}
          </div>
        </section>

        <aside className="right-pane">
          <h3>Options</h3>

          <div className="option-group">
            <h4>General</h4>
            <label>
              <input
                type="checkbox"
                checked={trimTransparent}
                onChange={(event) => setTrimTransparent(event.target.checked)}
              />
              Trim transparent bounds (PNG)
            </label>
          </div>

          <div className="option-group">
            <h4>Dimensions</h4>
            <div className="grid-2">
              <label>
                Crop W
                <input value={cropWidth} onChange={(event) => setCropWidth(event.target.value)} />
              </label>
              <label>
                Crop H
                <input value={cropHeight} onChange={(event) => setCropHeight(event.target.value)} />
              </label>
              <label>
                Resize W
                <input value={resizeWidth} onChange={(event) => setResizeWidth(event.target.value)} />
              </label>
              <label>
                Resize H
                <input value={resizeHeight} onChange={(event) => setResizeHeight(event.target.value)} />
              </label>
            </div>
          </div>

          <div className="option-group">
            <h4>Compression</h4>
            <label>
              JPEG Quality {quality}
              <input
                type="range"
                min={20}
                max={100}
                value={quality}
                onChange={(event) => setQuality(Number(event.target.value))}
              />
            </label>

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

            <label>
              <input type="checkbox" checked={runZopfli} onChange={(event) => setRunZopfli(event.target.checked)} />
              Run zopflipng (optional)
            </label>
            <label>
              <input type="checkbox" checked={runPngout} onChange={(event) => setRunPngout(event.target.checked)} />
              Run pngout (optional)
            </label>
          </div>
        </aside>
      </main>
    </div>
  );
}

export default App;
