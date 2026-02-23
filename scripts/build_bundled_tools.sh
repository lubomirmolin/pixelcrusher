#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <bundled-tools-destination-dir>" >&2
  exit 1
fi

DEST_ROOT="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE_VERSION="${PIXELCRUSHER_BUNDLED_NODE_VERSION:-v22.14.0}"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd brew
require_cmd curl
require_cmd tar
require_cmd npm

ensure_formula() {
  local formula="$1"
  if ! brew list --versions "$formula" >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$formula"
  fi
}

ensure_formula mozjpeg
ensure_formula pngquant
ensure_formula pngcrush
ensure_formula gifsicle
# Optional but nice to have when available.
if ! brew list --versions zopfli >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install zopfli || true
fi

rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT/bin" "$DEST_ROOT/native/bin" "$DEST_ROOT/native/lib" "$DEST_ROOT/node/bin"

MOZJPEG_PREFIX="$(brew --prefix mozjpeg)"
PNGQUANT_PREFIX="$(brew --prefix pngquant)"
PNGCRUSH_PREFIX="$(brew --prefix pngcrush)"
GIFSICLE_PREFIX="$(brew --prefix gifsicle)"

cp "$MOZJPEG_PREFIX/bin/cjpeg" "$DEST_ROOT/native/bin/cjpeg"
cp "$PNGQUANT_PREFIX/bin/pngquant" "$DEST_ROOT/native/bin/pngquant"
cp "$PNGCRUSH_PREFIX/bin/pngcrush" "$DEST_ROOT/native/bin/pngcrush"
cp "$GIFSICLE_PREFIX/bin/gifsicle" "$DEST_ROOT/native/bin/gifsicle"

if brew list --versions zopfli >/dev/null 2>&1; then
  ZOPFLI_PREFIX="$(brew --prefix zopfli)"
  if [[ -x "$ZOPFLI_PREFIX/bin/zopflipng" ]]; then
    cp "$ZOPFLI_PREFIX/bin/zopflipng" "$DEST_ROOT/native/bin/zopflipng"
  fi
fi

chmod +x "$DEST_ROOT/native/bin"/*

SEARCH_LIB_DIRS=(
  "$MOZJPEG_PREFIX/lib"
  "$PNGQUANT_PREFIX/lib"
  "$PNGCRUSH_PREFIX/lib"
  "$GIFSICLE_PREFIX/lib"
  "/opt/homebrew/opt/libpng/lib"
  "/opt/homebrew/opt/little-cms2/lib"
  "/opt/homebrew/opt/zopfli/lib"
  "/opt/homebrew/lib"
)

resolve_dep_path() {
  local dep="$1"

  if [[ "$dep" == @rpath/* ]]; then
    local leaf
    leaf="${dep##*/}"
    local dir
    for dir in "${SEARCH_LIB_DIRS[@]}"; do
      if [[ -f "$dir/$leaf" ]]; then
        echo "$dir/$leaf"
        return 0
      fi
    done
    return 1
  fi

  if [[ "$dep" == /opt/homebrew/* ]] && [[ -f "$dep" ]]; then
    echo "$dep"
    return 0
  fi

  return 1
}

COPIED_LIBS_FILE="$TMP_DIR/copied-libs.txt"
touch "$COPIED_LIBS_FILE"

already_copied_lib() {
  local leaf="$1"
  grep -Fqx "$leaf" "$COPIED_LIBS_FILE"
}

mark_copied_lib() {
  local leaf="$1"
  echo "$leaf" >> "$COPIED_LIBS_FILE"
}

collect_deps() {
  local file="$1"

  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == /usr/lib/* ]] && continue
    [[ "$dep" == /System/* ]] && continue

    local source_path
    if ! source_path="$(resolve_dep_path "$dep")"; then
      continue
    fi

    local leaf
    leaf="$(basename "$source_path")"
    local dest_path="$DEST_ROOT/native/lib/$leaf"

    if already_copied_lib "$leaf"; then
      continue
    fi

    cp -L "$source_path" "$dest_path"
    chmod +x "$dest_path"
    mark_copied_lib "$leaf"

    collect_deps "$dest_path"
  done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
}

for tool_bin in "$DEST_ROOT/native/bin"/*; do
  collect_deps "$tool_bin"
done

create_native_wrapper() {
  local tool_name="$1"
  cat > "$DEST_ROOT/bin/$tool_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TOOL_ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
export DYLD_LIBRARY_PATH="\$TOOL_ROOT/native/lib\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}"
exec "\$TOOL_ROOT/native/bin/$tool_name" "\$@"
EOF
  chmod +x "$DEST_ROOT/bin/$tool_name"
}

create_native_wrapper cjpeg
create_native_wrapper pngquant
create_native_wrapper pngcrush
create_native_wrapper gifsicle

if [[ -x "$DEST_ROOT/native/bin/zopflipng" ]]; then
  create_native_wrapper zopflipng
fi

NODE_ARCHIVE_URL="https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_TARBALL="$TMP_DIR/node.tar.gz"
NODE_EXTRACT_DIR="$TMP_DIR/node"
mkdir -p "$NODE_EXTRACT_DIR"

curl -fLsS "$NODE_ARCHIVE_URL" -o "$NODE_TARBALL"
tar -xzf "$NODE_TARBALL" -C "$NODE_EXTRACT_DIR"
NODE_BIN_SOURCE="$(find "$NODE_EXTRACT_DIR" -type f -path '*/bin/node' | head -n 1)"
if [[ -z "$NODE_BIN_SOURCE" ]]; then
  echo "Failed to find node binary in downloaded archive" >&2
  exit 1
fi
cp "$NODE_BIN_SOURCE" "$DEST_ROOT/node/bin/node"
chmod +x "$DEST_ROOT/node/bin/node"

SVGO_RUNTIME_DIR="$TMP_DIR/svgo-runtime"
mkdir -p "$SVGO_RUNTIME_DIR"
cat > "$SVGO_RUNTIME_DIR/package.json" <<'JSON'
{
  "name": "pixelcrusher-svgo-runtime",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "svgo": "4.0.0"
  }
}
JSON

(
  cd "$SVGO_RUNTIME_DIR"
  npm install --omit=dev --ignore-scripts --silent
)

cp -R "$SVGO_RUNTIME_DIR/node_modules" "$DEST_ROOT/node/node_modules"

cat > "$DEST_ROOT/bin/svgo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$TOOL_ROOT/node/bin/node" "$TOOL_ROOT/node/node_modules/svgo/bin/svgo.js" "$@"
EOF
chmod +x "$DEST_ROOT/bin/svgo"

MANIFEST="$DEST_ROOT/runtime_manifest.txt"
{
  echo "PixelCrusher BundledTools build manifest"
  echo "Built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Node runtime: $NODE_VERSION"
  echo ""
  echo "Required tools:"
  for t in cjpeg pngquant pngcrush svgo gifsicle; do
    if [[ -x "$DEST_ROOT/bin/$t" ]]; then
      echo "- $t: $($DEST_ROOT/bin/$t --version 2>/dev/null | head -n 1 || echo ready)"
    else
      echo "- $t: missing"
    fi
  done
  if [[ -x "$DEST_ROOT/bin/zopflipng" ]]; then
    echo "- zopflipng: ready"
  else
    echo "- zopflipng: not bundled"
  fi
  if [[ -x "$DEST_ROOT/bin/pngout" ]]; then
    echo "- pngout: ready"
  else
    echo "- pngout: not bundled"
  fi
} > "$MANIFEST"

chmod -R go-w "$DEST_ROOT"
