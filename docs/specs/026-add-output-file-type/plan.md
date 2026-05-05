# Implementation Plan: Add Output File Type

**Branch**: `026-add-output-file-type` | **Date**: 2026-03-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/026-add-output-file-type/spec.md`

## Summary

Add `output` as a new valid file type in `structure.csv`, representing computationally generated artefacts (rendered notebooks, script-generated figures, log files). The change is localised to the two LLM prompt strings in `prompts.R` and three documentation files. No pipeline routing code changes are needed — the existing `type == "data"` gate naturally excludes `output` files from column extraction.

## Technical Context

**Language/Version**: R (base R — no new packages)
**Primary Dependencies**: `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed
**Storage**: CSV files on local filesystem — `outputs/<paper_id>/structure.csv`
**Testing**: Manual smoke-test via `run_single.R` on a paper with known script outputs
**Target Platform**: Local macOS pipeline (darwin)
**Project Type**: Data pipeline (batch processing)
**Performance Goals**: No performance impact — prompt changes only
**Constraints**: No new packages; all LLM prompts must live in `prompts.R`
**Scale/Scope**: Affects every file classification run; retroactive reclassification happens automatically on next pipeline run per paper

## Constitution Check

*GATE: Must pass before implementation.*

| Principle | Status | Notes |
|---|---|---|
| I. Crash Resilience | ✅ Pass | No output accumulation logic changed |
| II. Paper ID Preservation | ✅ Pass | No CSV read/write changes |
| III. Conservative Resource Limits | ✅ Pass | No new LLM calls; prompt change only |
| IV. Centralised Helpers & Prompts | ✅ Pass | All prompt changes in `prompts.R` |
| V. Structured Error Classification | ✅ Pass | No new failure modes |

**Constitution amendment required**: PATCH bump 1.3.0 → 1.3.1. Technical Standards note "LLM MUST classify [plot objects] as `supplemental`" updated to `output`. See Task 5.

## Project Structure

### Documentation (this feature)

```text
specs/026-add-output-file-type/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── spec.md
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (affected files only)

```text
pipeline/
├── prompts.R            ← STRUCTURE_PROMPT + SENTINEL_PROMPT (primary change)
└── (0_index.R, helper.R — no changes)

docs/
├── output-schemas.md    ← Add `output` to File Types; narrow `supplemental`
└── pipeline.md          ← Add `output` to type list

.specify/memory/
└── constitution.md      ← PATCH amendment: plot-object guidance
```

---

## Implementation Tasks

### Task 1 — Update `STRUCTURE_PROMPT` in `prompts.R`

**File**: `pipeline/prompts.R`
**Lines affected**: The `TYPE —` block and `Hard cases` block of `STRUCTURE_PROMPT`

Three sub-changes in one prompt:

#### 1a. Add `output` type to the TYPE block

Insert between `code` and `supplemental`:

```
  output       : file produced by executing a script — rendered notebooks (.html,
                 .pdf, .docx output from .Rmd/.qmd/.ipynb), script-generated
                 figures and graphs (.png, .jpg, .svg, .eps, .pdf plots saved
                 programmatically), log files (.log, .out), and other
                 computational byproducts. Classify as output when the filename
                 or folder context clearly indicates a script-generated artefact.
```

#### 1b. Update `supplemental` definition

Remove "output figures" and "appendices, experiment scripts" that overlap with `output`:

Change:
```
  supplemental : research support material that is not data, code, or a codebook —
                 manuscripts, preregistrations, instruments, consent forms, output
                 figures, appendices, experiment scripts.
```

To:
```
  supplemental : human-authored research material that is not data, code, or a
                 codebook — manuscripts, preregistrations, instruments, consent
                 forms, survey scales, appendices. Script-generated artefacts
                 (figures, rendered notebooks) → output, not supplemental.
                 When provenance is ambiguous, prefer supplemental.
