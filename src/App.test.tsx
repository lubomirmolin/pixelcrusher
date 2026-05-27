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

const installedBackgroundStatuses = [
  {
    model: 'fast',
    display_name: 'Fast',
    short_label: 'Quantized',
    detail: 'Quantized RMBG-1.4 ONNX.',
    is_installed: true,
    model_path: '/Users/demo/models/model_quantized.onnx',
    installed_bytes: 44403226,
    download_bytes: 44403226,
    suitability: {
      level: 'ready',
      message: 'Fast RMBG is available.',
      is_available: true,
    },
  },
  {
    model: 'highQuality',
    display_name: 'High Quality',
    short_label: 'Full',
    detail: 'Full RMBG-1.4 ONNX.',
    is_installed: false,
    model_path: '/Users/demo/models/model.onnx',
    installed_bytes: null,
    download_bytes: 176153355,
    suitability: {
      level: 'ready',
      message: 'High Quality RMBG is available.',
      is_available: true,
    },
  },
];

function configureInvoke(overrides?: Partial<Record<string, unknown>>) {
  invokeMock.mockImplementation(async (command: string, payload?: unknown) => {
    if (command === 'recent_results') return overrides?.recent_results ?? [];
    if (command === 'background_removal_statuses') return overrides?.background_removal_statuses ?? installedBackgroundStatuses;
    if (command === 'download_background_removal_model') return overrides?.download_background_removal_model ?? installedBackgroundStatuses[1];
    if (command === 'remove_background') return overrides?.remove_background ?? {
      ...recentResult,
      id: 'job-bg',
      input_path: (payload as { inputPath?: string })?.inputPath ?? recentResult.output_path,
      output_path: '/Users/demo/out/banner_nobg.png',
      stages_run: ['background-removal'],
    };
    if (command === 'app_version') return '1.2.3';
    if (command === 'runtime_platform') return 'windows';
    if (command === 'select_input_files') return overrides?.select_input_files ?? [];
    if (command === 'select_input_folder') return overrides?.select_input_folder ?? null;
    if (command === 'enqueue_paths') return overrides?.enqueue_paths ?? payload ?? [];
    if (command === 'open_external_url') return [];
    return [];
  });
}

describe('App Swift-style UI', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
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
    expect(screen.getByText('Automations')).toBeTruthy();
    expect(screen.getByText('Compress Image')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Update' })).toBeTruthy();
    expect(screen.getByRole('combobox', { name: 'Compression profile' })).toBeTruthy();
    expect(screen.getByLabelText('Add automation action')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Browse Files' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Browse Folder' })).toBeTruthy();
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
      const payload = enqueueCall?.[1] as {
        options?: { compression?: { quality?: number } };
        automation?: { actions?: string[]; background_model?: string };
      };
      expect(payload.options?.compression?.quality).toBe(70);
      expect(payload.automation?.actions).toEqual(['compression']);
      expect(payload.automation?.background_model).toBe('fast');
    });
  });

  it('adds automation actions and sends the chain to enqueue', async () => {
    configureInvoke({
      select_input_files: ['/Users/demo/assets/new-asset.png'],
    });

    const user = userEvent.setup();
    render(<App />);

    await user.selectOptions(screen.getByLabelText('Add automation action'), 'resize');
    await user.click(screen.getByRole('checkbox', { name: 'Resize by max side' }));
    await user.clear(screen.getByLabelText(/Max side/));
    await user.type(screen.getByLabelText(/Max side/), '800');
    await user.selectOptions(screen.getByLabelText('Add automation action'), 'convertFormat');
    await user.selectOptions(screen.getByLabelText('Format'), 'webp');
    await user.click(screen.getByRole('button', { name: 'Browse Files' }));

    await waitFor(() => {
      const enqueueCall = invokeMock.mock.calls.find(([command]) => command === 'enqueue_paths');
      expect(enqueueCall).toBeTruthy();
      const payload = enqueueCall?.[1] as {
        options?: {
          transform?: { resize_longest_side?: number | null };
          output_format?: string | null;
        };
        automation?: { actions?: string[] };
      };
      expect(payload.automation?.actions).toEqual(['compression', 'resize', 'convertFormat']);
      expect(payload.options?.transform?.resize_longest_side).toBe(800);
      expect(payload.options?.output_format).toBe('webp');
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

  it('enqueues selected folder when using folder picker', async () => {
    configureInvoke({
      select_input_folder: '/Users/demo/assets/folder',
    });

    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole('button', { name: 'Browse Folder' }));

    await waitFor(() => {
      const pickerCall = invokeMock.mock.calls.find(([command]) => command === 'select_input_folder');
      expect(pickerCall).toBeTruthy();

      const enqueueCall = invokeMock.mock.calls.find(([command]) => command === 'enqueue_paths');
      expect(enqueueCall).toBeTruthy();

      const payload = enqueueCall?.[1] as { paths?: string[] };
      expect(payload.paths).toEqual(['/Users/demo/assets/folder']);
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
    await user.click(screen.getByTitle('Crop image'));
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

  it('applies item resize as one-off enqueue against the latest output path', async () => {
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
    await user.click(screen.getByTitle('Resize image'));
    await user.clear(screen.getByLabelText('Width'));
    await user.type(screen.getByLabelText('Width'), '320');
    await user.clear(screen.getByLabelText('Height'));
    await user.type(screen.getByLabelText('Height'), '180');
    await user.click(screen.getByRole('button', { name: 'Apply' }));

    await waitFor(() => {
      const enqueueCalls = invokeMock.mock.calls.filter(([command]) => command === 'enqueue_paths');
      const payload = enqueueCalls.at(-1)?.[1] as {
        paths?: string[];
        options?: {
          trim_transparent?: boolean;
          transform?: {
            resize_width?: number | null;
            resize_height?: number | null;
          };
        };
      };

      expect(payload.paths).toEqual([recentResult.output_path]);
      expect(payload.options?.trim_transparent).toBe(false);
      expect(payload.options?.transform?.resize_width).toBe(320);
      expect(payload.options?.transform?.resize_height).toBe(180);
    });
  });

  it('opens background removal modal and runs quick remove', async () => {
    configureInvoke({
      recent_results: [recentResult],
    });

    const user = userEvent.setup();
    render(<App />);

    await screen.findByTestId('list-state');
    await user.click(screen.getByTitle('Remove background'));
    expect(await screen.findByRole('dialog', { name: 'remove-background-modal' })).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Quick Remove' }));

    await waitFor(() => {
      const removeCall = invokeMock.mock.calls.find(([command]) => command === 'remove_background');
      expect(removeCall).toBeTruthy();
      const payload = removeCall?.[1] as { inputPath?: string; model?: string; focusRect?: unknown };
      expect(payload.inputPath).toBe(recentResult.output_path);
      expect(payload.model).toBe('fast');
      expect(payload.focusRect).toBeNull();
    });
  });

  it('converts a completed image from the row action menu', async () => {
    configureInvoke({
      recent_results: [recentResult],
    });

    const user = userEvent.setup();
    render(<App />);

    await screen.findByTestId('list-state');
    await user.selectOptions(screen.getByLabelText('Convert image format'), 'webp');

    await waitFor(() => {
      const enqueueCalls = invokeMock.mock.calls.filter(([command]) => command === 'enqueue_paths');
      const payload = enqueueCalls.at(-1)?.[1] as {
        paths?: string[];
        options?: { output_format?: string | null };
      };

      expect(payload.paths).toEqual([recentResult.output_path]);
      expect(payload.options?.output_format).toBe('webp');
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
