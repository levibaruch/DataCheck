# Research: File Type Taxonomy Refactor (022)

## Findings

---

### R1 — Extension Override Conflicts (FR-009c)

**Decision**: Two conflicts found in `AGGREGATE_EXT_OVERRIDE`:
1. `.sps` must change from `code` → `supplemental`
2. Image/audio/video extensions (`jpg`, `png`, `mp4`, `wav`, etc.) stay as `asset` in the override — reasoning below

**Current `AGGREGATE_EXT_OVERRIDE` in `0_index.R` lines 29–40** (relevant entries):
```r
do = "code", sps = "code",          # .sps conflict
jpg = "asset", jpeg = "asset", ...  # image extensions — see nuance below
```

**`.sps` conflict**: SPSS syntax/output files support the research process; FR-003 and the existing prompt rule require `supplemental`. Override wins over LLM, silently forcing `code`. **Must change to `supplemental`**.

**Image/audio/video in aggregate override**: The override only applies to sentinel-expanded files — files from folders with >50 items. A folder with >50 image files is almost certainly a stimulus set, not a results folder. Keeping images → `asset` in `AGGREGATE_EXT_OVERRIDE` is therefore correct for the aggregate case. For non-sentinel files, the LLM applies the full prompt reasoning (including the FR-003b litmus test: "Would a participant see/hear this during the study?"). **No change needed to image/audio/video entries.**

**No other conflicts found.**

---

### R2 — `classify_by_rules()` in `helper.R` — Dead Code

**Finding**: `classify_by_rules()` is defined in `helper.R` (line 148) but is **never called** from any pipeline script. It references an undefined `RULES` object. The active rule mechanism is `AGGREGATE_EXT_OVERRIDE` in `0_index.R`. **Do not modify** — out of scope.

---

### R3 — `type_source` Column Implementation Strategy (FR-009c)

**Decision**: Track `type_source` when `file_df` is assembled in `0_index.R`.

- Non-aggregate files (`non_agg_df`): always `type_source = "llm"`.
- Sentinel-expanded files (`agg_expanded_df`): `type_source = ifelse(to_override, "rule", "llm")` — the `to_override` vector already computed at line ~460 is the exact signal.
- Sentinel rows (`is_sentinel = TRUE`): `type_source = "llm"`.

---

### R4 — Batch Size: Optimal Value (FR-008)

**Decision**: Set `LLM_BATCH_SIZE` default to 30; validate empirically.

- Current: 20 files/call → max 200 paths. At 30: max 300 paths (10 calls preserved).
- **Constitution impact**: Principle III documents "200 paths at batch size 20". Changing to 30 raises the effective cap to 300. This is a constants-table PATCH (1.1.0 → 1.1.1).

---

### R5 — Incremental Structure Summary Header (FR-008b)

**Decision**: After each batch, extract a compact experiment map from responses and prepend it as a header to the next batch's `user_prefix`.

**Format**:
```
Known experiment structure from prior batches:
- ex1: "Experiment_1/", "Study1_data.csv"
- pilot1: "Pilot_1/"
- shared: "combined_data.csv"
Use these group assignments to classify the following paths consistently.

Classify this repository tree:
```

**Implementation**: Loop over chunks in `run_index()` in `0_index.R`. `build_structure_summary()` and `update_experiment_map()` are inline helpers within `run_index()` — not added to `helper.R` since they are tightly coupled to the index batch loop.

---

### R6 — Ground Truth File Updates (FR-009b)

**Finding**: `ground_truth/` directory is currently empty. Ground truth review is a manual post-implementation step. The validation GUI must be updated to accept `"shared"` (replacing `"other"`) as a valid group value.

---

### R7 — Prompt Sharpening: All 8 Types

**Decision**: All 8 types get thorough litmus-test definitions in `STRUCTURE_PROMPT`. Key decisions per type:

#### `data`
Broad definition — includes non-tabular research measurement files (`.edf`, `.acq`, `.bdf` physiological recordings, `.mat` matrices, nested `.json` survey exports). The pipeline's column-extraction step simply skips formats it cannot parse; the file remains `data` and should receive `is_raw = TRUE`. Litmus test: *"Does this file contain measurements collected from participants or instruments for the purpose of analysis?"*

#### `codebook`
Primary-purpose inference from filename/path. `codebook` = file whose main purpose is describing what variables mean. LLM uses semantic reasoning about the filename — no rigid pattern matching. Defaults to `doc`/`supplemental` when ambiguous. Explicit exclusions: (a) README files, (b) methods documents that mention variables incidentally.

#### `code`
Executable source files: R, Python, MATLAB, Julia, SQL, shell scripts, Makefiles. `.Rmd`/`.qmd` are always `code` regardless of narrative content — the knitted output (HTML/PDF) is `doc` or `supplemental`. Litmus test: *"Can this file be run or sourced?"*

#### `supplemental`
Research-process support that does NOT report conclusions: surveys, consent forms, preregistrations, SPSS `.sps` syntax, HTML result output files, saved R plot objects (`.Rdata`/`.rda` with ggplot), **result figures and output graphs saved as image files**, and supporting appendices. Key question: *"Does this support or document the research process?"*

#### `doc`
Narrative document FOR human readers reporting research conclusions: manuscripts, papers, reports of findings, project proposals, general prose notes, lab notebook entries, research decision logs. Litmus test: *"Would a journal reviewer read this to understand the findings?"*

#### `readme`
Name-based only: files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*`. Classify by filename alone — if the filename is not one of these, it is not `readme`.

#### `asset`
Participant-facing sensory material only: images, audio, and video files that were **shown or played to participants during the study** (stimulus pictures, rating-scale images, video clips, audio stimuli). Result figures, output plots, and graphs documenting research outcomes → `supplemental`. Litmus test: *"Would a participant see or hear this file during the study?"*

#### `other`
No research content: OS metadata (`.DS_Store`, `Thumbs.db`), package lock files, environment config files, binary executables, installers. NOT a catch-all for ambiguous research files.

---

### R8 — Group Value Rename: `other` → `shared` (FR-005, FR-006, FR-007)

**Decision**: Replace group `"other"` with `"shared"` everywhere in `STRUCTURE_PROMPT`, output schemas, and validation GUI. Group `"na"` restricted to `readme`, `asset`, `other` types only — all other types must receive `ex<N>`, `pilot<N>`, or `shared`.

---

### R9 — Constitution Impact

**Principle III PATCH required**: Update `LLM_BATCH_SIZE` from `20` to `30` in the constitution constants table and update the parenthetical from "(i.e., 200 paths at batch size 20)" to "(i.e., 300 paths at batch size 30)". Version bump: 1.1.0 → 1.1.1.

---

### R10 — AGGREGATE_EXT_OVERRIDE: Non-Tabular `data` Formats

**Finding**: `.mat` (MATLAB) is not currently in `AGGREGATE_EXT_OVERRIDE`. Physiological recording extensions (`.edf`, `.acq`, `.bdf`) are also absent. Since `data` is now broad (includes non-tabular), these formats should flow through the LLM rather than be forced to `other`. No override entries need to be added — the LLM prompt handles them via the broad `data` definition and the "measurements from participants" litmus test. The existing `AGGREGATE_EXT_OVERRIDE` entries for tabular formats (`csv`, `sav`, `dta`, `sas7bdat`, `xlsx`, `xls`, `rds` → `data`) remain correct.
