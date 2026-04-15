# Implementation Plan: Sanitize LLM Outputs

**Branch**: `036-sanitize-llm-outputs` | **Date**: 2026-04-15 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/036-sanitize-llm-outputs/spec.md`

## Summary

LLM file type classification outputs are not validated, allowing invalid values like `"coden"` to slip through. This feature integrates validation into the existing retry mechanism: when LLM returns invalid type/group, the batch is retried (up to 4 attempts). Typo mapping aids recovery within retries. Only after all retries fail are rows marked `llm_error`. Retry limit increased from 3 to 4 to account for validation failures.

## Technical Context

**Language/Version**: R 4.5 (base R only per constitution.md Principle IV)  
**Primary Dependencies**: Base R + existing packages (`haven`, `readxl`, `jsonlite`, `xml2`, already installed)  
**Storage**: CSV files on local filesystem (`structure.csv`)  
**Testing**: Existing test infrastructure (`runners/run_tests.R` on test papers)  
**Target Platform**: Data pipeline (all papers)  
**Project Type**: Data pipeline / ETL  
**Performance Goals**: Minimal overhead (validation is string lookup; retries reuse existing LLM infrastructure)  
**Constraints**: No new packages; all code base R only; must maintain compatibility with existing pipeline  
**Scale/Scope**: Validation applied to every LLM batch (~30 files per batch); retry limit increased 3→4; max LLM calls per paper increases from 10 to ~11 (1-2 papers may trigger validation retry)  
**Resource Impact**: Max 11 file-classification LLM calls per paper (from 10); still well within constitutional limits

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

✅ **Principle I (Crash Resilience)**: Retries use existing mechanism; error log appends are atomic  
⚠️ **Principle III (Resource Limits)**: Max LLM calls/paper increases from 10 to ~11 (justified: prevents silent data corruption; still well within constitutional limits of 10 GB download and per-paper resource budgets)  
✅ **Principle IV (Centralised Helpers)**: New `validate_type()` and `validate_group()` helpers added to `helper.R`; typo mapping table centralized  
✅ **Principle V (Error Classification)**: Unmappable types → existing `llm_error` type; logged with full retry history  
✅ **No new packages**: Uses only base R string operations; integrates with existing `llm_batch()` retry loop  

**Status**: PASS with Justification — Principle III increase justified by data integrity need; 1 additional LLM call per paper is negligible impact given constitutional slack (max 10 GB download, typical paper 50-200 MB).

## Project Structure

### Documentation (this feature)

```text
specs/036-sanitize-llm-outputs/
├── spec.md              # Feature specification (COMPLETE)
├── plan.md              # This file (COMPLETE)
├── research.md          # Phase 0 output (COMPLETE — no unknowns)
├── data-model.md        # Phase 1 output (minimal — no new entities)
├── quickstart.md        # Phase 1 output (helper API reference)
├── checklists/
│   └── requirements.md  # Specification quality checklist (PASSED)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (modified files)

```text
pipeline/
├── helper.R             # ADD: sanitize_llm_type(), sanitize_llm_group(), typo_mapping table
├── 0_index.R            # MODIFY: call sanitizer immediately after llm_batch() returns
└── prompts.R            # (no changes — sanitization is post-LLM)

logs/
└── llm_batch_errors.log # APPEND: sanitization events logged here (already used by feature 027)

tests/
├── test_papers.csv      # (no changes — use existing test suite)
└── (paper 0956797614535937 becomes regression test case)

docs/
└── output-schemas.md    # (no changes — no new columns/values; existing llm_error type used)
```

**Structure Decision**: Single-point modification pattern. Sanitization occurs in `helper.R` (new helpers) and `0_index.R` (call site after LLM returns). No new files. Leverages existing error logging and test infrastructure.

## Complexity Tracking

No Constitution violations. Feature is orthogonal to existing architecture; sanitizer is a pure data-validation utility with no side effects beyond error logging.

