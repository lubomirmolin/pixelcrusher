#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

npm run test
cargo test --manifest-path crates/pixelcrusher-core/Cargo.toml
swift test
bash scripts/build-macos.sh

echo "Build done. Artifacts under dist/"
