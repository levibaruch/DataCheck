# Data Model: Software Folder Bulk Detection (040)

## New Constants (0_index.R)

### `SOFTWARE_FOLDER_THRESHOLD`
- **Type**: integer
- **Default**: `500L`
- **Purpose**: Minimum file count (recursive) under a matched folder to trigger bulk software labeling
- **Validation**: Must be > 0; warn if set below AGGREGATE_THRESHOLD (would overlap with aggregate logic)

### `SOFTWARE_FOLDER_PATTERNS`
- **Type**: character vector
- **Default**: `c("node_modules", "vendor", "renv", "site-packages", "__pycache__", "venv", ".venv", "libs", "lib", "dist", "build")`
- **Matching rule**: Case-insensitive exact match on directory basename (not substring)
- **Expandable**: New patterns added here only — no other code changes required

---

## Modified: `structure.csv` (outputs/<source>/<id>/structure.csv)

No new columns. Existing columns used as follows for bulk-labeled rows:

| Column | Value for software-folder rows | Notes |
|--------|-------------------------------|-------|
| `type` | `"software"` | Existing type from feature 029 |
| `type_source` | `"rule_folder"` | New value in the `type_source` vocabulary |
| `group` | `NA` | No sub-group classification without LLM |
| `aggregate_folder` | matched folder rel_path | e.g. `"pythonlibs/psychopy-libraries/Lib/site-packages"` — provides audit trail |
| `data_granularity` | `NA` | Not applicable |
| `granularity_source` | `NA` | Not applicable |
| `prompt_nr` | `NA` | No LLM call made |
| `data_format` | `NA` | Not applicable |

All other columns (paper_id, path, rel_path, filename, ext) populated normally from file metadata.

---

## New Helper: `detect_software_folders()` (helper.R)

### Input
| Parameter | Type | Description |
|-----------|------|-------------|
| `rel_paths` | character | All file paths relative to paper download root |
| `target_dir` | character | Absolute path to paper download root |
| `threshold` | integer | Min file count to trigger (caller passes `SOFTWARE_FOLDER_THRESHOLD`) |
| `patterns` | character | Folder name patterns (caller passes `SOFTWARE_FOLDER_PATTERNS`) |

### Output
Named list:
| Field | Type | Description |
|-------|------|-------------|
| `$software_rel_paths` | character | Rel_paths claimed as software (to be removed from LLM pipeline) |
| `$software_folder_map` | named character | Names = rel_path, values = matched folder that claimed it |
| `$clean_rel_paths` | character | Rel_paths NOT claimed by any software folder |

### Internal Logic
1. Enumerate all unique directory components across `rel_paths`
2. Find candidate folders: directories whose basename (lowercased) exactly matches a pattern
3. Sort candidates by depth ascending (fewest `/` segments first) — outermost wins
4. For each candidate folder (outermost-first):
   - Collect unclaimed rel_paths that are under this folder (startsWith prefix)
   - Count collected paths
   - If count < threshold: skip
   - Extension majority check: if >50% of collected paths have data extensions → skip
   - Otherwise: claim all collected paths; record matched folder in map
5. Return the three lists

### Extension majority check
Data extensions (case-insensitive): `csv`, `tsv`, `txt`, `dat`, `xlsx`, `xls`, `sav`, `dta`, `sas7bdat`, `rds`, `rda`, `rdata`

---

## Integration in `0_index.R` — Processing Order Change

```
Step 4:   Build rel_paths  (unchanged)
Step 4.5: [NEW] detect_software_folders() → software_rel_paths, clean_rel_paths
           Log detected folders and file counts
Step 5:   Aggregate detection runs on clean_rel_paths only  (was rel_paths)
Step 6:   LLM classification runs on clean_rel_paths only   (unchanged otherwise)
...
Step 10:  Build file_df — rbind(software_rows_df, llm_rows_df, aggregate_rows_df)
          software_rows_df built from software_rel_paths + software_folder_map
```

### software_rows_df construction
For each rel_path in `$software_rel_paths`:
- `paper_id` = paper_id (from outer scope)
- `path` = file.path(target_dir, rel_path)
- `rel_path` = rel_path
- `filename` = basename(rel_path)
- `ext` = tolower(tools::file_ext(rel_path))
- `type` = "software"
- `type_source` = "rule_folder"
- `group` = NA_character_
- `aggregate_folder` = software_folder_map[rel_path]
- `data_granularity` = NA_character_
- `granularity_source` = NA_character_
- `prompt_nr` = NA_integer_
- `data_format` = NA_character_

---

## State Transitions

```
rel_path (all files)
    │
    ▼
detect_software_folders()
    │
    ├──→ software_rel_paths  →  type="software", type_source="rule_folder"
    │
    └──→ clean_rel_paths
              │
              ├──→ aggregate detection  →  type_source="aggregate_llm"
              │
              └──→ LLM classification  →  type_source="llm"
                        │
                        └──→ post-LLM rules  →  type_source="rmd_pair_rule" (etc.)
```
