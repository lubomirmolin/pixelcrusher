// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const invokeMock = vi.fn();

vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
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

const recentResult = {
  id: 'job-1',
  input_path: '/Users/demo/assets/hero/banner.png',
  output_path: '/Users/demo/out/banner_pixelcrusher.png',
  status: 'completed',
  input_size: 1000,
  output_size: 700,
  size_delta_percent: -30,
  stages_run: ['pngquant'],
  duration_ms: 124,
};

function configureInvoke(overrides?: Partial<Record<string, unknown>>) {
  invokeMock.mockImplementation(async (command: string) => {
    if (command === 'startup_diagnostics') return [];
    if (command === 'recent_results') return overrides?.recent_results ?? [];
    if (command === 'app_version') return '1.2.3';
    if (command === 'runtime_platform') return 'windows';
    if (command === 'select_input_files') return [];
    if (command === 'select_input_folder') return '/Users/demo/assets';
    if (command === 'enqueue_paths') return [];
    return [];
  });
}

describe('App UI rewrite', () => {
  afterEach(() => {
    cleanup();
  });

  beforeEach(() => {
    vi.clearAllMocks();
    configureInvoke();
    (window as Window & { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__ = {};
  });

  it('renders empty state with top-bar profile selector', async () => {
    render(<App />);

    expect(await screen.findByText('Drop files to crush')).toBeTruthy();
    expect(screen.getByRole('combobox', { name: 'Compression profile' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Browse Files' })).toBeTruthy();
  });

  it('renders processed/results state when history exists', async () => {
    configureInvoke({ recent_results: [recentResult] });
    render(<App />);

    expect(await screen.findByText('Processed items')).toBeTruthy();
    expect(screen.getByText('banner.png')).toBeTruthy();
    expect(screen.getByText('-30.0%')).toBeTruthy();
  });

  it('opens crop and resize modals from item actions', async () => {
    configureInvoke({ recent_results: [recentResult] });
    const user = userEvent.setup();

    render(<App />);

    await screen.findByText('banner.png');

    const card = screen.getByText('banner.png').closest('.result-card');
    expect(card).toBeTruthy();
    if (!(card instanceof HTMLElement)) {
      throw new Error('missing card');
    }

    await user.click(within(card).getByRole('button', { name: 'Crop' }));
    expect(await screen.findByText('Crop image')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Cancel' }));

    await user.click(within(card).getByRole('button', { name: 'Resize' }));
    expect(await screen.findByText('Resize image')).toBeTruthy();
  });

  it('renders folder tree mode and applies folder-level controls', async () => {
    const user = userEvent.setup();
    render(<App />);

    await screen.findByText('Drop files to crush');
    await user.click(screen.getByRole('button', { name: 'Browse Folder' }));

    expect(await screen.findByText('Folder workflow')).toBeTruthy();
    expect(screen.getByText('assets')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Folder Resize' }));
    expect(await screen.findByText('Folder resize settings')).toBeTruthy();

    await user.selectOptions(screen.getByRole('combobox', { name: 'Size preset' }), '1024');
    await user.click(screen.getByRole('button', { name: 'Apply to Folder' }));

    await waitFor(() => {
      expect(screen.getByText(/Resize 1024×1024/)).toBeTruthy();
    });
  });

  it('keeps actionable Windows install controls in update rail', () => {
    render(
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

    expect(screen.getByRole('button', { name: 'Install Update' })).toBeTruthy();
  });
});
