import { useCallback, useEffect, useReducer, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { RELEASES_LATEST_URL } from '../../../config/release';
import {
  compareSemver,
  normalizeReleaseVersion,
  pickPreferredAsset,
  resolveExpectedSha256,
  updateReducer,
  type GitHubReleaseAsset,
  type RuntimePlatform,
  type UpdateFlowState,
} from '../../../state/updateState';
import { normalizeReleasePageURL } from '../utils';
import type { DownloadedUpdatePayload, InstallUpdateResult } from '../types';

type ReleasePayload = {
  tag_name?: string;
  html_url?: string;
  assets?: GitHubReleaseAsset[];
};

export function useUpdateController() {
  const [appVersion, setAppVersion] = useState('0.0.0');
  const [runtimePlatform, setRuntimePlatform] = useState<RuntimePlatform>('unknown');
  const [updateState, updateDispatch] = useReducer(updateReducer, { status: 'idle' } as UpdateFlowState);

  useEffect(() => {
    invoke<string>('app_version')
      .then((version) => {
        const normalized = normalizeReleaseVersion(version);
        if (normalized) {
          setAppVersion(normalized);
        }
      })
      .catch(() => undefined);

    invoke<string>('runtime_platform')
      .then((platform) => {
        if (platform === 'windows' || platform === 'linux' || platform === 'macos') {
          setRuntimePlatform(platform);
        }
      })
      .catch(() => undefined);
  }, []);

  const onCheckForUpdates = useCallback(async () => {
    updateDispatch({ type: 'START_CHECK' });

    try {
      const response = await fetch(RELEASES_LATEST_URL, {
        headers: {
          Accept: 'application/vnd.github+json',
        },
      });

      if (!response.ok) {
        throw new Error(`GitHub release check failed with HTTP ${response.status}`);
      }

      const payload = (await response.json()) as ReleasePayload;
      const releaseUrl = normalizeReleasePageURL(payload.html_url);

      const latestVersion = normalizeReleaseVersion(payload.tag_name ?? '');
      if (!latestVersion) {
        throw new Error('Latest release tag is not semantic.');
      }

      if (compareSemver(latestVersion, appVersion) <= 0) {
        updateDispatch({ type: 'SET_UP_TO_DATE', latestVersion });
        return;
      }

      const preferredAsset = pickPreferredAsset(payload.assets ?? [], runtimePlatform);
      if (!preferredAsset) {
        throw new Error('Latest release has no installable asset for this platform.');
      }

      updateDispatch({
        type: 'SET_AVAILABLE',
        latestVersion,
        releaseUrl,
        asset: preferredAsset,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  }, [appVersion, runtimePlatform]);

  const onDownloadUpdate = useCallback(async () => {
    if (updateState.status !== 'available') {
      return;
    }

    const candidate = updateState;
    updateDispatch({ type: 'START_DOWNLOAD' });

    try {
      const expectedSha256 = await resolveExpectedSha256(candidate.asset, fetch);
      updateDispatch({ type: 'SET_DOWNLOAD_PROGRESS', progress: null });

      const downloaded = await invoke<DownloadedUpdatePayload>('download_verified_update', {
        url: candidate.asset.url,
        fileName: candidate.asset.name,
        expectedSha256,
      });

      updateDispatch({
        type: 'SET_READY_TO_INSTALL',
        downloadPath: downloaded.path,
        downloadedSha256: downloaded.sha256,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  }, [updateState]);

  const onInstallUpdate = useCallback(async () => {
    if (updateState.status !== 'ready-to-install') {
      return;
    }

    const candidate = updateState;
    updateDispatch({ type: 'START_INSTALL' });

    try {
      const result = await invoke<InstallUpdateResult>('install_downloaded_update', {
        path: candidate.downloadPath,
        assetKind: candidate.asset.kind,
      });

      if (result.mode === 'guidance') {
        updateDispatch({
          type: 'SET_ACTION_REQUIRED',
          reason: result.message,
          command: result.command,
        });
        return;
      }

      updateDispatch({
        type: 'SET_RELAUNCHING',
        latestVersion: candidate.latestVersion,
      });
    } catch (error) {
      updateDispatch({
        type: 'FAIL',
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  }, [updateState]);

  const openReleasePage = useCallback(async (url: string) => {
    try {
      await invoke('open_external_url', { url });
    } catch {
      updateDispatch({
        type: 'FAIL',
        reason: 'Unable to open release page.',
      });
    }
  }, []);

  return {
    appVersion,
    updateState,
    onCheckForUpdates,
    onDownloadUpdate,
    onInstallUpdate,
    openReleasePage,
  };
}
