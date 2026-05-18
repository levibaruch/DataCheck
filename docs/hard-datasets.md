# Hard Dataset Index

A curated list of paper IDs with known edge-case properties for regression testing.
All outputs sourced from `_old/outputs_old/` (pre-024 pipeline run).

---

## How to use

```r
source("runners/run_single.R")
run_single("0956797614533802")   # or any ID below
```

Compare new output in `outputs/<paper_id>/` against the reference in `_old/outputs_old/<paper_id>/`.

---

## Categories

### 1. Multilevel / embedded CSV headers

Data files where the first row(s) are metadata notes, not column names. The pipeline must detect and skip these to avoid misclassifying columns.

| paper_id | what makes it hard |
|---|---|
| `0956797614533802` | CSVs with a metadata header row ("Last updated: November 23rd, 2013") above the real column names; 18 `empty` columns, 12 `continuous_outliers_excluded`, filename contains parentheses and spaces |
| `0956797614534695` | Multi-experiment CSV (`Data Expt 1,3,4,5.csv`) with inline notes as column headers; European comma-decimal format throughout (`continuous_comma_decimal`) |

---

### 2. European decimal format (comma decimals)

Numeric data using `,` as decimal separator instead of `.`. Rule-based detection must coerce these before computing stats.

| paper_id | what makes it hard |
|---|---|
| `0956797614533802` | Mix of `continuous_comma_decimal` and `continuous_outliers_excluded` in same file |
| `0956797614534695` | Consistently comma-decimal across all numeric columns; participant IDs also comma-decimal |
| `0956797614535810` | Additional mix with outlier-excluded columns |

---

### 3. Per-participant file structure (one file per subject)

Repos where each participant has their own `.dat` or `.csv` file. Sentinel detection and compression must handle these correctly.

| paper_id | what makes it hard |
|---|---|
| `0956797614547916` | 142 `.dat` files (one per participant × 8 experiments); all columns parse as `text`; filenames encode experimental metadata (e.g. `Exp1_1.dat`) |

---

### 4. Mixed formats — SAV + CSV + DAT from the same study

Same data published in multiple formats. Structure detection must not double-count files or produce duplicate column rows.

| paper_id | what makes it hard |
|---|---|
| `0956797614524581` | 17 data files (`.csv` + `.sav`) across 3 studies + 1 `Codebook.docx`; all groups detected correctly as `ex1`/`ex2`/`ex3` |
| `0956797614559730` | `.sav` + tab-delimited `.dat` files for same dataset (with/without variable labels); `Codebook_Foglio1.csv` correctly classified as `codebook` not `data`; HTML codebook pages as `supplemental` |
| `0956797614543801` | 7 data files + 5 codebook files; multiple coding schemes (manual + LIWC outputs) |

---

### 5. Codebook present alongside data

Tests the pipeline's ability to parse and match codebook labels to data columns.

| paper_id | what makes it hard |
|---|---|
| `0956797614524581` | DOCX codebook with variables spanning 3 experiments; coverage near-complete but `Zdetailsfinal` and `Ztotalfinal` appear as `unmatched_in_data` |
| `0956797614553121` | 10 data files + 6 codebook files; split across languages/populations; several variables `unmatched_in_data` |
| `0956797614559730` | CSV codebook (`Codebook_Foglio1.csv`) in same directory as data; risk of misclassifying it as data |
| `0956797614557867` | 3 data files + 2 codebook files; `id` col_type present in columns |

---

### 6. Massive repos (too_large risk)

Repos with hundreds or thousands of files. Tests `too_large` guard and `is_sentinel` compression logic.

| paper_id | file count | what makes it hard |
|---|---|---|
| `0956797617692107` | ~1,622 data files | Extreme per-trial file structure |
| `0956797615595607` | ~1,355 data files | Neuroscience IAT; `.mat` (MATLAB) + `.RData` + `.csv` mixed; 8,000+ column rows in output |
| `0956797617735745` | ~989 data files | Very deep hierarchy |
| `0956797614561045` | 99 data files + 1 codebook | Large multi-experiment set; still within processing limits |

---

### 7. Participant ID column (`col_type = id`)

Tests LLM and rule-based detection of identifier columns. These should be `id`, not `continuous` or `unknown`.

| paper_id | what makes it hard |
|---|---|
| `0956797614536738` | Numeric sequence columns parsed as `unknown` instead of `id` |
| `0956797614557867` | Alphanumeric participant codes; relies on column-name signal for correct `id` classification |
| `0956797615585115` | `.sav` files with numeric index columns (1–5) at risk of being typed as `ordinal` |

