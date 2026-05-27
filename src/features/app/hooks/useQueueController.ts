import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import type { ChangeEvent, DragEventHandler } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import {
  initialQueueState,
  queueReducer,
  type JobResultEntry,
  type JobSnapshot,
  type QueueEventPayload,
} from '../../../state/queueState';
import {
  AUTOMATION_ACTION_ORDER,
  BACKGROUND_MODEL_LABELS,
  DEFAULT_AUTOMATION_ACTIONS,
  ENQUEUE_DEDUPE_WINDOW_MS,
  OUTPUT_FORMATS,
  PROFILE_PRESETS,
  SUPPORTED_FORMATS_LABEL,
  TERMINAL_JOB_STATUSES,
} from '../constants';
import type {
  AutomationActionKind,
  BackgroundRemovalEventPayload,
  BackgroundRemovalFocusRect,
  BackgroundRemovalModelStatus,
  BackgroundRemovalModelVariant,
  CompressionProfileId,
  ConversionRequest,
  DragValidationState,
  EnqueueAutomationPayload,
  FolderDropState,
  OutputImageFormat,
  PunchCropTransform,
  PunchQueueItem,
  RasterConversionDraft,
  ResizeDraft,
  CropDraft,
} from '../types';
import {
  asOptionalDimension,
  classifyInputPath,
  dragStateFromFiles,
  dragStateFromPaths,
  fileExtension,
  basename,
  isTauriRuntime,
} from '../utils';

type EnqueueOptionsPayload = {
  trim_transparent: boolean;
  transform: {
    crop_width?: number | null;
    crop_height?: number | null;
    crop_x?: number | null;
    crop_y?: number | null;
    crop_anchor?: 'center' | 'top_left' | 'top_right' | 'bottom_left' | 'bottom_right';
    resize_width: number | null;
    resize_height: number | null;
    resize_longest_side: number | null;
  };
  output_format: OutputImageFormat | null;
  compression: {
    quality: number;
    png_quant_quality_min: number;
    png_quant_quality_max: number;
    run_png_quant: boolean;
    png_quant_speed: number;
    run_pngcrush: boolean;
    run_zopfli: boolean;
    run_pngout: boolean;
    svg_multipass: boolean;
    gif_optimization_level: number;
    gif_lossy_level: number;
  };
};

type BuildOptionsOverride = {
  actions?: AutomationActionKind[];
  trimTransparent?: boolean;
  crop?: {
    width: number;
    height: number;
    x?: number | null;
    y?: number | null;
  };
  resize?: {
    width: number | null;
    height: number | null;
    longestSide?: number | null;
  };
  outputFormat?: OutputImageFormat | null;
};

const STORAGE_KEYS = {
  actions: 'pixelcrusher.automationActions',
  profile: 'pixelcrusher.profile',
  trimTransparent: 'pixelcrusher.trimTransparent',
  resizeEnabled: 'pixelcrusher.resizeEnabled',
  resizeLongestSide: 'pixelcrusher.resizeLongestSide',
  outputFormat: 'pixelcrusher.outputFormat',
  backgroundModel: 'pixelcrusher.backgroundModel',
};

function processingSourcePath(item: JobResultEntry): string {
  return item.output_path || item.input_path;
}

function normalizeFolderPath(path: string): string {
  return path.trim().replace(/\\+/g, '/').replace(/\/+$/g, '');
}

function deriveFolderDropState(paths: string[]): FolderDropState | null {
  const normalized = [...new Set(paths.map((path) => normalizeFolderPath(path)).filter((path) => path.length > 0))];

  if (normalized.length !== 1) {
    return null;
  }

  const folderPath = normalized[0];
  if (fileExtension(folderPath).length > 0) {
    return null;
  }

  return {
    id: `folder-${folderPath}-${Date.now()}`,
    folderName: basename(folderPath),
    folderPath,
  };
}

function parseNonNegativeCoordinate(raw: string): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) {
    return 0;
  }
  return Math.max(0, Math.floor(parsed));
}

function readStoredString(key: string): string | null {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStoredValue(key: string, value: unknown) {
  if (typeof window === 'undefined') {
    return;
  }

  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Persistence is a convenience; enqueue behavior should not depend on it.
  }
}

