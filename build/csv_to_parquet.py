#!/usr/bin/env python3
"""
AGBref CSV -> Parquet converter.

Produces 4 Parquet files (one per resolution: 500m, 1km, 10km, 25km), each
containing all 4 epochs (2005/2010/2015/2020) stacked, with an `epoch` column.

Schema (matches what index.html / DuckDB-WASM expects):
    lon    DOUBLE   -- POINT_X
    lat    DOUBLE   -- POINT_Y
    agb    DOUBLE   -- AGB_T_HA (above-ground biomass, Mg/ha)
    sd     DOUBLE   -- SD (uncertainty, Mg/ha)
    n      INT32    -- N (number of plots)
    tc     DOUBLE   -- TC_GRID_MEAN (tree cover %, 0-100)
    gez    VARCHAR  -- single-char biome code: B/S/T/R
                       (Boreal / Subtropical / Temperate / tRopical)
                       README convention: R for Tropical to disambiguate from T-emperate
    fez    VARCHAR  -- FAO ecological zone (full name, 19 distinct values)
    qmp    BOOLEAN  -- QUALITY_MIN_PLOTS
    qto    BOOLEAN  -- QUALITY_NOT_OUTDATED (timeliness)
    qac    BOOLEAN  -- QUALITY_LARGE_SIZE (area covered)
    qlr    BOOLEAN  -- QUALITY_LOCALLY_REP
    qst    BOOLEAN  -- QUALITY_STRICT_FILTER (all four combined)
    epoch  INT16    -- 2005 | 2010 | 2015 | 2020

Usage:
    python3 csv_to_parquet.py <input_dir> <output_dir>
"""

import sys
import os
import glob
import duckdb


# Maps full GEZ name -> single-char code used everywhere downstream.
# README convention: R = tropical (not T, because T = Temperate).
GEZ_MAP = {
    "Boreal":      "B",
    "Subtropical": "S",
    "Temperate":   "T",
    "Tropical":    "R",
}


def convert(input_dir: str, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)
    con = duckdb.connect()

    # Build the GEZ remap as a SQL CASE expression.
    gez_case = "CASE GEZ " + " ".join(
        f"WHEN '{k}' THEN '{v}'" for k, v in GEZ_MAP.items()
    ) + " ELSE 'U' END"

    for res in ("500m", "1km", "10km", "25km"):
        patterns = sorted(glob.glob(os.path.join(input_dir, f"AGBref_*_{res}.csv")))
        if not patterns:
            print(f"  [skip] {res}: no files match", file=sys.stderr)
            continue

        # read_csv_auto across globbed files; UNION via UNION ALL into one Parquet.
        # We use a typed projection to keep the Parquet schema small and stable.
        file_list_sql = "[" + ", ".join(f"'{p}'" for p in patterns) + "]"
        out_path = os.path.join(output_dir, f"agbref_{res}.parquet")
        sql = f"""
            COPY (
              SELECT
                CAST(POINT_X AS DOUBLE)        AS lon,
                CAST(POINT_Y AS DOUBLE)        AS lat,
                CAST(AGB_T_HA AS DOUBLE)       AS agb,
                CAST(SD AS DOUBLE)             AS sd,
                CAST(N AS INTEGER)             AS n,
                CAST(TC_GRID_MEAN AS DOUBLE)   AS tc,
                {gez_case}                     AS gez,
                CAST(FEZ AS VARCHAR)           AS fez,
                CAST(QUALITY_MIN_PLOTS    AS BOOLEAN) AS qmp,
                CAST(QUALITY_NOT_OUTDATED AS BOOLEAN) AS qto,
                CAST(QUALITY_LARGE_SIZE   AS BOOLEAN) AS qac,
                CAST(QUALITY_LOCALLY_REP  AS BOOLEAN) AS qlr,
                CAST(QUALITY_STRICT_FILTER AS BOOLEAN) AS qst,
                CAST(Year AS SMALLINT)         AS epoch
              FROM read_csv_auto({file_list_sql}, header=True, nullstr='NA')
              ORDER BY epoch, lat, lon
            )
            TO '{out_path}' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 50000);
        """
        con.execute(sql)
        sz = os.path.getsize(out_path) / 1e6
        n = con.execute(f"SELECT COUNT(*) FROM '{out_path}'").fetchone()[0]
        print(f"  [ok]   {res}: {n:>7,} rows -> {out_path}  ({sz:.1f} MB)")

    # Cross-resolution combined file is optional but handy for some DuckDB queries.
    parts = sorted(glob.glob(os.path.join(output_dir, "agbref_*.parquet")))
    if len(parts) == 4:
        combined = os.path.join(output_dir, "agbref_all.parquet")
        union_sql = " UNION ALL ".join(
            f"SELECT *, '{p.split('agbref_')[1].split('.')[0]}' AS resolution FROM '{p}'"
            for p in parts
        )
        con.execute(f"""
            COPY ({union_sql})
            TO '{combined}' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 100000);
        """)
        sz = os.path.getsize(combined) / 1e6
        print(f"  [ok]   all: combined -> {combined}  ({sz:.1f} MB)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    print(f"AGBref CSV -> Parquet")
    print(f"  input : {sys.argv[1]}")
    print(f"  output: {sys.argv[2]}")
    convert(sys.argv[1], sys.argv[2])
    print("done.")
