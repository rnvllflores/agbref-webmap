# AGBref Web Map

Interactive web map for the **AGBref** global reference dataset of above-ground forest biomass.

Rendered with **MapLibre GL + PMTiles** for vector tiles, with **DuckDB-WASM** for in-browser analytics over Parquet — all served statically from GitHub Pages, no backend.

## About AGBref

AGBref is a global AGB reference dataset derived from National Forest Inventories (NFIs), permanent research plots, and local AGB maps from airborne LiDAR. It provides biomass estimates for multiple epochs (2005, 2010, 2015, 2020) at various spatial resolutions (500 m, 1 km, 10 km, 25 km), with uncertainty estimates and quality flags.

**Paper**: Araza, A., Herold, M., Avitabile, V., et al. *AGBref: A global reference dataset of above-ground forest biomass.*
**Data**: [Zenodo](https://zenodo.org/records/15495069) · **Code**: [Plot2Map](https://github.com/arnanaraza/Plot2Map)

## What's new in this build

| Concern              | Before                                           | After                                                 |
|----------------------|--------------------------------------------------|-------------------------------------------------------|
| Data format          | Custom JSON arrays (~50 MB per resolution loaded eagerly) | PMTiles (range-requested) + Parquet (HTTP range read) |
| Renderer             | deck.gl scatterplot overlay                      | Native MapLibre `circle` layer on vector tiles        |
| Filtering            | JS loop over the full row array on every change  | MapLibre filter expressions (GPU-side, instant)       |
| "Color by" switching | JS recomputes RGB for every point on every change | MapLibre `interpolate` paint expression (zero JS work) |
| Stats / analytics    | JS reduce over rows                              | DuckDB-WASM SQL over remote Parquet (range-read)      |
| Time to interactive  | Blocked on full JSON download                    | First tiles paint in ~hundreds of ms                  |

## Features

- **Epoch selection**: 2005 / 2010 / 2015 / 2020
- **Resolution selection**: 500 m, 1 km, 10 km, 25 km grid cells
- **Color by**: AGB, SD, Tree Cover, or Number of Plots (Viridis / Inferno / Greens / Blues)
- **Quality filters**: Minimum plots, Timeliness, Area covered, Local representativity, Strict
- **Biome filter**: All, Tropical, Subtropical, Temperate, Boreal
- **Analytics panel**: live "Mean AGB by biome" computed via DuckDB-WASM SQL over the current filter
- **Tooltips**: hover for AGB, SD, plot count, tree cover, biome, ecozone, and coordinates
- **Vector rendering**: zoom-aware, smooth at any extent, handles 200k+ points per layer

## Architecture

```
                          GitHub Pages (static)
                          ┌────────────────────────────┐
   ┌─────────────────┐    │  /data/pmtiles/*.pmtiles   │
   │   Browser       │    │  /data/parquet/*.parquet   │
   │                 │    │  /index.html               │
   │  ┌───────────┐  │    └────────────────────────────┘
   │  │ MapLibre  │◄─┼─── HTTP range → PMTiles tile fetch
   │  │   GL JS   │  │
   │  └───────────┘  │
   │  ┌───────────┐  │
   │  │  DuckDB   │◄─┼─── HTTP range → Parquet row-group fetch
   │  │   WASM    │  │
   │  └───────────┘  │
   └─────────────────┘
```

- **MapLibre** renders one `circle` layer per epoch+resolution, sourced from a single PMTiles file
- The `pmtiles://` protocol (registered via [`pmtiles@3`](https://www.npmjs.com/package/pmtiles)) does the range-read magic — only the tiles in view are fetched
- Quality / biome filters compile to native MapLibre filter expressions, evaluated GPU-side
- "Color by" is a `circle-color` paint expression with `interpolate` stops — no JS recompute
- DuckDB-WASM runs SQL against `read_parquet('https://…/agbref_<res>.parquet')`; the HTTP server only sees range requests for the row groups DuckDB actually needs

## Build the data (one-time, from source CSVs)

```bash
pip install duckdb pyarrow
# Install tippecanoe: https://github.com/felt/tippecanoe#installation
# (Ubuntu: apt install tippecanoe ; macOS: brew install tippecanoe)

# Put the 16 AGBref_<year>_<res>.csv files into data/csv/
./build.sh
```

Output:
- `data/parquet/agbref_{500m,1km,10km,25km}.parquet` — one per resolution, all epochs in one file
- `data/parquet/agbref_all.parquet` — combined view (optional, for cross-resolution queries)
- `data/pmtiles/agbref_<year>_<res>.pmtiles` — 16 vector tile archives (~204 MB total)

## Deploy to GitHub Pages

```bash
git init
git add index.html data/ build.sh build/ README.md
git commit -m "AGBref webmap with PMTiles + DuckDB-WASM"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/agbref-webmap.git
git push -u origin main
```

Then: **Settings → Pages → Source** → `main` branch, root `/`.

> The `data/pmtiles` folder is ~204 MB. GitHub allows files up to 100 MB and recommends repos under 1 GB; all individual `.pmtiles` files are well under 100 MB. For the initial push you may need `git config http.postBuffer 524288000`.

## Data format

### Parquet schema (for DuckDB-WASM)

| col   | type     | notes                                                     |
|-------|----------|-----------------------------------------------------------|
| lon   | DOUBLE   | POINT_X                                                   |
| lat   | DOUBLE   | POINT_Y                                                   |
| agb   | DOUBLE   | AGB_T_HA, above-ground biomass, Mg/ha                     |
| sd    | DOUBLE   | uncertainty, Mg/ha                                        |
| n     | INT32    | number of plots in cell                                   |
| tc    | DOUBLE   | tree cover %, 0–100. NULL where source had "NA"           |
| gez   | VARCHAR  | single-char biome: **B** Boreal · **S** Subtropical · **T** Temperate · **R** tRopical (R disambiguates from T-emperate) |
| fez   | VARCHAR  | FAO ecological zone (19 distinct full names)              |
| qmp   | BOOLEAN  | QUALITY_MIN_PLOTS                                         |
| qto   | BOOLEAN  | QUALITY_NOT_OUTDATED (Timeliness, ±3 yr of epoch)         |
| qac   | BOOLEAN  | QUALITY_LARGE_SIZE (Area covered, ≥75th pctl plot area)   |
| qlr   | BOOLEAN  | QUALITY_LOCALLY_REP (plot TC within 90% CI of grid cell)  |
| qst   | BOOLEAN  | QUALITY_STRICT_FILTER (all four above combined)           |
| epoch | INT16    | 2005 / 2010 / 2015 / 2020                                 |

Row-group size: 50,000. Compression: ZSTD.

### PMTiles attributes (per feature)

Same column codes as above (`agb`, `sd`, `n`, `tc`, `gez`, `fez`, `qmp`, `qto`, `qac`, `qlr`, `qst`); quality flags stored as int 0/1 (booleans aren't a primitive type in MVT). Coordinates rounded to 5 decimals (≈1 m), AGB/SD to 3 decimals, TC to 2 decimals — purely to shrink tile size.

Layer name in every tile: `agbref`. Max zoom: 8 (500m/1km), 6 (10km), 5 (25km).

## Customising / extending

- **Different basemap** — edit the `BASEMAPS` object in `index.html`
- **Different color scale** — edit `SCALES` (each entry has `min`/`max`/`stops`)
- **Custom SQL panel** — DuckDB views `agb_500m`, `agb_1km`, `agb_10km`, `agb_25km` are already registered; add a textarea and call `state.duckdbConn.query(sql)`
- **Larger or smaller circles** — adjust the per-resolution coefficients in `radiusExpression()`

## License

Code released under the same terms as the upstream Plot2Map project. Data: see Zenodo record for license.
