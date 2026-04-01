# Data Model: LLM Retry and Failure Logging

**Feature**: `027-llm-retry-logging` | **Date**: 2026-03-30

---

## New Constants

Added to `pipeline/0_index.R` alongside `LLM_BATCH_SIZE`:

| Constant | Default | Type | Purpose |
|---|---|---|---|
| `LLM_RETRY_LIMIT` | `3L` | integer | Max retry attempts per failed chunk (0 = no retries, original behavior) |
| `LLM_ERROR_LOG` | `"logs/llm_batch_errors.log"` | character | Path (relative to `data_check/`) where failure entries are appended |
| `LLM_SENTINEL_VAL` | `"llm_error"` | character | Value written to sentinel_cols on irrecoverable failure |

> `LLM_SENTINEL_VAL` is also used to guard `VALID_COL_TYPES` and must be defined before that vector is constructed.

---

## Modified Function Signature: `llm_batch()`

**File**: `pipeline/helper.R`

```r
llm_batch <- function(paths, system_prompt, user_prefix, key_col, extra_cols,
                      fallback_vals,
                      sentinel_cols = NULL,   # NEW: extra_cols that get LLM_SENTINEL_VAL on final failure
                      paper_id      = NULL,   # NEW: included in log entries; NULL = omit
                      stage_name    = NULL)   # NEW: included in log entries; NULL = omit
```

**Reads from calling environment** (same pattern as `LLM_BATCH_SIZE`):
- `LLM_RETRY_LIMIT` — integer, number of retries before final failure
- `LLM_ERROR_LOG`   — character, log file path
- `LLM_SENTINEL_VAL` — character, sentinel value for `sentinel_cols`

---

## Chunk Processing State Machine

Each chunk now follows this flow:

```
attempt = 1
LOOP:
  call llm() → parse response
  if SUCCESS:
    store result; break loop
  else (parse error):
    if attempt <= LLM_RETRY_LIMIT:
      message("── LLM chunk {i} retry {attempt}/{LLM_RETRY_LIMIT} ──")
      attempt++; continue loop
    else (all retries exhausted):
      build error_fallback (sentinel_cols = LLM_SENTINEL_VAL, others = fallback_vals)
      write_llm_log(paper_id, stage_name, i, chunk_paths, raw_response)
      warning("Chunk {i} failed after {LLM_RETRY_LIMIT} retries: {error}; using sentinel")
      store error_fallback; break loop
```

---

## Log Entry Format

**File**: `logs/llm_batch_errors.log`
**Mode**: Append (`open = "a"`)
**Encoding**: UTF-8

```
[<ISO8601 timestamp>] paper_id=<paper_id> stage=<stage_name> chunk=<i> n_items=<n>
--- system prompt ---
<system_prompt, verbatim>
--- user prompt ---
<chunk_input, verbatim>
--- raw response ---
<raw LLM output, verbatim>
---

```

**Fields**:
- Timestamp: `format(Sys.time(), "%Y-%m-%dT%H:%M:%S")`
- `paper_id`: character value passed to `llm_batch()`; `"<unknown>"` if `NULL`
- `stage`: character value passed to `llm_batch()`; `"<unknown>"` if `NULL`
- `chunk`: integer index of the failed chunk within the current `llm_batch()` call
- `n_items`: length of the chunk

**Example**:
```
[2026-03-30T14:22:01] paper_id=0956797615569001 stage=file-type Phase 1 chunk=3 n_items=20
--- raw response ---
Sure! Here are the classifications:
1. data.csv - this looks like a data file
[... truncated malformed JSON ...]
---

```

---

## Updated VALID_COL_TYPES (0_index.R)

```r
VALID_COL_TYPES <- c("continuous", "binary", "categorical", "ordinal", "date", "id",
                     "text", "continuous_comma_decimal", "continuous_outliers_excluded",
                     "empty", "constant", "unknown",
                     LLM_SENTINEL_VAL)  # NEW: prevents remapping sentinel rows to "unknown"
```

---

## Call Sites in 0_index.R

| Call site | Stage name (for log) | `sentinel_cols` |
|---|---|---|
| File-type Phase 1 (individual paths) | `"file-type Phase 1"` | `"type"` |
| File-type Phase 2 (aggregate sentinels) | `"file-type Phase 2"` | `"type"` |
| Col-type Batch 1 (numeric) | `"col-type Batch 1"` | `"col_type"` |
| Col-type Batch 2 (character) | `"col-type Batch 2"` | `"col_type"` |

> The stage name in the log entry matches the `message()` prefix already present in `0_index.R`.

---

## Schema Updates (docs/output-schemas.md)

### File Types table — new row

| Value | Meaning |
|---|---|
| `llm_error` | LLM batch chunk failed on all retry attempts — classification could not be determined. Indicates a process error; rows should be reviewed manually. |

### Column Types table — new row

| Value | Assigned by | Meaning |
|---|---|---|
| `llm_error` | `llm_batch()` (on retry exhaustion) | LLM batch chunk failed on all retry attempts — column type could not be determined. Indicates a process error; not remapped by any fallback rule. |
