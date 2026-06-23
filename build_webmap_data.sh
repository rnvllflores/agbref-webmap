#!/usr/bin/env bash
#
# build_webmap_data.sh — AGBref webmap data builder
# ════════════════════════════════════════════════════════════════════════════
#
# Turns a folder of AGBref CSVs into everything the webmap (index.html) needs:
#
#   CSVs  (AGBref_<year>_<res>.csv)
#     │
#     ├──► data/parquet/agbref_<res>.parquet   — per-resolution, all epochs
#     │    data/parquet/agbref_all.parquet       (for DuckDB-WASM analytics)
#     │
#     └──► data/pmtiles/agbref_<year>_<res>.pmtiles
#                                              — vector tiles (MapLibre points)
#
# Only one tool of each kind is required — no Python, no pip:
#     • duckdb      (CSV → Parquet and CSV → GeoJSON)
#     • tippecanoe  (GeoJSON → PMTiles)
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   ./build_webmap_data.sh <csv_dir> [output_root]
#
#   <csv_dir>      folder containing AGBref_<year>_<res>.csv files
#   [output_root]  where data/parquet and data/pmtiles are written
#                  (default: the repo root next to this script)
#
#   Example:
#     ./build_webmap_data.sh ~/Downloads/agb-ref-v2
#
# ── Installing the tools ─────────────────────────────────────────────────────
#   macOS (Homebrew):        brew install tippecanoe duckdb
#   conda / mamba (any OS):  conda install -c conda-forge tippecanoe python-duckdb
#                            (also installs the `duckdb` CLI)
#   Linux (manual):
#     duckdb CLI →  https://github.com/duckdb/duckdb/releases  (grab duckdb_cli-linux-*.zip,
#                   unzip, put the `duckdb` binary on your PATH)
#     tippecanoe →  git clone https://github.com/felt/tippecanoe
#                   cd tippecanoe && make -j && sudo make install
#
# ── Input CSV schema (columns used) ──────────────────────────────────────────
#   POINT_X, POINT_Y, AGB_T_HA, SD, N, TC_GRID_MEAN, GEZ, FEZ, Year,
#   QUALITY_MIN_PLOTS, QUALITY_NOT_OUTDATED, QUALITY_LARGE_SIZE,
#   QUALITY_LOCALLY_REP, QUALITY_STRICT_FILTER
#   (extra columns such as ID, VAR, Resolution are ignored.)
# ════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── 0. Dependency check ──────────────────────────────────────────────────────
missing=""
command -v duckdb     >/dev/null 2>&1 || missing="$missing duckdb"
command -v tippecanoe >/dev/null 2>&1 || missing="$missing tippecanoe"
if [ -n "$missing" ]; then
    echo "ERROR: missing required tool(s):$missing" >&2
    echo >&2
    echo "Install them:" >&2
    echo "  macOS:           brew install tippecanoe duckdb" >&2
    echo "  conda (any OS):  conda install -c conda-forge tippecanoe python-duckdb" >&2
    echo "  Linux (manual):  duckdb -> https://github.com/duckdb/duckdb/releases" >&2
    echo "                   tippecanoe -> build from https://github.com/felt/tippecanoe" >&2
    exit 1
fi

# ── 1. Arguments & paths ─────────────────────────────────────────────────────
CSV_DIR="${1:-}"
if [ -z "$CSV_DIR" ]; then
    echo "usage: $(basename "$0") <csv_dir> [output_root]" >&2
    exit 1
