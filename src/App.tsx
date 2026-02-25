import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { convertFileSrc, invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import {
  UploadCloud,
  Crop,
  Maximize2,
  CheckCircle2,
  ArrowRight,
  X,
} from 'lucide-react';
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

  // eslint-disable-next-line react-hooks/set-state-in-effect
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

        const fistScale = 1.45;
        const fistW = Math.round(100 * fistScale);
        const fistH = Math.round(140 * fistScale);
        const fistX = (cw - fistW) * 0.5;
        const targetFistY = Math.max(-20, imgY - fistH * 0.55);

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

  return <canvas ref={canvasRef} width={320} height={420} className="h-[280px] w-auto object-contain drop-shadow-2xl" />;
}

function App() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragState, setDragState] = useState<DragValidationState>('idle');
  const [appVersion, setAppVersion] = useState('0.0.0');
  const [runtimePlatform, setRuntimePlatform] = useState<RuntimePlatform>('unknown');
  const [updateState, updateDispatch] = useReducer(updateReducer, { status: 'idle' } as UpdateFlowState);
  const [showUpdateSheet, setShowUpdateSheet] = useState(false);

  const [profile, setProfile] = useState<CompressionProfileId>('balanced');
  const autoCrop = true;

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

  const processedItems = useMemo(
    () => [...queueState.recent].reverse().filter((item) => !dismissedResultIDs.has(item.id)),
    [dismissedResultIDs, queueState.recent],
  );



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



  const handlePunchComplete = useCallback(() => {
    setActivePunch(null);
  }, []);

  const clearProcessedItems = useCallback(() => {
    setDismissedResultIDs((previous) => {
      const next = new Set(previous);
      queueState.recent.forEach((item) => next.add(item.id));
      return next;
    });
  }, [queueState.recent]);

  const isEmptyState = processedItems.length === 0 && activePunch == null;

  return (
    <div className="h-screen w-screen flex flex-col bg-[#f3f3f3] font-sans antialiased text-[#333] transition-colors duration-300 overflow-hidden" onDrop={onDropFiles} onDragEnter={onDragEnter} onDragLeave={onDragLeave} onDragOver={onDragOver}>
        <div className="flex-1 overflow-hidden relative flex flex-col">
          <div className="flex-1 overflow-y-auto relative flex flex-col px-6 py-4">
            
            <div className="flex justify-between items-end mb-6">
              <h1 className="text-2xl font-semibold text-gray-900 tracking-tight">Image Queue</h1>
              <div className="flex space-x-3 items-center">
                <select 
                  value={profile}
                  onChange={(e) => setProfile(e.target.value as CompressionProfileId)}
                  aria-label="Compression profile"
                  className="bg-white border border-gray-300 rounded shadow-sm text-[13px] px-3 py-1.5 outline-none focus:ring-2 focus:ring-[#005fb8]/50 appearance-none pr-8 cursor-pointer text-gray-800"
                  style={{ backgroundImage: 'url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'12\' height=\'12\' fill=\'none\' stroke=\'%23333\' stroke-width=\'2\' stroke-linecap=\'round\' stroke-linejoin=\'round\'%3E%3Cpath d=\'M3 5l3 3 3-3\'/%3E%3C/svg%3E")', backgroundPosition: 'right 8px center', backgroundRepeat: 'no-repeat', backgroundSize: '12px' }}
                >
                  <option value="high">High Quality</option>
                  <option value="balanced">Balanced</option>
                  <option value="smallest">Smallest Size</option>
                </select>
                <button 
                  className="bg-[#005fb8] text-white font-semibold rounded text-[13px] px-4 py-1.5 shadow-sm hover:bg-[#0058a6] transition-colors"
                  onClick={() => setShowUpdateSheet(true)}
                >
                  Update
                </button>
                <label className="sr-only">
                  <input
                    type="checkbox"
                    checked={autoCrop}
                    readOnly
                    aria-label="Autocrop"
                  />
                  Autocrop
                </label>
              </div>
            </div>

            {isEmptyState ? (
              <div className="flex flex-col items-center justify-center text-gray-400 flex-1 border border-dashed border-gray-300 rounded-xl bg-white/50 mb-4" data-testid="empty-state">
                <div className="w-24 h-24 mb-4 flex items-center justify-center shadow-sm rounded-xl bg-white border border-gray-200">
                  <UploadCloud size={40} className="text-[#005fb8]" />
                </div>
                <p className="text-[14px] font-medium text-gray-800">Drag & Drop images here</p>
                <p className="text-[12px] mt-1">or</p>
                <button 
                  onClick={() => void onOpenSystemPicker()}
                  className="mt-3 px-4 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6] active:opacity-80"
                >
                  Browse Files
                </button>
              </div>
            ) : (
              <div className="flex flex-col flex-1 gap-4 min-h-0" data-testid="list-state">
                
                {processedItems.length > 0 && (
                  <>
                    <div className="flex items-center justify-between">
                      <p className="text-[12px] font-semibold uppercase tracking-wide text-gray-500">Processed images</p>
                      <button
                        type="button"
                        onClick={clearProcessedItems}
                        className="text-[12px] px-2.5 py-1 rounded bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
                      >
                        Clear
                      </button>
                    </div>
                  <div className="space-y-2 w-full flex-1 min-h-0 overflow-y-auto pr-1" ref={scrollViewportRef}>
                    {processedItems.map(item => {
                      const previewPath = item.output_path || item.input_path;
                      const previewSrc = toAssetUrl(previewPath);
                      const savingsText = formatSavings(item.size_delta_percent);
                      
                      return (
                        <div key={item.id} className="p-3 flex items-center group bg-white rounded-lg shadow-sm border border-gray-200 animate-[slideIn_0.3s_ease-out]">
                          
                          <div className="w-14 h-14 overflow-hidden flex-shrink-0 relative rounded-md bg-gray-100">
                             {previewSrc ? <img src={previewSrc} alt="" className="w-full h-full object-cover" /> : <div className="w-full h-full flex items-center justify-center font-bold text-gray-400">{basename(item.input_path).charAt(0)}</div>}
                          </div>
                          
                          <div className="ml-4 flex-1 min-w-0">
                            <div className="text-[14px] truncate font-semibold text-gray-900">
                              {basename(item.input_path)}
                            </div>
                            <div className="text-[12px] text-gray-500 flex items-center mt-1">
                              <span>{formatBytes(item.input_size)}</span>
                              <ArrowRight size={12} className="mx-2" />
                              <span className="text-green-600 font-medium">{formatBytes(item.output_size)}</span>
                              {savingsText && (
                                <span className="ml-2 px-1.5 py-0.5 font-semibold text-[11px] text-green-600">
                                  {savingsText}
                                </span>
                              )}
                            </div>
                          </div>

                          <div className="ml-4 flex items-center space-x-2">
                            <button 
                              onClick={() => openItemCropModal(item)}
                              className="p-2 transition-colors bg-transparent rounded hover:bg-black/5 text-gray-600 tooltip-trigger"
                              title="Crop Image"
                            >
                              <Crop size={16} strokeWidth={1.5} />
                            </button>
                            <button 
                              onClick={() => openItemResizeModal(item)}
                              className="p-2 transition-colors bg-transparent rounded hover:bg-black/5 text-gray-600 tooltip-trigger"
                              title="Resize Image"
                            >
                              <Maximize2 size={16} strokeWidth={1.5} />
                            </button>
                          </div>
                          
                          <div className="ml-4 w-6 flex justify-end">
                            {item.status === 'completed' ? (
                              <CheckCircle2 size={20} className="text-[#107c10]" strokeWidth={1.5} />
                            ) : (
                              <div className="text-red-500 font-bold">!</div>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                  </>
                )}

                {activePunch && (
                  <div className="w-full flex flex-col items-center justify-center mt-auto shrink-0 transition-all duration-300 pb-4">
                    <div className="w-[360px] h-[300px] rounded-2xl bg-transparent flex items-end justify-center overflow-hidden">
                      <PunchEffectCanvas 
                        inputPath={activePunch.inputPath} 
                        onComplete={handlePunchComplete} 
                      />
                    </div>
                    <p className="mt-2 text-sm text-gray-500">
                      Crushing <strong>{basename(activePunch.inputPath)}</strong>
                    </p>
                  </div>
                )}

              </div>
            )}
          </div>

          {dragState !== 'idle' && (
            <div className={`absolute inset-0 border-4 border-dashed m-4 flex items-center justify-center z-50 backdrop-blur-[2px] transition-all ${dragState === 'unsupported' ? 'bg-[#d7364a]/5 border-[#d7364a]/40' : 'bg-[#005fb8]/5 border-[#005fb8]/40'} rounded-xl`}>
              <div className="px-6 py-3 shadow-lg font-medium text-[14px] flex items-center bg-white rounded-md text-[#005fb8]">
                {dragState === 'unsupported' ? (
                  <>Unsupported format</>
                ) : (
                  <><UploadCloud size={18} className="mr-2" /> Drop to crush</>
                )}
              </div>
            </div>
          )}
        </div>

      <input 
        type="file" 
        multiple 
        className="hidden" 
        ref={fileInputRef} 
        onChange={onChooseFiles}
        accept=".png,.jpg,.jpeg,.svg,.gif"
      />

      {showUpdateSheet && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm" role="dialog" aria-label="updates-modal">
          <div className="w-[400px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
            <div className="h-12 flex items-center justify-between px-6 relative">
              <span className="font-semibold text-gray-900 text-[15px]">
                Updates
              </span>
              <button onClick={() => setShowUpdateSheet(false)} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
                <X size={16} />
              </button>
            </div>
            <div className="p-6 flex-1 bg-white">
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
        </div>
      )}

      {activeCropItem && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
          <div className="w-[400px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
            <div className="h-12 flex items-center justify-between px-6 relative">
              <span className="font-semibold text-gray-900 text-[15px]">
                Crop Image
              </span>
              <button onClick={() => setActiveCropItem(null)} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
                <X size={16} />
              </button>
            </div>
            <div className="p-6 flex-1 bg-white">
              <div className="space-y-4">
                <div className="w-full h-48 overflow-hidden relative bg-[#f3f3f3] rounded-md border border-gray-200">
                  <img src={toAssetUrl(activeCropItem.input_path)} className="w-full h-full object-contain opacity-50" alt="" />
                  <div className="absolute inset-8 border-2 border-white shadow-[0_0_0_999px_rgba(0,0,0,0.4)] flex items-center justify-center">
                    <Crop size={24} className="text-white opacity-80" />
                  </div>
                </div>
                <div className="flex items-center space-x-4">
                  <div className="flex-1">
                    <label className="block text-[11px] font-medium mb-1 text-gray-800">Width</label>
                    <input 
                      type="number" 
                      value={cropDraft.width}
                      onChange={(e) => setCropDraft(prev => ({ ...prev, width: e.target.value }))}
                      className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]" 
                    />
                  </div>
                  <div className="flex-1">
                    <label className="block text-[11px] font-medium mb-1 text-gray-800">Height</label>
                    <input 
                      type="number" 
                      value={cropDraft.height}
                      onChange={(e) => setCropDraft(prev => ({ ...prev, height: e.target.value }))}
                      className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]" 
                    />
                  </div>
                </div>
              </div>
            </div>
            <div className="p-4 flex justify-end space-x-3 bg-[#f3f3f3] border-t border-gray-200">
              <button 
                onClick={() => setActiveCropItem(null)}
                className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-white border border-gray-300 rounded text-gray-800 hover:bg-gray-50"
              >
                Cancel
              </button>
              <button 
                onClick={applyItemCrop}
                className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6]"
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      )}

      {activeResizeItem && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
          <div className="w-[400px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
            <div className="h-12 flex items-center justify-between px-6 relative">
              <span className="font-semibold text-gray-900 text-[15px]">
                Resize Image
              </span>
              <button onClick={() => setActiveResizeItem(null)} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
                <X size={16} />
              </button>
            </div>
            <div className="p-6 flex-1 bg-white">
              <div className="space-y-4">
                <div className="flex items-center space-x-4">
                  <div className="flex-1">
                    <label className="block text-[11px] font-medium mb-1 text-gray-800">Width</label>
                    <input 
                      type="number" 
                      value={resizeDraft.width}
                      onChange={(e) => setResizeDraft(prev => ({ ...prev, width: e.target.value }))}
                      className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]" 
                    />
                  </div>
                  <div className="mt-5 text-gray-400"><X size={14} /></div>
                  <div className="flex-1">
                    <label className="block text-[11px] font-medium mb-1 text-gray-800">Height</label>
                    <input 
                      type="number" 
                      value={resizeDraft.height}
                      onChange={(e) => setResizeDraft(prev => ({ ...prev, height: e.target.value }))}
                      className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]" 
                    />
                  </div>
                </div>
                <label className="flex items-center space-x-2 mt-4 cursor-pointer">
                  <input 
                    type="checkbox" 
                    checked={resizeDraft.lock}
                    onChange={(e) => setResizeDraft(prev => ({ ...prev, lock: e.target.checked }))}
                    className="rounded border-gray-300 text-[#005fb8] focus:ring-[#005fb8]/50 w-4 h-4" 
                  />
                  <span className="text-[13px] text-gray-800">Lock aspect ratio</span>
                </label>
              </div>
            </div>
            <div className="p-4 flex justify-end space-x-3 bg-[#f3f3f3] border-t border-gray-200">
              <button 
                onClick={() => setActiveResizeItem(null)}
                className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-white border border-gray-300 rounded text-gray-800 hover:bg-gray-50"
              >
                Cancel
              </button>
              <button 
                onClick={applyItemResize}
                className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6]"
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );

}

export default App;
