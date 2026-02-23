#!/usr/bin/env node

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { spawnSync } = require('node:child_process');

const ROOT_DIR = path.resolve(__dirname, '..');
const OUTPUT_DIR = path.join(ROOT_DIR, 'src-tauri', 'resources', 'BundledTools');
const BIN_DIR = path.join(OUTPUT_DIR, 'bin');
const NODE_DIR = path.join(OUTPUT_DIR, 'node');
const NODE_BIN_DIR = path.join(NODE_DIR, 'bin');
const NODE_MODULES_DIR = path.join(NODE_DIR, 'node_modules');
const NODE_VERSION = process.env.PIXELCRUSHER_BUNDLED_NODE_VERSION || 'v22.14.0';

const REQUIRED_TOOLS = ['cjpeg', 'pngquant', 'pngcrush', 'svgo', 'gifsicle'];

function npmCommand() {
  return process.platform === 'win32' ? 'npm.cmd' : 'npm';
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    stdio: 'inherit',
    ...options,
  });

  if (result.status !== 0) {
    throw new Error(`Command failed: ${command} ${args.join(' ')}`);
  }
}

function copyExecutable(sourcePath, targetBaseName) {
  const sourceExt = path.extname(sourcePath);
  const targetName = process.platform === 'win32'
    ? `${targetBaseName}${sourceExt || '.exe'}`
    : targetBaseName;
  const targetPath = path.join(BIN_DIR, targetName);

  fs.copyFileSync(sourcePath, targetPath);
  if (process.platform !== 'win32') {
    fs.chmodSync(targetPath, 0o755);
  }

  return targetPath;
}

async function downloadFile(url, destination) {
  await new Promise((resolve, reject) => {
    const file = fs.createWriteStream(destination);

    const request = https.get(url, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        file.close();
        fs.unlinkSync(destination);
        return resolve(downloadFile(response.headers.location, destination));
      }

      if (response.statusCode !== 200) {
        return reject(new Error(`Download failed (${response.statusCode}): ${url}`));
      }

      response.pipe(file);
      file.on('finish', () => {
        file.close(resolve);
      });
    });

    request.on('error', (error) => {
      file.close();
      if (fs.existsSync(destination)) {
        fs.unlinkSync(destination);
      }
      reject(error);
    });
  });
}

function extractArchive(archivePath, destination) {
  let result = spawnSync('tar', ['-xf', archivePath, '-C', destination], {
    stdio: 'inherit',
  });

  if (result.status === 0) {
    return;
  }

  if (process.platform === 'win32' && archivePath.endsWith('.zip')) {
    const escapedArchive = archivePath.replace(/'/g, "''");
    const escapedDestination = destination.replace(/'/g, "''");
    result = spawnSync(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        `Expand-Archive -Path '${escapedArchive}' -DestinationPath '${escapedDestination}' -Force`,
      ],
      { stdio: 'inherit' },
    );
  }

  if (result.status !== 0) {
    throw new Error(`Failed to extract archive ${archivePath}`);
  }
}

function nodeArchiveInfo() {
  if (process.platform === 'linux' && process.arch === 'x64') {
    return {
      archiveName: `node-${NODE_VERSION}-linux-x64.tar.xz`,
      binaryRelativePath: path.join(`node-${NODE_VERSION}-linux-x64`, 'bin', 'node'),
      bundledBinaryName: 'node',
    };
  }

  if (process.platform === 'win32' && process.arch === 'x64') {
    return {
      archiveName: `node-${NODE_VERSION}-win-x64.zip`,
      binaryRelativePath: path.join(`node-${NODE_VERSION}-win-x64`, 'node.exe'),
      bundledBinaryName: 'node.exe',
    };
  }

  throw new Error(`Unsupported platform/arch for bundled node runtime: ${process.platform}/${process.arch}`);
}

async function installNodeRuntime(tmpDir) {
  const archive = nodeArchiveInfo();
  const archivePath = path.join(tmpDir, archive.archiveName);
  const extractDir = path.join(tmpDir, 'node-runtime');
  await fsp.mkdir(extractDir, { recursive: true });

  const url = `https://nodejs.org/dist/${NODE_VERSION}/${archive.archiveName}`;
  console.log(`Downloading Node runtime: ${url}`);
  await downloadFile(url, archivePath);
  extractArchive(archivePath, extractDir);

  const sourceBinary = path.join(extractDir, archive.binaryRelativePath);
  if (!fs.existsSync(sourceBinary)) {
    throw new Error(`Node binary not found after extraction: ${sourceBinary}`);
  }

  const destinationBinary = path.join(NODE_BIN_DIR, archive.bundledBinaryName);
  fs.copyFileSync(sourceBinary, destinationBinary);
  if (process.platform !== 'win32') {
    fs.chmodSync(destinationBinary, 0o755);
  }
}

async function installSvgoRuntime(tmpDir) {
  const svgoRuntimeDir = path.join(tmpDir, 'svgo-runtime');
  await fsp.mkdir(svgoRuntimeDir, { recursive: true });

  const packageJson = {
    name: 'pixelcrusher-svgo-runtime',
    private: true,
    version: '1.0.0',
    dependencies: {
      svgo: '4.0.0',
    },
  };

  await fsp.writeFile(
    path.join(svgoRuntimeDir, 'package.json'),
    JSON.stringify(packageJson, null, 2),
  );

  run(npmCommand(), ['install', '--omit=dev', '--ignore-scripts', '--silent'], {
    cwd: svgoRuntimeDir,
  });

  await fsp.cp(path.join(svgoRuntimeDir, 'node_modules'), NODE_MODULES_DIR, {
    recursive: true,
  });
}

function writeSvgoWrapper() {
  if (process.platform === 'win32') {
    const wrapperPath = path.join(BIN_DIR, 'svgo.cmd');
    const content = [
      '@echo off',
      'setlocal',
      'set "TOOL_ROOT=%~dp0.."',
      '"%TOOL_ROOT%\\node\\bin\\node.exe" "%TOOL_ROOT%\\node\\node_modules\\svgo\\bin\\svgo.js" %*',
      '',
    ].join('\r\n');

    fs.writeFileSync(wrapperPath, content, 'utf8');
    return wrapperPath;
  }

  const wrapperPath = path.join(BIN_DIR, 'svgo');
  const content = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
    'exec "$TOOL_ROOT/node/bin/node" "$TOOL_ROOT/node/node_modules/svgo/bin/svgo.js" "$@"',
    '',
  ].join('\n');

  fs.writeFileSync(wrapperPath, content, 'utf8');
  fs.chmodSync(wrapperPath, 0o755);
  return wrapperPath;
}