fi
[ -d "$CSV_DIR" ] || { echo "ERROR: csv dir not found: $CSV_DIR" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="${2:-$HERE}"
PARQUET_DIR="$OUT_ROOT/data/parquet"
PMTILES_DIR="$OUT_ROOT/data/pmtiles"
GEOJSON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agbref_geojson.XXXXXX")"
trap 'rm -rf "$GEOJSON_DIR"' EXIT

mkdir -p "$PARQUET_DIR" "$PMTILES_DIR"

# Resolutions handled, and the max tile zoom for each (higher = more detail,
# bigger tiles). Min zoom is always 0 so the whole world renders.
RESOLUTIONS="500m 1km 10km 25km"
maxzoom_for() {
    case "$1" in
        500m) echo 8 ;;
        1km)  echo 8 ;;
        10km) echo 6 ;;
        25km) echo 5 ;;
        *)    echo 7 ;;
    esac
}

# Map the full GEZ name to the single-char code used everywhere downstream.
# Convention: R = tropical (T is taken by Temperate).
GEZ_CASE="CASE GEZ \
  WHEN 'Boreal' THEN 'B' \
  WHEN 'Subtropical' THEN 'S' \
  WHEN 'Temperate' THEN 'T' \
  WHEN 'Tropical' THEN 'R' \
  ELSE 'U' END"

# Strict filename pattern keeps stray files (e.g. a combined AGBref__.csv) out.
csv_re='^AGBref_[0-9][0-9][0-9][0-9]_(500m|1km|10km|25km)\.csv$'

echo "═══════════════════════════════════════════════════════════"
echo " AGBref webmap data build"
echo "   csv in : $CSV_DIR"
echo "   parquet: $PARQUET_DIR"
echo "   pmtiles: $PMTILES_DIR"
echo "═══════════════════════════════════════════════════════════"

# ── 2. CSV → Parquet (one file per resolution, all epochs stacked) ───────────
echo
echo "[1/3] CSV → Parquet …"
built_res=""
for res in $RESOLUTIONS; do
    # Only this resolution's files (glob suffix excludes the combined dump).
    count=$(ls "$CSV_DIR"/AGBref_*_"$res".csv 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
        echo "   [skip] $res: no AGBref_*_$res.csv files"
        continue
    fi
    out="$PARQUET_DIR/agbref_$res.parquet"
    duckdb -c "
        COPY (
          SELECT
            CAST(POINT_X AS DOUBLE)              AS lon,
            CAST(POINT_Y AS DOUBLE)              AS lat,
            CAST(AGB_T_HA AS DOUBLE)             AS agb,
            CAST(SD AS DOUBLE)                   AS sd,
            CAST(N AS INTEGER)                   AS n,
            CAST(TC_GRID_MEAN AS DOUBLE)         AS tc,
            $GEZ_CASE                            AS gez,
            CAST(FEZ AS VARCHAR)                 AS fez,
            CAST(QUALITY_MIN_PLOTS     AS BOOLEAN) AS qmp,
            CAST(QUALITY_NOT_OUTDATED  AS BOOLEAN) AS qto,
            CAST(QUALITY_LARGE_SIZE    AS BOOLEAN) AS qac,
            CAST(QUALITY_LOCALLY_REP   AS BOOLEAN) AS qlr,
            CAST(QUALITY_STRICT_FILTER AS BOOLEAN) AS qst,
            CAST(Year AS SMALLINT)               AS epoch
          FROM read_csv_auto('$CSV_DIR/AGBref_*_$res.csv', header=true, nullstr='NA')
          ORDER BY epoch, lat, lon
        ) TO '$out' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 50000);
    "
    rows=$(duckdb -noheader -list -c "SELECT COUNT(*) FROM '$out';")
    printf "   [ok]   %-5s %s rows -> %s\n" "$res" "$rows" "$out"
    built_res="$built_res $res"
done

# Combined cross-resolution Parquet (handy for some analytics queries).
if [ -n "$built_res" ]; then
    union=""
    for res in $built_res; do
        [ -n "$union" ] && union="$union UNION ALL "
        union="$union SELECT *, '$res' AS resolution FROM '$PARQUET_DIR/agbref_$res.parquet'"
    done
    duckdb -c "
        COPY ($union)
        TO '$PARQUET_DIR/agbref_all.parquet'
        (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 100000);
    "
    echo "   [ok]   all -> $PARQUET_DIR/agbref_all.parquet"
