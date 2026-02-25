import { RELEASE_OWNER, RELEASE_REPO, RELEASES_PAGE_URL } from '../config/release';

export type RuntimePlatform = 'windows' | 'linux' | 'macos' | 'unknown';

export type UpdateAssetKind =
  | 'windows-exe'
  | 'windows-msi'
  | 'linux-appimage'
  | 'linux-deb'
  | 'macos-zip'
  | 'macos-dmg';

export type UpdateAsset = {
  name: string;
  url: string;
  digest?: string | null;
  kind: UpdateAssetKind;
};

export type UpdateFlowState =
  | { status: 'idle' }
  | { status: 'checking' }
  | { status: 'up-to-date'; latestVersion: string }
  | { status: 'available'; latestVersion: string; releaseUrl: string; asset: UpdateAsset }
  | {
      status: 'downloading';
      latestVersion: string;
      releaseUrl: string;
      asset: UpdateAsset;
      progress: number | null;
    }
  | {
      status: 'ready-to-install';
      latestVersion: string;
      releaseUrl: string;
      asset: UpdateAsset;
      downloadPath: string;
      downloadedSha256: string;
    }
  | { status: 'installing'; latestVersion: string; releaseUrl: string; asset: UpdateAsset }
  | { status: 'relaunching'; latestVersion: string }
  | { status: 'action-required'; reason: string; releaseUrl: string; command?: string }
  | { status: 'error'; reason: string; releaseUrl?: string };

export type UpdateFlowEvent =
  | { type: 'START_CHECK' }
  | { type: 'SET_UP_TO_DATE'; latestVersion: string }
  | { type: 'SET_AVAILABLE'; latestVersion: string; releaseUrl: string; asset: UpdateAsset }
  | { type: 'START_DOWNLOAD' }
  | { type: 'SET_DOWNLOAD_PROGRESS'; progress: number | null }
  | { type: 'SET_READY_TO_INSTALL'; downloadPath: string; downloadedSha256: string }
  | { type: 'START_INSTALL' }
  | { type: 'SET_RELAUNCHING'; latestVersion: string }
  | { type: 'SET_ACTION_REQUIRED'; reason: string; command?: string }
  | { type: 'FAIL'; reason: string }
  | { type: 'RESET' };

type ParsedSemver = {
  major: number;
  minor: number;
  patch: number;
  preRelease: string[];
};

export type GitHubReleaseAsset = {
  name: string;
  browser_download_url: string;
  digest?: string | null;
};

function parseSemver(value: string): ParsedSemver | null {
  const normalized = value.trim().replace(/^v/i, '');
  const match = normalized.match(
    /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/,
  );

  if (!match) {
    return null;
  }

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    preRelease: match[4] ? match[4].split('.') : [],
  };
}

function comparePreReleaseIdentifiers(a: string[], b: string[]): number {
  const len = Math.max(a.length, b.length);

  for (let i = 0; i < len; i += 1) {
    const left = a[i];
    const right = b[i];

    if (left === undefined) return -1;
    if (right === undefined) return 1;

    const leftNum = /^\d+$/.test(left);
    const rightNum = /^\d+$/.test(right);

    if (leftNum && rightNum) {
      const diff = Number(left) - Number(right);
      if (diff !== 0) return diff;
      continue;
    }

    if (leftNum !== rightNum) {
      return leftNum ? -1 : 1;
    }

    if (left < right) return -1;
    if (left > right) return 1;
  }

  return 0;
}

export function compareSemver(leftRaw: string, rightRaw: string): number {
  const left = parseSemver(leftRaw);
  const right = parseSemver(rightRaw);

  if (!left || !right) {
    throw new Error(`Invalid semantic versions: ${leftRaw} vs ${rightRaw}`);
  }

  if (left.major !== right.major) return left.major - right.major;
  if (left.minor !== right.minor) return left.minor - right.minor;
  if (left.patch !== right.patch) return left.patch - right.patch;

  if (left.preRelease.length === 0 && right.preRelease.length === 0) return 0;
  if (left.preRelease.length === 0) return 1;
  if (right.preRelease.length === 0) return -1;

  return comparePreReleaseIdentifiers(left.preRelease, right.preRelease);
}

export function normalizeReleaseVersion(value: string): string | null {
  const parsed = parseSemver(value);
  if (!parsed) {
    return null;
  }

  const normalized = `${parsed.major}.${parsed.minor}.${parsed.patch}`;
  return parsed.preRelease.length > 0 ? `${normalized}-${parsed.preRelease.join('.')}` : normalized;
}

function inferAssetKind(name: string): UpdateAssetKind | null {
  const lowered = name.toLowerCase();
  if (lowered.endsWith('.msi')) return 'windows-msi';
  if (lowered.endsWith('.exe')) return 'windows-exe';
  if (lowered.endsWith('.appimage')) return 'linux-appimage';
  if (lowered.endsWith('.deb')) return 'linux-deb';
  if (lowered.endsWith('.zip')) return 'macos-zip';
  if (lowered.endsWith('.dmg')) return 'macos-dmg';
  return null;
}

