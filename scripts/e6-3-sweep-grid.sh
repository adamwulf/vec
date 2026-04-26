#!/usr/bin/env bash
# E6.3 — 24-point indexing-speed grid for e5-base.
#
# Runs 24 single-point sweeps sequentially against markdown-memory at
# e5-base@1200/0. Each point lives in its own benchmarks subdirectory
# so the archives survive independently.
#
# Grid:
#   concurrency N ∈ {6, 8, 10, 12}
#   batch_size b  ∈ {16, 24, 32}
#   compute_policy ∈ {auto, ane}
# = 4 × 3 × 2 = 24 points, ~6.5 h total wallclock.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT_BASE="benchmarks/sweep-e5-base-speed"
LOG_FILE="$OUT_BASE/driver.log"

mkdir -p "$OUT_BASE"

# Log helper — both stdout (for background-read) and append to driver.log.
log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

log "E6.3 driver start — 24 points"
log "repo: $REPO_ROOT"
log "out:  $OUT_BASE"

POINT_INDEX=0
for N in 6 8 10 12; do
    for B in 16 24 32; do
        for POLICY in auto ane; do
            POINT_INDEX=$((POINT_INDEX + 1))
            POINT_NAME="N${N}-b${B}-${POLICY}"
            POINT_DIR="$OUT_BASE/$POINT_NAME"

            if [ -f "$POINT_DIR/summary.md" ]; then
                log "[$POINT_INDEX/24] $POINT_NAME — already complete, skipping"
                continue
            fi

            log "[$POINT_INDEX/24] $POINT_NAME — start"
            POINT_START=$(date +%s)

            # Per-point stdout/stderr — sweep output goes here so the main
            # driver log stays compact.
            POINT_LOG="$OUT_BASE/${POINT_NAME}.log"

            if swift run -c release vec sweep \
                    --db markdown-memory \
                    --embedder e5-base \
                    --sizes 1200 \
                    --overlap-pcts 0 \
                    --concurrency "$N" \
                    --batch-size "$B" \
                    --compute-policy "$POLICY" \
                    --out "$POINT_DIR" \
                    --force > "$POINT_LOG" 2>&1; then
                POINT_END=$(date +%s)
                POINT_WALL=$((POINT_END - POINT_START))
                log "[$POINT_INDEX/24] $POINT_NAME — done in ${POINT_WALL}s"
            else
                POINT_END=$(date +%s)
                POINT_WALL=$((POINT_END - POINT_START))
                log "[$POINT_INDEX/24] $POINT_NAME — FAILED after ${POINT_WALL}s (see $POINT_LOG)"
                # Keep going — partial grid is more useful than no grid.
            fi
        done
    done
done

log "E6.3 driver done — grid complete"
