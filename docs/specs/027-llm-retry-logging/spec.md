# Feature Specification: LLM Retry and Failure Logging

**Feature Branch**: `027-llm-retry-logging`
**Created**: 2026-03-30
**Status**: Draft

## Overview

The pipeline's LLM classification step currently silences parse failures by substituting a generic fallback value (`"other"` / `"unknown"`) with no record that a failure occurred. This makes bulk-run post-mortems impossible and wastes re-classifiable items. This feature adds three capabilities: persistent failure logging, automatic batch retries, and a dedicated failure sentinel value that distinguishes process errors from legitimate classifications.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Review LLM failures after a bulk run (Priority: P1)

After running the bulk pipeline overnight, the researcher opens a log file and sees exactly which paper IDs, which batch chunks, and what raw LLM output caused classification failures — without needing to re-run anything or search console output.

**Why this priority**: The bulk run is the primary workflow. Without a persistent record, failures are invisible after the session ends. This is the foundational improvement that enables the other two stories.

**Independent Test**: Run the pipeline against a paper whose LLM will return malformed JSON (e.g. by temporarily injecting a bad prompt). Confirm a log entry is written to disk with paper ID, chunk index, and raw response. Deliver value independently of retry or sentinel features.

**Acceptance Scenarios**:

1. **Given** a bulk run encounters a batch chunk where the LLM returns unparseable JSON, **When** the run completes, **Then** a log file exists at a predictable path containing the paper ID, chunk number, timestamp, and raw LLM response for every failed chunk.
2. **Given** a bulk run with zero LLM failures, **When** the run completes, **Then** the log file is either absent or empty — it does not grow spuriously.
3. **Given** multiple bulk runs on different days, **When** both produce failures, **Then** each run's failures are distinguishable (e.g. by timestamp) and earlier entries are not silently overwritten.

---

### User Story 2 — Automatic retry of failed LLM batches (Priority: P2)

When an LLM batch chunk fails to parse, the pipeline automatically retries that chunk up to a configurable maximum number of times before accepting failure. In most cases the retry succeeds and the item is correctly classified without any manual intervention.

**Why this priority**: The user believes most failures are transient formatting issues. Retrying before logging/falling back recovers value silently and reduces log noise. Depends on P1 infrastructure (logging) for full visibility.

**Independent Test**: Inject a failure-then-success pattern into a test batch. Confirm the item is correctly classified on retry and no failure log entry is written for it.

**Acceptance Scenarios**:

1. **Given** a batch chunk fails on first attempt, **When** a retry attempt succeeds, **Then** the items in that chunk receive correct classifications and no failure log entry is written for them.
2. **Given** a batch chunk fails on every attempt up to the retry limit, **When** the final attempt also fails, **Then** all items in that chunk receive the failure sentinel value and the failure is logged.
3. **Given** a retry limit of N (configurable constant), **When** a chunk fails, **Then** the pipeline makes at most N+1 total attempts (1 original + N retries) before giving up.
4. **Given** retries are occurring, **When** viewed from outside, **Then** each retry attempt is noted in the existing console output (a `message()` is sufficient per-retry attempt).

---

### User Story 3 — Sentinel value for unresolvable LLM failures (Priority: P3)

After all retries are exhausted, items that could not be classified receive a distinct value (e.g. `"llm_error"`) rather than `"other"` or `"unknown"`. A researcher can filter output CSVs for this value to find rows that need manual review, and the value is documented in the output schema.

**Why this priority**: Completes the trilogy — without this, the log tells you what failed but the output CSV still silently masks failures with `"other"`. With this, both the log and the output are self-describing.

**Independent Test**: Force a chunk to exhaust all retries. Open the output `structure.csv` or `columns.csv` and confirm affected rows show the sentinel value. Filter for that value and confirm every row was a genuine failure.

**Acceptance Scenarios**:

1. **Given** a batch chunk exhausts all retries, **When** the output CSV is written, **Then** every item in that chunk carries `"llm_error"` (or equivalent sentinel) in the relevant type/col_type column rather than `"other"` or `"unknown"`.
2. **Given** a successfully classified item, **When** the output CSV is written, **Then** its type/col_type column never contains the failure sentinel.
3. **Given** the output schema documentation, **When** a developer reads it, **Then** the failure sentinel value is listed with a description explaining it indicates a process failure requiring investigation.

---

### Edge Cases

