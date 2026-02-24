import { describe, expect, it } from 'vitest';
import { compareSemver, describeUpdateState, normalizeReleaseVersion, type UpdateCheckState } from './updateState';

describe('updateState', () => {
  it('normalizes release tags to semantic versions', () => {
    expect(normalizeReleaseVersion('v1.2.3')).toBe('1.2.3');
    expect(normalizeReleaseVersion('1.2.3-beta.1')).toBe('1.2.3-beta.1');
    expect(normalizeReleaseVersion('not-a-version')).toBeNull();
  });

  it('compares semantic versions correctly', () => {
    expect(compareSemver('1.2.3', '1.2.3')).toBe(0);
    expect(compareSemver('1.2.4', '1.2.3')).toBeGreaterThan(0);
    expect(compareSemver('1.2.3', '1.3.0')).toBeLessThan(0);
    expect(compareSemver('1.2.3', '1.2.3-beta.1')).toBeGreaterThan(0);
  });

  it('renders user-facing status text for each update state', () => {
    const states: UpdateCheckState[] = [
      { status: 'idle' },
      { status: 'checking' },
      { status: 'up-to-date', latestVersion: '1.2.3' },
      { status: 'available', latestVersion: '1.3.0', releaseUrl: 'https://example.com/release' },
      { status: 'error', reason: 'Network unavailable' },
    ];

    const rendered = states.map((state) => describeUpdateState(state, '1.2.3')).join('\n');

    expect(rendered).toContain('Manual update checks are available.');
    expect(rendered).toContain('Checking for updates…');
    expect(rendered).toContain('You are up to date (v1.2.3).');
    expect(rendered).toContain('Update available: v1.3.0 (current v1.2.3).');
    expect(rendered).toContain('Update check failed: Network unavailable');
  });
});
