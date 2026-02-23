# PixelCrusher

PixelCrusher is the cross-platform rewrite of PNGAutoCrop.

- **Frontend:** React + TypeScript (Vite)
- **Desktop shell:** Tauri 2
- **Core engine:** Rust crate (`crates/pixelcrusher-core`) for format detection, crop/resize, optimization orchestration, and queue state machine.

> The original Swift app in `../png-autocrop` is intentionally kept as rollback only.

## Project structure

```text
pixelcrusher/
  src/                         # React UI (drop zone, queue, results, options)
  src/state/                   # frontend reducer + tests
  src-tauri/                   # Tauri host app + commands/events
  crates/pixelcrusher-core/    # Rust core processing engine
  scripts/build-local.sh       # local build pipeline helper
```

## Implemented v1 scope

### Rust core (`pixelcrusher-core`)

- Format detection: `jpg/jpeg/png/svg/gif`
- PNG transparent trim
- Explicit center-anchor crop + resize
- External optimizer orchestration:
  - JPEG: `cjpeg` (mozjpeg)
  - PNG: `pngquant` + `pngcrush`
  - PNG optional: `zopflipng` / `pngout`
  - SVG: `svgo`
  - GIF: `gifsicle`
- Queue state machine and transitions with statuses:
  - `queued -> diagnosing -> processing -> optimizing -> completed|failed`

### Frontend UI

- Dark split-pane layout
- Drop zone and file picker
- Active queue/progress cards with status
- Recent results list with size delta and **Reveal** action
- Options pane:
  - General: transparent trim
  - Dimensions: crop/resize
  - Compression: quality + optional tools
- Startup diagnostics row (tool availability + source path)

### Icon integration

Icons were regenerated from:

`/Users/bartando/.openclaw/media/inbound/5e8cfff4-b309-45d7-a75a-ecca528811b8.png`

Generated assets include:
- `src-tauri/icons/icon.icns` (macOS)
- `src-tauri/icons/icon.ico` (Windows)
- Linux PNG variants in `src-tauri/icons/linux/`

### Packaging config

Configured in `src-tauri/tauri.conf.json`:
- macOS: DMG
- Windows: MSI + NSIS
- Linux: AppImage + DEB

## Development

```bash
npm install
npm run tauri:dev
```

## Testing

```bash
cargo test --manifest-path crates/pixelcrusher-core/Cargo.toml
npm run test
```

## Builds

### macOS (native on this host, builds `.app` + `.dmg`)

```bash
npm run tauri:build:mac
```

### Windows config present (cross-build requires proper toolchains)

```bash
npm run tauri:build:windows
```

### Linux config present (cross-build requires linux target + packaging deps)

```bash
npm run tauri:build:linux
```

## Host limitations (current machine)

Current host is macOS arm64. Windows/Linux installers are configured but require additional target toolchains and packaging dependencies to actually produce artifacts.

## Output location

Built bundles are written under:

`src-tauri/target/release/bundle/`

At runtime, processed files are written to:

`~/Downloads/PixelCrusher/`
