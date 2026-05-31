#!/usr/bin/env python3
"""
AGBref CSV -> GeoJSON (line-delimited / ndjson) for tippecanoe input.

Produces 16 .geojsonl files (one per epoch x resolution).  ndjson is much
faster for tippecanoe to ingest than monolithic GeoJSON FeatureCollection.

Property names are short (<=3 chars) to keep tile size small -- they are
repeated in every feature in every tile, so length matters:
    agb, sd, n, tc, gez, fez, qmp, qto, qac, qlr, qst

Usage:
    python3 csv_to_geojson.py <input_dir> <output_dir>
"""

import sys
import os
import glob
import json
import duckdb


GEZ_MAP = {"Boreal": "B", "Subtropical": "S", "Temperate": "T", "Tropical": "R"}


def convert(input_dir: str, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)
    con = duckdb.connect()

    files = sorted(glob.glob(os.path.join(input_dir, "AGBref_*.csv")))
    if not files:
        print(f"No AGBref_*.csv files in {input_dir}", file=sys.stderr)
        sys.exit(1)

    gez_case = "CASE GEZ " + " ".join(
        f"WHEN '{k}' THEN '{v}'" for k, v in GEZ_MAP.items()
    ) + " ELSE 'U' END"

    for csv_path in files:
        base = os.path.basename(csv_path).replace("AGBref_", "").replace(".csv", "")
        # base looks like "2010_10km"
        out_path = os.path.join(output_dir, f"agbref_{base}.geojsonl")

        # Build ndjson via DuckDB's json_object / json_array string assembly.
        # Note: we write one JSON object per line, no trailing comma, no wrapper.
        # NULL tc is emitted as null (valid JSON); tippecanoe handles it.
        rows = con.execute(f"""
            SELECT
                CAST(POINT_X AS DOUBLE) AS lon,
                CAST(POINT_Y AS DOUBLE) AS lat,
                CAST(AGB_T_HA AS DOUBLE) AS agb,
                CAST(SD AS DOUBLE) AS sd,
                CAST(N AS INTEGER) AS n,
                TC_GRID_MEAN AS tc,
                {gez_case} AS gez,
                FEZ AS fez,
                CAST(QUALITY_MIN_PLOTS AS BOOLEAN) AS qmp,
                CAST(QUALITY_NOT_OUTDATED AS BOOLEAN) AS qto,
                CAST(QUALITY_LARGE_SIZE AS BOOLEAN) AS qac,
                CAST(QUALITY_LOCALLY_REP AS BOOLEAN) AS qlr,
                CAST(QUALITY_STRICT_FILTER AS BOOLEAN) AS qst
            FROM read_csv_auto('{csv_path}', nullstr='NA')
        """).fetchall()

        with open(out_path, "w", encoding="utf-8") as fh:
            for (lon, lat, agb, sd, n, tc, gez, fez, qmp, qto, qac, qlr, qst) in rows:
                props = {
                    "agb": round(agb, 3),
                    "sd":  round(sd, 3),
                    "n":   n,
                    "gez": gez,
                    "fez": fez,
                    "qmp": 1 if qmp else 0,
                    "qto": 1 if qto else 0,
                    "qac": 1 if qac else 0,
                    "qlr": 1 if qlr else 0,
                    "qst": 1 if qst else 0,
                }
                if tc is not None:
                    props["tc"] = round(float(tc), 2)
                feat = {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [round(lon, 5), round(lat, 5)]},
                    "properties": props,
                }
                fh.write(json.dumps(feat, separators=(",", ":"), ensure_ascii=False))
                fh.write("\n")

        sz = os.path.getsize(out_path) / 1e6
        print(f"  [ok]  {base}: {len(rows):>7,} features -> {out_path}  ({sz:.1f} MB)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    print(f"AGBref CSV -> GeoJSON (ndjson)")
    print(f"  input : {sys.argv[1]}")
    print(f"  output: {sys.argv[2]}")
    convert(sys.argv[1], sys.argv[2])
    print("done.")
