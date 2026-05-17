import type { CompressionProfileId, ProfilePreset } from './types';

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
