import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { convertFileSrc, invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import './App.css';
import {
  formatBytes,
  initialQueueState,
  queueReducer,
  type JobResultEntry,
  type QueueEventPayload,
} from './state/queueState';
import {
  compareSemver,
  normalizeReleaseVersion,
  pickPreferredAsset,
  resolveExpectedSha256,
  updateReducer,
  type GitHubReleaseAsset,
  type RuntimePlatform,
  type UpdateFlowState,
} from './state/updateState';
import { UpdateRail } from './components/UpdateRail';

const TERMINAL_JOB_STATUSES = new Set(['completed', 'failed']);
const RELEASES_LATEST_URL = 'https://api.github.com/repos/lubomirmolin/pixelcrusher/releases/latest';
const RELEASES_PAGE_URL = 'https://github.com/lubomirmolin/pixelcrusher/releases';
const SUPPORTED_EXTENSIONS = new Set(['png', 'jpg', 'jpeg', 'svg', 'gif']);
const SUPPORTED_FORMATS_LABEL = 'PNG/JPG/JPEG/SVG/GIF';
const ENQUEUE_DEDUPE_WINDOW_MS = 1000;

type DragValidationState = 'idle' | 'supported' | 'unsupported';

type ReleasePayload = {
  tag_name?: string;
  html_url?: string;
  assets?: GitHubReleaseAsset[];
};

type DownloadedUpdatePayload = {
  path: string;
  size: number;
  sha256: string;
};

type InstallUpdateResult = {
  mode: 'launched-and-exit' | 'launched' | 'guidance';
  message: string;
  command?: string;
};

type CompressionProfileId = 'balanced' | 'high' | 'smallest';

type ProfilePreset = {
  label: string;
  quality: number;
  pngQMin: number;
  pngQMax: number;
  runPngQuant: boolean;
  runPngcrush: boolean;
  runZopfli: boolean;
  runPngout: boolean;
};

type CropDraft = {
  width: string;
  height: string;
};

type ResizeDraft = {
  width: string;
  height: string;
  lock: boolean;
};

const PROFILE_PRESETS: Record<CompressionProfileId, ProfilePreset> = {
  balanced: {
    label: 'Balanced',
    quality: 82,
    pngQMin: 60,
    pngQMax: 90,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: false,
    runPngout: false,
  },
  high: {
    label: 'High Quality',
    quality: 92,
    pngQMin: 75,
    pngQMax: 98,
    runPngQuant: false,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
  },
  smallest: {
    label: 'Smallest Size',
    quality: 70,
    pngQMin: 45,
    pngQMax: 75,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
  },
};

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

function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

function normalizeReleasePageURL(candidate?: string): string {
  if (!candidate) {
    return RELEASES_PAGE_URL;
  }

  try {
    const parsed = new URL(candidate);
    if (
      parsed.protocol === 'https:' &&
      parsed.hostname.toLowerCase() === 'github.com' &&
      parsed.pathname.startsWith('/lubomirmolin/pixelcrusher/releases')
    ) {
      return parsed.toString();
    }
  } catch {
    // fallback to default
  }

  return RELEASES_PAGE_URL;
}

function toAssetUrl(path: string): string {
  if (!path) {
    return '';
  }

  if (isTauriRuntime()) {
    try {
      return convertFileSrc(path);
    } catch {
      // fallback below
    }
  }

  const normalized = path.replace(/\\/g, '/');
  const prefixed = normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
  return encodeURI(prefixed);
}

function fileExtension(path: string): string {
  const name = basename(path);
  const dotIndex = name.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex === name.length - 1) {
    return '';
  }
  return name.slice(dotIndex + 1).toLowerCase();
}

