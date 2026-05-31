#!/usr/bin/env bash
# Build PMTiles from AGBref GeoJSON ndjson files.
#
# Usage:
#   ./build_tiles.sh <geojson_dir> <output_dir>
#
# Produces 16 .pmtiles files (one per epoch x resolution) in <output_dir>.
# Resolution-aware zoom levels balance tile size vs visual detail.

set -euo pipefail

IN_DIR="${1:?usage: build_tiles.sh <geojson_dir> <output_dir>}"
OUT_DIR="${2:?usage: build_tiles.sh <geojson_dir> <output_dir>}"

command -v tippecanoe >/dev/null 2>&1 || {
    echo "ERROR: tippecanoe not found. Install from https://github.com/felt/tippecanoe" >&2
    exit 1
}

mkdir -p "$OUT_DIR"

# Max zoom per resolution. Higher = more detail at zoomed-in view, larger files.
# Min zoom is always 0 (need a tile for the world view).
# Layer name 'agbref' is what the frontend references.
declare -A MAXZOOM=( [500m]=8 [1km]=8 [10km]=6 [25km]=5 )

for f in "$IN_DIR"/agbref_*.geojsonl; do
    base=$(basename "$f" .geojsonl)            # e.g. agbref_2010_10km
    res="${base##*_}"                          # 10km
    zmax="${MAXZOOM[$res]:-7}"
    out="$OUT_DIR/$base.pmtiles"

    echo ">>> $base  (zmax=$zmax)"
    # --drop-densest-as-needed: at low zoom drop dense points to keep tile size sane
    # --extend-zooms-if-still-dropping: extend max zoom if still dropping at zmax
    # -l agbref: single layer name in every tile
    # -B 0: don't drop any features at the base (max) zoom
    # --no-tile-compression OFF (default = gzipped) keeps files small
    # --coalesce-densest-as-needed avoids merging features (we want originals)
    tippecanoe \
        -o "$out" \
        --force \
        -l agbref \
        -z "$zmax" -Z 0 \
        -B 0 \
        --drop-densest-as-needed \
        --extend-zooms-if-still-dropping \
        --read-parallel \
        --no-tile-stats \
        "$f" 2>&1 | tail -3
done

echo
echo "PMTiles built:"
ls -lh "$OUT_DIR"/*.pmtiles | awk '{print "  " $9, $5}'
