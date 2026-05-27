import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { CheckCircle2, Loader2, RotateCcw, X } from 'lucide-react';
import { formatBytes, type JobResultEntry } from '../state/queueState';
import type {
  BackgroundRemovalFocusRect,
  BackgroundRemovalModelStatus,
  BackgroundRemovalModelVariant,
} from '../features/app/types';
import { basename, toAssetUrl } from '../features/app/utils';

type BackgroundRemovalModalProps = {
  activeItem: JobResultEntry | null;
  modelStatuses: BackgroundRemovalModelStatus[];
  selectedModel: BackgroundRemovalModelVariant;
  setSelectedModel: (next: BackgroundRemovalModelVariant) => void;
  isRunning: boolean;
  progressMessage: string | null;
  errorMessage: string | null;
  onClose: () => void;
  onDownloadModel: (model: BackgroundRemovalModelVariant) => void;
  onQuickRemove: () => void;
  onFocusedRemove: (focusRect: BackgroundRemovalFocusRect) => void;
};

type Size = {
  width: number;
  height: number;
};

type DisplayRect = {
  left: number;
  top: number;
  width: number;
  height: number;
};

type DragMode = 'move' | 'resize';
type ResizeHandle = 'nw' | 'ne' | 'sw' | 'se';

type DragState = {
  pointerId: number;
  mode: DragMode;
  handle?: ResizeHandle;
  startPoint: { x: number; y: number };
  startRect: BackgroundRemovalFocusRect;
};

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function defaultFocusRect(sourceSize: Size): BackgroundRemovalFocusRect {
  const insetX = Math.round(sourceSize.width * 0.15);
  const insetY = Math.round(sourceSize.height * 0.15);
  return {
    x: insetX,
    y: insetY,
    width: Math.max(1, sourceSize.width - insetX * 2),
    height: Math.max(1, sourceSize.height - insetY * 2),
  };
}

function fittedRect(container: Size, source: Size): DisplayRect {
  const containerRatio = container.width / container.height;
  const sourceRatio = source.width / source.height;

  if (containerRatio > sourceRatio) {
    const height = container.height;
    const width = height * sourceRatio;
    return {
      left: (container.width - width) / 2,
      top: 0,
      width,
      height,
    };
  }

  const width = container.width;
  const height = width / sourceRatio;
  return {
    left: 0,
    top: (container.height - height) / 2,
    width,
    height,
  };
}

function normalizeFocusRect(rect: BackgroundRemovalFocusRect, sourceSize: Size): BackgroundRemovalFocusRect {
  const width = clamp(Math.round(rect.width), 1, sourceSize.width);
  const height = clamp(Math.round(rect.height), 1, sourceSize.height);
  const x = clamp(Math.round(rect.x), 0, Math.max(0, sourceSize.width - width));
  const y = clamp(Math.round(rect.y), 0, Math.max(0, sourceSize.height - height));
  return { x, y, width, height };
}

function statusLine(status: BackgroundRemovalModelStatus): string {
  if (status.is_installed && status.installed_bytes != null) {
    return `Installed - ${formatBytes(status.installed_bytes)}`;
  }

  return `Download - ${formatBytes(status.download_bytes)}`;
}

