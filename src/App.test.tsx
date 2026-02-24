import { describe, expect, it, vi } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn((command: string) => {
    if (command === 'app_version') {
      return Promise.resolve('1.2.3');
    }

    return Promise.resolve([]);
  }),
}));

vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(() => Promise.resolve(() => undefined)),
}));

vi.mock('@tauri-apps/api/webview', () => ({
  getCurrentWebview: vi.fn(() => ({
    onDragDropEvent: vi.fn(() => Promise.resolve(() => undefined)),
  })),
}));

import App from './App';
import { UpdateRail } from './components/UpdateRail';

function expectOrdered(text: string, sequence: string[]) {
  let index = -1;
  for (const item of sequence) {
    const next = text.indexOf(item);
    expect(next).toBeGreaterThan(index);
    index = next;
  }
}

describe('App layout', () => {
  it('renders split rail sections in expected order with update controls', () => {
    const html = renderToStaticMarkup(<App />);

    expectOrdered(html, ['Updates', 'General', 'Dimensions', 'Optimizers', 'JPEG quality']);
    expect(html).toContain('Check for Updates');
  });

  it('renders actionable Windows install controls (not release-page-only fallback)', () => {
    const html = renderToStaticMarkup(
      <UpdateRail
        appVersion="1.1.0"
        updateState={{
          status: 'ready-to-install',
          latestVersion: '1.2.0',
          releaseUrl: 'https://github.com/lubomirmolin/pixelcrusher/releases/tag/v1.2.0',
          asset: {
            kind: 'windows-exe',
            name: 'PixelCrusher_1.2.0_x64-setup.exe',
            url: 'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_x64-setup.exe',
          },
          downloadPath: 'C:/Temp/PixelCrusher_1.2.0_x64-setup.exe',
          downloadedSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        }}
        onCheckForUpdates={() => undefined}
        onDownloadUpdate={() => undefined}
        onInstallUpdate={() => undefined}
        onOpenReleasePage={() => undefined}
      />,
    );

    expect(html).toContain('Install Update');
    expect(html).not.toContain('Download Update');
  });

  it('renders drop zone, queue controls, and bottom status pills', () => {
    const html = renderToStaticMarkup(<App />);

    expect(html).toContain('Drop files to crush');
    expect(html).toContain('Drag images here or pick files');
    expect(html).toContain('Cancel queued');
    expect(html).toContain('Cancel all');
    expect(html).toContain('Reveal Output Folder');

    expectOrdered(html, ['Stack:', 'Queue:', 'Bundled:', 'State:']);
  });
});
