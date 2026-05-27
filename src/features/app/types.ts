import type { JobResultEntry } from '../../state/queueState';

export type DragValidationState = 'idle' | 'supported' | 'unsupported';

export type DownloadedUpdatePayload = {
  path: string;
  size: number;
  sha256: string;
};

export type InstallUpdateResult = {
  mode: 'launched-and-exit' | 'launched' | 'guidance';
  message: string;
  command?: string;
};

export type CompressionProfileId = 'balanced' | 'high' | 'smallest';
export type AutomationActionKind =
  | 'compression'
  | 'removeBackground'
  | 'resize'
  | 'convertFormat'
  | 'trimTransparentBorders';
export type OutputImageFormat = 'png' | 'jpeg' | 'gif' | 'webp';
export type BackgroundRemovalModelVariant = 'fast' | 'highQuality';

export type ProfilePreset = {
  label: string;
  quality: number;
  pngQMin: number;
  pngQMax: number;
  runPngQuant: boolean;
  runPngcrush: boolean;
  runZopfli: boolean;
  runPngout: boolean;
};

export type FolderDropState = {
  id: string;
  folderName: string;
  folderPath: string;
};

export type CropDraft = {
  width: string;
  height: string;
  x: string;
  y: string;
};

export type ResizeDraft = {
  width: string;
  height: string;
  lock: boolean;
};

export type ConversionRequest = {
  item: JobResultEntry;
  targetFormat: OutputImageFormat;
};

export type RasterConversionDraft = {
  width: string;
  height: string;
  lock: boolean;
};

export type BackgroundRemovalFocusRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type BackgroundRemovalSuitability = {
  level: 'ready' | 'warning' | 'unavailable';
  message: string;
  is_available: boolean;
};

export type BackgroundRemovalModelStatus = {
  model: BackgroundRemovalModelVariant;
  display_name: string;
  short_label: string;
  detail: string;
  is_installed: boolean;
  model_path: string;
  installed_bytes?: number | null;
  download_bytes: number;
  suitability: BackgroundRemovalSuitability;
};

export type BackgroundRemovalEventPayload = {
  phase: string;
  message: string;
};

export type EnqueueAutomationPayload = {
  actions: AutomationActionKind[];
  background_model: BackgroundRemovalModelVariant;
};

export type PunchQueueItem = {
  id: string;
  inputPath: string;
  cropTransform?: PunchCropTransform;
};

export type CropAnchor = 'center' | 'top_left' | 'top_right' | 'bottom_left' | 'bottom_right';

export type PunchCropTransform = {
  width: number;
  height: number;
  x: number | null;
  y: number | null;
  anchor: CropAnchor;
};
