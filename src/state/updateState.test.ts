import { describe, expect, it, vi } from 'vitest';
import {
  compareSemver,
  describeUpdateState,
  normalizeReleaseVersion,
  pickPreferredAsset,
  resolveExpectedSha256,
  updateReducer,
  verifyDownloadedHash,
  type UpdateFlowState,
} from './updateState';

describe('updateState version gating', () => {
  it('normalizes release tags to semantic versions', () => {
    expect(normalizeReleaseVersion('v1.2.3')).toBe('1.2.3');
    expect(normalizeReleaseVersion('1.2.3-beta.1')).toBe('1.2.3-beta.1');
    expect(normalizeReleaseVersion('not-a-version')).toBeNull();
  });

  it('compares semantic versions correctly for equal and newer releases', () => {
    expect(compareSemver('1.2.3', '1.2.3')).toBe(0);
    expect(compareSemver('1.2.4', '1.2.3')).toBeGreaterThan(0);
    expect(compareSemver('1.2.3', '1.3.0')).toBeLessThan(0);
    expect(compareSemver('1.2.3', '1.2.3-beta.1')).toBeGreaterThan(0);
  });

  it('picks preferred trusted update assets per platform', () => {
    const windowsAsset = pickPreferredAsset(
      [
        {
          name: 'PixelCrusher_1.2.0_x64_en-US.msi',
          browser_download_url:
            'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_x64_en-US.msi',
        },
        {
          name: 'PixelCrusher_1.2.0_x64-setup.exe',
          browser_download_url:
            'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_x64-setup.exe',
        },
      ],
      'windows',
    );

    const linuxAsset = pickPreferredAsset(
      [
        {
          name: 'PixelCrusher_1.2.0_amd64.deb',
          browser_download_url:
            'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_amd64.deb',
        },
        {
          name: 'PixelCrusher_1.2.0_amd64.AppImage',
          browser_download_url:
            'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_amd64.AppImage',
        },
      ],
      'linux',
    );

    expect(windowsAsset?.kind).toBe('windows-exe');
    expect(linuxAsset?.kind).toBe('linux-appimage');
  });
});

describe('updateState windows updater state machine', () => {
  const windowsAsset = {
    kind: 'windows-exe' as const,
    name: 'PixelCrusher_1.2.0_x64-setup.exe',
    url: 'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_x64-setup.exe',
    digest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  };

  it('transitions check -> download -> ready -> install -> relaunch', () => {
    let state: UpdateFlowState = { status: 'idle' };

    state = updateReducer(state, { type: 'START_CHECK' });
    expect(state.status).toBe('checking');

    state = updateReducer(state, {
      type: 'SET_AVAILABLE',
      latestVersion: '1.2.0',
      releaseUrl: 'https://github.com/lubomirmolin/pixelcrusher/releases/tag/v1.2.0',
      asset: windowsAsset,
    });
    expect(state.status).toBe('available');

    state = updateReducer(state, { type: 'START_DOWNLOAD' });
    expect(state.status).toBe('downloading');

    state = updateReducer(state, {
      type: 'SET_READY_TO_INSTALL',
      downloadPath: 'C:/Temp/PixelCrusher_1.2.0_x64-setup.exe',
      downloadedSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });
    expect(state.status).toBe('ready-to-install');

    state = updateReducer(state, { type: 'START_INSTALL' });
    expect(state.status).toBe('installing');

    state = updateReducer(state, { type: 'SET_RELAUNCHING', latestVersion: '1.2.0' });
    expect(state.status).toBe('relaunching');
  });

  it('enters fail state when any step errors', () => {
    const failed = updateReducer({ status: 'checking' }, { type: 'FAIL', reason: 'Network unavailable' });
    expect(failed.status).toBe('error');
    expect(describeUpdateState(failed, '1.1.0')).toContain('Network unavailable');
  });
});

describe('updateState hash verification', () => {
  it('verifies downloaded payload SHA-256', async () => {
    const payload = new TextEncoder().encode('pixelcrusher-update-test');
    const validDigest = '857fddb3e09d3806861d6092741ce094e538c6ef741ad1cd02065f3d0cdb3b96';

    await expect(verifyDownloadedHash(payload, validDigest)).resolves.toBe(true);
    await expect(
      verifyDownloadedHash(
        payload,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    ).resolves.toBe(false);
  });

  it('resolves expected digest from companion checksum when metadata digest is absent', async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      text: async () =>
        '857fddb3e09d3806861d6092741ce094e538c6ef741ad1cd02065f3d0cdb3b96  PixelCrusher_1.2.0_x64-setup.exe',
    }));

    const digest = await resolveExpectedSha256(
      {
        kind: 'windows-exe',
        name: 'PixelCrusher_1.2.0_x64-setup.exe',
        url: 'https://github.com/lubomirmolin/pixelcrusher/releases/download/v1.2.0/PixelCrusher_1.2.0_x64-setup.exe',
      },
      fetchImpl as unknown as typeof fetch,
    );

    expect(digest).toBe('857fddb3e09d3806861d6092741ce094e538c6ef741ad1cd02065f3d0cdb3b96');
  });
});