function readStoredScalarString(key: string): string | null {
  const raw = readStoredString(key);
  if (raw == null) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as unknown;
    return typeof parsed === 'string' ? parsed : raw;
  } catch {
    return raw;
  }
}

function readStoredBoolean(key: string, fallback: boolean): boolean {
  const raw = readStoredString(key);
  if (raw == null) {
    return fallback;
  }

  try {
    const parsed = JSON.parse(raw) as unknown;
    return typeof parsed === 'boolean' ? parsed : fallback;
  } catch {
    return fallback;
  }
}

function readStoredProfile(): CompressionProfileId {
  const raw = readStoredScalarString(STORAGE_KEYS.profile);
  if (raw === 'high' || raw === 'balanced' || raw === 'smallest') {
    return raw;
  }
  return 'balanced';
}

function readStoredOutputFormat(): OutputImageFormat | null {
  const raw = readStoredString(STORAGE_KEYS.outputFormat);
  if (raw == null || raw === 'null') {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as unknown;
    return OUTPUT_FORMATS.includes(parsed as OutputImageFormat) ? (parsed as OutputImageFormat) : null;
  } catch {
    return null;
  }
}

function readStoredBackgroundModel(): BackgroundRemovalModelVariant {
  const raw = readStoredScalarString(STORAGE_KEYS.backgroundModel);
  if (raw === 'fast' || raw === 'highQuality') {
    return raw;
  }
  return 'fast';
}

function normalizeAutomationActions(actions: AutomationActionKind[]): AutomationActionKind[] {
  const seen = new Set<AutomationActionKind>();
  const normalized = actions.filter((action) => {
    if (!AUTOMATION_ACTION_ORDER.includes(action) || seen.has(action)) {
      return false;
    }
    seen.add(action);
    return true;
  });

  if (!normalized.includes('compression')) {
    normalized.unshift('compression');
  }

  return normalized;
}

function readStoredAutomationActions(): AutomationActionKind[] {
  const raw = readStoredString(STORAGE_KEYS.actions);
  if (!raw) {
    return DEFAULT_AUTOMATION_ACTIONS;
  }

  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) {
      return DEFAULT_AUTOMATION_ACTIONS;
    }
    return normalizeAutomationActions(parsed as AutomationActionKind[]);
  } catch {
    return DEFAULT_AUTOMATION_ACTIONS;
  }
}

function isBackgroundRemovalSupported(path: string): boolean {
  const ext = fileExtension(path);
  return ext === 'png' || ext === 'jpg' || ext === 'jpeg';
}

