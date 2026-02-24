export type UpdateCheckState =
  | { status: 'idle' }
  | { status: 'checking' }
  | { status: 'up-to-date'; latestVersion: string }
  | { status: 'available'; latestVersion: string; releaseUrl: string }
  | { status: 'error'; reason: string };

type ParsedSemver = {
  major: number;
  minor: number;
  patch: number;
  preRelease: string[];
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

export function describeUpdateState(state: UpdateCheckState, currentVersion: string): string {
  switch (state.status) {
    case 'idle':
      return `Manual update checks are available. Current version: v${currentVersion}.`;
    case 'checking':
      return 'Checking for updates…';
    case 'up-to-date':
      return `You are up to date (v${state.latestVersion}).`;
    case 'available':
      return `Update available: v${state.latestVersion} (current v${currentVersion}).`;
    case 'error':
      return `Update check failed: ${state.reason}`;
    default:
      return 'Unknown update state.';
  }
}
