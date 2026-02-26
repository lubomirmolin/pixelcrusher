import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { Crop, X } from 'lucide-react';
import type { JobResultEntry } from '../state/queueState';
import type { CropDraft } from '../features/app/types';
import { toAssetUrl } from '../features/app/utils';

type CropModalProps = {
  activeItem: JobResultEntry | null;
  draft: CropDraft;
  onDraftChange: (next: CropDraft) => void;
  onClose: () => void;
  onApply: () => void;
};

type Size = {
  width: number;
  height: number;
};

type Rect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

type DisplayRect = {
  left: number;
  top: number;
  width: number;
  height: number;
};

type DragMode = 'create' | 'move';

type DragState = {
  pointerId: number;
  mode: DragMode;
  startX: number;
  startY: number;
  originX: number;
  originY: number;
  width: number;
  height: number;
};

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function parsePositiveInt(value: string): number | null {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }
  return Math.floor(parsed);
}

function parseNonNegativeInt(value: string): number | null {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }
  return Math.floor(parsed);
}

function toContainRect(container: Size, source: Size): DisplayRect {
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

export function CropModal({ activeItem, draft, onDraftChange, onClose, onApply }: CropModalProps) {
  const frameRef = useRef<HTMLDivElement>(null);
  const initializedSourcePathRef = useRef<string | null>(null);
  const [sourceSize, setSourceSize] = useState<Size | null>(null);
  const [displayRect, setDisplayRect] = useState<DisplayRect | null>(null);
  const [dragState, setDragState] = useState<DragState | null>(null);

  const sourcePath = activeItem ? activeItem.output_path || activeItem.input_path : '';

  const refreshDisplayRect = useCallback(() => {
    if (!sourceSize || !frameRef.current) {
      return;
    }

    const { width, height } = frameRef.current.getBoundingClientRect();
    if (width <= 0 || height <= 0) {
      return;
    }

    setDisplayRect(
      toContainRect(
        { width, height },
        sourceSize,
      ),
    );
  }, [sourceSize]);

  useEffect(() => {
    if (!sourceSize || !frameRef.current) {
      return;
    }

    refreshDisplayRect();

    const frame = frameRef.current;
    let observer: ResizeObserver | null = null;
    if (typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(() => refreshDisplayRect());
      observer.observe(frame);
    }

    const onResize = () => refreshDisplayRect();
    window.addEventListener('resize', onResize);

    return () => {
      observer?.disconnect();
      window.removeEventListener('resize', onResize);
    };
  }, [refreshDisplayRect, sourceSize]);

  useEffect(() => {
    if (!sourceSize || !sourcePath) {
      return;
    }

    if (initializedSourcePathRef.current === sourcePath) {
      return;
    }

    initializedSourcePathRef.current = sourcePath;
    onDraftChange({
      width: String(sourceSize.width),
      height: String(sourceSize.height),
      x: '0',
      y: '0',
    });
  }, [onDraftChange, sourcePath, sourceSize]);

  const activeRect = useMemo(() => {
    if (!sourceSize) {
      return null;
    }

    const widthValue = parsePositiveInt(draft.width);
    const heightValue = parsePositiveInt(draft.height);
    if (!widthValue || !heightValue) {
      return null;
    }

    const width = clamp(widthValue, 1, sourceSize.width);
    const height = clamp(heightValue, 1, sourceSize.height);
    const maxX = Math.max(0, sourceSize.width - width);
    const maxY = Math.max(0, sourceSize.height - height);

    const x = clamp(parseNonNegativeInt(draft.x) ?? 0, 0, maxX);
    const y = clamp(parseNonNegativeInt(draft.y) ?? 0, 0, maxY);

    return { x, y, width, height };
  }, [draft.height, draft.width, draft.x, draft.y, sourceSize]);

  const selectionStyle = useMemo(() => {
    if (!activeRect || !displayRect || !sourceSize) {
      return null;
    }

    const scaleX = displayRect.width / sourceSize.width;
    const scaleY = displayRect.height / sourceSize.height;
    return {
      left: displayRect.left + activeRect.x * scaleX,
      top: displayRect.top + activeRect.y * scaleY,
      width: Math.max(1, activeRect.width * scaleX),
      height: Math.max(1, activeRect.height * scaleY),
    };
  }, [activeRect, displayRect, sourceSize]);

  const updateDraftRect = useCallback((nextRect: Rect) => {
    if (!sourceSize) {
      return;
    }

    const width = clamp(nextRect.width, 1, sourceSize.width);
    const height = clamp(nextRect.height, 1, sourceSize.height);
    const x = clamp(nextRect.x, 0, Math.max(0, sourceSize.width - width));
    const y = clamp(nextRect.y, 0, Math.max(0, sourceSize.height - height));

    const nextDraft: CropDraft = {
      width: String(width),
      height: String(height),
      x: String(x),
      y: String(y),
    };

    if (
      nextDraft.width === draft.width
      && nextDraft.height === draft.height
      && nextDraft.x === draft.x
      && nextDraft.y === draft.y
    ) {
      return;
    }

    onDraftChange(nextDraft);
  }, [draft.height, draft.width, draft.x, draft.y, onDraftChange, sourceSize]);

  const toSourceCoordinates = useCallback((clientX: number, clientY: number) => {
    if (!sourceSize || !displayRect || !frameRef.current) {
      return null;
    }

    const frame = frameRef.current.getBoundingClientRect();
    const localX = clientX - frame.left;
    const localY = clientY - frame.top;

    const xInImage = clamp(localX - displayRect.left, 0, displayRect.width);
    const yInImage = clamp(localY - displayRect.top, 0, displayRect.height);

    const x = Math.round((xInImage / displayRect.width) * sourceSize.width);
    const y = Math.round((yInImage / displayRect.height) * sourceSize.height);

    return {
      x: clamp(x, 0, sourceSize.width),
      y: clamp(y, 0, sourceSize.height),
    };
  }, [displayRect, sourceSize]);

  const handlePointerDown = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0 || !sourceSize) {
      return;
    }

    const point = toSourceCoordinates(event.clientX, event.clientY);
    if (!point) {
      return;
    }

    const insideExisting = !!activeRect
      && point.x >= activeRect.x
      && point.x <= activeRect.x + activeRect.width
      && point.y >= activeRect.y
      && point.y <= activeRect.y + activeRect.height;

    const mode: DragMode = insideExisting ? 'move' : 'create';
    setDragState({
      pointerId: event.pointerId,
      mode,
      startX: point.x,
      startY: point.y,
      originX: insideExisting && activeRect ? activeRect.x : point.x,
      originY: insideExisting && activeRect ? activeRect.y : point.y,
      width: activeRect?.width ?? 1,
      height: activeRect?.height ?? 1,
    });

    if (!insideExisting) {
      updateDraftRect({
        x: point.x,
        y: point.y,
        width: 1,
        height: 1,
      });
    }

    event.currentTarget.setPointerCapture(event.pointerId);
    event.preventDefault();
  }, [activeRect, sourceSize, toSourceCoordinates, updateDraftRect]);

  const handlePointerMove = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragState || !sourceSize) {
      return;
    }

    const point = toSourceCoordinates(event.clientX, event.clientY);
    if (!point) {
      return;
    }

    if (dragState.mode === 'move') {
      const dx = point.x - dragState.startX;
      const dy = point.y - dragState.startY;
      updateDraftRect({
        x: dragState.originX + dx,
        y: dragState.originY + dy,
        width: dragState.width,
        height: dragState.height,
      });
      return;
    }

    const x = Math.min(dragState.startX, point.x);
    const y = Math.min(dragState.startY, point.y);
    const width = Math.max(1, Math.abs(point.x - dragState.startX));
    const height = Math.max(1, Math.abs(point.y - dragState.startY));

    updateDraftRect({ x, y, width, height });
  }, [dragState, sourceSize, toSourceCoordinates, updateDraftRect]);

  const clearDrag = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragState || dragState.pointerId !== event.pointerId) {
      return;
    }

    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }

    setDragState(null);
  }, [dragState]);

  const handleReset = useCallback(() => {
    if (!sourceSize) {
      return;
    }

    onDraftChange({
      width: String(sourceSize.width),
      height: String(sourceSize.height),
      x: '0',
      y: '0',
    });
  }, [onDraftChange, sourceSize]);

  if (!activeItem) {
    return null;
  }

  const sourceUrl = toAssetUrl(sourcePath);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
      <div className="w-[460px] shadow-2xl overflow-hidden flex flex-col transform transition-all rounded-lg bg-white border border-gray-300">
        <div className="h-12 flex items-center justify-between px-6 relative">
          <span className="font-semibold text-gray-900 text-[15px]">Crop Image</span>
          <button onClick={onClose} className="text-gray-500 hover:text-[#e81123] hover:bg-black/5 p-1 rounded transition-colors">
            <X size={16} />
          </button>
        </div>
        <div className="px-6 py-5 flex-1 bg-white">
          <div className="flex items-center justify-between mb-3">
            <p className="text-[12px] text-gray-500 truncate max-w-[320px]">{sourcePath.split(/[\\/]/).at(-1)}</p>
            <button
              type="button"
              onClick={handleReset}
              className="text-[12px] px-2.5 py-1 rounded bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
            >
              Reset
            </button>
          </div>
          <div
            ref={frameRef}
            className="w-full h-56 overflow-hidden relative bg-[#f3f3f3] rounded-md border border-gray-200 select-none touch-none cursor-crosshair"
            onPointerDown={handlePointerDown}
            onPointerMove={handlePointerMove}
            onPointerUp={clearDrag}
            onPointerCancel={clearDrag}
          >
            <img
              src={sourceUrl}
              className="absolute opacity-95 pointer-events-none"
              style={displayRect ? {
                left: `${displayRect.left}px`,
                top: `${displayRect.top}px`,
                width: `${displayRect.width}px`,
                height: `${displayRect.height}px`,
              } : { left: 0, top: 0, width: '100%', height: '100%', objectFit: 'contain' }}
              alt=""
              draggable={false}
              onLoad={(event) => {
                const target = event.currentTarget;
                const width = Math.max(1, Math.round(target.naturalWidth));
                const height = Math.max(1, Math.round(target.naturalHeight));
                setSourceSize({ width, height });
              }}
            />
            {selectionStyle ? (
              <div
                className="absolute border-2 border-white"
                style={{
                  left: `${selectionStyle.left}px`,
                  top: `${selectionStyle.top}px`,
                  width: `${selectionStyle.width}px`,
                  height: `${selectionStyle.height}px`,
                  boxShadow: '0 0 0 9999px rgba(0, 0, 0, 0.45)',
                }}
              >
                <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
                  <Crop size={20} className="text-white opacity-80" />
                </div>
              </div>
            ) : null}
          </div>
          <p className="mt-2 text-[11px] text-gray-500">Drag inside the image to define a crop, or drag the box to move it.</p>
          <div className="space-y-3 mt-4">
            <div className="flex items-center space-x-4">
              <div className="flex-1">
                <label htmlFor="crop-width-input" className="block text-[11px] font-medium mb-1 text-gray-800">Width</label>
                <input
                  id="crop-width-input"
                  type="number"
                  value={draft.width}
                  onChange={(event) => onDraftChange({ ...draft, width: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
              <div className="flex-1">
                <label htmlFor="crop-height-input" className="block text-[11px] font-medium mb-1 text-gray-800">Height</label>
                <input
                  id="crop-height-input"
                  type="number"
                  value={draft.height}
                  onChange={(event) => onDraftChange({ ...draft, height: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
            </div>
            <div className="flex items-center space-x-4">
              <div className="flex-1">
                <label htmlFor="crop-x-input" className="block text-[11px] font-medium mb-1 text-gray-800">X</label>
                <input
                  id="crop-x-input"
                  type="number"
                  value={draft.x}
                  onChange={(event) => onDraftChange({ ...draft, x: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
              <div className="flex-1">
                <label htmlFor="crop-y-input" className="block text-[11px] font-medium mb-1 text-gray-800">Y</label>
                <input
                  id="crop-y-input"
                  type="number"
                  value={draft.y}
                  onChange={(event) => onDraftChange({ ...draft, y: event.target.value })}
                  className="w-full text-[13px] px-2 py-1.5 focus:outline-none bg-white border-b-2 border-gray-300 rounded text-gray-900 focus:border-[#005fb8]"
                />
              </div>
            </div>
          </div>
        </div>
        <div className="p-4 flex justify-end space-x-3 bg-[#f3f3f3] border-t border-gray-200">
          <button
            onClick={onClose}
            className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-white border border-gray-300 rounded text-gray-800 hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            onClick={onApply}
            className="px-6 py-1.5 shadow-sm text-[13px] font-medium transition-colors bg-[#005fb8] border border-transparent rounded text-white hover:bg-[#0058a6]"
          >
            Apply
          </button>
        </div>
      </div>
    </div>
  );
}
