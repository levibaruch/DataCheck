# Data Model: Fix Column Type Detection

## `col_type` (enum)

**Valid values post-feature** (in `VALID_COL_TYPES`, `0_index.R`):
```
continuous, binary, categorical, ordinal, date, id,
text, continuous_comma_decimal, continuous_outliers_excluded,
empty, constant, unknown
```
Change from pre-feature: `constant` added.

---

## `classify_col_type_rules()` — complete rule sequence

Location: `pipeline/helper.R`

| Rule | Trigger | `col_type` | `ambiguous` | `is_numeric` | Notes |
|------|---------|-----------|-------------|--------------|-------|
| 1 | `n_noNA == 0` | `"empty"` | FALSE | FALSE | Unchanged |
| 2 | Name matches ID pattern | `"id"` | FALSE | FALSE | Expanded regex; hard-classify; no LLM |
| 3 | `n_unique == 1` | `"constant"` | FALSE | FALSE | New; only if Rule 2 did not match |
| 4 | `n_unique == 2` | `"binary"` | FALSE | FALSE | Narrowed from `<=2` |
| 5 | ≥70% date-parseable | `"date"` | FALSE | FALSE | Unchanged |
| 6 | Median `nchar > 40` | `"text"` | FALSE | FALSE | Deterministic long-string rule; unchanged |
| 7a | `is.numeric` + any fractional | `"continuous"` | FALSE | FALSE | Unchanged |
| 7 | `is.numeric` + `n_unique > 20` | `"continuous"` | FALSE | FALSE | Unchanged |
| 7 | `is.numeric` + `n_unique` 3–20 | `NA` | TRUE | **TRUE** | → Batch 1 (numeric LLM) |
| 8 | Comma-decimal ≥95% | `"continuous_comma_decimal"` | FALSE | FALSE | Unchanged |
| 8 | Comma-decimal 80–95% | `"continuous_outliers_excluded"` | FALSE | FALSE | Unchanged |
| 9 | *(all remaining character columns)* | `NA` | TRUE | **FALSE** | → Batch 2 (character LLM); **replaces** former rules 9/10 |

Rules 9/10 (former `categorical` / text fallback) are retired.

---

## LLM routing in `run_index()` — two-batch architecture

Location: `pipeline/0_index.R`

```
After classify_col_type_rules() runs on all columns:

  Batch 1 — numeric ambiguous
    Trigger : is.na(col_type) AND is_numeric == TRUE
    Cap     : MAX_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE (existing)
    Prompt  : COLUMN_TYPE_PROMPT
    Samples : up to 10 unique values
    Fallback: unknown + is_numeric → "continuous"
    Invalid : unknown → then numeric fallback; logged

  Batch 2 — character ambiguous
    Trigger : is.na(col_type) AND is_numeric == FALSE
    Cap     : MAX_CHAR_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE (new)
    Prompt  : CHAR_COLUMN_TYPE_PROMPT
    Samples : up to 20 unique values
    Fallback: unknown → "text"; invalid → "text"; logged
```

---

## New constants in `0_index.R`

| Constant | Default | Purpose |
|----------|---------|---------|
| `MAX_CHAR_COL_TYPE_LLM_CALLS` | `3L` | Max LLM calls for character column batch (caps at 90 columns at batch size 30) |

---

## Prompt inventory in `prompts.R`

| Prompt | Batch | Types |
|--------|-------|-------|
| `COLUMN_TYPE_PROMPT` | Numeric (Batch 1) | `continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown` |
| `CHAR_COLUMN_TYPE_PROMPT` | Character (Batch 2) | `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown` |

---

## `sample_values_unique` — per-column string

Populated for ambiguous columns only. Cap is type-dependent:
- `is_numeric == TRUE` (Batch 1): up to 10 unique values
- `is_numeric == FALSE` (Batch 2): up to 20 unique values

Format: `"val1, val2, val3, ..."` — comma-space separated.

---

## Constitution changes required

**File**: `.specify/memory/constitution.md`
**Amendment**: MINOR — version 1.2.0 → 1.3.0
- Add to Principle III resource limits: `MAX_CHAR_COL_TYPE_LLM_CALLS` (default 3)
- Add to constants table row