function mimeTypeForPath(path: string): string {
  const ext = fileExtension(path);
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

function classifyInputPath(path: string): 'supported' | 'unsupported' | 'unknown' {
  const ext = fileExtension(path);
  if (!ext) {
    return 'unknown';
  }
  return SUPPORTED_EXTENSIONS.has(ext) ? 'supported' : 'unsupported';
}

function formatSavings(deltaPercent?: number): string {
  if (deltaPercent == null || Number.isNaN(deltaPercent)) {
    return '';
  }

  const rounded = Math.round(Math.abs(deltaPercent));
  return deltaPercent <= 0 ? `-${rounded}%` : `+${rounded}%`;
}

function dragStateFromPaths(paths: string[]): DragValidationState {
  if (!paths.length) {
    return 'supported';
  }

  return paths.some((path) => classifyInputPath(path) === 'unsupported') ? 'unsupported' : 'supported';
}

function dragStateFromFiles(files: File[]): DragValidationState {
  if (!files.length) {
    return 'supported';
  }

  const hasUnsupported = files.some((file) => {
    const ext = fileExtension(file.name);
    if (!ext) {
      return false;
    }
    return !SUPPORTED_EXTENSIONS.has(ext);
  });

  return hasUnsupported ? 'unsupported' : 'supported';
}

function PunchEffectCanvas({ inputPath, onComplete }: { inputPath: string; onComplete: () => void }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    let blobURL: string | null = null;

    setResolvedSrc(null);

    const resolveSource = async () => {
      const fallback = toAssetUrl(inputPath);

      if (isTauriRuntime()) {
        try {
          const bytes = await invoke<number[]>('read_image_bytes', { path: inputPath });
          if (Array.isArray(bytes) && bytes.length > 0) {
            const blob = new Blob([new Uint8Array(bytes)], { type: mimeTypeForPath(inputPath) });
            blobURL = URL.createObjectURL(blob);
            if (!cancelled) {
              setResolvedSrc(blobURL);
            }
            return;
          }
        } catch {
          // fallback below
        }
      }

      if (!cancelled) {
        setResolvedSrc(fallback || '');
      }
    };

    void resolveSource();

    return () => {
      cancelled = true;
      if (blobURL) {
        URL.revokeObjectURL(blobURL);
      }
    };
  }, [inputPath]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || resolvedSrc == null) {
      return;
    }

    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) {
      return;
    }

    const targetImg = new Image();

    const fistImg = new Image();
    fistImg.src = '/fist.png';
    let fistLoaded = false;
    fistImg.onload = () => {
      fistLoaded = true;
    };

    type Block = { x: number; y: number; w: number; h: number; color: string };
    type Particle = { x: number; y: number; vx: number; vy: number; size: number; color: string };

    let animationId = 0;
    let startTime = 0;
    let particles: Particle[] = [];
    let phase = 0;
    let completed = false;

    const cornerBlocks: Block[] = [];
    const bodyBlocks: Block[] = [];

    const offscreen = document.createElement('canvas');
    const offCtx = offscreen.getContext('2d', { willReadFrequently: true });

    let started = false;

    const startAnimation = (hasSourceImage: boolean) => {
      if (started) {
        return;
      }
      started = true;

      const cw = canvas.width;
      const ch = canvas.height;

      const maxImageSize = 160;
      const ratio = hasSourceImage && targetImg.naturalWidth > 0 && targetImg.naturalHeight > 0
        ? targetImg.naturalWidth / targetImg.naturalHeight
        : 1;

      const imgW = ratio >= 1 ? maxImageSize : maxImageSize * ratio;
      const imgH = ratio >= 1 ? maxImageSize / ratio : maxImageSize;
      const imgX = (cw - imgW) * 0.5;
      const imgY = 58 + (160 - imgH) * 0.5;
      const floorY = ch - 15;

      const blockSize = 8;
      const cols = Math.max(1, Math.ceil(imgW / blockSize));
      const rows = Math.max(1, Math.ceil(imgH / blockSize));

      cornerBlocks.length = 0;
      bodyBlocks.length = 0;
      particles = [];
      phase = 0;

      const samplingCanvas = document.createElement('canvas');
      const samplingCtx = samplingCanvas.getContext('2d', { willReadFrequently: true });
      samplingCanvas.width = Math.max(1, Math.round(imgW));
      samplingCanvas.height = Math.max(1, Math.round(imgH));

      if (samplingCtx && hasSourceImage) {
        samplingCtx.clearRect(0, 0, samplingCanvas.width, samplingCanvas.height);
        samplingCtx.drawImage(targetImg, 0, 0, samplingCanvas.width, samplingCanvas.height);
      }

      const sampleColor = (block: Block): string => {
        if (!samplingCtx) {
          return 'rgba(59,130,246,1)';
        }

        const px = Math.min(
          samplingCanvas.width - 1,
          Math.max(0, Math.floor(block.x + block.w * 0.5)),
        );
        const py = Math.min(
          samplingCanvas.height - 1,
          Math.max(0, Math.floor(block.y + block.h * 0.5)),
        );
        const data = samplingCtx.getImageData(px, py, 1, 1).data;
        return `rgba(${data[0]}, ${data[1]}, ${data[2]}, ${data[3] / 255})`;
      };

      for (let row = 0; row < rows; row += 1) {
        for (let col = 0; col < cols; col += 1) {
          const x = col * blockSize;
          const y = row * blockSize;
          const w = Math.min(blockSize, imgW - x);
          const h = Math.min(blockSize, imgH - y);
          if (w <= 0 || h <= 0) {
            continue;
          }

          const block: Block = {
            x,
            y,
            w,
            h,
            color: 'rgba(59,130,246,1)',
          };
          block.color = sampleColor(block);

          const noise = Math.random() * 4 - 2;
          if (row + col + noise > rows + cols - 13) {
            cornerBlocks.push(block);
          } else {
            bodyBlocks.push(block);
          }
        }
      }

      const draw = (timestamp: number) => {
        if (!startTime) {
          startTime = timestamp;
        }

        const elapsed = timestamp - startTime;

        if (elapsed >= 4000) {
          if (!completed) {
            completed = true;
            onComplete();
          }
          return;
        }

        const localElapsed = elapsed;

        ctx.clearRect(0, 0, cw, ch);

        if (localElapsed > 3500) {
          ctx.globalAlpha = Math.max(0, 1 - (localElapsed - 3500) / 500);
        } else {
          ctx.globalAlpha = 1;
        }

        let shakeX = 0;
        let shakeY = 0;
        if ((localElapsed > 1000 && localElapsed < 1150) || (localElapsed > 2200 && localElapsed < 2300)) {
          shakeX = (Math.random() - 0.5) * 10;
          shakeY = (Math.random() - 0.5) * 10;
        }

        ctx.save();
        ctx.translate(shakeX, shakeY);

        if (localElapsed < 1000) {
          const holdMs = 180;
          let pixelSize = 1;

          if (localElapsed > holdMs) {
            const progress = Math.min(1, Math.max(0, (localElapsed - holdMs) / (1000 - holdMs)));
            const eased = Math.pow(progress, 1.2);
            pixelSize = 1 + eased * 7;
          }

          const scaledW = Math.max(1, Math.floor(imgW / pixelSize));
          const scaledH = Math.max(1, Math.floor(imgH / pixelSize));

          if (offCtx) {
            offscreen.width = scaledW;
            offscreen.height = scaledH;
            offCtx.clearRect(0, 0, scaledW, scaledH);
            if (hasSourceImage) {
              offCtx.drawImage(
                targetImg,
                0,
                0,
                targetImg.naturalWidth,
                targetImg.naturalHeight,
                0,
                0,
                scaledW,
                scaledH,
              );

              ctx.imageSmoothingEnabled = false;
              ctx.drawImage(offscreen, 0, 0, scaledW, scaledH, imgX, imgY, imgW, imgH);
            } else {
              bodyBlocks.forEach((block) => {
                ctx.fillStyle = block.color;
                ctx.fillRect(imgX + block.x, imgY + block.y, block.w, block.h);
              });
            }
          }
        } else if (localElapsed < 2200) {
          bodyBlocks.forEach((block) => {
            ctx.fillStyle = block.color;
            ctx.fillRect(imgX + block.x, imgY + block.y, block.w, block.h);
          });
        }

        const fistW = 100;
        const fistH = 140;
        const fistX = (cw - fistW) * 0.5;
        const targetFistY = imgY - fistH + 25;

        let fistY = -fistH;
        if (localElapsed > 600 && localElapsed <= 1000) {
          const p = (localElapsed - 600) / 400;
          fistY = -fistH + (targetFistY + fistH) * (p * p * p);
        } else if (localElapsed > 1000 && localElapsed <= 1600) {
          fistY = targetFistY;
        } else if (localElapsed > 1600 && localElapsed <= 2200) {
          const p = (localElapsed - 1600) / 600;
          fistY = targetFistY - (targetFistY + fistH) * (p * p);
        }

        if (localElapsed > 600 && localElapsed <= 2200) {
          if (fistLoaded) {
            ctx.drawImage(fistImg, fistX, fistY, fistW, fistH);
          } else {
            ctx.fillStyle = '#fca5a5';
            ctx.fillRect(fistX, fistY, fistW, fistH);
          }
        }

        ctx.restore();

        if (localElapsed >= 1000 && phase === 0) {
          phase = 1;
          cornerBlocks.forEach((block) => {
            particles.push({
              x: imgX + block.x,
              y: imgY + block.y,
              vx: Math.random() * 6 + 1,
              vy: Math.random() * 4 - 2,
              size: Math.min(block.w, block.h),
              color: block.color,
            });
          });
        }

        if (localElapsed >= 2200 && phase === 1) {
          phase = 2;
          bodyBlocks.forEach((block) => {
            particles.push({
              x: imgX + block.x,
              y: imgY + block.y,
              vx: (Math.random() - 0.5) * 8,
              vy: (Math.random() - 0.5) * 4 - 2,
              size: Math.min(block.w, block.h),
              color: block.color,
            });
          });
        }

        particles.forEach((particle) => {
          particle.vy += 0.8;
          particle.x += particle.vx;
          particle.y += particle.vy;

          if (particle.y > floorY - particle.size) {
            particle.y = floorY - particle.size;
            particle.vy *= -0.3;
            particle.vx *= 0.7;
          }

          ctx.fillStyle = particle.color;
          ctx.fillRect(particle.x, particle.y, particle.size, particle.size);
        });

        animationId = window.requestAnimationFrame(draw);
      };

      animationId = window.requestAnimationFrame(draw);
    };

    targetImg.onload = () => {
      startAnimation(true);
    };

    targetImg.onerror = () => {
      startAnimation(false);
    };

    if (resolvedSrc !== '') {
      targetImg.src = resolvedSrc;
    } else {
      startAnimation(false);
    }

    return () => {
      if (animationId) {
        window.cancelAnimationFrame(animationId);
      }
    };
  }, [onComplete, resolvedSrc]);

  return <canvas ref={canvasRef} width={260} height={340} className="punch-canvas" />;
}