export function BackgroundRemovalModal({
  activeItem,
  modelStatuses,
  selectedModel,
  setSelectedModel,
  isRunning,
  progressMessage,
  errorMessage,
  onClose,
  onDownloadModel,
  onQuickRemove,
  onFocusedRemove,
}: BackgroundRemovalModalProps) {
  const sourcePath = activeItem ? activeItem.output_path || activeItem.input_path : '';
  const [loadedSourceSize, setLoadedSourceSize] = useState<{ path: string; size: Size } | null>(null);
  const [focusRectState, setFocusRectState] = useState<{ path: string; rect: BackgroundRemovalFocusRect } | null>(null);
  const [useFocusRectState, setUseFocusRectState] = useState<{ path: string; enabled: boolean } | null>(null);
  const sourceSize = loadedSourceSize?.path === sourcePath ? loadedSourceSize.size : null;
  const focusRect = focusRectState?.path === sourcePath ? focusRectState.rect : null;
  const useFocusRect = useFocusRectState?.path === sourcePath ? useFocusRectState.enabled : false;
  const setCurrentFocusRect = useCallback((next: BackgroundRemovalFocusRect) => {
    setFocusRectState({ path: sourcePath, rect: next });
  }, [sourcePath]);

  useEffect(() => {
    if (!activeItem || !sourcePath) {
      return;
    }

    let cancelled = false;
    const image = new Image();
    image.onload = () => {
      if (cancelled) {
        return;
      }

      const nextSize = {
        width: Math.max(1, image.naturalWidth),
        height: Math.max(1, image.naturalHeight),
      };
      setLoadedSourceSize({ path: sourcePath, size: nextSize });
      setFocusRectState({ path: sourcePath, rect: defaultFocusRect(nextSize) });
    };
    image.src = toAssetUrl(sourcePath);

    return () => {
      cancelled = true;
    };
  }, [activeItem, sourcePath]);

  const selectedStatus = useMemo(
    () => modelStatuses.find((status) => status.model === selectedModel) ?? null,
    [modelStatuses, selectedModel],
  );
  const canRunSelectedModel = !!selectedStatus
    && selectedStatus.is_installed
    && selectedStatus.suitability.is_available;

  if (!activeItem) {
    return null;
  }

  const resolvedFocusRect = focusRect ?? (sourceSize ? defaultFocusRect(sourceSize) : null);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm" role="dialog" aria-label="remove-background-modal">
      <div className="flex w-[780px] max-w-[calc(100vw-32px)] flex-col overflow-hidden rounded-lg border border-gray-300 bg-white shadow-2xl">
        <div className="flex items-start justify-between gap-4 px-5 py-4">
          <div className="min-w-0">
            <h2 className="text-[18px] font-semibold text-gray-900">Remove Background</h2>
            <p className="mt-0.5 truncate text-[12px] font-medium text-gray-500">{basename(sourcePath)}</p>
            {selectedStatus ? (
              <p className="mt-1 text-[11px] font-medium text-gray-500">{statusLine(selectedStatus)}</p>
            ) : null}
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => {
                if (sourceSize) {
                  setCurrentFocusRect(defaultFocusRect(sourceSize));
                }
              }}
              disabled={isRunning || !useFocusRect || !sourceSize}
              className="inline-flex items-center gap-1.5 rounded border border-gray-300 bg-white px-2.5 py-1 text-[12px] font-medium text-gray-700 shadow-sm hover:bg-gray-50 disabled:opacity-50"
            >
              <RotateCcw size={13} />
              Reset Focus
            </button>
            <button
              type="button"
              onClick={onClose}
              disabled={isRunning}
              className="rounded p-1 text-gray-500 transition-colors hover:bg-black/5 hover:text-[#e81123] disabled:opacity-50"
              title="Cancel"
            >
              <X size={16} />
            </button>
          </div>
        </div>

        <div className="grid gap-4 border-y border-gray-200 bg-white px-5 pb-5">
          <div>
            <div className="mb-2 text-[13px] font-semibold text-gray-900">Model</div>
            <div className="grid grid-cols-2 gap-3">
              {modelStatuses.map((status) => (
                <div
                  key={status.model}
                  role="button"
                  tabIndex={0}
                  onClick={() => setSelectedModel(status.model)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault();
                      setSelectedModel(status.model);
                    }
                  }}
                  className={`rounded-lg border p-3 text-left transition-colors ${
                    status.model === selectedModel
                      ? 'border-[#005fb8] bg-[#005fb8]/5'
                      : 'border-gray-200 bg-[#f8f9fb] hover:bg-white'
                  } ${isRunning ? 'pointer-events-none opacity-70' : ''}`}
                >
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <div className="text-[14px] font-semibold text-gray-900">{status.display_name}</div>
                      <div className="text-[11px] font-medium text-gray-500">{status.short_label}</div>
                    </div>
                    {status.model === selectedModel ? (
                      <span className="rounded-full bg-[#005fb8]/10 px-2 py-0.5 text-[11px] font-semibold text-[#005fb8]">Selected</span>
                    ) : null}
                  </div>
                  <p className="mt-2 text-[12px] leading-4 text-gray-600">{status.detail}</p>
                  <p className="mt-2 text-[11px] font-medium text-gray-500">{statusLine(status)}</p>
                  <p className={`mt-1 text-[11px] font-medium ${status.suitability.is_available ? 'text-gray-500' : 'text-[#9a2e3a]'}`}>
                    {status.suitability.message}
                  </p>
                  <div className="mt-3 flex items-center gap-2">
                    {status.is_installed ? (
                      <span className="inline-flex items-center gap-1 text-[12px] font-semibold text-[#107c10]">
                        <CheckCircle2 size={14} />
                        Installed
                      </span>
                    ) : (
                      <button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          onDownloadModel(status.model);
                        }}
                        disabled={isRunning || !status.suitability.is_available}
                        className={`rounded border border-[#005fb8] bg-[#005fb8] px-2.5 py-1 text-[12px] font-semibold text-white ${
                          isRunning || !status.suitability.is_available ? 'opacity-50' : ''
                        }`}
                      >
                        Download
                      </button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>

          <SubjectFocusCanvas
            sourcePath={sourcePath}
            sourceSize={sourceSize}
            focusRect={resolvedFocusRect}
            setFocusRect={setCurrentFocusRect}
            enabled={useFocusRect && !isRunning}
          />

          <div className="space-y-2">
            {selectedStatus ? (
              <p className={`text-[12px] font-medium ${selectedStatus.suitability.is_available ? 'text-gray-600' : 'text-[#9a2e3a]'}`}>
                {selectedStatus.suitability.message}
              </p>
            ) : (
              <p className="text-[12px] font-medium text-gray-600">Loading model status</p>
            )}
            {progressMessage ? (
              <div className="flex items-center gap-2 text-[12px] font-medium text-gray-600">
                <Loader2 size={14} className="animate-spin" />
                {progressMessage}
              </div>
            ) : null}
            {errorMessage ? (
              <p className="text-[12px] font-medium text-[#9a2e3a]">{errorMessage}</p>
            ) : null}
            {selectedStatus && !selectedStatus.is_installed ? (
              <p className="text-[11px] font-medium text-gray-500">Download the selected model before running removal.</p>
            ) : null}
          </div>

          <label className="flex cursor-pointer items-center gap-2 text-[13px] font-medium text-gray-800">
            <input
              type="checkbox"
              checked={useFocusRect}
              onChange={(event) => setUseFocusRectState({ path: sourcePath, enabled: event.target.checked })}
              disabled={isRunning}
              className="h-4 w-4 rounded border-gray-300 text-[#005fb8] focus:ring-[#005fb8]/50"
            />
            Focus on a selected subject
          </label>
        </div>

        <div className="flex items-center justify-end gap-3 bg-[#f3f3f3] p-4">
          <button
            type="button"
            onClick={onClose}
            disabled={isRunning}
            className="rounded border border-gray-300 bg-white px-5 py-1.5 text-[13px] font-medium text-gray-800 shadow-sm transition-colors hover:bg-gray-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onQuickRemove}
            disabled={isRunning || !canRunSelectedModel}
            className="rounded border border-gray-300 bg-white px-5 py-1.5 text-[13px] font-medium text-gray-800 shadow-sm transition-colors hover:bg-gray-50 disabled:opacity-50"
          >
            Quick Remove
          </button>
          <button
            type="button"
            onClick={() => {
              if (resolvedFocusRect) {
                onFocusedRemove(resolvedFocusRect);
              }
            }}
            disabled={isRunning || !useFocusRect || !canRunSelectedModel || !resolvedFocusRect}
            className="rounded border border-transparent bg-[#005fb8] px-5 py-1.5 text-[13px] font-medium text-white shadow-sm transition-colors hover:bg-[#0058a6] disabled:opacity-50"
          >
            Remove Focused Subject
          </button>
        </div>
      </div>
    </div>
  );
}

