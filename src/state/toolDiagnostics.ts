export type ToolStatus = {
  name: string;
  available: boolean;
  source?: string | null;
  source_kind?: string | null;
};

export const REQUIRED_TOOLCHAIN = ['cjpeg', 'pngquant', 'pngcrush', 'svgo', 'gifsicle'];

const SYSTEM_SOURCE_KINDS = new Set(['host_path', 'environment_override']);

export function formatToolSourceLabel(tool: ToolStatus): 'bundled' | 'system' | 'available' | 'missing' {
  if (!tool.available) {
    return 'missing';
  }

  if (tool.source_kind === 'bundled') {
    return 'bundled';
  }

  if (tool.source_kind && SYSTEM_SOURCE_KINDS.has(tool.source_kind)) {
    return 'system';
  }

  return 'available';
}

export function summarizeBundledDiagnostics(diagnostics: ToolStatus[]) {
  const requiredStatuses = REQUIRED_TOOLCHAIN.map((name) => diagnostics.find((tool) => tool.name === name));
  const ready = requiredStatuses.filter((tool) => tool?.available && tool.source_kind === 'bundled').length;

  return {
    total: REQUIRED_TOOLCHAIN.length,
    ready,
    allReady: ready === REQUIRED_TOOLCHAIN.length,
  };
}

export function summarizeStackSource(diagnostics: ToolStatus[]): 'bundled' | 'system' | 'mixed' | 'missing' {
  const requiredStatuses = REQUIRED_TOOLCHAIN.map((name) => diagnostics.find((tool) => tool.name === name));

  const available = requiredStatuses.filter((tool): tool is ToolStatus => Boolean(tool?.available));

  if (available.length === 0) {
    return 'missing';
  }

  const bundledCount = available.filter((tool) => tool.source_kind === 'bundled').length;

  if (bundledCount === available.length) {
    return 'bundled';
  }

  if (bundledCount === 0) {
    return 'system';
  }

  return 'mixed';
}
