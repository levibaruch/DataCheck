# Research: Harvard Dataverse Source Support

**Feature**: 031-dataverse-source-support  
**Date**: 2026-04-08

---

## Decision 1 — Source detection strategy

**Decision**: Auto-detect Dataverse IDs by prefix: `startsWith(paper_id, "doi_")`.

**Rationale**: OSF paper IDs are always numeric strings (e.g. `0956797615569001`); they can never start with `"doi_"`. Dataverse DOI slugs always start with `"doi_"` (e.g. `doi_10.7910_DVN_0QEUU5`). No new function parameter, no enum, no config — detection is a one-liner helper in `helper.R`.

**Alternatives considered**:
- Explicit `source` parameter on `run_index()` — rejected; adds a required argument to every call site; auto-detection is equally reliable and zero-friction.
- Separate `run_dataverse_index()` function — rejected; duplicates the entire pipeline body. Source routing inside the existing function is cleaner.

---

## Decision 2 — Dataverse data root location

**Decision**: `./data_check/data/dataverse/` — a `dataverse/` subdirectory within the existing `data/` cache.

**Rationale**: Mirrors the OSF convention (`data/<paper_id>/`). Keeps all raw data under one root (`data/`). The psychDS size-check (`file.path("./data_check/data", pid)`) still won't resolve correctly (deferred TODO), but the `download_path` in psychDS provenance (`data/dataverse/<doi_slug>/`) is consistent and portable.

**Alternatives considered**:
- Keeping data at the external scrape path (`/Users/.../dataverse_scrape/downloads/`) — rejected; machine-specific, not portable, breaks psychDS provenance block conventions.
- `./data_check/dataverse/` (separate top-level) — rejected; diverges from existing `data/` convention without benefit.

---

## Decision 3 — `source` column placement

**Decision**: Add `source` as a column in `bulk_summary.csv` via `make_summary_row()` in `run_0_index_bulk.R`. OSF runner writes `"osf"`, Dataverse runner writes `"dataverse"`. The `run_index()` return list also includes `source`.

**Rationale**: `bulk_summary.csv` is the canonical index of all processed papers. Adding `source` there makes it the single place for cross-corpus filtering. The psychDS converter already reads `bulk_summary.csv`, so it can pick up `source` from there without needing a separate lookup.

**Alternatives considered**:
- Separate `dataverse_bulk_summary.csv` — rejected; splits the corpus index, complicates downstream analysis, and forces report scripts to read two files.

---

## Decision 4 — Validation GUI exclusion mechanism

**Decision**: In `gt_store.R::discover_papers()`, add a one-line filter after scanning `outputs/`: `dirs <- dirs[!startsWith(dirs, "doi_")]`.

**Rationale**: `discover_papers()` already has a filtering mechanism (`dc_papers_filter` option). The DOI prefix filter is a direct extension of this pattern. No new options or parameters needed — the `doi_` prefix is a reliable discriminator.

**Alternatives considered**:
- Read `bulk_summary.csv` and filter on the `source` column — technically more correct but adds a file dependency and read overhead at GUI startup. Prefix check is sufficient and immediate.

---

## Decision 5 — PsychDS `source_repository` dynamic platform field

**Decision**: In `3_psychds_convert.R::build_dataset_description()`, accept a `source` argument (defaulting to `"osf"` for backward compatibility). Set `platform = source` and `download_path` based on source: `data/<paper_id>/` for OSF, `data/dataverse/<paper_id>/` for Dataverse.

**Rationale**: The `source` value is already available in `bulk_summary.csv` and will be in `run_index()`'s return value. Passing it through to `build_dataset_description()` keeps the logic in one place. Defaulting to `"osf"` ensures all existing OSF psychDS conversions remain unaffected (backward compatibility, Principle I).

**Alternatives considered**:
- Re-derive source from `paper_id` prefix inside `build_dataset_description()` — possible, but couples the helper to an ID-format assumption. Better to pass the value explicitly from the caller which already has it.

---

## Decision 6 — New error code for missing Dataverse directory

**Decision**: Add `dataverse_dir_missing` error code for when `data/dataverse/<doi_slug>/` does not exist. Reuse existing `empty_repo` for an existing-but-empty Dataverse directory.

**Rationale**: Principle V requires all failure modes to have a structured code before merging. `no_links` and `download_failed` do not apply to Dataverse. `dataverse_dir_missing` is semantically distinct from `empty_repo` (missing vs. exists-but-empty).

---

## Integration points summary

| File | Change type | What changes |
|---|---|---|
| `pipeline/helper.R` | Add helper | `is_dataverse_id()` |
| `pipeline/0_index.R` | Modify | Source detection, `target_dir` routing, `source` in return value, new error code |
| `runners/run_0_index_bulk.R` | Modify | `source = "osf"` in `make_summary_row()` |
| `runners/run_dataverse_bulk.R` | New file | Dataverse bulk runner |
| `tools/validation_gui/gt_store.R` | Modify | Filter Dataverse IDs from `discover_papers()` |
| `pipeline/3_psychds_convert.R` | Modify | Dynamic `platform` + `download_path` in `build_dataset_description()` |
| `docs/output-schemas.md` | Modify | Add `source` column, `dataverse_dir_missing` error code |
| `docs/pipeline.md` | Modify | Dataverse flow, `DATAVERSE_DATA_DIR` constant |
