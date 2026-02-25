import type { RefObject } from 'react';
import { ArrowRight, CheckCircle2, Crop, Maximize2 } from 'lucide-react';
import { formatBytes, type JobResultEntry } from '../state/queueState';
import type { PunchQueueItem } from '../features/app/types';
import { basename, formatSavings, toAssetUrl } from '../features/app/utils';
import { PunchEffectCanvas } from './PunchEffectCanvas';

type ProcessedItemsPanelProps = {
  processedItems: JobResultEntry[];
  activePunch: PunchQueueItem | null;
  scrollViewportRef: RefObject<HTMLDivElement | null>;
  onOpenItemCrop: (item: JobResultEntry) => void;
  onOpenItemResize: (item: JobResultEntry) => void;
  onClearProcessedItems: () => void;
  onPunchComplete: () => void;
};

export function ProcessedItemsPanel({
  processedItems,
  activePunch,
  scrollViewportRef,
  onOpenItemCrop,
  onOpenItemResize,
  onClearProcessedItems,
  onPunchComplete,
}: ProcessedItemsPanelProps) {
  return (
    <>
      {processedItems.length > 0 && (
        <>
          <div className="flex items-center justify-between">
            <p className="text-[12px] font-semibold uppercase tracking-wide text-gray-500">Processed images</p>
            <button
              type="button"
              onClick={onClearProcessedItems}
              className="text-[12px] px-2.5 py-1 rounded bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
            >
              Clear
            </button>
          </div>
          <div className="space-y-2 w-full flex-1 min-h-0 overflow-y-auto pr-1" ref={scrollViewportRef}>
            {processedItems.map((item) => {
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
                      onClick={() => onOpenItemCrop(item)}
                      className="p-2 transition-colors bg-transparent rounded hover:bg-black/5 text-gray-600 tooltip-trigger"
                      title="Crop Image"
                    >
                      <Crop size={16} strokeWidth={1.5} />
                    </button>
                    <button
                      onClick={() => onOpenItemResize(item)}
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
              onComplete={onPunchComplete}
            />
          </div>
          <p className="mt-2 text-sm text-gray-500">
            Crushing <strong>{basename(activePunch.inputPath)}</strong>
          </p>
        </div>
      )}
    </>
  );
}
