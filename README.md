# PixelCrusher

PixelCrusher is now a **native macOS SwiftUI app** backed by a Rust processing engine.

- **Frontend (macOS):** SwiftUI (`Sources/PixelCrusherMac/main.swift`)
- **Backend/core:** Rust (`crates/pixelcrusher-core`)
- **Bridge:** bundled Rust CLI (`pixelcrusher-cli`) with JSON stdin/stdout status events
- **Bundled optimizers:** `cjpeg`, `pngquant`, `pngcrush`, `svgo`, `gifsicle` (+ optional `zopflipng`)
- **In-app updater (user initiated):** check latest release, download macOS asset, install to `/Applications/PixelCrusher.app`, relaunch

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

### macOS release (.app + .zip + .dmg)

```bash
bash scripts/build-macos.sh
```

Artifacts are written to:

- `dist/PixelCrusher.app`
- `dist/PixelCrusher-<version>.dmg`
- `dist/PixelCrusher-<version>.zip`
- compatibility aliases: `dist/PixelCrusher.dmg`, `dist/PixelCrusher.zip`

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

## In-app updater (macOS app)

In the right-side **Options** pane:

1. Click **Check for Updates**
2. If a newer release exists, click **Download & Install Update**

Behavior:

- User-initiated only (no background auto-update daemon)
- Checks GitHub API `repos/lubomirmolin/pixelcrusher/releases/latest`
- Compares semantic versions (`vX.Y.Z` tags supported) and only treats updates as available when `latest > current`
- When versions are equal, UI shows `You're up to date (x.y.z).` and no install action is offered
- Prefers macOS `.zip` release asset for in-place update (falls back to `.dmg`)
- Enforces SHA-256 verification before install:
  - Uses release asset metadata digest when present (`sha256:<hex>`)
  - If metadata digest is missing, attempts companion checksum files (`<asset>.sha256`, then `<asset-without-extension>.sha256`)
  - If no valid checksum is found, install is aborted with a clear verification error
  - If checksum mismatches downloaded bytes, install is aborted
- Downloads update, validates app bundle identifier, stages install, swaps app in `/Applications`, then relaunches
- Uses a helper script launched by the app, so the running app never overwrites itself
- Performs backup + rollback during swap if install move fails

Updater UI states include:

- checking
- update available
- downloading percentage
- installing
- relaunching
- failed reason

### Private vs public repositories

`/releases/latest` can return `404` when:

- no release exists yet, or
- the repository is private and unauthenticated

When API check is unavailable, the app shows a clear failure reason and **Open Releases Page** fallback.

### Optional GitHub token (for private repos / higher rate limits)

Updater checks these token sources (in order):

1. `PIXELCRUSHER_GITHUB_TOKEN`
2. `GITHUB_TOKEN`
3. macOS defaults key `PixelCrusherGitHubToken`

Set defaults key example:

```bash
defaults write com.lubo.pixelcrusher PixelCrusherGitHubToken "ghp_your_token_here"
```

### Permission notes (first in-app update)

The updater installs to `/Applications/PixelCrusher.app`.

- If `/Applications` is writable for current user: update proceeds in-app.
- If not writable: updater fails gracefully with guidance to move app to `~/Applications` or update manually via release download.

## In-app updater (Tauri Windows/Linux)

The Tauri app now includes a full manual updater flow in the **Updates** card:

1. **Check for Updates**
2. If newer release exists, app selects a trusted platform asset:
   - Windows: prefers **NSIS `.exe`** installer, fallback `.msi`
   - Linux: prefers **`.AppImage`**, fallback `.deb`
3. App resolves SHA-256 digest (metadata digest first, then companion checksum files)
4. App downloads installer, verifies SHA-256, and only then allows install action
5. Install is initiated from inside app (no release-page-only flow)

Security rules:

- Strict semantic version gating (`latest > current` only)
- Trusted release URL allow-list only:
  - `github.com/<owner>/<repo>/releases/download/...`
  - `objects.githubusercontent.com`
  - `github-releases.githubusercontent.com`
  - `release-assets.githubusercontent.com`
- Hash mismatch aborts install

Windows installer launch behavior:

- NSIS `.exe`: launched with silent switch `/S`
- MSI `.msi`: launched via `msiexec /i <installer> /passive /norestart`
- App exits cleanly after launch to allow replacement/update

Linux installer launch behavior:

- `.AppImage`: executable bit is set, AppImage is launched, app exits for relaunch path
- `.deb`: app opens package file with `xdg-open` and shows explicit privileged command guidance:
  - `sudo apt install '<downloaded-file>.deb'`

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

Version source of truth is synchronized across:

- `package.json`
- `src-tauri/tauri.conf.json`
- `src-tauri/Cargo.toml`

Run `npm run version:check` locally (CI also enforces this).

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
