#!/usr/bin/env bash
set -eo pipefail

# Generate concise, user-facing release notes grouped by commit prefix.
# Usage:
#   scripts/release-notes.sh                # from last tag..HEAD
#   scripts/release-notes.sh v0.1.9         # from tag..HEAD
#   scripts/release-notes.sh v0.1.9..v0.1.10

RANGE="${1:-}"

if [[ -z "$RANGE" ]]; then
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$LAST_TAG" ]]; then
    RANGE="$LAST_TAG..HEAD"
  else
    RANGE="HEAD"
  fi
fi

if [[ "$RANGE" != *".."* && "$RANGE" != "HEAD" ]]; then
  RANGE="$RANGE..HEAD"
fi

COMMITS_RAW="$(git log --pretty=format:'%s' "$RANGE")"

new_items=()
improvements=()
fixes=()
breaking=()
other=()

while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  lower="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *"breaking"* ]] || [[ "$lower" == feat!":"* ]] || [[ "$lower" == fix!":"* ]]; then
    breaking+=("$s")
    continue
  fi

  case "$lower" in
    feat*:*|feature*:*|ui*:*) new_items+=("$s") ;;
    perf*:*|refactor*:*|build*:*|chore*:*|style*:*|improvement*:*) improvements+=("$s") ;;
    fix*:*|bugfix*:*|hotfix*:*) fixes+=("$s") ;;
    *) other+=("$s") ;;
  esac
done <<< "$COMMITS_RAW"

print_section() {
  local title="$1"; shift
  local arr=("$@")
  [[ ${#arr[@]} -eq 0 ]] && return 0
  echo "## $title"
  for item in "${arr[@]}"; do
    # strip conventional prefix for readability
    cleaned="$(printf '%s' "$item" | sed -E 's/^[a-zA-Z!._-]+(\([^)]*\))?:\s*//')"
    echo "- $cleaned"
  done
  echo
}

echo "# Release notes"
echo
print_section "New" "${new_items[@]}"
print_section "Improvements" "${improvements[@]}"
print_section "Fixes" "${fixes[@]}"
print_section "Breaking changes" "${breaking[@]}"

if [[ ${#other[@]} -gt 0 ]]; then
  print_section "Other" "${other[@]}"
fi

if [[ -z "$COMMITS_RAW" ]]; then
  echo "No user-facing changes in $RANGE."
fi
