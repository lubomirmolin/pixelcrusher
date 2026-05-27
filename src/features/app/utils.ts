import { convertFileSrc } from '@tauri-apps/api/core';
import { RELEASES_PAGE_URL } from '../../config/release';
import { OUTPUT_FORMATS, SUPPORTED_EXTENSIONS } from './constants';
import type { DragValidationState, OutputImageFormat } from './types';

export function basename(filePath: string): string {
  const parts = filePath.split(/[\\/]/).filter(Boolean);
  return parts.at(-1) ?? filePath;
}

export function asOptionalDimension(value: string): number | null {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return null;
  }

  return Math.floor(num);
}

export function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

export function normalizeReleasePageURL(candidate?: string): string {
  if (!candidate) {
    return RELEASES_PAGE_URL;
  }

  try {
    const parsed = new URL(candidate);
    if (
      parsed.protocol === 'https:'
      && parsed.hostname.toLowerCase() === 'github.com'
      && parsed.pathname.startsWith('/lubomirmolin/pixelcrusher/releases')
    ) {
      return parsed.toString();
    }
  } catch {
    // fallback to default
  }

  return RELEASES_PAGE_URL;
}

export function toAssetUrl(path: string): string {
  if (!path) {
    return '';
  }

  if (isTauriRuntime()) {
    try {
      return convertFileSrc(path);
    } catch {
      // fallback below
    }
  }

  const normalized = path.replace(/\\/g, '/');
  const prefixed = normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
  return encodeURI(prefixed);
}

export function fileExtension(path: string): string {
  const name = basename(path);
  const dotIndex = name.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex === name.length - 1) {
    return '';
  }
  return name.slice(dotIndex + 1).toLowerCase();
}

export function mimeTypeForPath(path: string): string {
  const ext = fileExtension(path);
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'svg':
      return 'image/svg+xml';
    case 'webp':
      return 'image/webp';
    default:
      return 'application/octet-stream';
  }
}

export function outputFormatForPath(path: string): OutputImageFormat | null {
  const ext = fileExtension(path);
  if (ext === 'jpg') {
    return 'jpeg';
  }
  return OUTPUT_FORMATS.includes(ext as OutputImageFormat) ? (ext as OutputImageFormat) : null;
}

export function availableConversionFormats(path: string): OutputImageFormat[] {
  const sourceFormat = outputFormatForPath(path);
  if (!sourceFormat && fileExtension(path) !== 'svg') {
    return [];
  }
  if (fileExtension(path) === 'svg') {
    return OUTPUT_FORMATS;
  }
  return OUTPUT_FORMATS.filter((format) => format !== sourceFormat);
}

export function classifyInputPath(path: string): 'supported' | 'unsupported' | 'unknown' {
  const ext = fileExtension(path);
  if (!ext) {
    return 'unknown';
  }
  return SUPPORTED_EXTENSIONS.has(ext) ? 'supported' : 'unsupported';
}

export function formatSavings(deltaPercent?: number): string {
  if (deltaPercent == null || Number.isNaN(deltaPercent)) {
    return '';
  }

  const rounded = Math.round(Math.abs(deltaPercent));
  return deltaPercent <= 0 ? `-${rounded}%` : `+${rounded}%`;
}

export function dragStateFromPaths(paths: string[]): DragValidationState {
  if (!paths.length) {
    return 'supported';
  }

  return paths.some((path) => classifyInputPath(path) === 'unsupported') ? 'unsupported' : 'supported';
}

export function dragStateFromFiles(files: File[]): DragValidationState {
  if (!files.length) {
    return 'supported';
  }

  const hasUnsupported = files.some((file) => {
    const ext = fileExtension(file.name);
    if (!ext) {
      return false;
    }
    return !SUPPORTED_EXTENSIONS.has(ext);
  });

  return hasUnsupported ? 'unsupported' : 'supported';
}
