# Data Model: File Type Taxonomy Refactor (022)

## Entities

### 1. FileRecord (one row in `structure.csv`)

The core output record produced by `run_index()` for each discovered file.

| Field | Type | Change in this feature |
|---|---|---|
| `paper_id` | character | No change |
| `path` | character | No change |
| `rel_path` | character | No change |
| `filename` | character | No change |
| `ext` | character | No change |
| `type` | character | All 8 boundary definitions sharpened (see Type enum) |
| `group` | character | `"other"` value renamed to `"shared"` (see Group enum) |
| `type_source` | character | **NEW** — `"rule"` or `"llm"` |
| `is_raw` | logical | No change; now explicitly applicable to non-tabular `data` files |
| `is_sentinel` | logical | No change |

---

### 2. Type Enum (8 values — unchanged set, all definitions sharpened)

| Value | Definition | Litmus test | Changed? |
|---|---|---|---|
| `data` | Any file containing research measurements intended for analysis — tabular (csv, sav, xlsx, etc.) OR non-tabular (`.edf`, `.acq`, `.bdf` physiological recordings, `.mat` matrices, nested `.json` survey exports). Column extraction skips non-parseable formats; file remains `data` | "Does this contain measurements collected from participants or instruments for analysis?" | Broadened to include non-tabular formats |
| `codebook` | File whose *primary purpose* is describing what variables mean — variable dictionary, data dictionary, coding guide. LLM uses primary-purpose inference from filename/path; defaults to `doc`/`supplemental` when ambiguous | "Is describing variables this file's main job?" | Boundary sharpened; explicit defaults added |
| `code` | Executable source file: R, Python, MATLAB, Julia, SQL, shell scripts, `.Rmd`/`.qmd` notebooks (always `code` regardless of narrative content) | "Can this file be run or sourced?" | Clarified: `.Rmd`/`.qmd` always `code` |
| `supplemental` | Research-process support that does NOT report conclusions: surveys, consent forms, preregistrations, SPSS `.sps` syntax, HTML output files, saved plot objects, **result figures/graphs as image files**, supporting appendices | "Does this support or document the research process?" | Boundary sharpened; result figures explicitly added |
| `doc` | Narrative document FOR human readers reporting research conclusions: manuscripts, papers, reports of findings, proposals, lab notebook entries, research decision logs, general prose notes | "Would a journal reviewer read this to understand the findings?" | Boundary sharpened; defined positively only — no exclusion list in prompt |
| `readme` | Name-based only: files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*`. Classified by filename alone — no filename match = not readme | "Is the filename README, LICENSE, or CONTRIBUTING?" | Tightened to name-based only; CHANGELOG removed to eliminate collision with `doc` |
| `asset` | Participant-facing sensory material only: images, audio, video shown/played to participants during the study (stimuli, rating-scale images, audio clips) | "Would a participant see or hear this during the study?" | Tightened: result figures explicitly excluded → `supplemental` |
| `other` | No research content: OS metadata (`.DS_Store`, `Thumbs.db`), lock files, config files, executables, installers. NOT a catch-all | "Does this have any research content whatsoever?" (no → `other`) | Boundary sharpened; catch-all use prohibited |

---

### 3. Group Enum (breaking change: `other` → `shared`)

| Value | When to use | Changed? |
|---|---|---|
| `ex<N>` | File belongs to a specific numbered experiment (e.g. `ex1`, `ex4a`) | No |
| `pilot<N>` | File belongs to a pilot study; alphanumeric suffixes preserved exactly (e.g. `pilot1a` ≠ `pilot1`) | Clarified: alphanumeric suffixes required |
| `shared` | Meaningful research file not tied to a specific numbered experiment — combined datasets, project-wide scripts, meta-analyses, proposals | **Renamed from `other`** |
| `na` | Group not applicable — ONLY for type `readme`, `asset`, or `other`. All other types MUST NOT use `na` | Restriction tightened |

---

### 4. type_source Enum (new field)

| Value | Meaning |
|---|---|
| `rule` | `AGGREGATE_EXT_OVERRIDE` applied — final `type` came from extension-based rule |
| `llm` | LLM assignment accepted (either direct result or inherited from sentinel's LLM assignment) |

---

### 5. AGGREGATE_EXT_OVERRIDE Changes

| Extension | Old value | New value | Reason |
|---|---|---|---|
| `.sps` | `"code"` | `"supplemental"` | SPSS syntax/output supports the research process; per FR-003 |

All other entries remain unchanged. Image/audio/video extensions stay as `"asset"` — the override only applies to sentinel-expanded files (>50-file folders), which are almost certainly stimulus sets, not results folders.

---

### 6. Batch Strategy Changes

| Parameter | Old | New |
|---|---|---|
| `LLM_BATCH_SIZE` | 20 | 30 |
| Per-batch `user_prefix` | Fixed: `"Classify this repository tree:"` | Variable: includes incremental experiment-structure summary for batches 2+ |

---

## State Transitions

### File classification flow (per file)

```
file path
    │
    ▼
[llm_batch() per chunk of LLM_BATCH_SIZE=30 paths]
    │  uses STRUCTURE_PROMPT with all 8 sharpened definitions
    │  batches 2+: user_prefix includes incremental experiment-structure summary
    │  type fallback = "other", group fallback = "na"
    ▼
[Sentinel expansion: agg_expanded_df]
    │
    ├─ extension in AGGREGATE_EXT_OVERRIDE?
    │     YES → type = override value, type_source = "rule"
    │     NO  → type = sentinel LLM type, type_source = "llm"
    ▼
[Non-aggregate files: non_agg_df]
    │  type_source = "llm" (always)
    ▼
[rbind → file_df with type_source column]
    ▼
[written to outputs/<paper_id>/structure.csv]
```

---

## Validation Constraints

- Every `type` MUST be one of the 8 values; `other` is NOT a catch-all.
- Every `group` MUST be one of `ex<N>`, `pilot<N>`, `shared`, `na`; `"other"` is no longer valid.
- `group = "na"` ↔ `type ∈ {readme, asset, other}` only.
- `type_source` ∈ `{"rule", "llm"}`, never NA.
- `pilot<N>` values preserve alphanumeric suffixes exactly.
- Non-tabular `data` files (`.edf`, `.acq`, `.mat`) may have `is_raw = TRUE`; their column counts will be 0 (column extraction skipped).
