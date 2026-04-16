# Regression Analysis — Apr 10 → Apr 15

**Generated:** 2026-04-15  
**Context:** Features 037 (granularity detection) and 038 (LLM fallback retry) shipped between reports. Granularity and format classification improved dramatically. Group classification and raw accuracy regressed.

---

## Summary of Changes

| Metric | Apr 10 | Apr 15 | Δ |
|---|---|---|---|
| Paper-avg κ | 0.788 | 0.750 | −0.038 |
| Paper-avg accuracy | 87.8% | 85.0% | −2.8 pp |
| Paper-avg Macro F1 | 93.6% | 92.8% | −0.8 pp |
| Paper-avg MCC | 0.850 | 0.841 | −0.009 |
| File-pool accuracy | 91.2% | 94.0% | +2.8 pp |
| **Group classification** | **94.2%** | **77.1%** | **−17.1 pp** |
| **data_granularity** | **60.2%** | **95.8%** | **+35.6 pp** ✅ |
| **data_format** | **91.6%** | **97.2%** | **+5.6 pp** ✅ |
| software → data (file-pool FP) | 13 | 407 | +394 |
| software → code (paper-avg prop) | 0.332 | 0.460 | +0.128 |
| software → software (paper-avg prop) | 0.438 | 0.354 | −0.084 |

**Paper count dropped:** 225 → 218. Some papers lost from ground truth set — this may shift aggregate composition and partially explain some metric drift.

---

## Root Cause 1 — Aggregate Sentinel Group Propagation

### What happened

Feature 037 introduced or expanded aggregate detection. Folders with many same-extension files now collapse into a single aggregate sentinel, which receives one LLM classification call. That single group label (e.g., `ex1a`) is then propagated to every file in the aggregate.

**Before:** Analysis scripts (`.R`, `.py`, `.m`) classified individually → each got its own group label matching its filename (`Bracketing_1a.R` → `ex1a`, `Bracketing_2.R` → `ex2`, etc.).

**After:** The same folder collapses into one aggregate sentinel → LLM samples one or a few file paths → returns one group (e.g., `ex1a`) → stamped on all 20 files, even those belonging to `ex2`, `ex3`, `ex4`.

### Evidence

From TODO.txt (paper `09567976211061321`):
```
Aggregate [Analysis_scripts/.r]: 34 files → type=code, group=ex1a
Files: Bracketing_1a.R, Bracketing_1b.R, Bracketing_2.R, ..., Bracketing_4.R
```
All 34 files labeled `ex1a`. Ground truth spans `ex1a`, `ex1b`, `ex2`, `ex3`, `ex4`.

### Impact

- Group accuracy drop: 94.2% → 77.1% (−17.1 pp)
- Paper-level accuracy dragged down wherever heterogeneous-group code folders exist
- Most common in papers with multiple experiments sharing one `Analysis_scripts/` or `Code/` directory

### Proposed fixes

**Fix A — Heterogeneous aggregate detection (recommended):**  
After forming an aggregate sentinel, sample filename stems and run the group-extraction regex across all sampled names. If ≥ 2 distinct experiment labels are found, set `route_individually = TRUE` and bypass aggregation for that folder.

**Fix B — Per-file group extraction for code aggregates:**  
For `type = code` aggregates specifically, skip LLM group classification and apply the filename-based regex (`ex1`, `ex2`, `1a`, `2b`, etc.) directly to each file in the aggregate. This works because code files almost always carry explicit experiment labels in their filenames.

**Fix C — Post-hoc split:**  
After sentinel propagation, re-run filename-based group regex on each file in the aggregate. Override the sentinel group if a confident match is found. Low risk; no extra LLM calls.

Fix C is the safest incremental change. Fix A prevents the problem at the aggregate formation stage.

---

## Root Cause 2 — Software Classified as Data (407 FPs)

### What happened

407 files with ground truth `software` were predicted as `data`. In Apr 10, only 13 such errors existed. This is a **30× increase** in this specific error type.

It is the **single largest error category** (25.8% of all errors).

### Primary extension breakdown

| Extension | Error rate | Top pair |
|---|---|---|
| `.txt` | 18.0% (505 errors) | software→data (400) |
| `.js` | 88.7% (102 errors) | software→code (96) |
| `.html` | 47.2% (77 errors) | software→supplemental (73) |
| `.md` | 82.5% (66 errors) | software→supplemental (60) |
| `.m` | 79.9% (218 errors) | software→code (214) |
| `.py` | 71.4% (30 errors) | software→code (28) |

### Sub-pattern A — `.txt` files from jsPsych / software bundles → `data`

400 of 505 `.txt` errors are `software→data`. jsPsych and similar web experiment frameworks bundle `.txt` files (stimulus lists, configuration files, trial sequences) inside the library directory tree. These are software assets, not research data. The LLM sees `.txt` + something that looks like tabular content and calls it `data`.

