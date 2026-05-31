#!/usr/bin/env bash
# AGBref webmap build pipeline
#
#   CSVs (data/csv/AGBref_*.csv)
#     │
#     ├──► Parquet (data/parquet/*.parquet)      — for DuckDB-WASM queries
#     │
#     └──► GeoJSON ndjson (build/geojson/*)      — intermediate
#                │
#                └──► PMTiles (data/pmtiles/*)   — for MapLibre vector rendering
#
# Usage:
#   ./build.sh                         # full pipeline (default paths)
#   ./build.sh /path/to/csv_dir        # custom CSV input dir
#
# Requirements:
#   - Python 3 with: duckdb, pyarrow   (pip install duckdb pyarrow)
#   - tippecanoe v2.x (>= 2.30)        (https://github.com/felt/tippecanoe)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

CSV_DIR="${1:-$HERE/data/csv}"
PARQUET_DIR="$HERE/data/parquet"
GEOJSON_DIR="$HERE/build/geojson"
PMTILES_DIR="$HERE/data/pmtiles"

[[ -d "$CSV_DIR" ]] || { echo "ERROR: csv dir not found: $CSV_DIR" >&2; exit 1; }
[[ $(ls "$CSV_DIR"/AGBref_*.csv 2>/dev/null | wc -l) -ge 1 ]] || {
    echo "ERROR: no AGBref_*.csv files in $CSV_DIR" >&2; exit 1; }

command -v tippecanoe >/dev/null || { echo "ERROR: tippecanoe not installed" >&2; exit 1; }
python3 -c "import duckdb" 2>/dev/null || { echo "ERROR: python duckdb missing (pip install duckdb)" >&2; exit 1; }

echo "═══════════════════════════════════════════════════════════"
echo " AGBref build pipeline"
echo "   csv:     $CSV_DIR"
echo "   parquet: $PARQUET_DIR"
echo "   pmtiles: $PMTILES_DIR"
echo "═══════════════════════════════════════════════════════════"

echo
echo "[1/3] CSV → Parquet …"
python3 "$HERE/build/csv_to_parquet.py" "$CSV_DIR" "$PARQUET_DIR"

echo
echo "[2/3] CSV → GeoJSON (ndjson) …"
python3 "$HERE/build/csv_to_geojson.py" "$CSV_DIR" "$GEOJSON_DIR"

echo
echo "[3/3] GeoJSON → PMTiles …"
bash "$HERE/build/build_tiles.sh" "$GEOJSON_DIR" "$PMTILES_DIR"

echo
echo "Done. Build artefacts:"
du -sh "$PARQUET_DIR" "$PMTILES_DIR"
echo
echo "To serve locally:"
echo "  python3 -m http.server 8080"
echo "  open http://localhost:8080/"