function App() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragState, setDragState] = useState<DragValidationState>('idle');
  const [appVersion, setAppVersion] = useState('0.0.0');
  const [runtimePlatform, setRuntimePlatform] = useState<RuntimePlatform>('unknown');
  const [updateState, updateDispatch] = useReducer(updateReducer, { status: 'idle' } as UpdateFlowState);
  const [showUpdateSheet, setShowUpdateSheet] = useState(false);

  const [profile, setProfile] = useState<CompressionProfileId>('balanced');
  const [autoCrop, setAutoCrop] = useState(true);

  const [cropWidth, setCropWidth] = useState('');
  const [cropHeight, setCropHeight] = useState('');
  const [resizeWidth, setResizeWidth] = useState('');
  const [resizeHeight, setResizeHeight] = useState('');

  const [activeCropItem, setActiveCropItem] = useState<JobResultEntry | null>(null);
  const [activeResizeItem, setActiveResizeItem] = useState<JobResultEntry | null>(null);
  const [cropDraft, setCropDraft] = useState<CropDraft>({ width: '', height: '' });
  const [resizeDraft, setResizeDraft] = useState<ResizeDraft>({ width: '', height: '', lock: true });

  const [dismissedResultIDs, setDismissedResultIDs] = useState<Set<string>>(new Set());
  const [punchQueue, setPunchQueue] = useState<Array<{ id: string; inputPath: string }>>([]);
  const [activePunch, setActivePunch] = useState<{ id: string; inputPath: string } | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const dragDepthRef = useRef(0);
  const optionsPayloadRef = useRef<Record<string, unknown> | null>(null);
  const animatedPunchIDsRef = useRef<Set<string>>(new Set());
  const terminalPunchIDsRef = useRef<Set<string>>(new Set());
  const recentEnqueueRef = useRef<{ signature: string; at: number } | null>(null);

  useEffect(() => {
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

    invoke<string>('runtime_platform')
      .then((platform) => {
        if (platform === 'windows' || platform === 'linux' || platform === 'macos') {
          setRuntimePlatform(platform);
        }
      })
      .catch(() => undefined);

    let unlistenQueue: (() => void) | undefined;
    let unlistenDragDrop: (() => void) | undefined;
    let active = true;

    listen<QueueEventPayload>('queue://event', (event) => {
      dispatch({ type: 'INGEST_EVENT', payload: event.payload });

      const status = event.payload.job.status;
      const jobID = event.payload.job.id;
      const shouldAnimate = status === 'diagnosing' || status === 'processing' || status === 'optimizing';

      if (TERMINAL_JOB_STATUSES.has(status)) {
        terminalPunchIDsRef.current.add(jobID);
      }

      if (
        shouldAnimate &&
        !terminalPunchIDsRef.current.has(jobID) &&
        !animatedPunchIDsRef.current.has(jobID)
      ) {
        animatedPunchIDsRef.current.add(jobID);
        setPunchQueue((previous) => [...previous, { id: jobID, inputPath: event.payload.job.input_path }]);
      }
    })
      .then((off) => {
        if (!active) {
          off();
          return;
        }
        unlistenQueue = off;
      })
      .catch(() => undefined);

    if (isTauriRuntime()) {
      getCurrentWebview()
        .onDragDropEvent((event) => {
          const payload = event.payload as { type: string; paths?: string[] };

          if (payload.type === 'enter' || payload.type === 'over') {
            const state = dragStateFromPaths(payload.paths ?? []);
            setDragState(state);
            return;
          }

          if (payload.type === 'leave') {
            setDragState('idle');
            return;
          }

          if (payload.type === 'drop') {
            setDragState('idle');
            void enqueuePaths(payload.paths ?? []);
          }
        })
        .then((off) => {
          if (!active) {
            off();
            return;
          }
          unlistenDragDrop = off;
        })
        .catch(() => undefined);
    }

    return () => {
      active = false;
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

  const processedItems = useMemo(
    () => [...queueState.recent].reverse().filter((item) => !dismissedResultIDs.has(item.id)),
    [dismissedResultIDs, queueState.recent],
  );

  const completedCount = useMemo(
    () => Object.values(queueState.jobs).filter((job) => job.status === 'completed').length,
    [queueState.jobs],
  );

  const totalCount = activeJobs.length + completedCount;

  const selectedProfile = PROFILE_PRESETS[profile];

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: autoCrop,
      dimensions: {
        crop_width: asOptionalDimension(cropWidth),
        crop_height: asOptionalDimension(cropHeight),
        resize_width: asOptionalDimension(resizeWidth),
        resize_height: asOptionalDimension(resizeHeight),
      },
      compression: {
        quality: selectedProfile.quality,
        png_quant_quality_min: selectedProfile.pngQMin,
        png_quant_quality_max: selectedProfile.pngQMax,
        run_png_quant: selectedProfile.runPngQuant,
        run_pngcrush: selectedProfile.runPngcrush,
        run_zopfli: selectedProfile.runZopfli,
        run_pngout: selectedProfile.runPngout,
      },
    }),
    [autoCrop, cropHeight, cropWidth, resizeHeight, resizeWidth, selectedProfile],
  );

  useEffect(() => {
    optionsPayloadRef.current = optionsPayload;
  }, [optionsPayload]);

  useEffect(() => {
    if (activePunch || punchQueue.length === 0) {
      return;
    }

    setActivePunch(punchQueue[0]);
    setPunchQueue((previous) => previous.slice(1));
  }, [activePunch, punchQueue]);

  useEffect(() => {
    const viewport = scrollViewportRef.current;
    if (!viewport) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      viewport.scrollTop = viewport.scrollHeight;
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [activePunch?.id, processedItems.length]);

  const enqueuePaths = async (paths: string[]) => {
    const normalized = Array.from(new Set(paths.map((path) => path.trim()).filter((path) => path.length > 0)));

    if (!normalized.length) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'No valid files were selected.',
      });
      return;
    }

    const accepted: string[] = [];
    const rejected: string[] = [];

    normalized.forEach((path) => {
      const classification = classifyInputPath(path);
      if (classification === 'unsupported') {
        rejected.push(path);
      } else {
        accepted.push(path);
      }
    });

    if (!accepted.length) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: `Unsupported format. Supported: ${SUPPORTED_FORMATS_LABEL}`,
      });
      return;
    }

    if (rejected.length) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: `Skipped ${rejected.length} unsupported file${rejected.length === 1 ? '' : 's'}. Supported: ${SUPPORTED_FORMATS_LABEL}`,
      });
    } else {
      dispatch({ type: 'CLEAR_QUEUE_ERROR' });
    }

    const signature = accepted.slice().sort().join('|');
    const now = Date.now();
    const previous = recentEnqueueRef.current;
    if (
      previous &&
      previous.signature === signature &&
      now - previous.at <= ENQUEUE_DEDUPE_WINDOW_MS
    ) {
      return;
    }
    recentEnqueueRef.current = { signature, at: now };

    try {
      await invoke('enqueue_paths', {
        paths: accepted,
        options: optionsPayloadRef.current ?? optionsPayload,
      });
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Queue start failed. Please try again.',
      });
    }
  };

  const onOpenSystemPicker = async () => {
    if (!isTauriRuntime()) {
      fileInputRef.current?.click();
      return;
    }

    try {
      const selected = await invoke<string[]>('select_input_files');
      await enqueuePaths(selected ?? []);
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Unable to open the file picker.',
      });
    }
  };

  const onDropFiles: React.DragEventHandler<HTMLDivElement> = async (event) => {
    event.preventDefault();
    if (isTauriRuntime()) {
      return;
    }
    dragDepthRef.current = 0;
    setDragState('idle');

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
    event.currentTarget.value = '';
  };

  const onDragEnter: React.DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    dragDepthRef.current += 1;
    setDragState(dragStateFromFiles(Array.from(event.dataTransfer.files ?? [])));
  };

  const onDragOver: React.DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    if (dragDepthRef.current <= 0) {
      dragDepthRef.current = 1;
    }
    setDragState(dragStateFromFiles(Array.from(event.dataTransfer.files ?? [])));
  };

  const onDragLeave: React.DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
    if (dragDepthRef.current === 0) {
      setDragState('idle');
    }
  };

  const openItemCropModal = (item: JobResultEntry) => {
    setActiveCropItem(item);
    setCropDraft({ width: cropWidth, height: cropHeight });
  };

  const openItemResizeModal = (item: JobResultEntry) => {
    setActiveResizeItem(item);
    setResizeDraft({ width: resizeWidth, height: resizeHeight, lock: true });
  };

  const applyItemCrop = () => {
    setCropWidth(cropDraft.width);
    setCropHeight(cropDraft.height);
    setActiveCropItem(null);
  };

  const applyItemResize = () => {
    setResizeWidth(resizeDraft.width);
    setResizeHeight(resizeDraft.height);
    setActiveResizeItem(null);
  };

  const onCheckForUpdates = async () => {
    updateDispatch({ type: 'START_CHECK' });

    try {
      const response = await fetch(RELEASES_LATEST_URL, {
        headers: {
          Accept: 'application/vnd.github+json',
        },
      });

      if (!response.ok) {
        throw new Error(`GitHub release check failed with HTTP ${response.status}`);
      }

      const payload = (await response.json()) as ReleasePayload;
      const releaseUrl = normalizeReleasePageURL(payload.html_url);

      const latestVersion = normalizeReleaseVersion(payload.tag_name ?? '');
      if (!latestVersion) {
        throw new Error('Latest release tag is not semantic.');
      }

      if (compareSemver(latestVersion, appVersion) <= 0) {
        updateDispatch({ type: 'SET_UP_TO_DATE', latestVersion });
        return;
      }

      const preferredAsset = pickPreferredAsset(payload.assets ?? [], runtimePlatform);
      if (!preferredAsset) {
        throw new Error('Latest release has no installable asset for this platform.');
      }

      updateDispatch({
        type: 'SET_AVAILABLE',
        latestVersion,
        releaseUrl,
        asset: preferredAsset,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const onDownloadUpdate = async () => {
    if (updateState.status !== 'available') {
      return;
    }

    const candidate = updateState;
    updateDispatch({ type: 'START_DOWNLOAD' });

    try {
      const expectedSha256 = await resolveExpectedSha256(candidate.asset, fetch);
      updateDispatch({ type: 'SET_DOWNLOAD_PROGRESS', progress: null });

      const downloaded = await invoke<DownloadedUpdatePayload>('download_verified_update', {
        url: candidate.asset.url,
        fileName: candidate.asset.name,
        expectedSha256,
      });

      updateDispatch({
        type: 'SET_READY_TO_INSTALL',
        downloadPath: downloaded.path,
        downloadedSha256: downloaded.sha256,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const onInstallUpdate = async () => {
    if (updateState.status !== 'ready-to-install') {
      return;
    }

    const candidate = updateState;
    updateDispatch({ type: 'START_INSTALL' });

    try {
      const result = await invoke<InstallUpdateResult>('install_downloaded_update', {
        path: candidate.downloadPath,
        assetKind: candidate.asset.kind,
      });

      if (result.mode === 'guidance') {
        updateDispatch({
          type: 'SET_ACTION_REQUIRED',
          reason: result.message,
          command: result.command,
        });
        return;
      }

      updateDispatch({
        type: 'SET_RELAUNCHING',
        latestVersion: candidate.latestVersion,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const openReleasePage = async (url: string) => {
    try {
      await invoke('open_external_url', { url });
    } catch {
      updateDispatch({
        type: 'FAIL',
        reason: 'Unable to open release page.',
      });
    }
  };

  const recentOutputFolder = useMemo(() => {
    const latest = queueState.recent[0];
    return latest?.output_path ? dirname(latest.output_path) : '';
  }, [queueState.recent]);

  const isEmptyState = processedItems.length === 0 && activePunch == null;
  const showBottomHint = !isEmptyState || activeJobs.length > 0;

  const clearProcessedItems = () => {
    setDismissedResultIDs((previous) => {
      const next = new Set(previous);
      queueState.recent.forEach((item) => next.add(item.id));
      return next;
    });
  };

  const handlePunchComplete = useCallback(() => {
    setActivePunch(null);
  }, []);

  return (
    <div
      className="app-shell"
      onDrop={onDropFiles}
      onDragEnter={onDragEnter}
      onDragLeave={onDragLeave}
      onDragOver={onDragOver}
    >
      <header className="titlebar">
        <div className="titlebar-spacer" />
        <h1>Pixel Crusher</h1>
        <div className="titlebar-right">
          <button className="secondary-btn" onClick={() => setShowUpdateSheet(true)}>
            Update
          </button>
          <label className="checkbox-inline" htmlFor="autocrop-toggle">
            <input
              id="autocrop-toggle"
              type="checkbox"
              checked={autoCrop}
              onChange={(event) => setAutoCrop(event.target.checked)}
            />
            <span>Autocrop</span>
          </label>
          <select
            aria-label="Compression profile"
            value={profile}
            onChange={(event) => setProfile(event.target.value as CompressionProfileId)}
          >
            <option value="high">High Quality</option>
            <option value="balanced">Balanced</option>
            <option value="smallest">Smallest Size</option>
          </select>
        </div>
      </header>

      <main className="workspace">
        {isEmptyState ? (
          <section className="empty-state" data-testid="empty-state">
            <div className="empty-icon" aria-hidden="true">
              ⤴
            </div>
            <h2>Drag &amp; Drop images here</h2>
            <p>or</p>
            <button className="secondary-btn big" onClick={() => void onOpenSystemPicker()}>
              Browse Files
            </button>
            <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} accept=".png,.jpg,.jpeg,.svg,.gif" />
          </section>
        ) : (
          <section className="content-pane" data-testid="list-state">
            <div className="list-header">
              <h2>Processed images</h2>
              <div className="list-header-actions">
                <button className="secondary-btn" onClick={clearProcessedItems} disabled={processedItems.length === 0}>
                  Clear
                </button>
                <button
                  className="secondary-btn"
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
            </div>

            <div className="results-scroll" ref={scrollViewportRef}>
              {processedItems.map((item) => {
                const previewPath = item.output_path || item.input_path;
                const previewSrc = toAssetUrl(previewPath);
                const savingsText = formatSavings(item.size_delta_percent);
                const savingsClass = (item.size_delta_percent ?? 0) <= 0 ? 'good' : 'bad';

                return (
                  <article key={item.id} className="result-row">
                    <div className="thumb">
                      {previewSrc ? <img src={previewSrc} alt="" loading="lazy" /> : <span>{basename(item.input_path).charAt(0)}</span>}
                    </div>

                    <div className="result-main">
                      <strong>{basename(item.input_path)}</strong>
                      <p>
                        <span>{formatBytes(item.input_size)}</span>
                        <span className="arrow">→</span>
                        <span className="optimized">{formatBytes(item.output_size)}</span>
                        {savingsText ? <span className={`delta-pill ${savingsClass}`}>{savingsText}</span> : null}
                      </p>
                    </div>

                    <div className="row-actions">
                      <button className="icon-btn" onClick={() => openItemCropModal(item)} title="Crop image" aria-label="Crop image">
                        ⌗
                      </button>
                      <button className="icon-btn" onClick={() => openItemResizeModal(item)} title="Resize image" aria-label="Resize image">
                        ⤢
                      </button>
                    </div>

                    <div className={`status-indicator ${item.status === 'completed' ? 'ok' : 'bad'}`}>
                      {item.status === 'completed' ? '✓' : '!'}
                    </div>
                  </article>
                );
              })}

              {activePunch ? (
                <div className="punch-zone">
                  <PunchEffectCanvas inputPath={activePunch.inputPath} onComplete={handlePunchComplete} />
                  <p>
                    Crushing <strong>{basename(activePunch.inputPath)}</strong>
                  </p>
                </div>
              ) : null}

              {!processedItems.length && !activePunch ? <p className="empty-list-note">Add files to start crushing.</p> : null}
            </div>
          </section>
        )}

        {queueState.lastError ? <p className="queue-error">{queueState.lastError}</p> : null}
      </main>

      {showBottomHint ? (
        <footer className="status-footer">
          <span>Drag and drop to process more images</span>
          {totalCount > 0 ? (
            <>
              <span>•</span>
              <span>
                {completedCount}/{totalCount} done
              </span>
            </>
          ) : null}
          <span>•</span>
          <span>Profile: {selectedProfile.label}</span>
        </footer>
      ) : null}

      {dragState !== 'idle' ? (
        <div className={`drag-overlay ${dragState === 'unsupported' ? 'unsupported' : ''}`} role="presentation">
          <div className="drag-pill">
            <strong>{dragState === 'unsupported' ? 'Unsupported format' : 'Drop to crush'}</strong>
            {dragState === 'unsupported' ? <span>Supported: {SUPPORTED_FORMATS_LABEL}</span> : null}
          </div>
        </div>
      ) : null}

      {showUpdateSheet ? (
        <div className="modal-backdrop" role="dialog" aria-label="updates-modal">
          <div className="modal-card">
            <div className="modal-top">
              <h3>Updates</h3>
              <button className="secondary-btn" onClick={() => setShowUpdateSheet(false)}>
                Close
              </button>
            </div>
            <UpdateRail
              appVersion={appVersion}
              updateState={updateState}
              onCheckForUpdates={() => void onCheckForUpdates()}
              onDownloadUpdate={() => void onDownloadUpdate()}
              onInstallUpdate={() => void onInstallUpdate()}
              onOpenReleasePage={(url) => void openReleasePage(url)}
            />
          </div>
        </div>
      ) : null}

      {activeCropItem ? (
        <div className="modal-backdrop" role="dialog" aria-label="crop-modal">
          <div className="modal-card small">
            <h3>Crop image</h3>
            <p>{basename(activeCropItem.input_path)}</p>
            <div className="grid-2">
              <label>
                Width
                <input
                  type="number"
                  value={cropDraft.width}
                  onChange={(event) => setCropDraft((previous) => ({ ...previous, width: event.target.value }))}
                />
              </label>
              <label>
                Height
                <input
                  type="number"
                  value={cropDraft.height}
                  onChange={(event) => setCropDraft((previous) => ({ ...previous, height: event.target.value }))}
                />
              </label>
            </div>
            <div className="modal-actions">
              <button className="secondary-btn" onClick={() => setActiveCropItem(null)}>
                Cancel
              </button>
              <button className="primary-btn" onClick={applyItemCrop}>
                Apply
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeResizeItem ? (
        <div className="modal-backdrop" role="dialog" aria-label="resize-modal">
          <div className="modal-card small">
            <h3>Resize image</h3>
            <p>{basename(activeResizeItem.input_path)}</p>
            <div className="grid-2">
              <label>
                Width
                <input
                  type="number"
                  value={resizeDraft.width}
                  onChange={(event) => setResizeDraft((previous) => ({ ...previous, width: event.target.value }))}
                />
              </label>
              <label>
                Height
                <input
                  type="number"
                  value={resizeDraft.height}
                  onChange={(event) => setResizeDraft((previous) => ({ ...previous, height: event.target.value }))}
                />
              </label>
            </div>
            <label className="checkbox-row">
              <input
                type="checkbox"
                checked={resizeDraft.lock}
                onChange={(event) => setResizeDraft((previous) => ({ ...previous, lock: event.target.checked }))}
              />
              <span>Lock aspect ratio</span>
            </label>
            <div className="modal-actions">
              <button className="secondary-btn" onClick={() => setActiveResizeItem(null)}>
                Cancel
              </button>
              <button className="primary-btn" onClick={applyItemResize}>
                Apply
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default App;
