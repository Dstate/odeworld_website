#!/usr/bin/env bash
# Compress rollout mp4s under figures/ for faster page loads.
#
# Usage:
#   ./scripts/compress_videos.sh              # write *.web.mp4 next to originals
#   ./scripts/compress_videos.sh --inplace    # replace originals (keeps *.orig.mp4 backup)
#   ./scripts/compress_videos.sh --height 480 --crf 30
#   ./scripts/compress_videos.sh --dry-run
#
# Requires: ffmpeg (brew install ffmpeg)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIGURES="${ROOT}/figures"
HEIGHT=720
CRF=28
PRESET=medium
INPLACE=0
DRY_RUN=0
KEEP_BACKUP=1

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inplace) INPLACE=1; shift ;;
    --no-backup) KEEP_BACKUP=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --crf) CRF="$2"; shift 2 ;;
    --preset) PRESET="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Install with: brew install ffmpeg" >&2
  exit 1
fi

if [[ ! -d "$FIGURES" ]]; then
  echo "figures/ not found at $FIGURES" >&2
  exit 1
fi

bytes() {
  # Prefer stat (no stdin); fall back to wc.
  if stat -f%z "$1" >/dev/null 2>&1; then
    stat -f%z "$1"
  elif stat -c%s "$1" >/dev/null 2>&1; then
    stat -c%s "$1"
  else
    wc -c <"$1" | tr -d '[:space:]'
  fi
}

TOTAL_BEFORE=0
TOTAL_AFTER=0
DONE=0
SKIPPED=0
COUNT=0

# Collect paths first (portable; avoids mapfile / process-sub issues on macOS bash 3.2).
TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT
find "$FIGURES" -type f -name '*.mp4' \
  ! -name '*.web.mp4' \
  ! -name '*.orig.mp4' \
  ! -name '*.tmp.mp4' \
  | sort > "$TMP_LIST"

COUNT=$(wc -l < "$TMP_LIST" | tr -d ' ')
if [[ "$COUNT" -eq 0 ]]; then
  echo "No mp4 files found under figures/"
  exit 0
fi

echo "Found ${COUNT} videos under figures/"
echo "Settings: height=${HEIGHT} crf=${CRF} preset=${PRESET} inplace=${INPLACE}"
echo

while IFS= read -r src || [[ -n "$src" ]]; do
  [[ -z "$src" ]] && continue
  # Missing cases (e.g. agibot case2/3) or stale paths: skip quietly.
  if [[ ! -f "$src" ]]; then
    echo "↷ skip (missing): ${src#"$FIGURES"/}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  before=$(bytes "$src")
  TOTAL_BEFORE=$((TOTAL_BEFORE + before))
  rel="${src#"$FIGURES"/}"
  tmp="${src%.mp4}.tmp.mp4"
  out="${src%.mp4}.web.mp4"

  # Already have a smaller web copy from a previous run.
  if [[ $INPLACE -eq 0 && -f "$out" ]]; then
    out_sz=$(bytes "$out")
    if [[ "$out_sz" -lt "$before" ]]; then
      echo "↷ skip (exists): $rel → ${rel%.mp4}.web.mp4"
      TOTAL_AFTER=$((TOTAL_AFTER + out_sz))
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  echo "→ $rel ($(awk -v b="$before" 'BEGIN{printf "%.1f MB", b/1024/1024}'))"

  if [[ $DRY_RUN -eq 1 ]]; then
    TOTAL_AFTER=$((TOTAL_AFTER + before))
    continue
  fi

  # -nostdin is critical: otherwise ffmpeg drains this while-loop's stdin
  # (the file list) and subsequent paths get corrupted / "missing".
  if ! ffmpeg -nostdin -y -hide_banner -loglevel error -stats \
    -i "$src" \
    -vf "scale=-2:'min(${HEIGHT},ih)'" \
    -c:v libx264 -crf "$CRF" -preset "$PRESET" \
    -pix_fmt yuv420p \
    -an \
    -movflags +faststart \
    "$tmp" </dev/null
  then
    echo "  ✗ ffmpeg failed, keeping original"
    rm -f "$tmp"
    SKIPPED=$((SKIPPED + 1))
    TOTAL_AFTER=$((TOTAL_AFTER + before))
    continue
  fi

  after=$(bytes "$tmp")
  if [[ "$after" -ge "$before" ]]; then
    echo "  ✗ compressed is not smaller ($(awk -v a="$after" 'BEGIN{printf "%.1f MB", a/1024/1024}')), keeping original"
    rm -f "$tmp"
    SKIPPED=$((SKIPPED + 1))
    TOTAL_AFTER=$((TOTAL_AFTER + before))
    continue
  fi

  ratio=$(awk -v a="$after" -v b="$before" 'BEGIN{printf "%.0f", (1-a/b)*100}')
  echo "  ✓ $(awk -v a="$after" 'BEGIN{printf "%.1f MB", a/1024/1024}') (−${ratio}%)"

  if [[ $INPLACE -eq 1 ]]; then
    if [[ $KEEP_BACKUP -eq 1 ]]; then
      mv "$src" "${src%.mp4}.orig.mp4"
    else
      rm -f "$src"
    fi
    mv "$tmp" "$src"
  else
    mv "$tmp" "$out"
    echo "    wrote ${rel%.mp4}.web.mp4"
  fi

  TOTAL_AFTER=$((TOTAL_AFTER + after))
  DONE=$((DONE + 1))
done < "$TMP_LIST"

echo
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run only. Re-run without --dry-run to compress."
  exit 0
fi

echo "Done: ${DONE} compressed, ${SKIPPED} skipped"
if [[ $DONE -gt 0 ]]; then
  echo "Size: $(awk -v b="$TOTAL_BEFORE" 'BEGIN{printf "%.1f MB", b/1024/1024}') → $(awk -v a="$TOTAL_AFTER" 'BEGIN{printf "%.1f MB", a/1024/1024}')"
fi

if [[ $INPLACE -eq 0 && $DONE -gt 0 ]]; then
  echo
  echo "Outputs are *.web.mp4. After checking quality, replace originals with:"
  echo "  ./scripts/compress_videos.sh --inplace"
fi
