import { describe, expect, it } from 'vitest';
import { formatToolSourceLabel } from './toolDiagnostics';

describe('formatToolSourceLabel', () => {
  it('normalizes bundled and system source kinds without exposing paths', () => {
    expect(
      formatToolSourceLabel({
        name: 'pngquant',
        available: true,
        source_kind: 'bundled',
        source: '/Users/someone/resources/BundledTools/bin/pngquant',
      }),
    ).toBe('bundled');

    expect(
      formatToolSourceLabel({
        name: 'pngcrush',
        available: true,
        source_kind: 'host_path',
        source: '/usr/local/bin/pngcrush',
      }),
    ).toBe('system');

    expect(
      formatToolSourceLabel({
        name: 'cjpeg',
        available: true,
        source_kind: 'environment_override',
        source: 'C:\\tools\\jpeg\\cjpeg.exe',
      }),
    ).toBe('system');
  });

  it('marks unavailable tools as missing', () => {
    expect(
      formatToolSourceLabel({
        name: 'svgo',
        available: false,
        source_kind: null,
        source: null,
      }),
    ).toBe('missing');
  });
});
