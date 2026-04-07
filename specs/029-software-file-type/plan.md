# Implementation Plan: Software File Type

**Branch**: `029-software-file-type` | **Date**: 2026-04-02 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `specs/029-software-file-type/spec.md`

## Summary

Add a `software` file type to the pipeline to resolve the ambiguous classification of experiment programs (task delivery tools, compiled binaries, stimulus apps) that currently fall into `code`, `other`, or `supplemental`. The distinction is **purpose-based**: `code` files generate research outputs/analyses; `software` files run code for any other purpose (experiment delivery, data collection, task presentation).

Three components need updating: LLM classification prompts (`prompts.R`), the aggregate extension override map (`0_index.R`), and the validation GUI (`app.R`). Schema documentation must also be updated.

## Technical Context

**Language/Version**: R (base R only — no new packages)  
**Primary Dependencies**: `metacheck` (`llm_batch()`), `shiny` + `bslib` (validation GUI) — all already installed  
**Storage**: CSV files on local filesystem (`outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv`)  
**Testing**: `runners/run_tests.R` → `runners/report_tests.R`  
**Target Platform**: Local R environment, macOS  
**Project Type**: CLI pipeline + Shiny validation GUI  
**Performance Goals**: No change — this feature adds no new LLM calls  
**Constraints**: Base R only; no new packages; prompts must live in `prompts.R` (Principle IV)  
**Scale/Scope**: One new enum value propagating across 4 files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I — Crash Resilience | ✅ Pass | No new bulk runners or CSV writes added |
| II — Paper ID Preservation | ✅ Pass | No changes to paper ID handling |
| III — Conservative Resource Limits | ✅ Pass | No new LLM calls; existing limits unchanged |
| IV — Centralised Helpers & Prompts | ✅ Pass | Prompt changes in `prompts.R`; extension map in `0_index.R` constants block |
| V — Structured Error Classification | ✅ Pass | No new error codes needed |

No violations. Proceeding.

## Project Structure

### Documentation (this feature)

```text
specs/029-software-file-type/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (affected files)

```text
pipeline/
├── prompts.R            ← STRUCTURE_PROMPT + SENTINEL_PROMPT: add `software` type
└── 0_index.R            ← AGGREGATE_EXT_OVERRIDE: add compiled-binary extensions

tools/validation_gui/
└── app.R                ← TYPE_MAP, TYPE_ABBREV, CSS (×4 rules), key_press handler

docs/
└── output-schemas.md    ← File Types table: add `software` row
```

---

## Phase 0: Research

### Findings

All unknowns were resolved during spec clarification. No external research needed.

| Decision | Rationale | Alternatives Considered |
|---|---|---|
| Purpose-based distinction (`code` = analysis; `software` = experiment delivery) | Cleaner taxonomy than source-vs-compiled; maps to researcher intent | Form-based (source vs compiled) — rejected: a PsychoPy `.py` is software, not code |
| LLM handles ambiguous source files via full path context | LLM already receives relative paths (e.g., `experiment/run_task.py`); no rule-based folder heuristic needed | Keyword matching on folder names — rejected: fragile, duplicates what LLM already does |
| `AGGREGATE_EXT_OVERRIDE` only for compiled binaries | The override map is blunt (extension-only, no path context); source files in aggregates remain `code` for now | Remove source entries from map — rejected as out-of-scope; deferred to later feature |
| Notebooks always `code` | Notebooks are analysis artefacts regardless of content | Primary-purpose detection — rejected: ambiguous, inconsistent |
| `"9"` keyboard shortcut | Keys 1–8 are taken; 9 is the next available numeric key | Letter key — not needed since 9 is available |
| `VALID_TYPES` derives from `TYPE_MAP` | `VALID_TYPES <- unname(TYPE_MAP)` means adding to `TYPE_MAP` automatically propagates to the filter panel | Separate filter list — unnecessary |

---

## Phase 1: Design

### Data Model

**New enum value**: `type = "software"` in `structure.csv`

| Field | Existing definition | Change |
|---|---|---|
| `type` | `"data" \| "codebook" \| "code" \| "output" \| "supplemental" \| "readme" \| "asset" \| "other"` | Add `"software"` |
| `data_format` | Sub-classification for `type = "data"` rows only | No change — remains `NA` for `software` rows |

No new columns. No schema migration. `ground_truth/<paper_id>.csv` already stores `type_gt` as free-form character; no migration needed.

**Definition**: Files whose purpose is to run the experiment — stimulus delivery tools, task runners, data collection applications, compiled binaries and installers — as distinct from analysis scripts (`code`) and OS/config detritus (`other`).

---

### Implementation Design

#### 1. `pipeline/prompts.R` — `STRUCTURE_PROMPT`

**Location**: The `TYPE —` block in `STRUCTURE_PROMPT` (around line 101) and the JSON schema enum (line 198).

Add `software` definition between `code` and `output`:

```
  software     : program or application whose purpose is to run the experiment —
                 stimulus delivery, task presentation, data collection tools.
                 Distinct from `code` (which generates analyses/outputs):
                 - run_task.py, experiment.m, StimulusApp.exe → software
                 - analysis.R, clean_data.py, model_fit.m     → code
                 Compiled binaries (.exe, .app, .jar, .msi, .dmg) → always software.
                 Notebooks (.ipynb, .Rmd, .qmd) → always code, never software.
