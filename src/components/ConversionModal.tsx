import { useEffect, useMemo, useRef, useState } from 'react';
import { X } from 'lucide-react';
import { OUTPUT_FORMAT_LABELS } from '../features/app/constants';
import type { RasterConversionDraft, ConversionRequest } from '../features/app/types';
import { basename, toAssetUrl } from '../features/app/utils';

type ConversionModalProps = {
  activeRequest: ConversionRequest | null;
  draft: RasterConversionDraft;
  onDraftChange: (next: RasterConversionDraft) => void;
  onClose: () => void;
  onApply: () => void;
};

type ImageSize = {
  width: number;
  height: number;
};

function parseDimension(value: string): number | null {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }
  return Math.floor(parsed);
}

export function ConversionModal({
  activeRequest,
  draft,
  onDraftChange,
  onClose,
  onApply,
}: ConversionModalProps) {
  const initializedPathRef = useRef<string | null>(null);
  const [loadedSourceSize, setLoadedSourceSize] = useState<{ path: string; size: ImageSize } | null>(null);
  const sourcePath = activeRequest ? activeRequest.item.output_path || activeRequest.item.input_path : '';
  const sourceSize = loadedSourceSize?.path === sourcePath ? loadedSourceSize.size : null;
  const targetLabel = activeRequest ? OUTPUT_FORMAT_LABELS[activeRequest.targetFormat] : '';

  useEffect(() => {
    if (!activeRequest || !sourcePath || initializedPathRef.current === sourcePath) {
      return;
    }

    initializedPathRef.current = sourcePath;
    const image = new Image();
    image.onload = () => {
      const nextSize = {
        width: Math.max(1, image.naturalWidth),
        height: Math.max(1, image.naturalHeight),
      };
      setLoadedSourceSize({ path: sourcePath, size: nextSize });
      onDraftChange({
        width: String(nextSize.width),
        height: String(nextSize.height),
        lock: true,
      });
    };
    image.src = toAssetUrl(sourcePath);
  }, [activeRequest, onDraftChange, sourcePath]);

  const applyDisabled = useMemo(
    () => parseDimension(draft.width) == null || parseDimension(draft.height) == null,
    [draft.height, draft.width],
  );

  const updateWidth = (width: string) => {
    if (!draft.lock || !sourceSize) {
      onDraftChange({ ...draft, width });
      return;
    }

    const parsedWidth = parseDimension(width);
    const height = parsedWidth == null
      ? draft.height
      : String(Math.max(1, Math.round((parsedWidth * sourceSize.height) / sourceSize.width)));
    onDraftChange({ ...draft, width, height });
  };

  const updateHeight = (height: string) => {
    if (!draft.lock || !sourceSize) {
      onDraftChange({ ...draft, height });
      return;
    }

    const parsedHeight = parseDimension(height);
    const width = parsedHeight == null
      ? draft.width
      : String(Math.max(1, Math.round((parsedHeight * sourceSize.width) / sourceSize.height)));
    onDraftChange({ ...draft, width, height });
  };

  if (!activeRequest) {
    return null;
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm" role="dialog" aria-label="svg-export-modal">
      <div className="w-[380px] overflow-hidden rounded-lg border border-gray-300 bg-white shadow-2xl">
        <div className="flex h-12 items-center justify-between px-5">
          <div className="min-w-0">
            <div className="truncate text-[15px] font-semibold text-gray-900">Export SVG as {targetLabel}</div>
            <div className="truncate text-[11px] font-medium text-gray-500">{basename(sourcePath)}</div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-gray-500 transition-colors hover:bg-black/5 hover:text-[#e81123]"
            title="Cancel"
          >
            <X size={16} />
          </button>
        </div>

        <div className="space-y-4 border-y border-gray-200 bg-white p-5">
          <div className="grid grid-cols-[1fr_auto_1fr] items-end gap-3">
            <label htmlFor="conversion-width" className="grid gap-1 text-[11px] font-medium text-gray-800">
              Width
              <input
                id="conversion-width"
                type="number"
                min={1}
                value={draft.width}
                onChange={(event) => updateWidth(event.target.value)}
                className="rounded border border-gray-300 bg-white px-2 py-1.5 text-[13px] text-gray-900 focus:border-[#005fb8] focus:outline-none"
              />
            </label>
            <X size={14} className="mb-2 text-gray-400" />
            <label htmlFor="conversion-height" className="grid gap-1 text-[11px] font-medium text-gray-800">
              Height
              <input
                id="conversion-height"
                type="number"
                min={1}
                value={draft.height}
                onChange={(event) => updateHeight(event.target.value)}
                className="rounded border border-gray-300 bg-white px-2 py-1.5 text-[13px] text-gray-900 focus:border-[#005fb8] focus:outline-none"
              />
            </label>
          </div>

          <label className="flex cursor-pointer items-center gap-2 text-[13px] text-gray-800">
            <input
              type="checkbox"
              checked={draft.lock}
              onChange={(event) => onDraftChange({ ...draft, lock: event.target.checked })}
              className="h-4 w-4 rounded border-gray-300 text-[#005fb8] focus:ring-[#005fb8]/50"
            />
            Lock aspect ratio
          </label>
        </div>

        <div className="flex justify-end gap-3 bg-[#f3f3f3] p-4">
          <button
            type="button"
            onClick={onClose}
            className="rounded border border-gray-300 bg-white px-5 py-1.5 text-[13px] font-medium text-gray-800 shadow-sm transition-colors hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onApply}
            disabled={applyDisabled}
            className="rounded border border-transparent bg-[#005fb8] px-5 py-1.5 text-[13px] font-medium text-white shadow-sm transition-colors hover:bg-[#0058a6] disabled:opacity-50"
          >
            Convert
          </button>
        </div>
      </div>
    </div>
  );
}
