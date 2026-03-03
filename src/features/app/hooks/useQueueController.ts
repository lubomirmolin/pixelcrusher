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
  ENQUEUE_DEDUPE_WINDOW_MS,
  PROFILE_PRESETS,
  SUPPORTED_FORMATS_LABEL,
  TERMINAL_JOB_STATUSES,
} from '../constants';
import type {
  CompressionProfileId,
  CropDraft,
  DragValidationState,
  FolderDropState,
  PunchCropTransform,
  PunchQueueItem,
  ResizeDraft,
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
  };
  compression: {
    quality: number;
    png_quant_quality_min: number;
    png_quant_quality_max: number;
    run_png_quant: boolean;
    run_pngcrush: boolean;
    run_zopfli: boolean;
    run_pngout: boolean;
  };
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

export function useQueueController() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragState, setDragState] = useState<DragValidationState>('idle');

  const [profile, setProfile] = useState<CompressionProfileId>('balanced');
  const autoCrop = true;

  const [resizeWidth, setResizeWidth] = useState('');
  const [resizeHeight, setResizeHeight] = useState('');

  const [activeCropItem, setActiveCropItem] = useState<JobResultEntry | null>(null);
  const [activeResizeItem, setActiveResizeItem] = useState<JobResultEntry | null>(null);
  const [cropDraft, setCropDraft] = useState<CropDraft>({
    width: '',
    height: '',
    x: '0',
    y: '0',
  });
  const [resizeDraft, setResizeDraft] = useState<ResizeDraft>({ width: '', height: '', lock: true });

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
  const enqueuePathsRef = useRef<((paths: string[]) => Promise<void>) | null>(null);
  const animatedPunchIDsRef = useRef<Set<string>>(new Set());
  const terminalPunchIDsRef = useRef<Set<string>>(new Set());
  const recentEnqueueRef = useRef<{ signature: string; at: number } | null>(null);
  const cropTransformByJobIDRef = useRef<Map<string, PunchCropTransform>>(new Map());

  const processedItems = useMemo(
    () => [...queueState.recent].reverse().filter((item) => !dismissedResultIDs.has(item.id)),
    [dismissedResultIDs, queueState.recent],
  );

  const selectedProfile = PROFILE_PRESETS[profile];

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: autoCrop,
      transform: {
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
    [autoCrop, resizeHeight, resizeWidth, selectedProfile],
  );

  useEffect(() => {
    optionsPayloadRef.current = optionsPayload;
  }, [optionsPayload]);

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
    ): Promise<JobSnapshot[]> => {
      const created = await invoke<JobSnapshot[] | null>('enqueue_paths', { paths, options });
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
      await enqueueWithOptions(accepted, optionsPayloadRef.current ?? optionsPayload);
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Queue start failed. Please try again.',
      });
    }
  }, [enqueueWithOptions, optionsPayload]);

  useEffect(() => {
    enqueuePathsRef.current = enqueuePaths;
  }, [enqueuePaths]);

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
    };
  }, []);

  useEffect(() => {
    if (activePunch || punchQueue.length === 0) {
      return;
    }

    // eslint-disable-next-line react-hooks/set-state-in-effect
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
    setResizeDraft({ width: resizeWidth, height: resizeHeight, lock: true });
  }, [resizeHeight, resizeWidth]);

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

    const baseOptions = optionsPayloadRef.current ?? optionsPayload;
    const options: EnqueueOptionsPayload = {
      ...baseOptions,
      // Manual crop should not run auto-trim first, otherwise the source bounds can shift.
      trim_transparent: false,
      transform: {
        ...baseOptions.transform,
        crop_width: width,
        crop_height: height,
        crop_x: cropX,
        crop_y: cropY,
        crop_anchor: 'center',
      },
    };

    const sourcePath = processingSourcePath(activeCropItem);
    setActiveCropItem(null);
    void enqueueWithOptions([sourcePath], options, cropTransform).catch(() => {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Crop apply failed. Please try again.',
      });
    });
  }, [activeCropItem, cropDraft.height, cropDraft.width, cropDraft.x, cropDraft.y, enqueueWithOptions, optionsPayload]);

  const applyItemResize = useCallback(() => {
    setResizeWidth(resizeDraft.width);
    setResizeHeight(resizeDraft.height);
    setActiveResizeItem(null);
  }, [resizeDraft.height, resizeDraft.width]);

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
    autoCrop,
    activeCropItem,
    activeResizeItem,
    cropDraft,
    setCropDraft,
    resizeDraft,
    setResizeDraft,
    activePunch,
    activeFolderDrop,
    activeFolderPunch,
    fileInputRef,
    scrollViewportRef,
    processedItems,
    isEmptyState,
    onOpenSystemPicker,
    onDropFiles,
    onChooseFiles,
    onDragEnter,
    onDragOver,
    onDragLeave,
    openItemCropModal,
    openItemResizeModal,
    applyItemCrop,
    applyItemResize,
    handlePunchComplete,
    handleFolderPunchComplete,
    clearProcessedItems,
    closeCropModal: () => setActiveCropItem(null),
    closeResizeModal: () => setActiveResizeItem(null),
  };
}
