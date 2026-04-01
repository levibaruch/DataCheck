# Research: LLM Retry and Failure Logging

**Feature**: `027-llm-retry-logging` | **Date**: 2026-03-30

## Design Decisions

---

### 1. Where retry and logging logic lives

**Decision**: All retry and logging logic is added inside `llm_batch()` in `helper.R`.

**Rationale**: `llm_batch()` is already the single site that processes chunks, catches parse errors, and returns fallback rows. Placing retry and logging here keeps the logic co-located with the failure detection, avoids duplicating error handling across the four `llm_batch()` call sites in `0_index.R`, and respects Principle IV (centralised helpers).

**Alternatives considered**:
- _Retry in each call site_: Each of the four `llm_batch()` invocations in `0_index.R` would need a wrapper loop. Violates DRY and Principle IV.
- _Separate `llm_batch_with_retry()` wrapper_: Possible, but adds a redundant indirection layer. The spec says `llm_batch()` is "the sole function requiring modification".

---

### 2. How paper_id and stage_name reach llm_batch()

**Decision**: Add `paper_id = NULL` and `stage_name = NULL` as optional parameters to `llm_batch()`. If both are non-NULL, they are included in log entries. Callers in `0_index.R` pass these explicitly.

**Rationale**: `helper.R` has no ambient context about which paper or pipeline stage is running. Global variables are fragile (they require callers to set them before calling and unset afterward). Explicit parameters are safer and make the call site self-documenting.

**Alternatives considered**:
- _Global variables `LLM_PAPER_ID` / `LLM_STAGE_NAME`_: Works but couples `helper.R` to caller-managed globals. Omitting the log entirely if not set is the right fallback — not crashing.
- _Always require paper_id and stage_name_: Would break `2_codebook_label.R` callers at source and require broader changes.

---

### 3. Sentinel value scope — which columns get "llm_error"

**Decision**: Add a `sentinel_cols` parameter to `llm_batch()` (default `NULL`). On final failure, only the listed `extra_cols` receive `"llm_error"`; other extra columns retain their `fallback_vals`. Callers set `sentinel_cols = "type"` for file-type classification and `sentinel_cols = "col_type"` for column-type classification.

**Rationale**: File-type classification has `extra_cols = c("type", "group")`. Setting `group = "llm_error"` would be semantically wrong — `group` is an experiment label. Only `type` indicates the classification. For column-type classification, there is only one extra column (`col_type`), so `sentinel_cols = "col_type"` covers the full fallback.

**Alternatives considered**:
- _Always set all extra_cols to "llm_error"_: Corrupts the `group` column for file-type failures. Rejected.
- _Hardcode which column gets the sentinel inside llm_batch_: Makes `llm_batch()` aware of domain-specific column names. Rejected — helper should be generic.

---

### 4. Log format

**Decision**: Plain text, one block per failed chunk, appended. Format:

```
[2026-03-30T14:22:01] paper_id=0956797615569001 stage=file-type Phase 1 chunk=3 n_items=20
--- raw response ---
<raw LLM output>
---
```

**Rationale**: The spec explicitly requires plain text for post-mortem readability, not a structured CSV. A clearly delimited block per entry makes `grep` and manual review easy.

**Alternatives considered**:
- _CSV log_: More parseable programmatically, but the spec says plain text. The raw LLM response can contain commas, newlines, and quotes — escaping is painful. Rejected.
- _One line per failure_: Would require escaping newlines in the raw response. Rejected.

---

### 5. Log directory auto-creation

**Decision**: `llm_batch()` calls `dir.create(dirname(LLM_ERROR_LOG), recursive = TRUE, showWarnings = FALSE)` before the first write.

**Rationale**: The spec's edge cases explicitly require "The pipeline must create it automatically rather than crashing." Doing this inside `llm_batch()` means callers never need to pre-create the directory.

**Alternatives considered**:
- _Create at script startup (top of `0_index.R`)_: Requires duplicating the call in `2_codebook_label.R` and any future caller. Rejected.

---

### 6. "llm_error" in VALID_COL_TYPES

**Decision**: Add `"llm_error"` to the `VALID_COL_TYPES` character vector in `0_index.R`.

**Rationale**: After `llm_batch()` returns, `0_index.R` checks returned types against `VALID_COL_TYPES` and remaps invalid values to `"unknown"`. Without adding `"llm_error"` here, sentinel rows would be silently remapped — violating FR-008.

**Note**: The `"unknown" → "continuous"` and `"unknown" → "text"` fallback rules already guard on exact string `"unknown"` — they will not touch `"llm_error"` rows. The only code path that would clobber it is the `VALID_COL_TYPES` guard.

---

### 7. Retry count messaging

**Decision**: Each retry attempt emits a `message()` call: e.g. `"── LLM chunk 3 retry 1/3 ──"`. The original failure message is suppressed on attempts that will be retried; it is only shown (as a warning) when all retries are exhausted.

**Rationale**: The spec (US2 AC4) requires each retry to be noted in console output. Surfacing the raw LLM response on every attempt would be noisy for transient failures that succeed on retry.
