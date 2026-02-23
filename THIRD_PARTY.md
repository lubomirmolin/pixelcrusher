# Third-Party Software (Bundled Optimizer Toolchain)

PixelCrusher release artifacts may bundle prebuilt optimizer/runtime components for self-contained execution on supported platforms.

## Bundled components

- **mozjpeg** (`cjpeg`)
  - Upstream: <https://github.com/mozilla/mozjpeg>
  - Typical npm wrapper used in CI: `mozjpeg`
  - License: BSD-3-Clause (see upstream repository)

- **pngquant** (`pngquant`)
  - Upstream: <https://github.com/kornelski/pngquant>
  - Typical npm wrapper used in CI: `pngquant-bin`
  - License: GPL-3.0 (see upstream repository)

- **pngcrush** (`pngcrush`)
  - Upstream: <https://pmt.sourceforge.io/pngcrush/>
  - Typical npm wrapper used in CI: `pngcrush-bin`
  - License: PNG Reference Library style / permissive terms (see upstream distribution)

- **gifsicle** (`gifsicle`)
  - Upstream: <https://www.lcdf.org/gifsicle/>
  - Typical npm wrapper used in CI: `gifsicle`
  - License: GPL-2.0-or-later (see upstream distribution)

- **SVGO** (`svgo` + bundled Node.js runtime)
  - SVGO upstream: <https://github.com/svg/svgo>
  - Node.js upstream: <https://nodejs.org/>
  - Licenses:
    - SVGO: MIT
    - Node.js: MIT

- **Optional: ZopfliPNG** (`zopflipng`)
  - Upstream: <https://github.com/google/zopfli>
  - Typical npm wrapper used in CI: `zopflipng-bin`
  - License: Apache-2.0

## Notes

- Final bundled binaries are generated in CI and copied into platform-specific installer resources.
- Verify exact bundled versions from `src-tauri/resources/BundledTools/runtime_manifest.txt` produced during build.