---

### 8. Multi-study repos (multiple experiment groups)

Tests group detection across `ex1`/`ex2`/`ex3`/`shared` etc.

| paper_id | what makes it hard |
|---|---|
| `0956797614524581` | 3 studies, each with CSV + SAV pair; groups correctly split as `ex1`, `ex2`, `ex3` |
| `0956797614533969` | 13 data files across `ex1`–`ex3` and `shared` groups |
| `0956797614523297` | 2 experiment files cleanly in `ex1`/`ex2`; simple baseline for group detection |

---

### 9. Baseline / simple cases

Known-clean papers useful as sanity checks that the pipeline still runs without regression.

| paper_id | what makes it hard |
|---|---|
| `0956797614523297` | 2 clean CSVs, 2 groups, no codebook; should produce only `continuous`/`binary`/`categorical` col_types |
| `0956797614559543` | 2 data files + 1 `readme.txt` codebook; `match_status = matched` for all variables |
| `0956797615620784` | GambleWalker (Wearing a Bicycle Helmet study); 1 CSV + 1 RTF codebook + 1 R script; `ID` column currently classified as `unknown` — good check for `id` col_type rule coverage |

---

### Known-limit: per-participant files below the aggregate threshold

These papers have per-participant data files (clear `individual`-granularity
intent by filename pattern) that the pipeline classifies as `combined`.
Root cause: the containing folder sits **below `AGGREGATE_THRESHOLD`**, so it
is never aggregated and US3's LLM granularity inference never fires. The
fallback US1 filename heuristic (`is_participant_id`, `helper.R:1616`) misses
these because `PARTICIPANT_ID_PATTERNS` covers only a narrow set of prefixes
(`sub`, `subj`, `s`, `p`, `id`, `participant_`, `pp`, `vp` + immediate digits).
Result: `granularity_source = "default_combined"`, prediction = combined,
GT = individual. Together these papers account for ~211 of the remaining
file-pooled `individual → combined` errors in the report.

This is accepted behaviour for now — not a bug to fix in this round. If
revisited, options are: (a) broaden `PARTICIPANT_ID_PATTERNS` to match space
separators, `subject-NNNN`, descriptor-prefix patterns, end-anchored
`-A01`-style suffixes; (b) apply US3-style filename-pattern detection to
non-aggregate folders that contain ≥N files matching a single
`prefix_NUMBER` regex.

| paper_id | n_err | filename example | regex gap |
|---|---|---|---|
| `0956797617713798` | 42 | `Participant 13_positive.doc` | space separator after `Participant` |
| `0956797615611933` | 36 | `ac_1_m1.txt` | short-prefix (initials) + number |
| `09567976211055375` | 32 | `inter_shape_data_00.mat` | descriptive-prefix + number |
| `0956797620943834` | 28 | `CK1.2018-06-18.17_39_26.mat` | initials + digit + dotted date |
| `0956797614564191` | 21 | `ad185_ac184.csv` | letter-pair + digits + `_` + letter-pair + digits |
| `0956797614563958` | 17 | `study 1a-beer reasons_Sheet1.csv` | LLM said `combined` for aggregate (Excel sheet explosion) — ambiguous case |
| `0956797614533969` | 11 | `subject-2294_run1_gain_hrf.txt` | `subject-NNNN` not covered by `^sub\d+` |
| `0956797618761660` | 9 | `coding_1_J.csv` | descriptor + number + initial |
| `0956797615595607` | 8 | `Eval_IAT__V3__InLab1st__ASD.csv` | structured suffix, no numeric subject ID |
| `0956797617735533` | 7 | `Cha-Chong_AvgOrientation_Behavior_Raw Data-A01.csv` | end-anchored `-A01` suffix |

Confirmed not stale-cache artefacts (rerunning `run_index` on each produced
identical predictions, 0 delta).

---

## Quick reference — paper IDs by test priority

```
# Must-run (covers most edge cases)
0956797614533802   # multilevel headers, comma decimals, outlier exclusion
0956797614524581   # multi-format, multi-study, DOCX codebook
0956797614547916   # per-participant .dat files, 142 files
0956797614559730   # mixed .sav/.dat, CSV codebook misclassification risk

# Secondary
0956797614534695   # comma decimals, multi-experiment CSV
0956797614536738   # id col_type detection
0956797614561045   # large repo (99 files), within-limit
0956797614543801   # multiple codebook files

# Baseline
0956797614523297   # simple two-study clean CSV
0956797614559543   # readme codebook, full match
0956797615620784   # GambleWalker: 1 CSV + RTF codebook; ID column currently unknown
```
