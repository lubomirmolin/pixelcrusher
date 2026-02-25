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

export type CropDraft = {
  width: string;
  height: string;
};

export type ResizeDraft = {
  width: string;
  height: string;
  lock: boolean;
};

export type PunchQueueItem = {
  id: string;
  inputPath: string;
};
