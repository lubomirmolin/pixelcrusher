# PixelCrusher

PixelCrusher is now a **native macOS SwiftUI app** backed by a Rust processing engine.

- **Frontend (macOS):** SwiftUI (`Sources/PixelCrusherMac/main.swift`)
- **Backend/core:** Rust (`crates/pixelcrusher-core`)
- **Bridge:** bundled Rust CLI (`pixelcrusher-cli`) with JSON stdin/stdout status events
- **Bundled optimizers:** `cjpeg`, `pngquant`, `pngcrush`, `svgo`, `gifsicle` (+ optional `zopflipng`)

The previous Tauri rewrite is still in the repository for reference, but macOS release artifacts are produced by the SwiftUI packaging pipeline.

## Repository layout

```text
pixelcrusher/
  Sources/PixelCrusherMac/             # SwiftUI macOS app
  Sources/PixelCrusherMacCore/         # Swift-side queue, options, backend bridge, tool resolver
  Tests/PixelCrusherMacCoreTests/      # Swift tests (resolver, backend invocation, bundle checks)
  crates/pixelcrusher-core/            # Rust processing core + CLI binary (pixelcrusher-cli)
  scripts/build_bundled_tools.sh       # Bundles optimizer toolchain into app resources
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

## Runtime notes

At launch, the app resolves optimizer tools in this order:

1. `PIXELCRUSHER_<TOOL>_PATH` override
2. Bundled app tools: `PixelCrusher.app/Contents/Resources/BundledTools/bin/*`
3. Host `PATH`

Bundled tools directory override:

- `PIXELCRUSHER_BUNDLED_TOOLS_DIR`
