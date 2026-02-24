import { useEffect, useMemo, useReducer, useRef, useState, type CSSProperties } from 'react';
import { invoke } from '@tauri-apps/api/core';
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

const SIZE_PRESETS = [
  { value: 'original', label: 'Original size', width: null, height: null },
  { value: '512', label: '512 × 512', width: 512, height: 512 },
  { value: '1024', label: '1024 × 1024', width: 1024, height: 1024 },
  { value: '2048', label: '2048 × 2048', width: 2048, height: 2048 },
] as const;

const CROP_ANCHORS = [
  { value: 'center', label: 'Center' },
  { value: 'top-left', label: 'Top left' },
  { value: 'top-right', label: 'Top right' },
  { value: 'bottom-left', label: 'Bottom left' },
  { value: 'bottom-right', label: 'Bottom right' },
] as const;

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

type ItemDescriptor = {
  id: string;
  inputPath: string;
  outputPath?: string;
  status: string;
  progress: number;
  inputSize?: number;
  outputSize?: number;
  sizeDeltaPercent?: number;
};

type CropSettings = {
  width: string;
  height: string;
  anchor: (typeof CROP_ANCHORS)[number]['value'];
};

type ResizeSettings = {
  width: string;
  height: string;
  lock: boolean;
};

type ItemAdjustments = {
  crop?: CropSettings;
  resize?: ResizeSettings;
};

type FolderBatchSettings = {
  cropPreset?: (typeof SIZE_PRESETS)[number]['value'];
  cropAnchor?: CropSettings['anchor'];
  resizePreset?: (typeof SIZE_PRESETS)[number]['value'];
  lockAspect?: boolean;
};

type FolderTreeNode = {
  name: string;
  path: string;
  kind: 'folder' | 'file';
  children: FolderTreeNode[];
};

type ProfilePreset = {
  quality: number;
  pngQMin: number;
  pngQMax: number;
  runPngQuant: boolean;
  runPngcrush: boolean;
  runZopfli: boolean;
  runPngout: boolean;
  trimTransparent: boolean;
};

const PROFILE_PRESETS: Record<CompressionProfileId, ProfilePreset> = {
  balanced: {
    quality: 82,
    pngQMin: 60,
    pngQMax: 90,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: false,
    runPngout: false,
    trimTransparent: true,
  },
  high: {
    quality: 92,
    pngQMin: 75,
    pngQMax: 98,
    runPngQuant: false,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
    trimTransparent: true,
  },
  smallest: {
    quality: 70,
    pngQMin: 45,
    pngQMax: 75,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
    trimTransparent: true,
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

function normalizePathForMatch(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+$/, '');
}

function asOptionalDimension(value: string): number | null {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return null;
  }

  return Math.floor(num);
}

