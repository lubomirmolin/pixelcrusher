import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import type { ChangeEvent, DragEventHandler } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import {
  initialQueueState,
  queueReducer,
  type JobResultEntry,
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
  PunchQueueItem,
  ResizeDraft,
} from '../types';
import {
  asOptionalDimension,
  classifyInputPath,
  dragStateFromFiles,
  dragStateFromPaths,
  isTauriRuntime,
} from '../utils';

export function useQueueController() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragState, setDragState] = useState<DragValidationState>('idle');

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
  const [punchQueue, setPunchQueue] = useState<PunchQueueItem[]>([]);
  const [activePunch, setActivePunch] = useState<PunchQueueItem | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const dragDepthRef = useRef(0);
  const optionsPayloadRef = useRef<Record<string, unknown> | null>(null);
  const enqueuePathsRef = useRef<((paths: string[]) => Promise<void>) | null>(null);
  const animatedPunchIDsRef = useRef<Set<string>>(new Set());
  const terminalPunchIDsRef = useRef<Set<string>>(new Set());
  const recentEnqueueRef = useRef<{ signature: string; at: number } | null>(null);

  const processedItems = useMemo(
    () => [...queueState.recent].reverse().filter((item) => !dismissedResultIDs.has(item.id)),
    [dismissedResultIDs, queueState.recent],
  );

  const selectedProfile = PROFILE_PRESETS[profile];

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: autoCrop,
      transform: {
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
  }, [optionsPayload]);

  useEffect(() => {
    enqueuePathsRef.current = enqueuePaths;
  }, [enqueuePaths]);

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
      }

      if (
        shouldAnimate
        && !terminalPunchIDsRef.current.has(jobID)
        && !animatedPunchIDsRef.current.has(jobID)
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
            setDragState(dragStateFromPaths(payload.paths ?? []));
            return;
          }

          if (payload.type === 'leave') {
            setDragState('idle');
            return;
          }

          if (payload.type === 'drop') {
            setDragState('idle');
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
    setCropDraft({ width: cropWidth, height: cropHeight });
  }, [cropHeight, cropWidth]);

  const openItemResizeModal = useCallback((item: JobResultEntry) => {
    setActiveResizeItem(item);
    setResizeDraft({ width: resizeWidth, height: resizeHeight, lock: true });
  }, [resizeHeight, resizeWidth]);

  const applyItemCrop = useCallback(() => {
    setCropWidth(cropDraft.width);
    setCropHeight(cropDraft.height);
    setActiveCropItem(null);
  }, [cropDraft.height, cropDraft.width]);

  const applyItemResize = useCallback(() => {
    setResizeWidth(resizeDraft.width);
    setResizeHeight(resizeDraft.height);
    setActiveResizeItem(null);
  }, [resizeDraft.height, resizeDraft.width]);

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
    clearProcessedItems,
    closeCropModal: () => setActiveCropItem(null),
    closeResizeModal: () => setActiveResizeItem(null),
  };
}