**Fix:** Prompt clarification: files in paths containing `jspsych`, `jsPsych`, `experiment_code`, `online_study_code`, or similar framework directories should be classified as `software` regardless of extension. Alternatively, add path-based pre-classification rule: if ancestor directory is already classified as software, inherit `software`.

### Sub-pattern B — `.js` files → `code` instead of `software`

96 of 102 `.js` errors are `software→code`. jsPsych plugin files (`plugins/*.js`) are third-party library code, not researcher-written analysis scripts. The LLM correctly identifies them as code but misapplies the `code` label (researcher scripts) instead of `software` (third-party library).

**Fix:** Prompt clarification: `.js`, `.html`, `.css` files are almost never researcher-written analysis code in psychology repos. If in a framework/library context (`jspsych`, `node_modules`, `plugins/`), label `software`. If standalone, label `supplemental` or `software`. Not `code`.

Alternatively: add `js = "software"` to `AGGREGATE_EXT_OVERRIDE` (`.js` files are always software in psych repos — no psychology researcher writes original `.js` analysis code that should be classified as `code`).

### Sub-pattern C — `.m` MATLAB files → `code` instead of `software`

214 of 218 `.m` errors are `software→code`. This is the same distinction problem: MATLAB `.m` files that form a complete analysis pipeline or toolbox should be `software`, but isolated researcher-written scripts should be `code`. The LLM consistently calls all `.m` files `code`.

**Fix:** This is harder. The `software` vs `code` distinction for `.m` depends on whether the file is part of a library/toolbox (directory has many `.m` files with package structure: `@class/`, `+pkg/`) vs a standalone script. A heuristic: if the aggregate folder containing `.m` files has no data files nearby, it's more likely a toolbox → `software`.

---

## Root Cause 3 — Aggregate Granularity Over-Detection ✅ Fixed

_Already resolved. Removed from open issues._

---

## Root Cause 4 — Group Classification for `.csv` Experiment Sequences

From TODO.txt (paper `0956797615620784` / `0956797616672268`):

```
Aggregate [test/.csv]: 36 files → type=data, group=ex1
Aggregate [textSequences/.csv]: 36 files → type=data, group=ex1
```

These are jsPsych stimulus sequence files — they are software/materials, not data. Because they're classified as `data`, they enter group classification and get assigned `ex1` based on the surrounding folder name (`E1 Materials`). Ground truth is `shared` or `software`.

This combines Roots 1 and 2: the files are software misclassified as data, then group-labeled from context.

**Fix:** The primary fix is Root Cause 2 Sub-pattern A — if these files are correctly classified as `software` they never enter group classification at all. A path-based `Materials` heuristic is not viable: `Materials` is a widely used top-level folder name for legitimate shared data/files and would produce many false positives. The group contamination here is a symptom of the type misclassification, not an independent group-detection bug.

---

## Proposed: Dedicated Aggregate Classification Phase

### Why aggregates need different treatment

| Dimension | Per-file | Aggregate |
|---|---|---|
| Input signal | Full path + filename | Folder path + shared extension + N sampled filenames |
| Error cost | 1 wrong label | 1 wrong label × N files |
| Key question | "What is this file?" | "Is this folder homogeneous? What is it?" |
| Group source | Filename or path | Folder name — often ambiguous (`Materials/E1`, `Analysis_scripts/`) |
| Code vs software | Usually clear | Requires framework detection |

### Prompt architecture

**Do not append aggregate rules to the existing base prompt.** Appending adds noise to non-aggregate calls and forces the LLM to reason about irrelevant output fields (e.g., `mixed_groups`) for every single-file classification. Instead, maintain two separate prompt strings that share a common taxonomy block:

```
prompts.R
├── TAXONOMY_BLOCK         # shared: type definitions, group definitions, enum values
├── STRUCTURE_PROMPT_NEW   # non-aggregate header + TAXONOMY_BLOCK + per-file output schema
└── AGGREGATE_PROMPT       # aggregate header + TAXONOMY_BLOCK + aggregate output schema
```

`STRUCTURE_PROMPT_NEW` and `AGGREGATE_PROMPT` each open with their own instruction header that establishes the task, then both embed the same `TAXONOMY_BLOCK` by reference. The output schemas are different — no shared confusion about what fields to return.

### Phase structure

```
Phase 1   — Individual file classification  → uses STRUCTURE_PROMPT_NEW  (unchanged)
Phase 1A  — Aggregate formation             → detect folders, group by ext (unchanged)
Phase 1B  — Aggregate classification        → uses AGGREGATE_PROMPT       (new)
Phase 1C  — Heterogeneous resolution        → fires only when mixed_groups = TRUE (new)
```

### AGGREGATE_PROMPT — header and extra rules

The header sets context the LLM needs to know upfront before seeing the taxonomy:

