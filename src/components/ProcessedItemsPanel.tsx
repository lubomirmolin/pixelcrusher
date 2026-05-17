import { useEffect, useMemo, useState } from 'react';
import type { RefObject } from 'react';
import {
  ArrowRight,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Crop,
  FolderOpen,
  Loader2,
  Maximize2,
  XCircle,
} from 'lucide-react';
import { formatBytes, type JobResultEntry, type JobSnapshot } from '../state/queueState';
import type { FolderDropState, PunchQueueItem } from '../features/app/types';
import { basename, formatSavings, toAssetUrl } from '../features/app/utils';
import { FolderPunchAnimation } from './FolderPunchAnimation';
import { PunchEffectCanvas } from './PunchEffectCanvas';

type ProcessedItemsPanelProps = {
  processedItems: JobResultEntry[];
  queueJobs: Record<string, JobSnapshot>;
  activeFolderDrop: FolderDropState | null;
  activePunch: PunchQueueItem | null;
  activeFolderPunch: FolderDropState | null;
  scrollViewportRef: RefObject<HTMLDivElement | null>;
  onOpenItemCrop: (item: JobResultEntry) => void;
  onOpenItemResize: (item: JobResultEntry) => void;
  onClearProcessedItems: () => void;
  onPunchComplete: () => void;
  onFolderPunchComplete: () => void;
};

const RESOLUTION_CACHE = new Map<string, string>();

function normalizeFolderPath(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+$/g, '');
}

function isPathInsideFolder(path: string, folderPath: string): boolean {
  const normalizedPath = normalizeFolderPath(path);
  const normalizedFolder = normalizeFolderPath(folderPath);

  if (!normalizedFolder) {
    return false;
  }

  return normalizedPath === normalizedFolder || normalizedPath.startsWith(`${normalizedFolder}/`);
}

function ItemResolution({ path }: { path: string }) {
  const [resolvedLabel, setResolvedLabel] = useState<string | null>(() => RESOLUTION_CACHE.get(path) ?? null);
  const [retryTick, setRetryTick] = useState(0);
  const label = path ? RESOLUTION_CACHE.get(path) ?? resolvedLabel ?? '—' : '—';

  useEffect(() => {
    if (!path || RESOLUTION_CACHE.has(path)) {
      return;
    }

    let cancelled = false;
    let retryTimer: ReturnType<typeof setTimeout> | null = null;
    const image = new Image();
    image.onload = () => {
      if (cancelled) {
        return;
      }
      const next = `${Math.max(1, image.naturalWidth)}×${Math.max(1, image.naturalHeight)}`;
      RESOLUTION_CACHE.set(path, next);
      setResolvedLabel(next);
    };
    image.onerror = () => {
      if (cancelled) {
        return;
      }
      // Some files are briefly unreadable right after start; retry a few times.
      if (retryTick < 3) {
        retryTimer = setTimeout(() => {
          setRetryTick((value) => value + 1);
        }, 250 * (retryTick + 1));
      }
    };
    image.src = toAssetUrl(path);

    return () => {
      cancelled = true;
      if (retryTimer) {
        clearTimeout(retryTimer);
      }
    };
  }, [path, retryTick]);

  return (
    <span className="ml-3 min-w-[100px] text-right font-mono text-[12px] text-gray-500">{label}</span>
  );
}