function assetPriority(kind: UpdateAssetKind, platform: RuntimePlatform): number {
  switch (platform) {
    case 'windows':
      if (kind === 'windows-exe') return 0;
      if (kind === 'windows-msi') return 1;
      return 999;
    case 'linux':
      if (kind === 'linux-appimage') return 0;
      if (kind === 'linux-deb') return 1;
      return 999;
    case 'macos':
      if (kind === 'macos-zip') return 0;
      if (kind === 'macos-dmg') return 1;
      return 999;
    default:
      return 999;
  }
}

export function isTrustedReleaseAssetUrl(
  urlRaw: string,
  owner = RELEASE_OWNER,
  repo = RELEASE_REPO,
): boolean {
  try {
    const url = new URL(urlRaw);
    if (url.protocol !== 'https:') return false;

    const host = url.hostname.toLowerCase();
    if (host === 'github.com') {
      return url.pathname.includes(`/${owner}/${repo}/releases/download/`);
    }

    return (
      host === 'objects.githubusercontent.com' ||
      host === 'github-releases.githubusercontent.com' ||
      host === 'release-assets.githubusercontent.com'
    );
  } catch {
    return false;
  }
}

export function pickPreferredAsset(
  assets: GitHubReleaseAsset[],
  platform: RuntimePlatform,
): UpdateAsset | null {
  const candidates: UpdateAsset[] = [];

  for (const asset of assets) {
    const kind = inferAssetKind(asset.name);
    if (!kind || !isTrustedReleaseAssetUrl(asset.browser_download_url)) {
      continue;
    }

    candidates.push({
      name: asset.name,
      url: asset.browser_download_url,
      digest: asset.digest,
      kind,
    });
  }

  candidates.sort((left, right) => {
    const rank = assetPriority(left.kind, platform) - assetPriority(right.kind, platform);
    if (rank !== 0) {
      return rank;
    }

    const setupRankLeft = left.name.toLowerCase().includes('setup') ? -1 : 0;
    const setupRankRight = right.name.toLowerCase().includes('setup') ? -1 : 0;
    if (setupRankLeft !== setupRankRight) {
      return setupRankLeft - setupRankRight;
    }

    return left.name.localeCompare(right.name);
  });

  const preferred = candidates[0];
  if (!preferred) {
    return null;
  }

  return assetPriority(preferred.kind, platform) >= 999 ? null : preferred;
}

function isSha256Hex(value: string): boolean {
  return /^[a-f0-9]{64}$/i.test(value);
}

export function parseMetadataDigest(rawDigest: string | null | undefined, sourceName: string): string | null {
  const normalized = rawDigest?.trim().toLowerCase();
  if (!normalized) {
    return null;
  }

  if (!normalized.startsWith('sha256:')) {
    throw new Error(`Invalid digest metadata format for ${sourceName}.`);
  }

  const digest = normalized.slice('sha256:'.length).trim();
  if (!isSha256Hex(digest)) {
    throw new Error(`Invalid SHA-256 digest metadata for ${sourceName}.`);
  }

  return digest;
}

export function digestCompanionUrls(assetUrl: string): string[] {
  const primary = `${assetUrl}.sha256`;

  const parsed = new URL(assetUrl);
  const basePath = parsed.pathname;
  const dot = basePath.lastIndexOf('.');
  const secondary =
    dot > basePath.lastIndexOf('/')
      ? `${parsed.origin}${basePath.slice(0, dot)}.sha256${parsed.search}`
      : primary;

  return Array.from(new Set([primary, secondary]));
}

export function extractSha256Hex(text: string): string | null {
  const match = text.match(/\b([a-fA-F0-9]{64})\b/);
  return match ? match[1].toLowerCase() : null;
}

