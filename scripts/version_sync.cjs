#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

const ROOT_DIR = path.resolve(__dirname, '..');
const PACKAGE_JSON_PATH = path.join(ROOT_DIR, 'package.json');
const TAURI_CONF_PATH = path.join(ROOT_DIR, 'src-tauri', 'tauri.conf.json');
const CARGO_TOML_PATH = path.join(ROOT_DIR, 'src-tauri', 'Cargo.toml');

function parseArgs(argv) {
  const args = { check: false, set: null, fromTag: null };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--check') {
      args.check = true;
    } else if (arg === '--set') {
      args.set = argv[i + 1] ?? null;
      i += 1;
    } else if (arg === '--from-tag') {
      args.fromTag = argv[i + 1] ?? null;
      i += 1;
    }
  }

  return args;
}

function normalizeVersion(raw) {
  if (!raw || typeof raw !== 'string') {
    throw new Error('Version value is required.');
  }

  const version = raw.trim().replace(/^v/i, '');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`Invalid semantic version: ${raw}`);
  }

  return version;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function readCargoVersion() {
  const content = fs.readFileSync(CARGO_TOML_PATH, 'utf8');
  const lines = content.split(/\r?\n/);
  let inPackageSection = false;

  for (const line of lines) {
    if (/^\s*\[/.test(line)) {
      inPackageSection = /^\s*\[package\]\s*$/.test(line);
      continue;
    }

    if (inPackageSection) {
      const match = line.match(/^\s*version\s*=\s*"([^"]+)"\s*$/);
      if (match) {
        return match[1];
      }
    }
  }

  throw new Error('Failed to locate [package].version in src-tauri/Cargo.toml');
}

function writeCargoVersion(version) {
  const content = fs.readFileSync(CARGO_TOML_PATH, 'utf8');
  const lines = content.split(/\r?\n/);
  let inPackageSection = false;
  let updated = false;

  const nextLines = lines.map((line) => {
    if (/^\s*\[/.test(line)) {
      inPackageSection = /^\s*\[package\]\s*$/.test(line);
      return line;
    }

    if (!updated && inPackageSection && /^\s*version\s*=\s*"([^"]+)"\s*$/.test(line)) {
      updated = true;
      return `version = "${version}"`;
    }

    return line;
  });

  if (!updated) {
    throw new Error('Failed to update [package].version in src-tauri/Cargo.toml');
  }

  fs.writeFileSync(CARGO_TOML_PATH, `${nextLines.join('\n')}\n`, 'utf8');
}

function readVersions() {
  const packageJson = readJson(PACKAGE_JSON_PATH);
  const tauriConf = readJson(TAURI_CONF_PATH);

  return {
    packageJson: packageJson.version,
    tauriConf: tauriConf.version,
    cargoToml: readCargoVersion(),
  };
}

function syncVersion(version) {
  const packageJson = readJson(PACKAGE_JSON_PATH);
  const tauriConf = readJson(TAURI_CONF_PATH);

  packageJson.version = version;
  tauriConf.version = version;

  writeJson(PACKAGE_JSON_PATH, packageJson);
  writeJson(TAURI_CONF_PATH, tauriConf);
  writeCargoVersion(version);
}

function ensureConsistent(versions) {
  const unique = new Set(Object.values(versions));
  if (unique.size !== 1) {
    throw new Error(
      `Version mismatch detected:\n${Object.entries(versions)
        .map(([k, v]) => `  - ${k}: ${v}`)
        .join('\n')}`,
    );
  }

  return [...unique][0];
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  let targetVersion = null;
  if (args.set) {
    targetVersion = normalizeVersion(args.set);
  }
  if (args.fromTag) {
    targetVersion = normalizeVersion(args.fromTag);
  }

  if (targetVersion) {
    syncVersion(targetVersion);
    console.log(`Synced package.json, src-tauri/tauri.conf.json, and src-tauri/Cargo.toml to ${targetVersion}`);
  }

  if (args.check || !targetVersion) {
    const versions = readVersions();
    const resolved = ensureConsistent(versions);
    console.log(`Version check passed: ${resolved}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message || error);
  process.exit(1);
}
