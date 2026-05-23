# AGBref Web Map

Interactive web map for the **AGBref** global reference dataset of above-ground forest biomass.

## About AGBref

AGBref is a global AGB reference dataset derived from National Forest Inventories (NFIs), permanent research plots, and local AGB maps from airborne LiDAR. It provides biomass estimates for multiple epochs (2005, 2010, 2015, 2020) at various spatial resolutions (500 m, 1 km, 10 km, 25 km), with uncertainty estimates and quality flags.

**Paper**: Araza, A., Herold, M., Avitabile, V., et al. *AGBref: A global reference dataset of above-ground forest biomass.*

**Data**: [Zenodo](https://zenodo.org/records/15495069) · **Code**: [Plot2Map](https://github.com/arnanaraza/Plot2Map)

## Features

- **Epoch selection**: Toggle between 2005, 2010, 2015, 2020
- **Resolution selection**: 500m, 1km, 10km, 25km grid cells
- **Color by**: AGB, SD, Tree Cover, or Number of Plots
- **Quality filters**: Minimum plots, Timeliness, Area covered, Local representativity, Strict
- **Biome filter**: All, Tropical, Subtropical, Temperate, Boreal
- **Interactive tooltips**: Hover for detailed grid cell information
- **WebGL rendering**: Handles 200k+ points via deck.gl

## Deploy to GitHub Pages

```bash
git init
git add .
git commit -m "AGBref webmap"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/agbref-webmap.git
git push -u origin main
```

Then: **Settings → Pages → Source** → `main` branch, root `/`.

> The `data/` folder is ~100 MB total. You may need: `git config http.postBuffer 524288000`

## Data Format

Each `data/{year}_{resolution}.json`:

```json
{
  "cols": ["x","y","agb","sd","n","tc","q","gez","fez"],
  "rows": [[lon, lat, agb, sd, nplots, treecover, quality_bitmask, biome, ecozone], ...]
}
```

Quality bitmask: bit 0=min_plots, 1=timeliness, 2=area_covered, 3=local_rep, 4=strict.
Biome codes: B=Boreal, S=Subtropical, T=Temperate, R=Tropical.