export async function sha256Hex(data: Uint8Array): Promise<string> {
  if (!globalThis.crypto?.subtle) {
    throw new Error('Web Crypto API is unavailable in this runtime.');
  }

  const portableBytes = new Uint8Array(data.byteLength);
  portableBytes.set(data);
  const digest = await globalThis.crypto.subtle.digest('SHA-256', portableBytes.buffer);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function verifyDownloadedHash(data: Uint8Array, expectedSha256: string): Promise<boolean> {
  if (!isSha256Hex(expectedSha256)) {
    throw new Error('Expected SHA-256 digest is not valid hex.');
  }

  const actual = await sha256Hex(data);
  return actual === expectedSha256.toLowerCase();
}

export async function resolveExpectedSha256(
  asset: UpdateAsset,
  fetchImpl: typeof fetch,
): Promise<string> {
  const metadataDigest = parseMetadataDigest(asset.digest, asset.name);
  if (metadataDigest) {
    return metadataDigest;
  }

  const companionCandidates = digestCompanionUrls(asset.url);
  for (const candidate of companionCandidates) {
    if (!isTrustedReleaseAssetUrl(candidate)) {
      continue;
    }

    const response = await fetchImpl(candidate, {
      headers: {
        Accept: 'text/plain,application/octet-stream;q=0.9,*/*;q=0.8',
      },
    });

    if (response.status === 404) {
      continue;
    }

    if (!response.ok) {
      throw new Error(`Checksum fetch failed with HTTP ${response.status}.`);
    }

    const digestText = await response.text();
    const parsed = extractSha256Hex(digestText);
    if (!parsed) {
      throw new Error(`Unable to parse SHA-256 checksum from ${candidate}.`);
    }

    return parsed;
  }

  throw new Error(
    `Update verification failed: ${asset.name} has no SHA-256 digest metadata and no companion .sha256 checksum file was found.`,
  );
}

export function updateReducer(state: UpdateFlowState, event: UpdateFlowEvent): UpdateFlowState {
  switch (event.type) {
    case 'START_CHECK':
      return { status: 'checking' };
    case 'SET_UP_TO_DATE':
      return { status: 'up-to-date', latestVersion: event.latestVersion };
    case 'SET_AVAILABLE':
      return {
        status: 'available',
        latestVersion: event.latestVersion,
        releaseUrl: event.releaseUrl,
        asset: event.asset,
      };
    case 'START_DOWNLOAD':
      if (state.status !== 'available') {
        return state;
      }
      return {
        status: 'downloading',
        latestVersion: state.latestVersion,
        releaseUrl: state.releaseUrl,
        asset: state.asset,
        progress: 0,
      };
    case 'SET_DOWNLOAD_PROGRESS':
      if (state.status !== 'downloading') {
        return state;
      }
      return {
        ...state,
        progress: event.progress,
      };
    case 'SET_READY_TO_INSTALL':
      if (state.status !== 'downloading') {
        return state;
      }
      return {
        status: 'ready-to-install',
        latestVersion: state.latestVersion,
        releaseUrl: state.releaseUrl,
        asset: state.asset,
        downloadPath: event.downloadPath,
        downloadedSha256: event.downloadedSha256,
      };
    case 'START_INSTALL':
      if (state.status !== 'ready-to-install') {
        return state;
      }
      return {
        status: 'installing',
        latestVersion: state.latestVersion,
        releaseUrl: state.releaseUrl,
        asset: state.asset,
      };
    case 'SET_RELAUNCHING':
      return { status: 'relaunching', latestVersion: event.latestVersion };
    case 'SET_ACTION_REQUIRED':
      if (
        state.status === 'available' ||
        state.status === 'downloading' ||
        state.status === 'ready-to-install' ||
        state.status === 'installing'
      ) {
        return {
          status: 'action-required',
          reason: event.reason,
          releaseUrl: state.releaseUrl,
          command: event.command,
        };
      }

      return {
        status: 'action-required',
        reason: event.reason,
        releaseUrl: RELEASES_PAGE_URL,
        command: event.command,
      };
    case 'FAIL':
      return {
        status: 'error',
        reason: event.reason,
        releaseUrl:
          state.status === 'available' ||
          state.status === 'downloading' ||
          state.status === 'ready-to-install' ||
          state.status === 'installing' ||
          state.status === 'action-required'
            ? state.releaseUrl
            : undefined,
      };
    case 'RESET':
      return { status: 'idle' };
    default:
      return state;
  }
}

export function describeUpdateState(state: UpdateFlowState, currentVersion: string): string {
  switch (state.status) {
    case 'idle':
      return `Manual update checks are available. Current version: v${currentVersion}.`;
    case 'checking':
      return 'Checking for updates…';
    case 'up-to-date':
      return `You are up to date (v${state.latestVersion}).`;
    case 'available':
      return `Update available: v${state.latestVersion} (current v${currentVersion}). Ready to download ${state.asset.name}.`;
    case 'downloading':
      if (state.progress == null) {
        return `Downloading ${state.asset.name}…`;
      }
      return `Downloading ${state.asset.name}… ${Math.round(state.progress * 100)}%`;
    case 'ready-to-install':
      return `Update package is verified and ready to install (v${state.latestVersion}).`;
    case 'installing':
      return 'Installing update…';
    case 'relaunching':
      return `Relaunching into v${state.latestVersion}…`;
    case 'action-required':
      return state.reason;
    case 'error':
      return `Update check failed: ${state.reason}`;
    default:
      return 'Unknown update state.';
  }
}

export function installButtonLabel(state: UpdateFlowState): string {
  if (state.status !== 'ready-to-install') {
    return 'Install Update';
  }

  if (state.asset.kind === 'linux-deb') {
    return 'Install .deb Package';
  }

  if (state.asset.kind === 'linux-appimage') {
    return 'Install & Relaunch';
  }

  return 'Install Update';
}
