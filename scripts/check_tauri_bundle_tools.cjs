#!/usr/bin/env node

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const ROOT_DIR = path.resolve(__dirname, '..');

function parseArgs() {
  const args = process.argv.slice(2);
  const parsed = {};

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith('--')) continue;

    const key = arg.slice(2);
    const value = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true;
    parsed[key] = value;
  }

  return parsed;
}

async function walk(dir) {
  const entries = await fsp.readdir(dir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const absolutePath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(absolutePath)));
    } else {
      files.push(absolutePath);
    }
  }

  return files;
}

function expectedForPlatform(platform) {
  if (platform === 'windows') {
    return {
      required: ['cjpeg.exe', 'pngquant.exe', 'pngcrush.exe', 'gifsicle.exe', 'svgo.cmd', 'node.exe'],
      optional: ['zopflipng.exe'],
    };
  }

  if (platform === 'linux') {
    return {
      required: ['cjpeg', 'pngquant', 'pngcrush', 'gifsicle', 'svgo', 'node'],
      optional: ['zopflipng'],
    };
  }

  throw new Error(`Unsupported platform argument: ${platform}`);
}

function normalize(filePath) {
  return filePath.split(path.sep).join('/');
}

function installerExtensions(platform) {
  return platform === 'windows' ? ['.msi', '.exe'] : ['.AppImage', '.deb'];
}

async function fileContainsAsciiToken(filePath, token) {
  const handle = await fsp.open(filePath, 'r');
  const tokenBuffer = Buffer.from(token, 'utf8');
  const chunkSize = 1024 * 1024;
  let previousTail = Buffer.alloc(0);

  try {
    const buffer = Buffer.alloc(chunkSize);
    let position = 0;

    while (true) {
      const { bytesRead } = await handle.read(buffer, 0, chunkSize, position);
      if (bytesRead === 0) {
        return false;
      }

      const chunk = buffer.subarray(0, bytesRead);
      const scanBuffer = previousTail.length > 0 ? Buffer.concat([previousTail, chunk]) : chunk;
      if (scanBuffer.indexOf(tokenBuffer) !== -1) {
        return true;
      }

      const tailLength = Math.min(tokenBuffer.length - 1, scanBuffer.length);
      previousTail = scanBuffer.subarray(scanBuffer.length - tailLength);
      position += bytesRead;
    }
  } finally {
    await handle.close();
  }
}

async function main() {
  const args = parseArgs();
  const platform = args.platform;
  if (!platform) {
    throw new Error('Missing required argument: --platform <windows|linux>');
  }

  const defaultBundleRoot =
    platform === 'windows'
      ? path.join(ROOT_DIR, 'src-tauri', 'target', 'x86_64-pc-windows-msvc', 'release', 'bundle')
      : path.join(ROOT_DIR, 'src-tauri', 'target', 'x86_64-unknown-linux-gnu', 'release', 'bundle');

  const bundleRoot = path.resolve(String(args['bundle-root'] || defaultBundleRoot));

  if (!fs.existsSync(bundleRoot)) {
    throw new Error(`Bundle directory does not exist: ${bundleRoot}`);
  }

  const { required, optional } = expectedForPlatform(platform);
  const files = await walk(bundleRoot);
  const normalizedFiles = files.map(normalize);

  const found = new Map();

  for (const expectedName of [...required, ...optional]) {
    const matches = normalizedFiles.filter(
      (file) =>
        file.includes('/BundledTools/') &&
        file.endsWith(`/${expectedName}`),
    );

    if (matches.length > 0) {
      found.set(expectedName, matches);
    }
  }

  let missing = required.filter((name) => !found.has(name));

  if (missing.length > 0) {
    const extensions = installerExtensions(platform);
    const installers = files.filter((filePath) =>
      extensions.some((extension) => filePath.endsWith(extension)),
    );

    for (const missingName of [...missing]) {
      for (const installer of installers) {
        if (await fileContainsAsciiToken(installer, missingName)) {
          found.set(missingName, [`${installer}#binary-scan`]);
          break;
        }
      }
    }

    missing = required.filter((name) => !found.has(name));
  }

  if (missing.length > 0) {
    throw new Error(
      `Missing required bundled tools in built bundle output (${platform}): ${missing.join(', ')}`,
    );
  }

  const evidenceLines = [];
  evidenceLines.push(`Bundle tool evidence (${platform})`);
  evidenceLines.push(`Bundle root: ${bundleRoot}`);
  evidenceLines.push('');

  for (const name of required) {
    const matches = found.get(name) || [];
    for (const match of matches) {
      if (match.endsWith('#binary-scan')) {
        evidenceLines.push(`required ${name}: ${match}`);
      } else {
        const stat = fs.statSync(match);
        evidenceLines.push(`required ${name}: ${match} (${stat.size} bytes)`);
      }
    }
  }

  for (const name of optional) {
    const matches = found.get(name) || [];
    if (matches.length === 0) {
      evidenceLines.push(`optional ${name}: not present`);
      continue;
    }

    for (const match of matches) {
      if (match.endsWith('#binary-scan')) {
        evidenceLines.push(`optional ${name}: ${match}`);
      } else {
        const stat = fs.statSync(match);
        evidenceLines.push(`optional ${name}: ${match} (${stat.size} bytes)`);
      }
    }
  }

  const evidenceDir = path.join(ROOT_DIR, 'dist', 'bundle-evidence');
  await fsp.mkdir(evidenceDir, { recursive: true });
  const evidencePath = path.join(evidenceDir, `bundled-tools-${platform}.txt`);
  await fsp.writeFile(evidencePath, `${evidenceLines.join('\n')}\n`, 'utf8');

  console.log(evidenceLines.join('\n'));
  console.log(`\nSaved evidence file: ${evidencePath}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
