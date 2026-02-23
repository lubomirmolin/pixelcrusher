import { describe, expect, it, vi } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(() => Promise.resolve([])),
}));

vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(() => Promise.resolve(() => undefined)),
}));

import App from './App';

function expectOrdered(text: string, sequence: string[]) {
  let index = -1;
  for (const item of sequence) {
    const next = text.indexOf(item);
    expect(next).toBeGreaterThan(index);
    index = next;
  }
}

describe('App layout', () => {
  it('renders split rail sections in expected order', () => {
    const html = renderToStaticMarkup(<App />);

    expectOrdered(html, ['General', 'Dimensions', 'Optimizers', 'JPEG quality']);
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
