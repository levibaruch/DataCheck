# Research: Software Folder Bulk Detection (040)

## Decision 1: Integration point in pipeline

**Decision**: Insert software folder detection after step 4 (build `rel_paths`) and before step 5 (aggregate detection) in `0_index.R`.

**Rationale**: Stripping software paths from `rel_paths` before step 5 means:
- Aggregate detection never sees software folder contents
- The `too_large` LLM cap check runs on a cleaned path list (software paths already removed)
- LLM calls are never made for software-folder files

**Alternatives considered**:
- After step 5 / before step 6 (LLM): Works but aggregate detection wastes time processing software folders. Rejected.
- Post-LLM correction pass: Files still consume LLM calls. Directly contradicts the feature goal. Rejected.

---

## Decision 2: Folder matching strategy

**Decision**: Case-insensitive exact match on the basename of every directory component in each rel_path. A folder is a "candidate" if any directory segment in its path exactly matches a pattern name.

**Rationale**: The user's example (`site-packages`) can appear at arbitrary depth (e.g. `74kqe/Stimuli_and_Psychopy_Experiment/pythonlibs/psychopy-libraries/Lib/site-packages/`). Matching only the top-level folder would miss this. Matching the basename of any component catches it at any depth.

**Alternatives considered**:
- Top-level folder only: Misses deeply nested software packages. Rejected.
- Substring match: Would match `node_modules` inside `old_node_modules_backup`. False positive risk. Rejected.

---

## Decision 3: File count scope

**Decision**: Count ALL files recursively under a matched folder (i.e., all rel_paths where any ancestor path component matches). Threshold = 500.

**Rationale**: The user confirmed 500 as the threshold. The user's real example (psychopy `site-packages`) has hundreds of files spread across subdirectories — a direct-children-only count would undercount. Recursive count is also consistent with how list.dirs() is already used in the aggregate detection step.

---

## Decision 4: Extension-majority safety gate

**Decision**: Before bulk-labeling a folder, compute the fraction of files whose extension is in the recognized data extension set (csv, tsv, txt, dat, xlsx, xls, sav, dta, sas7bdat, rds, rda, rdata). If the majority (>50%) are data extensions, skip bulk labeling for that folder.

**Rationale**: Prevents false positives on data folders that happen to be named `lib` or similar. Chosen by user (Option B in clarification).

**Data extensions checked** (same set as `read_data_head()` supported formats):
csv, tsv, txt, dat, xlsx, xls, sav, dta, sas7bdat, rds, rda, rdata

---

## Decision 5: Nesting handling

**Decision**: Process matched folders from outermost to innermost. Once a rel_path is claimed by an outer software folder, it is excluded from inner folder counting and labeling.

**Rationale**: Prevents double-counting when a matched folder contains another matched folder (e.g. `Lib/site-packages`). The outermost match wins.

**Implementation note**: Sort candidate folders by path depth (number of `/` separators) ascending, then process greedily. Track claimed paths in a set.

---

## Decision 6: Pattern list (initial)

**Decision**: Default `SOFTWARE_FOLDER_PATTERNS` (case-insensitive exact basename match):

| Pattern | Why included |
|---------|-------------|
| `node_modules` | npm/Node.js packages — thousands of files, zero ambiguity |
| `vendor` | Go/PHP vendor dirs — same |
| `renv` | R environment cache — common in psychology R repos |
| `site-packages` | Python pip installs — seen in real test paper (psychopy repo) |
| `__pycache__` | Python bytecode — unambiguous |
| `venv` | Python virtual env |
| `.venv` | Python virtual env (dotfile variant) |
| `libs` | bundled library collections (e.g. `pythonlibs` would NOT match — exact name only) |
| `lib` | Python/R stdlib copies; included with extension-majority safety gate |
| `dist` | Built distribution output |
| `build` | Build artifacts |

**Excluded** (too risky for false positives even with safety gate):
- `src` — too common as a data/script folder name in psychology repos
- `data` — obviously dangerous
- `scripts` — contains legitimate analysis code

---

## Decision 7: Output representation

**Decision**: Files bulk-labeled by this rule get `type_source = "rule_folder"` in `structure.csv`. This aligns with the existing `type_source` vocabulary (`"llm"`, `"aggregate_llm"`, `"rmd_pair_rule"`) — all are kebab-case strings identifying the classification mechanism.

**type** value: `"software"` (existing type, introduced in feature 029)
**group** value: `NA` (no sub-group classification without LLM; consistent with how classify_by_rules() assigns group for some types)
**aggregate_folder** value: the matched software folder path (mirrors how aggregate_folder is used for aggregate-detected files — gives traceability)

---

## Decision 8: New helper function location

**Decision**: `detect_software_folders(rel_paths, target_dir, threshold, patterns)` goes in `helper.R`, consistent with Principle IV.

**Signature**:
- `rel_paths`: character vector of all file paths relative to paper root
- `target_dir`: absolute path to paper root (for building absolute paths)
- `threshold`: integer, minimum file count to trigger (default `SOFTWARE_FOLDER_THRESHOLD`)
- `patterns`: character vector of folder name patterns (default `SOFTWARE_FOLDER_PATTERNS`)

**Returns**: list with:
- `$software_rel_paths`: character vector of rel_paths claimed as software
- `$software_folder_map`: named character vector mapping each software rel_path to the matched folder that claimed it
- `$clean_rel_paths`: rel_paths not claimed by any software folder

---

## Decision 9: Constants placement

Both new constants live in `0_index.R` alongside existing constants (`AGGREGATE_THRESHOLD`, `LLM_BATCH_SIZE`, etc.):
- `SOFTWARE_FOLDER_THRESHOLD <- 500L`
- `SOFTWARE_FOLDER_PATTERNS <- c("node_modules", "vendor", "renv", "site-packages", "__pycache__", "venv", ".venv", "libs", "lib", "dist", "build")`