```

Add `"software"` to the JSON schema enum array (currently `["data","codebook","code","output","supplemental","readme","asset","other"]`).

Update the hard-cases disambiguation section to add:
```
- code vs software: purpose is the signal. Analysis/modelling/cleaning scripts → code.
  Experiment task runners, stimulus apps, compiled programs → software.
  When the full path contains experiment/, task/, paradigm/, or stimulus/ folder AND
  the file runs something (not a data/codebook/readme/asset), prefer software.
  Notebooks are always code.
```

Also update the JSON schema `description` string for `type` to include `software` in the enum and its definition.

#### 2. `pipeline/prompts.R` — `SENTINEL_PROMPT`

**Location**: The `TYPE —` block in `SENTINEL_PROMPT` (line 303).

Add after the `code` line:
```
  software     : series of experiment programs, compiled binaries, or task tools
```

#### 3. `pipeline/0_index.R` — `AGGREGATE_EXT_OVERRIDE`

**Location**: Lines 30–41 in the constants block.

Add compiled-binary/installer extensions as a new group:
```r
exe = "software", app = "software", jar = "software",
msi = "software", dmg = "software",
```

#### 4. `tools/validation_gui/app.R`

Four changes, all in `app.R`:

**a. `TYPE_MAP`** (line 27–30): Add `"9" = "software"`:
```r
TYPE_MAP <- c(
  "1" = "data", "2" = "code", "3" = "codebook", "4" = "supplemental",
  "5" = "readme", "6" = "asset", "7" = "output", "8" = "other",
  "9" = "software"
)
```
`VALID_TYPES` derives from this automatically — filter panel updates for free.

**b. `TYPE_ABBREV`** (line 33–36): Add `software = "sfw"`:
```r
TYPE_ABBREV <- c(
  data = "dat", code = "cod", codebook = "cbk", supplemental = "sup",
  readme = "rdm", asset = "ast", other = "oth", output = "out",
  software = "sfw"
)
```

**c. CSS — badge and active-button styles**: Add 4 rules (light badge, dark badge, light active button, dark active button). Colour chosen: amber/brown tone to visually distinguish from existing types.

Light mode:
```css
.tbadge-software        { background:#fff3e0; color:#e65100; }
.tbtn-software.tbtn-active { border-color:#e65100 !important; background:rgba(230,101,0,0.1) !important; color:#bf360c !important; box-shadow:0 0 8px rgba(230,101,0,0.2) !important; }
```

Dark mode:
```css
[data-theme='dark'] .tbadge-software        { background:rgba(255,183,77,0.22); color:#ffcc80; }
[data-theme='dark'] .tbtn-software.tbtn-active { border-color:#ffb300 !important; background:rgba(255,179,0,0.22) !important; color:#ffe082 !important; box-shadow:0 0 10px rgba(255,179,0,0.25) !important; }
```

**d. `observeEvent(input$key_press)` handler** (line 795): Add `"9"` case:
```r
"9" = { rv$selected_type <- "software" },
```

Also add `"9"` to the JavaScript key allowlist (line 225):
```js
if (["1","2","3","4","5","6","7","8","9","i","c","g"].indexOf(k) !== -1) {
```

#### 5. `docs/output-schemas.md` — File Types table

Add row for `software` after the `code` row:

```markdown
| `software` | Program or application whose purpose is to run the experiment — stimulus delivery, task presentation, data collection tools, compiled binaries (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`), installers. Distinct from `code` (which generates analyses/outputs). Notebooks (`.ipynb`, `.Rmd`, `.qmd`) are always `code`, never `software`. |
```

Update the "Current consumers" section to note that `software` must be added to all listed consumers.

---

### No External Contracts

This is an internal pipeline modification. No public APIs or external interfaces are exposed.

---

## Complexity Tracking

No constitution violations. Table not required.
