# PixelCrusher

PixelCrusher is now a **native macOS SwiftUI app** backed by a Rust processing engine.

- **Frontend (macOS):** SwiftUI (`Sources/PixelCrusherMac/main.swift`)
- **Backend/core:** Rust (`crates/pixelcrusher-core`)
- **Bridge:** bundled Rust CLI (`pixelcrusher-cli`) with JSON stdin/stdout status events
- **Bundled optimizers:** `cjpeg`, `pngquant`, `pngcrush`, `svgo`, `gifsicle` (+ optional `zopflipng`)
- **Manual update check:** “Check for Updates” button in the app options pane (queries GitHub Releases, no auto-update daemon)

The Tauri app path is used for Windows/Linux installers, while macOS release artifacts are produced by the SwiftUI packaging pipeline.

## Repository layout

```text
pixelcrusher/
  Sources/PixelCrusherMac/             # SwiftUI macOS app
  Sources/PixelCrusherMacCore/         # Swift-side queue, options, backend bridge, tool resolver
  Tests/PixelCrusherMacCoreTests/      # Swift tests (resolver, backend invocation, bundle checks)
  crates/pixelcrusher-core/            # Rust processing core + CLI binary (pixelcrusher-cli)
  scripts/build_bundled_tools.sh       # Bundles optimizer toolchain for native macOS app
  scripts/prepare_tauri_bundled_tools.cjs # Builds bundled optimizer toolchain for Tauri win/linux
  scripts/check_tauri_bundle_tools.cjs # Validates bundled tools are present in built win/linux bundles
  scripts/build-macos.sh               # Builds .app + .dmg (with /Applications symlink)
```

## Build & test

### Rust tests

```bash
cargo test --manifest-path crates/pixelcrusher-core/Cargo.toml
```

### Swift tests

```bash
swift test
```

### macOS release (.app + .dmg)

```bash
bash scripts/build-macos.sh
```

Artifacts are written to:

- `dist/PixelCrusher.app`
- `dist/PixelCrusher.dmg`
- `dist/PixelCrusher.zip`

The DMG includes:

- `PixelCrusher.app`
- `/Applications` symlink (drag-and-drop install flow)

### Windows/Linux Tauri bundled toolchain prep

Before building Tauri installers, prepare bundled tools and runtime:

```bash
npm run bundled-tools:prepare
```

This creates:

- `src-tauri/resources/BundledTools/bin/*` (required binaries: `cjpeg`, `pngquant`, `pngcrush`, `gifsicle`, `svgo`)
- `src-tauri/resources/BundledTools/node/bin/node`
- optional `zopflipng` when available

Post-build verification:

```bash
npm run bundled-tools:check:linux
npm run bundled-tools:check:windows
```

## Manual update button (macOS app)

In the right-side **Options** pane, click **Check for Updates**.

Behavior:

- Calls GitHub API `repos/lubomirmolin/pixelcrusher/releases/latest`
- Parses semantic versions from the current app bundle version and release tag (supports `vX.Y.Z`)
- If a newer release exists: shows version + notes + **Open Download**
- If current version is latest: shows up-to-date confirmation
- No background polling / no automatic install

## GitHub Actions CI + Releases

Workflows:

- `.github/workflows/ci-artifacts.yml`
  - Trigger: pushes + pull requests
  - Builds installer artifacts and uploads them as CI artifacts:
    - macOS native: `.dmg`, `.zip`
    - Windows (Tauri): `.msi`, `.exe` (NSIS)
    - Linux (Tauri): `.AppImage`, `.deb`

- `.github/workflows/release.yml`
  - Trigger: git tags matching `v*` (for example `v1.2.0`)
  - Builds all platform artifacts and publishes them to GitHub Releases

### Release flow

1. Ensure version/tag is ready.
2. Push a semver tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

3. GitHub Release is created/updated with generated notes + installer files.

## Runtime notes

At launch, the app resolves optimizer tools in this order:

1. `PIXELCRUSHER_<TOOL>_PATH` override
2. Bundled app tools (`BundledTools/bin/*`) resolved from app resources (macOS app bundle + Tauri win/linux resources)
3. Host `PATH`

Bundled tools directory override:

- `PIXELCRUSHER_BUNDLED_TOOLS_DIR`

## Third-party bundled tooling licenses

See `THIRD_PARTY.md` for bundled optimizer/runtime components and upstream license references.