type SubjectFocusCanvasProps = {
  sourcePath: string;
  sourceSize: Size | null;
  focusRect: BackgroundRemovalFocusRect | null;
  setFocusRect: (next: BackgroundRemovalFocusRect) => void;
  enabled: boolean;
};

function SubjectFocusCanvas({
  sourcePath,
  sourceSize,
  focusRect,
  setFocusRect,
  enabled,
}: SubjectFocusCanvasProps) {
  const frameRef = useRef<HTMLDivElement>(null);
  const [displayRect, setDisplayRect] = useState<DisplayRect | null>(null);
  const [dragState, setDragState] = useState<DragState | null>(null);

  const updateDisplayRect = useCallback(() => {
    if (!sourceSize || !frameRef.current) {
      return;
    }

    const bounds = frameRef.current.getBoundingClientRect();
    const inset = 10;
    setDisplayRect(
      fittedRect(
        { width: Math.max(1, bounds.width - inset * 2), height: Math.max(1, bounds.height - inset * 2) },
        sourceSize,
      ),
    );
  }, [sourceSize]);

  useEffect(() => {
    updateDisplayRect();
    const onResize = () => updateDisplayRect();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, [updateDisplayRect]);

  const adjustedDisplayRect = useMemo(() => {
    if (!displayRect) {
      return null;
    }
    return {
      ...displayRect,
      left: displayRect.left + 10,
      top: displayRect.top + 10,
    };
  }, [displayRect]);

  const focusStyle = useMemo(() => {
    if (!adjustedDisplayRect || !focusRect || !sourceSize) {
      return null;
    }

    const scaleX = adjustedDisplayRect.width / sourceSize.width;
    const scaleY = adjustedDisplayRect.height / sourceSize.height;
    return {
      left: adjustedDisplayRect.left + focusRect.x * scaleX,
      top: adjustedDisplayRect.top + focusRect.y * scaleY,
      width: Math.max(1, focusRect.width * scaleX),
      height: Math.max(1, focusRect.height * scaleY),
    };
  }, [adjustedDisplayRect, focusRect, sourceSize]);

  const toSourcePoint = useCallback((clientX: number, clientY: number) => {
    if (!frameRef.current || !adjustedDisplayRect || !sourceSize) {
      return null;
    }

    const frameBounds = frameRef.current.getBoundingClientRect();
    const localX = clamp(clientX - frameBounds.left - adjustedDisplayRect.left, 0, adjustedDisplayRect.width);
    const localY = clamp(clientY - frameBounds.top - adjustedDisplayRect.top, 0, adjustedDisplayRect.height);
    return {
      x: Math.round((localX / adjustedDisplayRect.width) * sourceSize.width),
      y: Math.round((localY / adjustedDisplayRect.height) * sourceSize.height),
    };
  }, [adjustedDisplayRect, sourceSize]);

  const beginDrag = (
    event: ReactPointerEvent<HTMLDivElement>,
    mode: DragMode,
    handle?: ResizeHandle,
  ) => {
    if (!enabled || !focusRect) {
      return;
    }

    const point = toSourcePoint(event.clientX, event.clientY);
    if (!point) {
      return;
    }

    event.currentTarget.setPointerCapture(event.pointerId);
    setDragState({
      pointerId: event.pointerId,
      mode,
      handle,
      startPoint: point,
      startRect: focusRect,
    });
  };

  const updateDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragState || !sourceSize) {
      return;
    }

    const point = toSourcePoint(event.clientX, event.clientY);
    if (!point) {
      return;
    }

    const deltaX = point.x - dragState.startPoint.x;
    const deltaY = point.y - dragState.startPoint.y;
    const start = dragState.startRect;

    if (dragState.mode === 'move') {
      setFocusRect(normalizeFocusRect({
        ...start,
        x: start.x + deltaX,
        y: start.y + deltaY,
      }, sourceSize));
      return;
    }

    const left = dragState.handle?.includes('w') ? start.x + deltaX : start.x;
    const right = dragState.handle?.includes('e') ? start.x + start.width + deltaX : start.x + start.width;
    const top = dragState.handle?.includes('n') ? start.y + deltaY : start.y;
    const bottom = dragState.handle?.includes('s') ? start.y + start.height + deltaY : start.y + start.height;

    setFocusRect(normalizeFocusRect({
      x: Math.min(left, right),
      y: Math.min(top, bottom),
      width: Math.abs(right - left),
      height: Math.abs(bottom - top),
    }, sourceSize));
  };

  const endDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (dragState?.pointerId === event.pointerId) {
      setDragState(null);
    }
  };

  return (
    <div
      ref={frameRef}
      className="relative h-[360px] overflow-hidden rounded-lg border border-gray-200 bg-[#f1f2f4]"
      onPointerMove={updateDrag}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
    >
      {adjustedDisplayRect ? (
        <img
          src={toAssetUrl(sourcePath)}
          alt=""
          className="absolute object-contain"
          style={{
            left: adjustedDisplayRect.left,
            top: adjustedDisplayRect.top,
            width: adjustedDisplayRect.width,
            height: adjustedDisplayRect.height,
          }}
        />
      ) : null}

      {adjustedDisplayRect && focusStyle ? (
        <>
          <div className="absolute inset-0 bg-black/20" />
          <div
            className="absolute border-2 border-white shadow-[0_0_0_9999px_rgba(0,0,0,0.34)]"
            style={focusStyle}
            onPointerDown={(event) => beginDrag(event, 'move')}
          >
            {(['nw', 'ne', 'sw', 'se'] as ResizeHandle[]).map((handle) => {
              const horizontal = handle.includes('w') ? '-left-1.5' : '-right-1.5';
              const vertical = handle.includes('n') ? '-top-1.5' : '-bottom-1.5';
              return (
                <div
                  key={handle}
                  className={`absolute h-3 w-3 rounded-full border border-gray-500 bg-white ${horizontal} ${vertical}`}
                  onPointerDown={(event) => {
                    event.stopPropagation();
                    beginDrag(event, 'resize', handle);
                  }}
                />
              );
            })}
          </div>
        </>
      ) : (
        <div className="grid h-full place-items-center text-[12px] font-medium text-gray-500">Loading preview</div>
      )}
    </div>
  );
}
