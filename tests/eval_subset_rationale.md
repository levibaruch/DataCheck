# Evaluation Subset — Rationale

**File:** `tests/eval_papers.csv`  
**Original test set:** `tests/test_papers.csv` (unchanged — used for regression testing)  
**Eval subset:** 28 papers (21 original + 7 additions)

---

## What changed from the original test set

`0956797614536738` was **dropped**. It has 1 GT file total. A single file cannot produce a meaningful F1 score or kappa — it only adds noise to mean metrics without contributing signal.

7 papers were **added** to cover detection systems and file types absent from the original set.

---

## Detection system coverage

The original 22 papers cover `llm`, `aggregate_llm`, and `rmd_pair_rule`. Analysis of `type_source` in pipeline outputs confirmed:

| System | Original set | Eval set |
|---|---|---|
| `llm` | ✓ all papers | ✓ |
| `aggregate_llm` | ✓ 6 papers | ✓ |
| `rmd_pair_rule` | ✓ 1 paper (0956797617739368) | ✓ |
| `rule_folder` | **✗ 0 papers** | ✓ 2 papers added |

The `rule_folder` system bulk-classifies entire folder trees matching known software package naming conventions (`.venv`, `lib`, `node_modules`, etc.) when they exceed 500 files. Without it in the tuning subset, the grid search has no signal for whether a model config handles this path correctly.

---

## Papers added

### rule_folder coverage

**`0956797617737128`** — 408 software / 427 total files  
A repository dominated by a software package dependency tree. At this scale the folder rule fires before any LLM call, meaning performance here is entirely rule-based — but the downstream group and non-software classification still matters.

**`0956797620985832`** — 291 software / 497 total, plus 2 readmes  
Secondary rule_folder case with a more mixed repo (software + other types), testing that the folder rule does not over-fire and swallow non-software files nearby.

---

### raw data format

The original set has raw data in only two papers (0956797614557867: 1 psydat file; 0956797614561045: 49 mat files). Raw format coverage is thin and concentrated. Added:

**`0956797617740646`** — 97 mp4 / 125 total  
Participant video recordings. The clearest possible raw data signal — large count, unambiguous extension, likely individual-level. Tests whether the model correctly labels video files as `data` rather than `asset`.

**`0956797615611933`** — 12 asc / 76 total  
EyeLink eye tracking files (`.asc`). Specialty proprietary format not covered anywhere in the original set. Tests extension-based raw classification on a non-obvious type.

**`0956797619881134`** — 36 mat + nii / 84 total  
MATLAB data files alongside NIfTI neuroimaging files (`.nii`). Best format diversity of all candidates — two distinct raw types in one repo, associated with fMRI data collection.

---

### readme coverage

The original set has readmes in only 5 papers (15 files total), all embedded in larger mixed repos. Added:

**`0956797620904990`** — 8 readmes / 42 total  
Highest readme density of any candidate. Tests whether readme files distributed across a repo are consistently classified rather than falling into `supplemental` or `other`.

**`09567976211055375`** — 8 readmes + 174 raw mat / 191 total  
Double value: readme-rich and raw data. The combination also tests whether the model handles two simultaneously unusual patterns without cross-contamination.

---

## Coverage summary after additions

| Type | Papers | Files |
|---|---|---|
| data | 21 | ~500+ |
| software | 8 | ~800+ (incl. rule_folder) |
| supplemental | 16 | ~241 |
| output | 8 | ~103 |
| code | 11 | ~64 |
| codebook | 11 | ~26 |
| readme | 9 | ~35+ |
| asset | 8 | ~341 |
| other | 3 | ~6 |

`other` remains thin — this is acceptable since it is a fallback category by design. Misclassification into/out of `other` is a low-stakes error and adding papers just to inflate `other` count would distort the tuning signal for more meaningful categories.

---

## Data availability note

All papers must be downloaded to `data/osf/<paper_id>/` before running eval steps. The 7 new papers may not be cached — download them before running `step1_tune.R`.