function normalizeModuleExport(value) {
  if (typeof value === 'string') {
    return value;
  }

  if (typeof value === 'function') {
    try {
      const maybePath = value();
      if (typeof maybePath === 'string') {
        return maybePath;
      }
    } catch (_) {
      return null;
    }
  }

  if (!value || typeof value !== 'object') {
    return null;
  }

  if (typeof value.default === 'string') {
    return value.default;
  }

  if (typeof value.default === 'function') {
    try {
      const maybePath = value.default();
      if (typeof maybePath === 'string') {
        return maybePath;
      }
    } catch (_) {
      return null;
    }
  }

  if (typeof value.path === 'string') {
    return value.path;
  }

  if (typeof value.path === 'function') {
    try {
      const maybePath = value.path();
      if (typeof maybePath === 'string') {
        return maybePath;
      }
    } catch (_) {
      return null;
    }
  }

  return null;
}

async function resolveModuleBinary(moduleName, optional = false) {
  const attempts = [];

  try {
    attempts.push(require(moduleName));
  } catch (error) {
    if (!['ERR_REQUIRE_ESM', 'ERR_PACKAGE_PATH_NOT_EXPORTED'].includes(error.code)) {
      if (!optional) {
        throw error;
      }
    }
  }

  try {
    attempts.push(await import(moduleName));
  } catch (_) {
    // ignore import failure when optional
  }

  for (const candidate of attempts) {
    const normalized = normalizeModuleExport(candidate);
    if (normalized) {
      return normalized;
    }
  }

  if (optional) {
    return null;
  }

  throw new Error(`Unable to resolve executable path from module: ${moduleName}`);
}

async function main() {
  if (!['linux', 'win32'].includes(process.platform)) {
    throw new Error(`Unsupported platform for Tauri bundled tool build: ${process.platform}`);
  }

  await fsp.rm(OUTPUT_DIR, { recursive: true, force: true });
  await fsp.mkdir(BIN_DIR, { recursive: true });
  await fsp.mkdir(NODE_BIN_DIR, { recursive: true });

  const binaries = [
    { name: 'cjpeg', moduleName: 'mozjpeg' },
    { name: 'pngquant', moduleName: 'pngquant-bin' },
    { name: 'pngcrush', moduleName: 'pngcrush-bin' },
    { name: 'gifsicle', moduleName: 'gifsicle' },
  ];

  const copied = [];

  for (const binary of binaries) {
    const sourcePath = await resolveModuleBinary(binary.moduleName);
    if (!sourcePath || !fs.existsSync(sourcePath)) {
      throw new Error(`Unable to resolve ${binary.name} from ${binary.moduleName}`);
    }

    const copiedPath = copyExecutable(sourcePath, binary.name);
    copied.push({ name: binary.name, path: copiedPath });
  }

  const zopflipngPath = await resolveModuleBinary('zopflipng-bin', true);
  if (zopflipngPath && fs.existsSync(zopflipngPath)) {
    const copiedPath = copyExecutable(zopflipngPath, 'zopflipng');
    copied.push({ name: 'zopflipng', path: copiedPath });
  }

  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'pixelcrusher-bundled-tools-'));
  try {
    await installNodeRuntime(tmpDir);
    await installSvgoRuntime(tmpDir);
  } finally {
    await fsp.rm(tmpDir, { recursive: true, force: true });
  }

  const svgoWrapperPath = writeSvgoWrapper();
  copied.push({ name: 'svgo', path: svgoWrapperPath });

  const nodeBinaryName = process.platform === 'win32' ? 'node.exe' : 'node';
  copied.push({
    name: 'node',
    path: path.join(NODE_BIN_DIR, nodeBinaryName),
  });

  const manifestPath = path.join(OUTPUT_DIR, 'runtime_manifest.txt');
  const lines = [];
  lines.push('PixelCrusher Tauri bundled tools manifest');
  lines.push(`Built at: ${new Date().toISOString()}`);
  lines.push(`Platform: ${process.platform}-${process.arch}`);
  lines.push(`Node runtime: ${NODE_VERSION}`);
  lines.push('');

  for (const toolName of REQUIRED_TOOLS) {
    const found = copied.find((entry) => entry.name === toolName);
    lines.push(`- ${toolName}: ${found ? found.path : 'missing'}`);
  }

  const optional = copied.find((entry) => entry.name === 'zopflipng');
  lines.push(`- zopflipng: ${optional ? optional.path : 'not bundled'}`);

  await fsp.writeFile(manifestPath, `${lines.join('\n')}\n`, 'utf8');

  console.log('Prepared Tauri bundled toolchain in:');
  console.log(`  ${OUTPUT_DIR}`);
  for (const entry of copied) {
    const stats = fs.statSync(entry.path);
    console.log(`  - ${entry.name}: ${entry.path} (${stats.size} bytes)`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
