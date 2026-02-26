// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

const invokeMock = vi.fn();

vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
  convertFileSrc: (path: string) => `asset://${path}`,
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
  invokeMock.mockImplementation(async (command: string, payload?: unknown) => {
    if (command === 'recent_results') return overrides?.recent_results ?? [];
    if (command === 'app_version') return '1.2.3';
    if (command === 'runtime_platform') return 'windows';
    if (command === 'select_input_files') return overrides?.select_input_files ?? [];
    if (command === 'enqueue_paths') return overrides?.enqueue_paths ?? payload ?? [];
    if (command === 'open_external_url') return [];
    return [];
  });
}

describe('App Swift-style UI', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    configureInvoke();
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({
        ok: true,
        status: 200,
        json: async () => ({
          tag_name: 'v1.2.4',
          html_url: 'https://github.com/lubomirmolin/pixelcrusher/releases/tag/v1.2.4',
          assets: [
            {
              name: 'PixelCrusher_1.2.4_x64-setup.exe',
              browser_download_url:
                'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.4/PixelCrusher_1.2.4_x64-setup.exe',
            },
          ],
        }),
      })),
    );
    (window as Window & { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__ = {};
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('renders initial empty view with top controls', async () => {
    render(<App />);

    expect(await screen.findByTestId('empty-state')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Update' })).toBeTruthy();
    expect(screen.getByRole('combobox', { name: 'Compression profile' })).toBeTruthy();
    expect(screen.getByRole('checkbox', { name: 'Autocrop' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Browse Files' })).toBeTruthy();
  });

  it('renders processed list when recent items exist', async () => {
    configureInvoke({ recent_results: [recentResult] });
    render(<App />);

    expect(await screen.findByTestId('list-state')).toBeTruthy();
    expect(screen.getByText('Processed images')).toBeTruthy();
    expect(screen.getByText('banner.png')).toBeTruthy();
    expect(screen.getByText('-30%')).toBeTruthy();
  });

  it('clears processed list back to empty state', async () => {
    configureInvoke({ recent_results: [recentResult] });
    const user = userEvent.setup();
    render(<App />);

    await screen.findByTestId('list-state');
    await user.click(screen.getByRole('button', { name: 'Clear' }));

    expect(await screen.findByTestId('empty-state')).toBeTruthy();
  });

  it('applies selected profile to enqueue payload', async () => {
    configureInvoke({
      select_input_files: ['/Users/demo/assets/new-asset.png'],
    });

    const user = userEvent.setup();
    render(<App />);

    await user.selectOptions(screen.getByRole('combobox', { name: 'Compression profile' }), 'smallest');
    await user.click(screen.getByRole('button', { name: 'Browse Files' }));

    await waitFor(() => {
      const enqueueCall = invokeMock.mock.calls.find(([command]) => command === 'enqueue_paths');
      expect(enqueueCall).toBeTruthy();
      const payload = enqueueCall?.[1] as { options?: { compression?: { quality?: number } } };
      expect(payload.options?.compression?.quality).toBe(70);
    });
  });

  it('shows queue error when only unsupported files are selected', async () => {
    configureInvoke({
      select_input_files: ['/Users/demo/assets/notes.txt'],
    });

    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole('button', { name: 'Browse Files' }));

    await waitFor(() => {
      const alert = screen.getByRole('alert');
      expect(alert.textContent).toContain('Unsupported format');
    });
  });

  it('applies item crop as one-off enqueue against the latest output path', async () => {
    configureInvoke({
      recent_results: [recentResult],
      enqueue_paths: [
        {
          id: 'job-2',
          input_path: recentResult.output_path,
          status: 'queued',
          progress: 0,
          message: 'Queued',
        },
      ],
    });

    const user = userEvent.setup();
    render(<App />);

    await screen.findByTestId('list-state');
    await user.click(screen.getByTitle('Crop Image'));
    await user.type(screen.getByLabelText('Width'), '120');
    await user.type(screen.getByLabelText('Height'), '80');
    await user.clear(screen.getByLabelText('X'));
    await user.type(screen.getByLabelText('X'), '12');
    await user.clear(screen.getByLabelText('Y'));
    await user.type(screen.getByLabelText('Y'), '18');
    await user.click(screen.getByRole('button', { name: 'Apply' }));

    await waitFor(() => {
      const enqueueCalls = invokeMock.mock.calls.filter(([command]) => command === 'enqueue_paths');
      expect(enqueueCalls.length).toBeGreaterThan(0);

      const payload = enqueueCalls.at(-1)?.[1] as {
        paths?: string[];
        options?: {
          trim_transparent?: boolean;
          transform?: {
            crop_width?: number;
            crop_height?: number;
            crop_x?: number;
            crop_y?: number;
          };
        };
      };

      expect(payload.paths).toEqual([recentResult.output_path]);
      expect(payload.options?.trim_transparent).toBe(false);
      expect(payload.options?.transform?.crop_width).toBe(120);
      expect(payload.options?.transform?.crop_height).toBe(80);
      expect(payload.options?.transform?.crop_x).toBe(12);
      expect(payload.options?.transform?.crop_y).toBe(18);
    });
  });

  it('opens updates modal and fetches latest release', async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole('button', { name: 'Update' }));
    expect(await screen.findByRole('dialog', { name: 'updates-modal' })).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Check for Updates' }));

    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Download Update' })).toBeTruthy();
    });

    const fetchMock = global.fetch as unknown as ReturnType<typeof vi.fn>;
    expect(fetchMock).toHaveBeenCalled();
  });
});