function FolderFileRow({
  job,
  result,
}: {
  job: JobSnapshot;
  result?: JobResultEntry;
}) {
  const progress = Math.max(0, Math.min(100, job.progress));
  const outputPath = result?.output_path || job.input_path;
  const savingsText = result ? formatSavings(result.size_delta_percent) : '';
  const isCompleted = job.status === 'completed' || job.status === 'failed';
  const isSuccessful = job.status === 'completed';

  const statusColor = isSuccessful
    ? 'text-[#107c10]'
    : job.status === 'failed'
      ? 'text-[#c43535]'
      : 'text-[#005fb8]';

  return (
    <div className="p-3 rounded-lg border border-gray-200 bg-white/95 shadow-sm">
      <div className="flex items-center gap-3">
        <div className="w-12 h-12 overflow-hidden flex-shrink-0 relative rounded-md bg-gray-100">
          <img src={toAssetUrl(outputPath)} alt="" className="w-full h-full object-contain" />
        </div>

        <div className="flex-1 min-w-0">
          <div className="text-[13px] truncate font-semibold text-gray-900">{basename(job.input_path)}</div>
          <div className="text-[11px] text-gray-500 mt-1 flex items-center gap-2">
            {isCompleted && result && <span>{formatBytes(result.input_size)}</span>}
            {isCompleted && result && (
              <>
                <ArrowRight size={12} />
                <span className="text-green-600 font-medium">{formatBytes(result.output_size)}</span>
                {savingsText ? <span className="px-1.5 py-0.5 rounded bg-green-50 text-green-700 text-[11px] font-semibold">{savingsText}</span> : null}
              </>
            )}
            {!isCompleted ? <span>{job.message || 'Processing'}</span> : null}
          </div>
          {!isCompleted ? (
            <div className="mt-1 h-1 w-full overflow-hidden rounded-full bg-black/10">
              <div
                className="h-full rounded-full bg-[#005fb8] transition-all duration-300"
                style={{ width: `${progress}%` }}
              />
            </div>
          ) : null}
        </div>

        <div className="w-8 flex justify-end text-right text-sm">
          <span className={`font-medium ${statusColor}`}>
            {job.status === 'completed' ? <CheckCircle2 size={18} /> : job.status === 'failed' ? <XCircle size={18} /> : <Loader2 size={18} className="animate-spin" />}
          </span>
        </div>
      </div>

      {isCompleted && result ? <ItemResolution path={outputPath} /> : null}
      {job.status === 'failed' ? <div className="mt-2 text-[11px] text-[#9a2e3a]">{job.message || 'Failed'}</div> : null}
    </div>
  );
}