- What happens when the LLM service is entirely unreachable (network error, not a parse error)? The retry logic should apply to all error types from `llm_batch`, not just JSON parse failures.
- What if the log directory does not exist at run time? The pipeline must create it automatically rather than crashing.
- What if a batch chunk contains only one item and it fails every retry? The sentinel applies to single-item chunks the same as multi-item ones.
- What if the retry limit is set to 0? The pipeline should behave identically to current behavior (no retries), but logging and sentinel still apply on the first failure.
- What happens to the existing `num_unknown → continuous` and `char_unknown → text` fallback rules that run after `llm_batch`? These should only apply to `"unknown"` values; the new `"llm_error"` sentinel must not be remapped by these rules.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST write a persistent log entry to a file on disk whenever a `llm_batch` chunk fails after all retry attempts, containing: timestamp, paper ID, batch stage name (e.g. "file-type Phase 1", "col_type Batch 2"), chunk index, number of items in the chunk, and the raw LLM response.
- **FR-002**: The log file MUST be written to a configurable path that is consistent across a bulk run (not per-paper), so failures from all papers appear in one place.
- **FR-003**: The pipeline MUST append to the log file (not overwrite), so failures from different papers in the same bulk run accumulate in a single file.
- **FR-004**: The pipeline MUST retry a failed `llm_batch` chunk up to a configurable maximum number of times (default: 3 retries) before recording a failure.
- **FR-005**: The retry limit MUST be controllable via a named constant in the same location as `LLM_BATCH_SIZE`, so it can be changed without hunting through code.
- **FR-006**: After all retries are exhausted, affected items MUST receive a designated failure sentinel value (e.g. `"llm_error"`) rather than `"other"` or `"unknown"` in the output CSV.
- **FR-007**: The failure sentinel value MUST be the same for both file-type classification and column-type classification failures, so a single filter finds all LLM failures in any output file.
- **FR-008**: The existing post-`llm_batch` fallback rules (e.g. `unknown → continuous` for confirmed-numeric columns) MUST NOT remap rows carrying the failure sentinel — sentinel rows must reach the output CSV unchanged.
- **FR-009**: The failure sentinel value MUST be documented in `docs/output-schemas.md` under the relevant enum tables with a description indicating it represents a process error.

### Key Entities

- **LLM failure log**: A flat append-only file recording each unresolved batch chunk failure. Key attributes: timestamp, paper_id, stage name, chunk index, item count, raw response text.
- **Failure sentinel**: A reserved string value used in output CSV type columns to distinguish unresolvable LLM failures from legitimate classifications. Same value across all output files.
- **Retry limit constant**: A named, centrally-defined integer controlling how many times a failed chunk is retried before the sentinel is applied.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After any bulk run that encounters LLM failures, 100% of failed batch chunks are represented in the log file — zero silent failures.
- **SC-002**: In a test scenario where LLM failures are artificially induced, at least 80% of failures that succeed on retry are recovered (classified correctly) without appearing in the failure log.
- **SC-003**: Zero rows carrying the failure sentinel value appear in the output CSVs for a paper where all LLM batches succeed.
- **SC-004**: The failure sentinel value is filterable in a single pass over any output CSV — a researcher can identify all LLM-failed items without knowledge of which paper IDs were affected.
- **SC-005**: The retry limit constant can be changed in one place and the change is respected across all LLM batch stages without code modification elsewhere.

## Assumptions

- The default retry limit of 3 is appropriate. This can be adjusted post-implementation via the constant.
- The log file path defaults to `logs/llm_batch_errors.log` relative to the `data_check/` root. This can be overridden by changing a constant.
- "Retry" means re-sending the identical prompt with the identical items — no prompt modification between retries.
- All error types (JSON parse failure, missing fields, network/service error) are treated equally for retry and logging purposes.
- The failure sentinel string is `"llm_error"`. This does not conflict with any existing valid `type` or `col_type` value.
- Log entries are plain text (one entry per failed chunk), not a structured CSV — readability for post-mortem inspection is the goal.

## Dependencies

- `helper.R` — `llm_batch()` is the sole function requiring modification for retry and logging.
- `0_index.R` — `fallback_vals` arguments passed to `llm_batch()` and downstream fallback rules need updating to use the sentinel.
- `docs/output-schemas.md` — must be updated to document the new sentinel value in the File Types and Column Types enum tables.
- Feature 022 (file-type taxonomy refactor) and Feature 024 (col type detection) — both already merged and define the current enum values that the sentinel must not collide with.