export function useQueueController() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragState, setDragState] = useState<DragValidationState>('idle');

  const [profile, setProfileState] = useState<CompressionProfileId>(() => readStoredProfile());
  const [automationActions, setAutomationActionsState] = useState<AutomationActionKind[]>(() => readStoredAutomationActions());
  const [autoTrimTransparentBorders, setAutoTrimTransparentBordersState] = useState(() => readStoredBoolean(STORAGE_KEYS.trimTransparent, true));
  const [autoResizeLongestSideEnabled, setAutoResizeLongestSideEnabledState] = useState(() => readStoredBoolean(STORAGE_KEYS.resizeEnabled, false));
  const [autoResizeLongestSide, setAutoResizeLongestSideState] = useState(() => {
    const stored = readStoredScalarString(STORAGE_KEYS.resizeLongestSide);
    return stored ?? '1024';
  });
  const [autoConvertOutputFormat, setAutoConvertOutputFormatState] = useState<OutputImageFormat | null>(() => readStoredOutputFormat());
  const [selectedBackgroundRemovalModel, setSelectedBackgroundRemovalModelState] = useState<BackgroundRemovalModelVariant>(() => readStoredBackgroundModel());

  const [backgroundRemovalStatuses, setBackgroundRemovalStatuses] = useState<BackgroundRemovalModelStatus[]>([]);
  const [backgroundRemovalProgressMessage, setBackgroundRemovalProgressMessage] = useState<string | null>(null);
  const [backgroundRemovalErrorMessage, setBackgroundRemovalErrorMessage] = useState<string | null>(null);
  const [backgroundRemovalRunning, setBackgroundRemovalRunning] = useState(false);

  const [activeCropItem, setActiveCropItem] = useState<JobResultEntry | null>(null);
  const [activeResizeItem, setActiveResizeItem] = useState<JobResultEntry | null>(null);
  const [activeBackgroundRemovalItem, setActiveBackgroundRemovalItem] = useState<JobResultEntry | null>(null);
  const [activeConversionRequest, setActiveConversionRequest] = useState<ConversionRequest | null>(null);

  const [cropDraft, setCropDraft] = useState<CropDraft>({
    width: '',
    height: '',
    x: '0',
    y: '0',
  });
  const [resizeDraft, setResizeDraft] = useState<ResizeDraft>({ width: '', height: '', lock: true });
  const [rasterConversionDraft, setRasterConversionDraft] = useState<RasterConversionDraft>({ width: '', height: '', lock: true });

  const [dismissedResultIDs, setDismissedResultIDs] = useState<Set<string>>(new Set());
  const [punchQueue, setPunchQueue] = useState<PunchQueueItem[]>([]);
  const [activePunch, setActivePunch] = useState<PunchQueueItem | null>(null);
  const [activeFolderDrop, setActiveFolderDrop] = useState<FolderDropState | null>(null);
  const [activeFolderPunch, setActiveFolderPunch] = useState<FolderDropState | null>(null);
  const folderPunchTimerRef = useRef<number | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const dragDepthRef = useRef(0);
  const optionsPayloadRef = useRef<EnqueueOptionsPayload | null>(null);
  const automationPayloadRef = useRef<EnqueueAutomationPayload | null>(null);
  const enqueuePathsRef = useRef<((paths: string[]) => Promise<void>) | null>(null);
  const animatedPunchIDsRef = useRef<Set<string>>(new Set());
  const terminalPunchIDsRef = useRef<Set<string>>(new Set());
  const recentEnqueueRef = useRef<{ signature: string; at: number } | null>(null);
  const cropTransformByJobIDRef = useRef<Map<string, PunchCropTransform>>(new Map());

  const processedItems = useMemo(
    () => [...queueState.recent].reverse().filter((item) => !dismissedResultIDs.has(item.id)),
    [dismissedResultIDs, queueState.recent],
  );

  const setProfile = useCallback((next: CompressionProfileId) => {
    writeStoredValue(STORAGE_KEYS.profile, next);
    setProfileState(next);
  }, []);

  const setAutomationActions = useCallback((updater: AutomationActionKind[] | ((current: AutomationActionKind[]) => AutomationActionKind[])) => {
    setAutomationActionsState((current) => {
      const next = normalizeAutomationActions(typeof updater === 'function' ? updater(current) : updater);
      writeStoredValue(STORAGE_KEYS.actions, next);
      return next;
    });
  }, []);

  const setAutoTrimTransparentBorders = useCallback((next: boolean) => {
    writeStoredValue(STORAGE_KEYS.trimTransparent, next);
    setAutoTrimTransparentBordersState(next);
  }, []);

  const setAutoResizeLongestSideEnabled = useCallback((next: boolean) => {
    writeStoredValue(STORAGE_KEYS.resizeEnabled, next);
    setAutoResizeLongestSideEnabledState(next);
  }, []);

  const setAutoResizeLongestSide = useCallback((next: string) => {
    writeStoredValue(STORAGE_KEYS.resizeLongestSide, next);
    setAutoResizeLongestSideState(next);
  }, []);

  const setAutoConvertOutputFormat = useCallback((next: OutputImageFormat | null) => {
    writeStoredValue(STORAGE_KEYS.outputFormat, next);
    setAutoConvertOutputFormatState(next);
  }, []);

  const setSelectedBackgroundRemovalModel = useCallback((next: BackgroundRemovalModelVariant) => {
    writeStoredValue(STORAGE_KEYS.backgroundModel, next);
    setSelectedBackgroundRemovalModelState(next);
  }, []);

  const availableAutomationActions = useMemo(
    () => AUTOMATION_ACTION_ORDER.filter((action) => action !== 'compression' && !automationActions.includes(action)),
    [automationActions],
  );

  const selectedProfile = PROFILE_PRESETS[profile];

  const buildOptionsPayload = useCallback((override: BuildOptionsOverride = {}): EnqueueOptionsPayload => {
    const actions = normalizeAutomationActions(override.actions ?? automationActions);
    const hasResize = actions.includes('resize');
    const hasConvert = actions.includes('convertFormat');
    const hasTrim = actions.includes('trimTransparentBorders');
    const explicitResize = override.resize;
    const resizeLongestSide = explicitResize?.longestSide
      ?? (hasResize && autoResizeLongestSideEnabled ? asOptionalDimension(autoResizeLongestSide) : null);

    return {
      trim_transparent: override.crop ? false : (override.trimTransparent ?? (hasTrim && autoTrimTransparentBorders)),
      transform: {
        crop_width: override.crop?.width ?? null,
        crop_height: override.crop?.height ?? null,
        crop_x: override.crop?.x ?? null,
        crop_y: override.crop?.y ?? null,
        crop_anchor: 'center',
        resize_width: explicitResize?.width ?? null,
        resize_height: explicitResize?.height ?? null,
        resize_longest_side: resizeLongestSide,
      },
      output_format: override.outputFormat ?? (hasConvert ? autoConvertOutputFormat : null),
      compression: {
        quality: selectedProfile.quality,
        png_quant_quality_min: selectedProfile.pngQMin,
        png_quant_quality_max: selectedProfile.pngQMax,
        run_png_quant: selectedProfile.runPngQuant,
        png_quant_speed: 3,
        run_pngcrush: selectedProfile.runPngcrush,
        run_zopfli: selectedProfile.runZopfli,
        run_pngout: selectedProfile.runPngout,
        svg_multipass: true,
        gif_optimization_level: 3,
        gif_lossy_level: 0,
      },
    };
  }, [
    autoConvertOutputFormat,
    autoResizeLongestSide,
    autoResizeLongestSideEnabled,
    autoTrimTransparentBorders,
    automationActions,
    selectedProfile,
  ]);

  const optionsPayload = useMemo(() => buildOptionsPayload(), [buildOptionsPayload]);
  const automationPayload = useMemo(
    () => ({
      actions: automationActions,
      background_model: selectedBackgroundRemovalModel,
    }),
    [automationActions, selectedBackgroundRemovalModel],
  );

  useEffect(() => {
    optionsPayloadRef.current = optionsPayload;
    automationPayloadRef.current = automationPayload;
  }, [automationPayload, optionsPayload]);

  const refreshBackgroundRemovalStatuses = useCallback(async () => {
    try {
      const statuses = await invoke<BackgroundRemovalModelStatus[]>('background_removal_statuses');
      setBackgroundRemovalStatuses(statuses);
    } catch {
      setBackgroundRemovalStatuses([
        {
          model: 'fast',
          display_name: BACKGROUND_MODEL_LABELS.fast,
          short_label: 'Quantized',
          detail: 'Quantized RMBG-1.4 ONNX. Smaller download, lower memory use, slightly softer edges.',
          is_installed: false,
          model_path: '',
          installed_bytes: null,
          download_bytes: 44_403_226,
          suitability: {
            level: 'unavailable',
            message: 'Bundled background-removal runtime is missing.',
            is_available: false,
          },
        },
        {
          model: 'highQuality',
          display_name: BACKGROUND_MODEL_LABELS.highQuality,
          short_label: 'Full',
          detail: 'Full RMBG-1.4 ONNX. Larger download, heavier RAM use, better edge fidelity.',
          is_installed: false,
          model_path: '',
          installed_bytes: null,
          download_bytes: 176_153_355,
          suitability: {
            level: 'unavailable',
            message: 'Bundled background-removal runtime is missing.',
            is_available: false,
          },
        },
      ]);
    }
  }, []);

  const stopFolderPunch = useCallback(() => {
    if (folderPunchTimerRef.current != null) {
      window.clearTimeout(folderPunchTimerRef.current);
      folderPunchTimerRef.current = null;
    }

    setActiveFolderPunch(null);
  }, []);

  const startFolderPunch = useCallback((paths: string[]) => {
    const folderDrop = deriveFolderDropState(paths);
    if (!folderDrop) {
      return;
    }

    setActiveFolderDrop(folderDrop);
    setActiveFolderPunch(folderDrop);
  }, []);

  const enqueueWithOptions = useCallback(
    async (
      paths: string[],
      options: EnqueueOptionsPayload,
      cropTransform?: PunchCropTransform,
      automation?: EnqueueAutomationPayload,
    ): Promise<JobSnapshot[]> => {
      const created = await invoke<JobSnapshot[] | null>('enqueue_paths', { paths, options, automation });
      const createdJobs = Array.isArray(created) ? created : [];

      if (cropTransform) {
        createdJobs.forEach((job) => {
          cropTransformByJobIDRef.current.set(job.id, cropTransform);
        });
      }

      return createdJobs;
    },
    [],
  );

  const enqueuePaths = useCallback(async (paths: string[]) => {
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
    if (previous && previous.signature === signature && now - previous.at <= ENQUEUE_DEDUPE_WINDOW_MS) {
      return;
    }
    recentEnqueueRef.current = { signature, at: now };

    try {
      await enqueueWithOptions(
        accepted,
        optionsPayloadRef.current ?? optionsPayload,
        undefined,
        automationPayloadRef.current ?? automationPayload,
      );
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Queue start failed. Please try again.',
      });
    }
  }, [automationPayload, enqueueWithOptions, optionsPayload]);

  useEffect(() => {
    enqueuePathsRef.current = enqueuePaths;
  }, [enqueuePaths]);

  useEffect(() => {
    void refreshBackgroundRemovalStatuses();
  }, [refreshBackgroundRemovalStatuses]);

  useEffect(() => {
    if (!activeFolderPunch) {
      return;
    }

    folderPunchTimerRef.current = window.setTimeout(() => {
      stopFolderPunch();
    }, 1100);

    return () => {
      if (folderPunchTimerRef.current != null) {
        window.clearTimeout(folderPunchTimerRef.current);
        folderPunchTimerRef.current = null;
      }
    };
  }, [activeFolderPunch, stopFolderPunch]);

  useEffect(() => {
    invoke<JobResultEntry[]>('recent_results')
      .then((items) => {
        dispatch({ type: 'SET_RECENT', payload: items });
      })
      .catch(() => undefined);

    let unlistenQueue: (() => void) | undefined;
    let unlistenDragDrop: (() => void) | undefined;
    let unlistenBackgroundRemoval: (() => void) | undefined;
    let active = true;

    listen<QueueEventPayload>('queue://event', (event) => {
      dispatch({ type: 'INGEST_EVENT', payload: event.payload });

      const status = event.payload.job.status;
      const jobID = event.payload.job.id;
      const shouldAnimate = status === 'diagnosing' || status === 'processing' || status === 'optimizing';

      if (TERMINAL_JOB_STATUSES.has(status)) {
        terminalPunchIDsRef.current.add(jobID);
        cropTransformByJobIDRef.current.delete(jobID);
      }

      if (
        shouldAnimate
        && !terminalPunchIDsRef.current.has(jobID)
        && !animatedPunchIDsRef.current.has(jobID)
      ) {
        animatedPunchIDsRef.current.add(jobID);
        const cropTransform = cropTransformByJobIDRef.current.get(jobID);
        setPunchQueue((previous) => [
          ...previous,
          {
            id: jobID,
            inputPath: event.payload.job.input_path,
            cropTransform,
          },
        ]);
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

    listen<BackgroundRemovalEventPayload>('background-removal://event', (event) => {
      setBackgroundRemovalProgressMessage(event.payload.message);
    })
      .then((off) => {
        if (!active) {
          off();
          return;
        }
        unlistenBackgroundRemoval = off;
      })
      .catch(() => undefined);

    if (isTauriRuntime()) {
      getCurrentWebview()
        .onDragDropEvent((event) => {
          const payload = event.payload as { type: string; paths?: string[] };

          if (payload.type === 'enter' || payload.type === 'over') {
            setDragState(dragStateFromPaths(payload.paths ?? []));
            return;
          }

          if (payload.type === 'leave') {
            setDragState('idle');
            return;
          }

          if (payload.type === 'drop') {
            setDragState('idle');
            startFolderPunch(payload.paths ?? []);
            if (enqueuePathsRef.current) {
              void enqueuePathsRef.current(payload.paths ?? []);
            }
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
      unlistenBackgroundRemoval?.();
    };
  }, [startFolderPunch]);

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

  const onOpenSystemPicker = useCallback(async () => {
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
  }, [enqueuePaths]);

  const onOpenFolderPicker = useCallback(async () => {
    if (!isTauriRuntime()) {
      fileInputRef.current?.click();
      return;
    }

    try {
      const selected = await invoke<string | null>('select_input_folder');
      const folderPath = selected?.trim();
      if (!folderPath) {
        return;
      }

      startFolderPunch([folderPath]);
      await enqueuePaths([folderPath]);
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Unable to open the folder picker.',
      });
    }
  }, [enqueuePaths, startFolderPunch]);

  const onDropFiles: DragEventHandler<HTMLDivElement> = async (event) => {
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
    startFolderPunch(paths);

    await enqueuePaths(paths);
  };

  const onChooseFiles = async (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    const paths = files
      .map((file) => (file as unknown as { path?: string }).path)
      .filter((path): path is string => !!path);

    await enqueuePaths(paths);
    event.currentTarget.value = '';
  };

  const onDragEnter: DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    dragDepthRef.current += 1;
    setDragState(dragStateFromFiles(Array.from(event.dataTransfer.files ?? [])));
  };

  const onDragOver: DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    if (dragDepthRef.current <= 0) {
      dragDepthRef.current = 1;
    }
    setDragState(dragStateFromFiles(Array.from(event.dataTransfer.files ?? [])));
  };

  const onDragLeave: DragEventHandler<HTMLDivElement> = (event) => {
    event.preventDefault();
    dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
    if (dragDepthRef.current === 0) {
      setDragState('idle');
    }
  };

  const openItemCropModal = useCallback((item: JobResultEntry) => {
    setActiveCropItem(item);
    setCropDraft({ width: '', height: '', x: '0', y: '0' });
  }, []);

  const openItemResizeModal = useCallback((item: JobResultEntry) => {
    setActiveResizeItem(item);
    setResizeDraft({ width: '', height: '', lock: true });
  }, []);

  const openItemBackgroundRemovalModal = useCallback((item: JobResultEntry) => {
    setBackgroundRemovalProgressMessage(null);
    setBackgroundRemovalErrorMessage(null);
    setActiveBackgroundRemovalItem(item);
    void refreshBackgroundRemovalStatuses();
  }, [refreshBackgroundRemovalStatuses]);

  const openItemConversion = useCallback((item: JobResultEntry, targetFormat: OutputImageFormat) => {
    const sourcePath = processingSourcePath(item);
    if (fileExtension(sourcePath) === 'svg') {
      setRasterConversionDraft({ width: '', height: '', lock: true });
      setActiveConversionRequest({ item, targetFormat });
      return;
    }

    const options = {
      ...buildOptionsPayload({ actions: ['compression'], outputFormat: targetFormat }),
      output_format: targetFormat,
    };
    void enqueueWithOptions([sourcePath], options).catch(() => {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Format conversion failed. Please try again.',
      });
    });
  }, [buildOptionsPayload, enqueueWithOptions]);

  const applyItemCrop = useCallback(() => {
    if (!activeCropItem) {
      setActiveCropItem(null);
      return;
    }

    const width = asOptionalDimension(cropDraft.width);
    const height = asOptionalDimension(cropDraft.height);

    if (!width || !height) {
      setActiveCropItem(null);
      return;
    }

    const cropX = parseNonNegativeCoordinate(cropDraft.x);
    const cropY = parseNonNegativeCoordinate(cropDraft.y);
    const cropTransform: PunchCropTransform = {
      width,
      height,
      x: cropX,
      y: cropY,
      anchor: 'center',
    };

    const options = buildOptionsPayload({
      actions: ['compression'],
      crop: {
        width,
        height,
        x: cropX,
        y: cropY,
      },
      trimTransparent: false,
    });

    const sourcePath = processingSourcePath(activeCropItem);
    setActiveCropItem(null);
    void enqueueWithOptions([sourcePath], options, cropTransform).catch(() => {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Crop apply failed. Please try again.',
      });
    });
  }, [activeCropItem, buildOptionsPayload, cropDraft.height, cropDraft.width, cropDraft.x, cropDraft.y, enqueueWithOptions]);

  const applyItemResize = useCallback(() => {
    if (!activeResizeItem) {
      setActiveResizeItem(null);
      return;
    }

    const width = asOptionalDimension(resizeDraft.width);
    const height = asOptionalDimension(resizeDraft.height);
    if (!width || !height) {
      setActiveResizeItem(null);
      return;
    }

    const sourcePath = processingSourcePath(activeResizeItem);
    const options = buildOptionsPayload({
      actions: ['compression'],
      resize: {
        width,
        height,
      },
      trimTransparent: false,
    });
    setActiveResizeItem(null);

    void enqueueWithOptions([sourcePath], options).catch(() => {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Resize apply failed. Please try again.',
      });
    });
  }, [activeResizeItem, buildOptionsPayload, enqueueWithOptions, resizeDraft.height, resizeDraft.width]);

  const applyRasterConversion = useCallback(() => {
    if (!activeConversionRequest) {
      return;
    }

    const width = asOptionalDimension(rasterConversionDraft.width);
    const height = asOptionalDimension(rasterConversionDraft.height);
    const sourcePath = processingSourcePath(activeConversionRequest.item);
    const options = buildOptionsPayload({
      actions: ['compression'],
      outputFormat: activeConversionRequest.targetFormat,
      resize: {
        width,
        height,
      },
      trimTransparent: false,
    });

    setActiveConversionRequest(null);
    void enqueueWithOptions([sourcePath], options).catch(() => {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'SVG export failed. Please try again.',
      });
    });
  }, [activeConversionRequest, buildOptionsPayload, enqueueWithOptions, rasterConversionDraft.height, rasterConversionDraft.width]);

  const downloadBackgroundRemovalModel = useCallback(async (model: BackgroundRemovalModelVariant) => {
    setSelectedBackgroundRemovalModel(model);
    setBackgroundRemovalRunning(true);
    setBackgroundRemovalErrorMessage(null);
    setBackgroundRemovalProgressMessage(`Downloading ${BACKGROUND_MODEL_LABELS[model]} RMBG model`);

    try {
      const status = await invoke<BackgroundRemovalModelStatus>('download_background_removal_model', { model });
      setBackgroundRemovalStatuses((current) => {
        const rest = current.filter((item) => item.model !== status.model);
        return [...rest, status].sort((left, right) => left.model.localeCompare(right.model));
      });
      setBackgroundRemovalProgressMessage(null);
    } catch (error) {
      setBackgroundRemovalErrorMessage(error instanceof Error ? error.message : String(error));
    } finally {
      setBackgroundRemovalRunning(false);
    }
  }, [setSelectedBackgroundRemovalModel]);

  const applyBackgroundRemoval = useCallback(async (focusRect: BackgroundRemovalFocusRect | null) => {
    if (!activeBackgroundRemovalItem || backgroundRemovalRunning) {
      return;
    }

    const sourcePath = processingSourcePath(activeBackgroundRemovalItem);
    if (!isBackgroundRemovalSupported(sourcePath)) {
      setBackgroundRemovalErrorMessage('Background removal supports PNG and JPEG only.');
      return;
    }

    setBackgroundRemovalRunning(true);
    setBackgroundRemovalErrorMessage(null);
    setBackgroundRemovalProgressMessage('Preparing background removal');

    try {
      const result = await invoke<JobResultEntry>('remove_background', {
        inputPath: sourcePath,
        model: selectedBackgroundRemovalModel,
        focusRect,
        options: buildOptionsPayload({ actions: ['compression'], trimTransparent: false }),
      });
      dispatch({
        type: 'INGEST_EVENT',
        payload: {
          job: {
            id: result.id,
            input_path: result.input_path,
            status: 'completed',
            progress: 100,
            message: 'Background removed',
          },
          result,
        },
      });
      setActiveBackgroundRemovalItem(null);
      setBackgroundRemovalProgressMessage(null);
    } catch (error) {
      setBackgroundRemovalErrorMessage(error instanceof Error ? error.message : String(error));
    } finally {
      setBackgroundRemovalRunning(false);
    }
  }, [
    activeBackgroundRemovalItem,
    backgroundRemovalRunning,
    buildOptionsPayload,
    selectedBackgroundRemovalModel,
  ]);

  const addAutomationAction = useCallback((action: AutomationActionKind) => {
    if (action === 'compression') {
      return;
    }
    setAutomationActions((current) => [...current, action]);
  }, [setAutomationActions]);

  const removeAutomationAction = useCallback((action: AutomationActionKind) => {
    if (action === 'compression') {
      return;
    }
    setAutomationActions((current) => current.filter((item) => item !== action));
  }, [setAutomationActions]);

  const moveAutomationAction = useCallback((action: AutomationActionKind, direction: -1 | 1) => {
    setAutomationActions((current) => {
      const index = current.indexOf(action);
      const target = index + direction;
      if (index < 0 || target < 0 || target >= current.length) {
        return current;
      }
      const next = [...current];
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  }, [setAutomationActions]);

  const handlePunchComplete = useCallback(() => {
    setActivePunch(null);
  }, []);

  const handleFolderPunchComplete = useCallback(() => {
    stopFolderPunch();
  }, [stopFolderPunch]);

  const clearProcessedItems = useCallback(() => {
    setDismissedResultIDs((previous) => {
      const next = new Set(previous);
      queueState.recent.forEach((item) => next.add(item.id));
      return next;
    });
  }, [queueState.recent]);

  const hasActiveJobs = Object.values(queueState.jobs).some((job) => !TERMINAL_JOB_STATUSES.has(job.status));
  const isEmptyState = processedItems.length === 0 && activePunch == null && activeFolderPunch == null && !hasActiveJobs && activeFolderDrop == null;

  return {
    queueState,
    dragState,
    profile,
    setProfile,
    automationActions,
    availableAutomationActions,
    autoTrimTransparentBorders,
    setAutoTrimTransparentBorders,
    autoResizeLongestSideEnabled,
    setAutoResizeLongestSideEnabled,
    autoResizeLongestSide,
    setAutoResizeLongestSide,
    autoConvertOutputFormat,
    setAutoConvertOutputFormat,
    selectedBackgroundRemovalModel,
    setSelectedBackgroundRemovalModel,
    backgroundRemovalStatuses,
    backgroundRemovalProgressMessage,
    backgroundRemovalErrorMessage,
    backgroundRemovalRunning,
    activeCropItem,
    activeResizeItem,
    activeBackgroundRemovalItem,
    activeConversionRequest,
    cropDraft,
    setCropDraft,
    resizeDraft,
    setResizeDraft,
    rasterConversionDraft,
    setRasterConversionDraft,
    activePunch,
    activeFolderDrop,
    activeFolderPunch,
    fileInputRef,
    scrollViewportRef,
    processedItems,
    isEmptyState,
    onOpenSystemPicker,
    onOpenFolderPicker,
    onDropFiles,
    onChooseFiles,
    onDragEnter,
    onDragOver,
    onDragLeave,
    openItemCropModal,
    openItemResizeModal,
    openItemBackgroundRemovalModal,
    openItemConversion,
    applyItemCrop,
    applyItemResize,
    applyRasterConversion,
    applyBackgroundRemoval,
    downloadBackgroundRemovalModel,
    addAutomationAction,
    removeAutomationAction,
    moveAutomationAction,
    handlePunchComplete,
    handleFolderPunchComplete,
    clearProcessedItems,
    closeCropModal: () => setActiveCropItem(null),
    closeResizeModal: () => setActiveResizeItem(null),
    closeBackgroundRemovalModal: () => {
      if (!backgroundRemovalRunning) {
        setActiveBackgroundRemovalItem(null);
      }
    },
    closeConversionModal: () => setActiveConversionRequest(null),
  };
}