```
You are classifying a FOLDER of files, not a single file.
All files share the same extension and parent directory.
Your label applies to every file in the folder — classify the folder as a unit.

Inputs you will receive:
  folder_path  — the directory path
  extension    — shared file extension
  n_files      — total file count
  sampled_names — up to 20 filenames (not full paths)

[TAXONOMY_BLOCK — identical to STRUCTURE_PROMPT_NEW]

Aggregate-specific classification rules:

THIRD-PARTY SOFTWARE vs RESEARCHER CODE
  Ask: were these files written by the researcher for this study, or are they
  part of an external tool, library, or experiment platform that the researcher
  is using?
  - If third-party origin (generic utilities, plugin systems, test harnesses,
    framework internals, files that would be identical across many different
    studies) → type = "software", group = "shared"
  - If researcher-authored for this specific study → type = "code"
  The folder structure is your primary signal: files nested deep inside a
  platform or library directory tree are almost always third-party software.
  This applies to configuration files, scripts, data sequences, and markup
  bundled with the software. It does NOT override media type: image, audio,
  and video files within a software directory are still `asset` — they are
  stimulus materials that happen to be stored alongside the experiment code,
  not software components.

CODE vs SOFTWARE for script aggregates (.R, .py, .m, .js, .html):
  software — reusable library/toolbox/framework, many files, generic utilities,
             third-party origin, package structure
  code     — researcher-written analysis scripts specific to this study

HOMOGENEITY CHECK
  Scan sampled_names for experiment group markers (ex1, ex2, 1a, 1b, 2...).
  If ≥ 2 distinct experiment labels appear: set mixed_groups = TRUE, group = null.
  Otherwise: mixed_groups = FALSE, return group normally.
```

Output schema (aggregate-only):

```json
{
  "type": "code|data|software|...",
  "group": "ex1|shared|null",
  "mixed_groups": false,
  "reasoning": "one sentence"
}
```

### Phase 1C — Heterogeneous aggregate resolution

Fires only when Phase 1B returns `mixed_groups = TRUE`. Applied per-file within the aggregate:

1. **Filename regex** — apply existing experiment-label regex to each filename. No LLM call. Covers most code folders where names are explicit (`Bracketing_1a.R` → `ex1a`).
2. **Per-file LLM fallback** — for files where regex returns no match, route through normal `STRUCTURE_PROMPT_NEW` call. Gated on `!FULL_RUN` cap.
3. **Conservative fallback** — if neither resolves, assign `group = "shared"`.

### What stays the same

- Base type taxonomy — identical in both prompts via shared `TAXONOMY_BLOCK`
- Non-aggregate classification — no changes to `STRUCTURE_PROMPT_NEW` or its call path
- `llm_batch()` infrastructure — Phase 1B still uses it; different prompt string only
- Aggregate formation logic — unchanged

---

## Group Accuracy by File Type

| File type | N files | N papers | Paper-avg group acc | File-pooled group acc |
|---|---|---|---|---|
| asset | 17761 | 49 | 93.6% | 99.0% |
| data | 6814 | 192 | 93.5% | 77.2% |
| software | 1226 | 28 | 87.3% | 91.8% |
| supplemental | 944 | 151 | 93.2% | 88.2% |
| code | 431 | 86 | 93.7% | 87.7% |
| output | 259 | 49 | 91.2% | 92.7% |
| codebook | 179 | 88 | 94.7% | 93.3% |
| readme | 64 | 39 | 97.4% | 96.9% |
| other | 20 | 7 | 100.0% | 100.0% |

**Key observation:** `data` is the only type with a large paper-avg vs file-pooled divergence (93.5% vs 77.2% — a 16 pp gap). Every other type has these two metrics within ~5 pp of each other. This means a small number of large data-heavy papers are responsible for most group errors on data files. The aggregate sentinel group propagation bug (Root Cause 1) is concentrated in these papers — when a sentinel stamps the wrong group across hundreds of data files in one paper, file-pooled accuracy tanks while paper-averaged is only mildly affected (one paper out of 192 moves the average little).

`software` has the lowest paper-avg group accuracy (87.3%), consistent with Root Cause 1: code/script aggregates spanning multiple experiment groups collapse to one group label. This drags per-paper accuracy down even when file counts are small.

All non-data, non-software types cluster between 91–97% paper-averaged, suggesting group classification is reliable once type is correct. The group problem is specifically a data + software issue driven by aggregation, not a fundamental weakness of the group classifier.

---

## Priority Order for Fixes

| Priority | Fix | Expected impact | Effort |
|---|---|---|---|
| ~~1~~ | ~~Raise US3 regex threshold (≥5 matches)~~ | ~~Reduces granularity FPs~~ | ✅ Fixed |
| 1 | Add `js = "software"` to `AGGREGATE_EXT_OVERRIDE` | Removes 96 software→code errors | Very low |
| 2 | Prompt: framework-directory `.txt`/`.html` files → software | Removes ~400 software→data errors; also fixes RC4 group contamination as side effect | Low |
| 3 | Fix C: post-hoc filename group override for aggregate members | Recovers group accuracy for code aggregates | Medium |
| 5 | Dedicated `AGGREGATE_PROMPT` with `mixed_groups` output | Prevents group propagation at root; enables Phase 1C | Medium-high |