fi

# ── 3. CSV → GeoJSON (line-delimited features, one file per epoch×res) ────────
echo
echo "[2/3] CSV → GeoJSON (ndjson) …"
for f in "$CSV_DIR"/AGBref_*.csv; do
    name=$(basename "$f")
    echo "$name" | grep -Eq "$csv_re" || { echo "   [skip] $name (not <year>_<res>)"; continue; }
    base=$(echo "$name" | sed -E 's/^AGBref_//; s/\.csv$//')   # e.g. 2010_10km
    out="$GEOJSON_DIR/agbref_$base.geojsonl"
    # DuckDB FORMAT JSON writes one JSON object per line; selecting
    # type/geometry/properties columns yields valid GeoJSON Features.
    # NULL tc is emitted as null and dropped by tippecanoe. Property names are
    # kept short (repeated in every feature in every tile).
    duckdb -c "
        COPY (
          SELECT
            'Feature' AS type,
            {'type':'Point',
             'coordinates':[round(CAST(POINT_X AS DOUBLE),5),
                            round(CAST(POINT_Y AS DOUBLE),5)]} AS geometry,
            {'agb': round(CAST(AGB_T_HA AS DOUBLE),3),
             'sd':  round(CAST(SD AS DOUBLE),3),
             'n':   CAST(N AS INTEGER),
             'tc':  round(CAST(TC_GRID_MEAN AS DOUBLE),2),
             'gez': $GEZ_CASE,
             'fez': CAST(FEZ AS VARCHAR),
             'qmp': CAST(QUALITY_MIN_PLOTS     AS INTEGER),
             'qto': CAST(QUALITY_NOT_OUTDATED  AS INTEGER),
             'qac': CAST(QUALITY_LARGE_SIZE    AS INTEGER),
             'qlr': CAST(QUALITY_LOCALLY_REP   AS INTEGER),
             'qst': CAST(QUALITY_STRICT_FILTER AS INTEGER)} AS properties
          FROM read_csv_auto('$f', header=true, nullstr='NA')
        ) TO '$out' (FORMAT JSON);
    "
    feats=$(wc -l < "$out" | tr -d ' ')
    printf "   [ok]   %-10s %s features\n" "$base" "$feats"
done

# ── 4. GeoJSON → PMTiles ─────────────────────────────────────────────────────
echo
echo "[3/3] GeoJSON → PMTiles …"
for gj in "$GEOJSON_DIR"/agbref_*.geojsonl; do
    base=$(basename "$gj" .geojsonl | sed 's/^agbref_//')      # 2010_10km
    res="${base##*_}"                                          # 10km
    zmax=$(maxzoom_for "$res")
    out="$PMTILES_DIR/agbref_$base.pmtiles"
    tippecanoe \
        -o "$out" --force \
        -l agbref \
        -z "$zmax" -Z 0 -B 0 \
        --drop-densest-as-needed \
        --extend-zooms-if-still-dropping \
        --read-parallel \
        --no-tile-stats \
        "$gj" >/dev/null 2>&1
    sz=$(du -h "$out" | cut -f1)
    printf "   [ok]   %-10s zmax=%s -> %s (%s)\n" "$base" "$zmax" "$(basename "$out")" "$sz"
done

echo
echo "Done."
echo "  parquet: $(du -sh "$PARQUET_DIR" | cut -f1)  ($PARQUET_DIR)"
echo "  pmtiles: $(du -sh "$PMTILES_DIR" | cut -f1)  ($PMTILES_DIR)"
echo
echo "Preview locally with a range-capable server (PMTiles needs HTTP byte serving):"
echo "  npx serve $OUT_ROOT          # or any server that supports Range requests"
echo "  (python3 -m http.server does NOT support ranges — tiles won't load)"
