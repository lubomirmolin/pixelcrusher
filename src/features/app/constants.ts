import type {
  AutomationActionKind,
  BackgroundRemovalModelVariant,
  CompressionProfileId,
  OutputImageFormat,
  ProfilePreset,
} from './types';

export const TERMINAL_JOB_STATUSES = new Set(['completed', 'failed']);

export const SUPPORTED_EXTENSIONS = new Set(['png', 'jpg', 'jpeg', 'svg', 'gif', 'webp']);
export const SUPPORTED_FORMATS_LABEL = 'PNG/JPG/JPEG/SVG/GIF/WEBP';

export const ENQUEUE_DEDUPE_WINDOW_MS = 1000;

export const PROFILE_PRESETS: Record<CompressionProfileId, ProfilePreset> = {
  balanced: {
    label: 'Balanced',
    quality: 82,
    pngQMin: 60,
    pngQMax: 90,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: false,
    runPngout: false,
  },
  high: {
    label: 'High Quality',
    quality: 92,
    pngQMin: 75,
    pngQMax: 98,
    runPngQuant: false,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
  },
  smallest: {
    label: 'Smallest Size',
    quality: 70,
    pngQMin: 45,
    pngQMax: 75,
    runPngQuant: true,
    runPngcrush: true,
    runZopfli: true,
    runPngout: false,
  },
};

export const DEFAULT_AUTOMATION_ACTIONS: AutomationActionKind[] = ['compression'];

export const AUTOMATION_ACTION_META: Record<
  AutomationActionKind,
  {
    title: string;
    subtitle: string;
  }
> = {
  compression: {
    title: 'Compress Image',
    subtitle: 'Optimize size and quality',
  },
  removeBackground: {
    title: 'Remove Background',
    subtitle: 'Isolate main subject',
  },
  resize: {
    title: 'Resize',
    subtitle: 'Scale to target dimensions',
  },
  convertFormat: {
    title: 'Convert Format',
    subtitle: 'Save in another format',
  },
  trimTransparentBorders: {
    title: 'Trim Transparent Edges',
    subtitle: 'Remove empty alpha bounds',
  },
};

export const AUTOMATION_ACTION_ORDER: AutomationActionKind[] = [
  'compression',
  'removeBackground',
  'resize',
  'convertFormat',
  'trimTransparentBorders',
];

export const OUTPUT_FORMATS: OutputImageFormat[] = ['png', 'jpeg', 'gif', 'webp'];

export const OUTPUT_FORMAT_LABELS: Record<OutputImageFormat, string> = {
  png: 'PNG',
  jpeg: 'JPG',
  gif: 'GIF',
  webp: 'WEBP',
};

export const BACKGROUND_MODEL_LABELS: Record<BackgroundRemovalModelVariant, string> = {
  fast: 'Fast',
  highQuality: 'High Quality',
};
