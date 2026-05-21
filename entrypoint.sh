#!/usr/bin/env bash
# video → 3DGS pipeline: ffmpeg → COLMAP → Brush
#
# UPA contract:
#   - Input:  /workspace/input/<one video file>  (placed by upstream Get-asset action)
#   - Output: /workspace/output/scene.ply         (consumed by downstream Add-file action)
#
# Local testing override:
#   entrypoint.sh <video-path> <output-dir>
#
# Env vars:
#   FPS         frames per second to sample          (default 4)
#   STEPS       Brush training steps                  (default 30000; smoke-test: 5000)
#   MAX_SPLATS  hard cap on splats                    (default 3000000)
#   MAX_RES     max image resolution Brush uses       (default 1920)
#   SH_DEGREE   spherical harmonics degree            (default 3)
#   USE_GPU_SIFT  '1' to enable CUDA SIFT in COLMAP   (default 1; auto-falls back if no GPU)
#   WORK        intermediate workdir                  (default /tmp/v2gs-$$)

set -euo pipefail

INPUT_DIR=${INPUT_DIR:-/workspace/input}
OUTPUT_DIR=${OUTPUT_DIR:-/workspace/output}

# Local-override mode: first arg is video, second is output dir.
if [ -n "${1:-}" ] && [ -f "$1" ]; then
    SRC_VIDEO="$1"
    OUTPUT_DIR="${2:-$OUTPUT_DIR}"
else
    SRC_VIDEO=$(find "$INPUT_DIR" -maxdepth 2 -type f \
        \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.mkv' \) \
        | head -1)
fi

if [ -z "${SRC_VIDEO:-}" ] || [ ! -f "$SRC_VIDEO" ]; then
    echo "ERROR: no input video found. Looked in: $INPUT_DIR (and CLI arg)." >&2
    exit 1
fi

FPS=${FPS:-4}
STEPS=${STEPS:-30000}
MAX_SPLATS=${MAX_SPLATS:-3000000}
MAX_RES=${MAX_RES:-1920}
SH_DEGREE=${SH_DEGREE:-3}
USE_GPU_SIFT=${USE_GPU_SIFT:-1}
WORK=${WORK:-/tmp/v2gs-$$}
BRUSH_BIN=${BRUSH_BIN:-/opt/video2gs/brush_app}

mkdir -p "$OUTPUT_DIR" "$WORK/images" "$WORK/sparse"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

log "video=$SRC_VIDEO  out=$OUTPUT_DIR  work=$WORK"
log "config: fps=$FPS steps=$STEPS max_splats=$MAX_SPLATS max_res=$MAX_RES sh=$SH_DEGREE gpu_sift=$USE_GPU_SIFT"

# ─── 1. Extract frames ──────────────────────────────────────────────────────
log "[1/4] ffmpeg: extracting frames @ ${FPS} fps"
ffmpeg -y -hide_banner -loglevel error \
       -i "$SRC_VIDEO" -vf "fps=${FPS}" -q:v 2 \
       "$WORK/images/frame_%06d.jpg"
N_FRAMES=$(ls "$WORK/images" | wc -l | tr -d ' ')
log "  → $N_FRAMES frames"

# ─── 2. COLMAP SfM (sequential matcher fits video input) ────────────────────
log "[2/4] colmap feature_extractor"
colmap feature_extractor \
    --database_path "$WORK/database.db" \
    --image_path    "$WORK/images" \
    --ImageReader.single_camera 1 \
    --SiftExtraction.max_num_features 16384 \
    --FeatureExtraction.use_gpu "$USE_GPU_SIFT"

log "[2/4] colmap sequential_matcher (video-ordered, with loop closure)"
colmap sequential_matcher \
    --database_path "$WORK/database.db" \
    --SequentialMatching.overlap 10 \
    --SequentialMatching.loop_detection 1 \
    --FeatureMatching.use_gpu "$USE_GPU_SIFT"

log "[2/4] colmap mapper"
colmap mapper \
    --database_path "$WORK/database.db" \
    --image_path    "$WORK/images" \
    --output_path   "$WORK/sparse"

if [ ! -d "$WORK/sparse/0" ]; then
    log "  !! mapper produced no reconstruction in $WORK/sparse/0 — aborting"
    ls -la "$WORK/sparse"
    exit 2
fi

# Quick reconstruction stats.
colmap model_analyzer --path "$WORK/sparse/0" 2>&1 \
    | grep -E "Registered images|Points:|Frames:" | sed 's/^/  /'

# ─── 3. Brush training ──────────────────────────────────────────────────────
log "[3/4] brush training ($STEPS steps, max-splats $MAX_SPLATS, max-res $MAX_RES, SH $SH_DEGREE)"
"$BRUSH_BIN" "$WORK" \
    --total-steps  "$STEPS" \
    --max-splats   "$MAX_SPLATS" \
    --max-resolution "$MAX_RES" \
    --sh-degree    "$SH_DEGREE" \
    --export-every "$STEPS" \
    --export-path  "$WORK/exports" \
    --export-name  "scene.ply"

# ─── 4. Collect output ──────────────────────────────────────────────────────
log "[4/4] collecting output"
PLY=$(ls -t "$WORK"/exports/*.ply 2>/dev/null | head -1)
if [ -z "$PLY" ]; then
    log "  !! no .ply produced under $WORK/exports"
    ls -la "$WORK/exports" 2>&1 || true
    exit 3
fi
cp "$PLY" "$OUTPUT_DIR/scene.ply"
SIZE=$(stat -f%z "$OUTPUT_DIR/scene.ply" 2>/dev/null || stat -c%s "$OUTPUT_DIR/scene.ply")
log "  → $OUTPUT_DIR/scene.ply  ($SIZE bytes)"

log "done."