export function ProcessedItemsPanel({
  processedItems,
  queueJobs,
  activeFolderDrop,
  activePunch,
  activeFolderPunch,
  scrollViewportRef,
  onOpenItemCrop,
  onOpenItemResize,
  onClearProcessedItems,
  onPunchComplete,
  onFolderPunchComplete,
}: ProcessedItemsPanelProps) {
  const resultById = useMemo(
    () => new Map(processedItems.map((item) => [item.id, item])),
    [processedItems],
  );

  const folderJobs = useMemo(() => {
    if (!activeFolderDrop) {
      return [] as JobSnapshot[];
    }

    return Object.values(queueJobs)
      .filter((job) => isPathInsideFolder(job.input_path, activeFolderDrop.folderPath))
      .sort((left, right) => basename(left.input_path).localeCompare(basename(right.input_path)));
  }, [activeFolderDrop, queueJobs]);

  const folderJobIDs = useMemo(() => new Set(folderJobs.map((job) => job.id)), [folderJobs]);
  const visibleProcessedItems = useMemo(
    () => processedItems.filter((item) => !folderJobIDs.has(item.id)),
    [folderJobIDs, processedItems],
  );

  const [collapsedFolderIDs, setCollapsedFolderIDs] = useState<Set<string>>(new Set());
  const activeFolderExpanded = activeFolderDrop ? !collapsedFolderIDs.has(activeFolderDrop.id) : false;

  const toggleFolder = (folderID: string) => {
    setCollapsedFolderIDs((current) => {
      const next = new Set(current);
      if (next.has(folderID)) {
        next.delete(folderID);
      } else {
        next.add(folderID);
      }
      return next;
    });
  };

  return (
    <>
      {(activeFolderDrop != null || visibleProcessedItems.length > 0 || folderJobs.length > 0) && (
        <>
          <div className="flex items-center justify-between">
            <p className="text-[12px] font-semibold uppercase tracking-wide text-gray-500">
              {activeFolderDrop ? 'Queue' : 'Processed images'}
            </p>
            {visibleProcessedItems.length > 0 ? (
              <button
                type="button"
                onClick={onClearProcessedItems}
                className="text-[12px] px-2.5 py-1 rounded bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
              >
                Clear
              </button>
            ) : null}
          </div>

          <div className="space-y-2 w-full flex-1 min-h-0 overflow-y-auto pr-1" ref={scrollViewportRef}>
            {activeFolderDrop ? (
              <div className="rounded-lg border border-gray-200 bg-white p-3 shadow-sm">
                <button
                  type="button"
                  onClick={() => toggleFolder(activeFolderDrop.id)}
                  className="w-full flex items-center justify-between text-left"
                >
                  <div className="flex items-center gap-2">
                    {activeFolderExpanded ? (
                      <ChevronDown size={14} />
                    ) : (
                      <ChevronRight size={14} />
                    )}
                    <FolderOpen size={17} className="text-[#005fb8]" />
                    <span className="text-[14px] font-semibold text-gray-800">{activeFolderDrop.folderName}</span>
                  </div>
                  <span className="text-[11px] text-gray-500">{folderJobs.length} file{folderJobs.length === 1 ? '' : 's'}</span>
                </button>

                {activeFolderExpanded ? (
                  <div className="mt-3 space-y-2">
                    {folderJobs.length === 0 ? (
                      <div className="text-[12px] text-gray-500 px-1">Preparing files…</div>
                    ) : (
                      folderJobs.map((job) => {
                        const result = resultById.get(job.id);
                        return <FolderFileRow key={job.id} job={job} result={result} />;
                      })
                    )}
                  </div>
                ) : null}
              </div>
            ) : null}

            {visibleProcessedItems.map((item) => {
              const previewPath = item.output_path || item.input_path;
              const previewSrc = toAssetUrl(previewPath);
              const savingsText = formatSavings(item.size_delta_percent);

              return (
                <div
                  key={item.id}
                  className="p-3 flex items-center group bg-white rounded-lg shadow-sm border border-gray-200 animate-[slideIn_0.3s_ease-out]"
                >
                  <div className="w-14 h-14 overflow-hidden flex-shrink-0 relative rounded-md bg-gray-100">
                    {previewSrc ? (
                      <img src={previewSrc} alt="" className="w-full h-full object-contain" />
                    ) : (
                      <div className="w-full h-full flex items-center justify-center font-bold text-gray-400">
                        {basename(item.input_path).charAt(0)}
                      </div>
                    )}
                  </div>

                  <div className="ml-4 flex-1 min-w-0">
                    <div className="text-[14px] truncate font-semibold text-gray-900">{basename(item.input_path)}</div>
                    <div className="text-[12px] text-gray-500 flex items-center mt-1">
                      <span>{formatBytes(item.input_size)}</span>
                      <ArrowRight size={12} className="mx-2" />
                      <span className="text-green-600 font-medium">{formatBytes(item.output_size)}</span>
                      {savingsText ? (
                        <span className="ml-2 px-1.5 py-0.5 font-semibold text-[11px] text-green-600">
                          {savingsText}
                        </span>
                      ) : null}
                    </div>
                  </div>

                  <div className="ml-4 flex items-center space-x-2">
                    <ItemResolution path={previewPath} />
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
                    <CheckCircle2 size={20} className="text-[#107c10]" strokeWidth={1.5} />
                  </div>
                </div>
              );
            })}
          </div>
        </>
      )}

      {activeFolderPunch && (
        <div className="w-full flex flex-col items-center justify-center mt-auto shrink-0 transition-all duration-300 pb-4">
          <div className="w-[320px] h-[300px] rounded-2xl bg-transparent flex items-end justify-center overflow-hidden">
            <FolderPunchAnimation folderName={activeFolderPunch.folderName} onComplete={onFolderPunchComplete} />
          </div>
        </div>
      )}

      {!activeFolderPunch && activePunch && (
        <div className="w-full flex flex-col items-center justify-center mt-auto shrink-0 transition-all duration-300 pb-4">
          <div className="w-[360px] h-[300px] rounded-2xl bg-transparent flex items-end justify-center overflow-hidden">
            <PunchEffectCanvas
              inputPath={activePunch.inputPath}
              cropTransform={activePunch.cropTransform}
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
