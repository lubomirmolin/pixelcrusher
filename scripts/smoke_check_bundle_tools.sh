#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-PixelCrusher.app>" >&2
  exit 1
fi

APP_PATH="$1"
TOOLS_ROOT="$APP_PATH/Contents/Resources/BundledTools"
BIN_DIR="$TOOLS_ROOT/bin"

required=(cjpeg pngquant pngcrush svgo gifsicle)
for tool in "${required[@]}"; do
  if [[ ! -x "$BIN_DIR/$tool" ]]; then
    echo "Missing required bundled tool executable: $tool" >&2
    exit 1
  fi
done

"$BIN_DIR/cjpeg" -version >/dev/null
"$BIN_DIR/pngquant" --version >/dev/null
"$BIN_DIR/pngcrush" -version >/dev/null
"$BIN_DIR/svgo" --version >/dev/null
"$BIN_DIR/gifsicle" --version >/dev/null

if [[ -x "$BIN_DIR/zopflipng" ]]; then
  "$BIN_DIR/zopflipng" --version >/dev/null || true
fi

echo "Bundled tool smoke check OK: cjpeg, pngquant, pngcrush, svgo, gifsicle"
