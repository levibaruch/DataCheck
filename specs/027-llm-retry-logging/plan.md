# Implementation Plan: LLM Retry and Failure Logging

**Branch**: `027-llm-retry-logging` | **Date**: 2026-03-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/027-llm-retry-logging/spec.md`

## Summary

Add three tightly coupled capabilities to `llm_batch()` in `helper.R`: (1) automatic chunk retries up to a configurable limit before accepting failure, (2) persistent append-only failure logging to `logs/llm_batch_errors.log`, and (3) a `"llm_error"` sentinel value that replaces `"other"` / `"unknown"` fallbacks for irrecoverable failures. Two constants (`LLM_RETRY_LIMIT`, `LLM_ERROR_LOG`) are added near `LLM_BATCH_SIZE` in `0_index.R`. The fallback remapping rules in `0_index.R` and VALID_COL_TYPES guard are updated to leave sentinel rows untouched.

## Technical Context

**Language/Version**: R (base R only — no new packages)
**Primary Dependencies**: `pipeline/helper.R` (`llm_batch()`), `pipeline/0_index.R` (constants + fallback rules), `docs/output-schemas.md`
**Storage**: Append-only plain-text log at `logs/llm_batch_errors.log` (relative to `data_check/` root); auto-created by pipeline if absent
**Testing**: `runners/run_tests.R` → `runners/report_tests.R` (existing test harness)
**Target Platform**: Local filesystem (macOS/Linux)
**Project Type**: CLI pipeline tool (internal — no external API surface)
**Performance Goals**: Retry overhead is bounded: at most `LLM_RETRY_LIMIT + 1` LLM calls per failing chunk; does not affect the per-paper call count caps (caps count chunk submissions, not underlying API calls)
**Constraints**: No new R packages; log directory auto-created; all logic in `helper.R` and `0_index.R`
**Scale/Scope**: Core change is ~30 lines inside `llm_batch()`; 2 new constants in `0_index.R`; 1-line guard updates in `0_index.R`; 1 schema doc update

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I — Crash Resilience | ✅ Pass | Log is append-only, written immediately per failed chunk. Retry failures are durable. |
| II — Paper ID Preservation | ✅ Pass | `paper_id` passed as character parameter to `llm_batch()` for log writing. |
| III — Conservative Resource Limits | ✅ Pass | Retries are within the same chunk slot — they do not add to the chunk count used by the per-paper call cap checks. Retry attempts are bounded by `LLM_RETRY_LIMIT` (default 3). |
| IV — Centralised Helpers | ✅ Pass | All retry and logging logic added to `llm_batch()` in `helper.R`. No duplication. Constants follow the `LLM_BATCH_SIZE` pattern (defined in calling scripts, read by `helper.R`). |
| V — Structured Error Classification | ✅ Pass | `"llm_error"` is a new classification value in output CSVs — it is not a paper-level error code and does not conflict with the `bulk_summary.csv` error code table. |

**No violations. Proceed.**

**Post-design re-check**: Same results. Design adds `"llm_error"` to `VALID_COL_TYPES` so the existing invalid-type remapping guard does not clobber it. Fallback rules already guard on `"unknown"` only — no changes needed there.

## Project Structure

### Documentation (this feature)

```text
specs/027-llm-retry-logging/
├── plan.md              # This file
├── research.md          # Phase 0: design decisions
├── data-model.md        # Phase 1: log entry schema, sentinel, constants
├── quickstart.md        # Phase 1: how to test/exercise the feature
└── tasks.md             # Phase 2 output (/speckit.tasks — not yet generated)
```

### Source Code (files modified)

```text
pipeline/
├── helper.R             # llm_batch() — add retry loop, log write, sentinel on final failure
└── 0_index.R            # 2 new constants (LLM_RETRY_LIMIT, LLM_ERROR_LOG);
                         # add "llm_error" to VALID_COL_TYPES

logs/                    # auto-created by pipeline; .gitignore entry added
└── llm_batch_errors.log # append-only failure log (created at runtime)

docs/
└── output-schemas.md    # add "llm_error" to File Types and Column Types tables
```

**Structure Decision**: No new files in `pipeline/`. All changes are targeted edits to existing files. The `logs/` directory is auto-created at runtime; a `.gitignore` entry ensures it is not committed.

## Complexity Tracking

*No constitution violations — section not required.*