```

#### 1c. Update hard-case rules

1. **Image rule** — update to distinguish output figures from stimuli and supplemental:

   Change:
   ```
   - Images/audio/video → asset if inside a stimuli/stim/materials/sounds/images
     folder or filename contains "stim", "stimulus", "trial", or "item"; otherwise
     supplemental.
   ```

   To:
   ```
   - Images/audio/video → asset if inside a stimuli/stim/materials/sounds/images
     folder or filename contains "stim", "stimulus", "trial", or "item".
     → output if clearly script-generated: filename contains "figure", "fig",
     "plot", "graph", "results", or "output" AND not in stimuli context.
     → supplemental if provenance is ambiguous.
   ```

2. **`.rds`/`.rdata`/`.rda` rule** — update destination for plot-named files:

   Change:
   ```
   - .rds/.rdata/.rda → data unless filename contains "plot", "figure", or "graph".
   ```

   To:
   ```
   - .rds/.rdata/.rda → data unless filename contains "plot", "figure", or "graph"
     → output (not data, not supplemental).
   ```

3. **`.html` rule** — add new hard case:

   Add after the `.spv` rule:
   ```
   - .html → output if it appears to be a rendered notebook (shares a basename with
     an .Rmd/.qmd/.ipynb file in the same folder, or is in a folder containing
     scripts); otherwise supplemental.
   ```

4. **`.spv` rule** — update note for clarity (no type change):

   Update:
   ```
   - .spv → supplemental (SPSS Viewer output file, NOT code — .sps is code, .spv is not).
   ```

   *(No change to type; already supplemental. No action needed.)*

---

### Task 2 — Update `SENTINEL_PROMPT` in `prompts.R`

**File**: `pipeline/prompts.R`
**Lines affected**: The `TYPE —` block of `SENTINEL_PROMPT`

Add `output` to the sentinel type list and update `supplemental`:

Change:
```
  supplemental : research support material — manuscripts, instruments, output figures
```

To:
```
  output       : script-generated artefacts — rendered notebooks, figures, graphs,
                 log files, computational byproducts
  supplemental : human-authored research material — manuscripts, instruments, consent
                 forms. Ambiguous provenance → supplemental.
```

Also update the sentinel key signals section if it references "output figures → supplemental":
```
- Numbered stimulus files (.jpg, .png, .wav) → asset
```
Add below it:
```
- Figure/graph/plot series named files (.jpg, .png, .svg) outside stimuli folder → output
```

---

### Task 3 — Update `docs/output-schemas.md`

**File**: `docs/output-schemas.md`

#### 3a. Add `output` to the File Types table

Insert between `code` and `supplemental`:

```markdown
| `output` | File produced by executing a script: rendered notebooks (`.html`, `.pdf`, `.docx` output from `.Rmd`/`.qmd`/`.ipynb`), script-generated figures and graphs, log files, and other computational byproducts. Not column-extracted. |
```

#### 3b. Narrow `supplemental` definition

Change current `supplemental` row from:
```
| `supplemental` | Any research-related document or material that is not data, code, or a codebook — manuscripts, articles, reports, proposals, theses, preregistrations, registered reports, survey instruments, consent forms, SPSS `.sps` syntax, HTML output files, saved plot objects, result figures and output graphs, supporting appendices, experiment scripts. |
```

To:
```
| `supplemental` | Human-authored research material that is not data, code, or a codebook — manuscripts, articles, reports, proposals, theses, preregistrations, registered reports, survey instruments, consent forms, SPSS `.spv` syntax, supporting appendices. Script-generated artefacts (figures, rendered notebooks, log files) → `output`. When provenance is ambiguous, `supplemental` is the fallback. |
```

---

### Task 4 — Update `docs/pipeline.md`

**File**: `docs/pipeline.md`

Add `output` to wherever the file type enum is listed (file classification step, constants/types table, or File Types reference). Exact location to be determined by reading the file; search for "supplemental" or "file type" sections.

---

### Task 5 — PATCH amendment to constitution

**File**: `.specify/memory/constitution.md`

1. Bump version: `1.3.0` → `1.3.1`
2. Update the Technical Standards note:

   Change:
   ```
   - **ggplot / plot objects**: `read_data_head()` MUST return NULL for saved plot objects — this
     is correct behaviour; LLM MUST classify them as `supplemental`
   ```

   To:
   ```
   - **ggplot / plot objects**: `read_data_head()` MUST return NULL for saved plot objects — this
     is correct behaviour; LLM MUST classify them as `output` (filename contains "plot",
     "figure", or "graph") or `data` (no such keyword — classification deferred to empirical
     validation per feature 026)
   ```

3. Prepend a Sync Impact Report comment:

   ```html
   <!--
   SYNC IMPACT REPORT
   ==================
   Version change: 1.3.0 → 1.3.1 (PATCH — Technical Standards: ggplot/plot-object
   guidance updated from `supplemental` to `output` following addition of `output` file type)

   Modified sections:
     - Technical Standards: ggplot / plot objects guidance

   Added sections: None
   Removed sections: None

   Templates requiring updates: None
   -->
   ```

---

## Out of Scope

- `AGGREGATE_EXT_OVERRIDE` in `0_index.R`: image extensions remain mapped to `"asset"` — three-way ambiguity (output/asset/supplemental) requires LLM context; extension-level rule is insufficient.
- `classify_by_rules()` in `helper.R`: no change — `output` has no deterministic extension rule.
- `0_index.R` routing code: no change — `type == "data"` naturally excludes `output` files from column extraction.
- Retroactive reclassification: existing `structure.csv` files are not backfilled; reclassification occurs on next pipeline run per paper.
- Ground truth files (`ground_truth/<paper_id>.csv`): updating expected types for known papers is out of scope; treat as a follow-up validation task.
