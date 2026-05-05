# Research: Source-Aware Storage Paths (032)

**Date**: 2026-04-08  
**Status**: Complete — all NEEDS CLARIFICATION resolved

## Decision 1: DOI / ID Sanitization Rule

**Decision**: Replace `:` → `-` and `/` → `_` in `sanitize_id()`.

**Rationale**: Dataverse DOIs take the form `doi:10.7910/DVN/XXXXXX`. Both `:` and `/` are unsafe in filesystem paths on macOS/Linux. The substitution is short, deterministic, and produces readable directory names (`doi-10.7910_DVN_XXXXXX`). Full reversibility is not required since the original ID is stored unmodified in the CSV `paper_id` column.

**Alternatives considered**:
- URL-percent-encoding (e.g., `%3A`, `%2F`): readable only to developers familiar with URL encoding; longer paths.
- Base64 encoding: compact but completely opaque; debugging becomes painful.
- MD5 hash: irreversible; no value here.

---

## Decision 2: Full Touchpoint Inventory

**Decision**: 12 files require path-logic changes (no new files created except `ground_truth/osf/` directory).

| File | Change Type | Lines affected |
|------|-------------|----------------|
| `pipeline/helper.R` | Add helpers; update `apply_ground_truth` | 12, 1052–1061 |
| `pipeline/0_index.R` | Constants + per-paper path construction | 23–25, 95–96, output_dir |
| `pipeline/2_codebook_label.R` | OUTPUT_DIR per-paper paths | 32, per-paper construction |
| `pipeline/3_psychds_convert.R` | PSYCHDS_OUT_DIR per-paper; data path; `apply_ground_truth` call | 491–493, 1010, 1032, 1062, 1084 |
| `runners/run_0_index_bulk.R` | Paper discovery; GT_DIR; columns.csv path | 40, 54, 84, 216 |
| `runners/run_single.R` | OUTPUT_DIR paths | 75, 106 |
| `runners/run_psychds_bulk.R` | Per-paper psychds path | 16, downstream |
| `runners/run_dataverse_bulk.R` | Per-paper path construction | TBD (read during impl) |
| `runners/run_tests.R` | Source column read; GT path; PSYCHDS override | 103, 621, 634–635 |
| `runners/run_test_validation_gui.R` | dc_gt_dir → osf-scoped | 26 |
| `reports/report_normal.R` | GT_DIR constant | 29 |
| `tools/validation_gui/app.R` | OSF filter; source-aware output paths | paper loading section |
| `tools/validation_gui/gt_store.R` | Ground_truth root | 19 |
| `tests/test_papers.csv` | Add `source` column | all rows |

**Note**: `3_psychds_convert.R:1010` hardcodes `"./data_check/outputs"` instead of using `OUTPUT_DIR` — this is a pre-existing bug that must be fixed as part of this feature.

---

## Decision 3: Bulk Paper Discovery

**Decision**: New `list_downloaded_papers()` helper in `helper.R` replaces `list.dirs(DATA_DIR, ...)` in bulk runners.

**Rationale**: After the refactor, `data/` contains `osf/` and `dataverse/` subdirectories — not paper IDs. A naïve `list.dirs(DATA_DIR, ...)` would return `["osf", "dataverse"]` instead of paper IDs. `list_downloaded_papers()` scans each registered source subdirectory and returns a unified `data.frame(source, paper_id)`.

**Alternatives considered**:
- Scan `data/osf/` and `data/dataverse/` separately in each runner: duplicates logic across runners (violates Principle IV).
- Drive paper list from `bulk_summary.csv`: suitable for re-processing but not initial discovery of newly-downloaded-but-not-yet-indexed papers.

---

## Decision 4: `apply_ground_truth` Signature

**Decision**: `apply_ground_truth(structure_df, source, paper_id)` — add `source` as second parameter.

**Rationale**: The function constructs the GT file path internally. Without `source`, it cannot resolve `ground_truth/osf/<id>.csv` vs a hypothetical `ground_truth/researchbox/<id>.csv`. Since ground-truth is currently OSF-only (per clarification Q3), callers always pass `source = "osf"` for now — but the signature is future-safe.

**Callers to update**: `3_psychds_convert.R:1032`.

---

## Decision 5: `GROUND_TRUTH_DIR` Constant

**Decision**: Add `GROUND_TRUTH_DIR <- "./data_check/ground_truth"` alongside the other layer-root constants in `0_index.R`.

**Rationale**: Currently GT path is hardcoded in `helper.R:1054` and locally re-defined in `run_0_index_bulk.R`, `report_normal.R`. Centralising as a constant follows Principle IV and makes the root configurable in tests.

---

## Decision 6: `psychds/conversion_summary.csv` Scope

**Decision**: Stays unified at `psychds/conversion_summary.csv` — not split per source.

**Rationale**: It's a rollup summary, not a raw artifact. Keeping it unified makes querying all conversions simple. Per-paper psychDS artifacts are still fully namespaced under `psychds/<source>/<id>/`.

---

## Decision 7: `test_papers.csv` Schema

**Decision**: Add explicit `source` column → schema `id, source, label`. All existing OSF rows get `source = "osf"`.

**Rationale**: Explicit is unambiguous; future sources (ResearchBox) may have IDs that don't look different from OSF IDs. `run_tests.R` reads `source` column and passes it to `paper_path()`.

---

## Decision 8: Ground-Truth Migration

**Decision**: Move all existing `ground_truth/*.csv` → `ground_truth/osf/*.csv` as a one-time step in the implementation. No automated migration script; done inline as part of the refactor task.

**Rationale**: ~25 files; straightforward filesystem move. Migration of downloaded `data/` is out of scope per spec Assumptions.

---

## Decision 9: Constitution Amendment

**Decision**: MINOR bump 1.3.1 → 1.4.0 to register new helpers and constant.

**Changes**:
- Principle IV helper list: add `paper_path()`, `sanitize_id()`, `list_downloaded_papers()`
- Key Constants table: add `GROUND_TRUTH_DIR`; note that `DATA_DIR`/`OUTPUT_DIR`/`PSYCHDS_OUT_DIR` are layer roots, not direct paper-path prefixes
- Processing Order step 10: update path from `outputs/<paper_id>/` to `outputs/<source>/<paper_id>/`