function toHumanStatus(status: string): string {
  if (!status) {
    return 'Idle';
  }

  return status
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function formatDelta(delta?: number): string {
  if (delta == null || Number.isNaN(delta)) {
    return '—';
  }

  return `${delta > 0 ? '+' : ''}${delta.toFixed(1)}%`;
}

function isLikelyFolderPath(path: string): boolean {
  const name = basename(path).toLowerCase();
  return !['.png', '.jpg', '.jpeg', '.svg', '.gif'].some((ext) => name.endsWith(ext));
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

function buildFolderTree(roots: string[], filePaths: string[]): FolderTreeNode[] {
  const normalizedFiles = filePaths.map((path) => normalizePathForMatch(path));

  return roots.map((rootPath) => {
    const normalizedRoot = normalizePathForMatch(rootPath);
    const rootNode: FolderTreeNode = {
      name: basename(rootPath),
      path: rootPath,
      kind: 'folder',
      children: [],
    };

    const filesInRoot = normalizedFiles.filter(
      (filePath) => filePath === normalizedRoot || filePath.startsWith(`${normalizedRoot}/`),
    );

    for (const filePath of filesInRoot) {
      const relative = filePath.replace(`${normalizedRoot}/`, '');
      const segments = relative.split('/').filter(Boolean);
      if (!segments.length) {
        continue;
      }

      let cursor = rootNode;
      segments.forEach((segment, index) => {
        const isLeaf = index === segments.length - 1;
        const nextPath = `${cursor.path}/${segment}`;
        let child = cursor.children.find((item) => item.name === segment && item.kind === (isLeaf ? 'file' : 'folder'));

        if (!child) {
          child = {
            name: segment,
            path: nextPath,
            kind: isLeaf ? 'file' : 'folder',
            children: [],
          };
          cursor.children.push(child);
        }

        cursor = child;
      });
    }

    return rootNode;
  });
}

function FolderTreeView({
  node,
  depth,
  onOpenFolderCrop,
  onOpenFolderResize,
  folderBatch,
}: {
  node: FolderTreeNode;
  depth: number;
  onOpenFolderCrop: (path: string) => void;
  onOpenFolderResize: (path: string) => void;
  folderBatch: Record<string, FolderBatchSettings>;
}) {
  if (node.kind === 'file') {
    return (
      <li className="folder-leaf" style={{ '--depth': depth } as CSSProperties}>
        <span>{node.name}</span>
      </li>
    );
  }

  const applied = folderBatch[node.path];

  return (
    <li className="folder-branch" style={{ '--depth': depth } as CSSProperties}>
      <div className="folder-node-row">
        <strong>{node.name}</strong>
        <div className="row-actions">
          <button className="secondary-btn" onClick={() => onOpenFolderCrop(node.path)}>
            Folder Crop
          </button>
          <button className="secondary-btn" onClick={() => onOpenFolderResize(node.path)}>
            Folder Resize
          </button>
        </div>
      </div>
      {applied ? (
        <p className="folder-applied">
          {applied.cropPreset ? `Crop ${applied.cropPreset === 'original' ? 'Original' : `${applied.cropPreset}×${applied.cropPreset}`}` : ''}
          {applied.resizePreset
            ? `${applied.cropPreset ? ' · ' : ''}Resize ${
                applied.resizePreset === 'original' ? 'Original' : `${applied.resizePreset}×${applied.resizePreset}`
              }`
            : ''}
          {applied.cropAnchor ? ` · Anchor ${applied.cropAnchor}` : ''}
        </p>
      ) : null}
      {node.children.length > 0 ? (
        <ul className="folder-subtree">
          {node.children
            .slice()
            .sort((a, b) => {
              if (a.kind !== b.kind) {
                return a.kind === 'folder' ? -1 : 1;
              }
              return a.name.localeCompare(b.name);
            })
            .map((child) => (
              <FolderTreeView
                key={`${node.path}-${child.path}`}
                node={child}
                depth={depth + 1}
                onOpenFolderCrop={onOpenFolderCrop}
                onOpenFolderResize={onOpenFolderResize}
                folderBatch={folderBatch}
              />
            ))}
        </ul>
      ) : (
        <p className="folder-empty">No queued files yet.</p>
      )}
    </li>
  );
}

function App() {
  const [queueState, dispatch] = useReducer(queueReducer, initialQueueState);
  const [dragActive, setDragActive] = useState(false);
  const [appVersion, setAppVersion] = useState('0.0.0');
  const [runtimePlatform, setRuntimePlatform] = useState<RuntimePlatform>('unknown');
  const [updateState, updateDispatch] = useReducer(updateReducer, { status: 'idle' } as UpdateFlowState);
  const [showUpdateSheet, setShowUpdateSheet] = useState(false);

  const [profile, setProfile] = useState<CompressionProfileId>('balanced');
  const [cropWidth, setCropWidth] = useState('');
  const [cropHeight, setCropHeight] = useState('');
  const [resizeWidth, setResizeWidth] = useState('');
  const [resizeHeight, setResizeHeight] = useState('');

  const [folderRoots, setFolderRoots] = useState<string[]>([]);
  const [itemAdjustments, setItemAdjustments] = useState<Record<string, ItemAdjustments>>({});
  const [folderBatch, setFolderBatch] = useState<Record<string, FolderBatchSettings>>({});

  const [activeCropItem, setActiveCropItem] = useState<ItemDescriptor | null>(null);
  const [activeResizeItem, setActiveResizeItem] = useState<ItemDescriptor | null>(null);
  const [activeFolderCropPath, setActiveFolderCropPath] = useState<string | null>(null);
  const [activeFolderResizePath, setActiveFolderResizePath] = useState<string | null>(null);

  const [cropDraft, setCropDraft] = useState<CropSettings>({
    width: '',
    height: '',
    anchor: 'center',
  });
  const [resizeDraft, setResizeDraft] = useState<ResizeSettings>({
    width: '',
    height: '',
    lock: true,
  });

  const [folderCropPreset, setFolderCropPreset] = useState<(typeof SIZE_PRESETS)[number]['value']>('original');
  const [folderCropAnchor, setFolderCropAnchor] = useState<CropSettings['anchor']>('center');
  const [folderResizePreset, setFolderResizePreset] = useState<(typeof SIZE_PRESETS)[number]['value']>('original');
  const [folderResizeLock, setFolderResizeLock] = useState(true);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const optionsPayloadRef = useRef<Record<string, unknown> | null>(null);

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

    listen<QueueEventPayload>('queue://event', (event) => {
      dispatch({ type: 'INGEST_EVENT', payload: event.payload });
    })
      .then((off) => {
        unlistenQueue = off;
      })
      .catch(() => undefined);

    if (isTauriRuntime()) {
      getCurrentWebview()
        .onDragDropEvent((event) => {
          if (event.payload.type === 'enter' || event.payload.type === 'over') {
            setDragActive(true);
            return;
          }

          if (event.payload.type === 'leave') {
            setDragActive(false);
            return;
          }

          if (event.payload.type === 'drop') {
            setDragActive(false);
            const dropped = event.payload.paths;
            const guessedFolders = dropped.filter(isLikelyFolderPath);
            void enqueuePaths(dropped, guessedFolders);
          }
        })
        .then((off) => {
          unlistenDragDrop = off;
        })
        .catch(() => undefined);
    }

    return () => {
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

  const completedCount = useMemo(
    () => Object.values(queueState.jobs).filter((job) => job.status === 'completed').length,
    [queueState.jobs],
  );

  const resultItems = useMemo<ItemDescriptor[]>(
    () =>
      queueState.recent.map((item) => ({
        id: item.id,
        inputPath: item.input_path,
        outputPath: item.output_path,
        status: item.status,
        progress: 100,
        inputSize: item.input_size,
        outputSize: item.output_size,
        sizeDeltaPercent: item.size_delta_percent,
      })),
    [queueState.recent],
  );

  const resultIds = useMemo(() => new Set(resultItems.map((item) => item.id)), [resultItems]);

  const activeOnlyItems = useMemo<ItemDescriptor[]>(
    () =>
      activeJobs
        .filter((job) => !resultIds.has(job.id))
        .map((job) => ({
          id: job.id,
          inputPath: job.input_path,
          status: job.status,
          progress: job.progress,
        })),
    [activeJobs, resultIds],
  );

  const visibleItems = useMemo(() => [...activeOnlyItems, ...resultItems], [activeOnlyItems, resultItems]);

  const currentJob = activeJobs[0] ?? null;
  const queueStateLabel = currentJob ? `${activeJobs.length} active` : 'idle';

  const recentOutputFolder = useMemo(() => {
    const latest = queueState.recent[0];
    return latest ? dirname(latest.output_path) : '';
  }, [queueState.recent]);

  const folderTree = useMemo(
    () => buildFolderTree(folderRoots, visibleItems.map((item) => item.inputPath)),
    [folderRoots, visibleItems],
  );

  const selectedProfile = PROFILE_PRESETS[profile];

  const optionsPayload = useMemo(
    () => ({
      trim_transparent: selectedProfile.trimTransparent,
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
    [cropHeight, cropWidth, resizeHeight, resizeWidth, selectedProfile],
  );

  useEffect(() => {
    optionsPayloadRef.current = optionsPayload;
  }, [optionsPayload]);

  const enqueuePaths = async (paths: string[], detectedFolderRoots: string[] = []) => {
    const normalized = Array.from(new Set(paths.map((value) => value.trim()).filter((value) => value.length > 0)));

    if (!normalized.length) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'No valid files were selected.',
      });
      return;
    }

    const roots = Array.from(new Set([...detectedFolderRoots, ...normalized.filter(isLikelyFolderPath)]));
    if (roots.length) {
      setFolderRoots((previous) => Array.from(new Set([...previous, ...roots])));
    }

    dispatch({ type: 'CLEAR_QUEUE_ERROR' });

    try {
      await invoke('enqueue_paths', {
        paths: normalized,
        options: optionsPayloadRef.current ?? optionsPayload,
      });
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Queue start failed. Please try again.',
      });
    }
  };

  const onDropFiles: React.DragEventHandler<HTMLDivElement> = async (event) => {
    event.preventDefault();
    setDragActive(false);

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

  const onOpenFolderPicker = async () => {
    if (!isTauriRuntime()) {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Folder selection works in desktop builds.',
      });
      return;
    }

    try {
      const selected = await invoke<string | null>('select_input_folder');
      if (!selected) {
        return;
      }

      await enqueuePaths([selected], [selected]);
    } catch {
      dispatch({
        type: 'QUEUE_ERROR',
        payload: 'Unable to open the folder picker.',
      });
    }
  };

  const openItemCropModal = (item: ItemDescriptor) => {
    setActiveCropItem(item);
    const existing = itemAdjustments[item.id]?.crop;
    setCropDraft(
      existing ?? {
        width: cropWidth,
        height: cropHeight,
        anchor: 'center',
      },
    );
  };

  const openItemResizeModal = (item: ItemDescriptor) => {
    setActiveResizeItem(item);
    const existing = itemAdjustments[item.id]?.resize;
    setResizeDraft(
      existing ?? {
        width: resizeWidth,
        height: resizeHeight,
        lock: true,
      },
    );
  };

  const openFolderCropModal = (path: string) => {
    setActiveFolderCropPath(path);
    setFolderCropPreset(folderBatch[path]?.cropPreset ?? 'original');
    setFolderCropAnchor(folderBatch[path]?.cropAnchor ?? 'center');
  };

  const openFolderResizeModal = (path: string) => {
    setActiveFolderResizePath(path);
    setFolderResizePreset(folderBatch[path]?.resizePreset ?? 'original');
    setFolderResizeLock(folderBatch[path]?.lockAspect ?? true);
  };

  const applyItemCrop = () => {
    if (!activeCropItem) return;

    setItemAdjustments((previous) => ({
      ...previous,
      [activeCropItem.id]: {
        ...previous[activeCropItem.id],
        crop: cropDraft,
      },
    }));

    setCropWidth(cropDraft.width);
    setCropHeight(cropDraft.height);
    setActiveCropItem(null);
  };

  const applyItemResize = () => {
    if (!activeResizeItem) return;

    setItemAdjustments((previous) => ({
      ...previous,
      [activeResizeItem.id]: {
        ...previous[activeResizeItem.id],
        resize: resizeDraft,
      },
    }));

    setResizeWidth(resizeDraft.width);
    setResizeHeight(resizeDraft.height);
    setActiveResizeItem(null);
  };

  const applyFolderCrop = () => {
    if (!activeFolderCropPath) return;

    setFolderBatch((previous) => ({
      ...previous,
      [activeFolderCropPath]: {
        ...previous[activeFolderCropPath],
        cropPreset: folderCropPreset,
        cropAnchor: folderCropAnchor,
      },
    }));

    const preset = SIZE_PRESETS.find((item) => item.value === folderCropPreset);
    if (preset) {
      setCropWidth(preset.width ? String(preset.width) : '');
      setCropHeight(preset.height ? String(preset.height) : '');
    }

    setActiveFolderCropPath(null);
  };

  const applyFolderResize = () => {
    if (!activeFolderResizePath) return;

    setFolderBatch((previous) => ({
      ...previous,
      [activeFolderResizePath]: {
        ...previous[activeFolderResizePath],
        resizePreset: folderResizePreset,
        lockAspect: folderResizeLock,
      },
    }));

    const preset = SIZE_PRESETS.find((item) => item.value === folderResizePreset);
    if (preset) {
      setResizeWidth(preset.width ? String(preset.width) : '');
      setResizeHeight(preset.height ? String(preset.height) : '');
    }

    setActiveFolderResizePath(null);
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

  const showResultsState = visibleItems.length > 0 || folderRoots.length > 0;

  return (
    <div className="app-shell" onDrop={onDropFiles} onDragOver={(event) => event.preventDefault()}>
      <header className="titlebar">
        <button className="secondary-btn" onClick={() => setShowUpdateSheet(true)} aria-label="Open updates">
          Updates
        </button>

        <h1>Pixel Crusher</h1>

        <div className="titlebar-right">
          <label htmlFor="profile-picker">Profile</label>
          <select
            id="profile-picker"
            aria-label="Compression profile"
            value={profile}
            onChange={(event) => setProfile(event.target.value as CompressionProfileId)}
          >
            <option value="balanced">Balanced</option>
            <option value="high">High Quality</option>
            <option value="smallest">Smallest Size</option>
          </select>
        </div>
      </header>

      <main className="workspace">
        {!showResultsState ? (
          <section className="drop-empty" data-testid="empty-state">
            <h2>Drop images to crush</h2>
            <p>PNG · JPG · SVG · GIF</p>
            <button className="primary-btn" onClick={() => void onOpenSystemPicker()}>
              Browse
            </button>
            <button className="secondary-btn" onClick={() => void onOpenFolderPicker()}>
              Browse Folder
            </button>
            <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} />
          </section>
        ) : (
          <section className="results-layout" data-testid="list-state">
            <article className="inline-drop-zone">
              <p>Add more files or folders</p>
              <div className="row-actions">
                <button className="secondary-btn" onClick={() => void onOpenSystemPicker()}>
                  Browse
                </button>
                <button className="secondary-btn" onClick={() => void onOpenFolderPicker()}>
                  Browse Folder
                </button>
                <input ref={fileInputRef} type="file" multiple hidden onChange={onChooseFiles} />
              </div>
            </article>

            <article className="panel">
              <div className="panel-header">
                <h3>Queue</h3>
                <span>
                  {queueStateLabel} · {completedCount} done
                </span>
              </div>
              <div className="progress-wrap" role="progressbar" aria-valuenow={currentJob?.progress ?? 0}>
                <div className="progress-bar" style={{ width: `${currentJob?.progress ?? 0}%` }} />
              </div>
              <p className="queue-subtle">
                {currentJob
                  ? `${basename(currentJob.input_path)} · ${toHumanStatus(currentJob.status)}`
                  : 'Queue idle'}
              </p>
              {queueState.lastError ? <p className="queue-error">Queue error. Please retry.</p> : null}
            </article>

            {folderRoots.length > 0 ? (
              <article className="panel">
                <div className="panel-header">
                  <h3>Folders</h3>
                  <span>{folderRoots.length} root(s)</span>
                </div>
                <ul className="folder-tree">
                  {folderTree.map((node) => (
                    <FolderTreeView
                      key={node.path}
                      node={node}
                      depth={0}
                      onOpenFolderCrop={openFolderCropModal}
                      onOpenFolderResize={openFolderResizeModal}
                      folderBatch={folderBatch}
                    />
                  ))}
                </ul>
              </article>
            ) : null}

            <article className="panel">
              <div className="panel-header">
                <h3>Items</h3>
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

              <div className="results-grid">
                {visibleItems.map((item) => {
                  const adjustments = itemAdjustments[item.id];
                  const statusClass = item.status === 'completed' ? 'ok' : item.status === 'failed' ? 'bad' : 'live';

                  return (
                    <article key={item.id} className="result-row">
                      <div className="thumb" aria-hidden="true">
                        {basename(item.inputPath).slice(0, 1).toUpperCase()}
                      </div>

                      <div className="result-main">
                        <strong>{basename(item.inputPath)}</strong>
                        <p>
                          {item.inputSize != null && item.outputSize != null
                            ? `${formatBytes(item.inputSize)} → ${formatBytes(item.outputSize)}`
                            : `${toHumanStatus(item.status)} · ${item.progress}%`}
                        </p>
                        {(adjustments?.crop || adjustments?.resize) && (
                          <p className="adjustment-summary">
                            {adjustments.crop ? `Crop ${adjustments.crop.width || 'auto'}×${adjustments.crop.height || 'auto'}` : ''}
                            {adjustments.crop && adjustments.resize ? ' · ' : ''}
                            {adjustments.resize
                              ? `Resize ${adjustments.resize.width || 'auto'}×${adjustments.resize.height || 'auto'}`
                              : ''}
                          </p>
                        )}
                      </div>

                      <span className={`status-badge ${statusClass}`}>{toHumanStatus(item.status)}</span>

                      <span className={`delta-pill ${(item.sizeDeltaPercent ?? 0) <= 0 ? 'good' : 'bad'}`}>
                        {formatDelta(item.sizeDeltaPercent)}
                      </span>

                      <div className="row-actions">
                        <button className="secondary-btn" onClick={() => openItemCropModal(item)}>
                          Crop
                        </button>
                        <button className="secondary-btn" onClick={() => openItemResizeModal(item)}>
                          Resize
                        </button>
                      </div>
                    </article>
                  );
                })}
              </div>
            </article>
          </section>
        )}
      </main>

      <footer className="status-footer">
        <span>v{appVersion}</span>
        <span>Profile: {profile === 'high' ? 'High Quality' : profile === 'smallest' ? 'Smallest Size' : 'Balanced'}</span>
        <span>Queue: {queueStateLabel}</span>
      </footer>

      {dragActive ? (
        <div className="drag-overlay" role="presentation">
          Drop to add files
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
          <div className="modal-card">
            <h3>Crop image</h3>
            <p>{basename(activeCropItem.inputPath)}</p>
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
            <label>
              Anchor
              <select
                value={cropDraft.anchor}
                onChange={(event) =>
                  setCropDraft((previous) => ({
                    ...previous,
                    anchor: event.target.value as CropSettings['anchor'],
                  }))
                }
              >
                {CROP_ANCHORS.map((anchor) => (
                  <option key={anchor.value} value={anchor.value}>
                    {anchor.label}
                  </option>
                ))}
              </select>
            </label>
            <div className="modal-actions">
              <button className="secondary-btn" onClick={() => setActiveCropItem(null)}>
                Cancel
              </button>
              <button className="primary-btn" onClick={applyItemCrop}>
                Apply Crop
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeResizeItem ? (
        <div className="modal-backdrop" role="dialog" aria-label="resize-modal">
          <div className="modal-card">
            <h3>Resize image</h3>
            <p>{basename(activeResizeItem.inputPath)}</p>
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
                Apply Resize
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeFolderCropPath ? (
        <div className="modal-backdrop" role="dialog" aria-label="folder-crop-modal">
          <div className="modal-card">
            <h3>Folder crop settings</h3>
            <p>{basename(activeFolderCropPath)}</p>
            <label>
              Size preset
              <select
                value={folderCropPreset}
                onChange={(event) => setFolderCropPreset(event.target.value as (typeof SIZE_PRESETS)[number]['value'])}
              >
                {SIZE_PRESETS.map((preset) => (
                  <option key={preset.value} value={preset.value}>
                    {preset.label}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Anchor
              <select
                value={folderCropAnchor}
                onChange={(event) => setFolderCropAnchor(event.target.value as CropSettings['anchor'])}
              >
                {CROP_ANCHORS.map((anchor) => (
                  <option key={anchor.value} value={anchor.value}>
                    {anchor.label}
                  </option>
                ))}
              </select>
            </label>
            <div className="modal-actions">
              <button className="secondary-btn" onClick={() => setActiveFolderCropPath(null)}>
                Cancel
              </button>
              <button className="primary-btn" onClick={applyFolderCrop}>
                Apply to Folder
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeFolderResizePath ? (
        <div className="modal-backdrop" role="dialog" aria-label="folder-resize-modal">
          <div className="modal-card">
            <h3>Folder resize settings</h3>
            <p>{basename(activeFolderResizePath)}</p>
            <label>
              Size preset
              <select
                value={folderResizePreset}
                onChange={(event) => setFolderResizePreset(event.target.value as (typeof SIZE_PRESETS)[number]['value'])}
              >
                {SIZE_PRESETS.map((preset) => (
                  <option key={preset.value} value={preset.value}>
                    {preset.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="checkbox-row">
              <input
                type="checkbox"
                checked={folderResizeLock}
                onChange={(event) => setFolderResizeLock(event.target.checked)}
              />
              <span>Lock aspect ratio</span>
            </label>
            <div className="modal-actions">
              <button className="secondary-btn" onClick={() => setActiveFolderResizePath(null)}>
                Cancel
              </button>
              <button className="primary-btn" onClick={applyFolderResize}>
                Apply to Folder
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default App;
