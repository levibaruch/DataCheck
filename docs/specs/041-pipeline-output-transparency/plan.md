# Implementation Plan: Pipeline Output Transparency

**Branch**: `041-pipeline-output-transparency` | **Date**: 2026-04-23 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/041-pipeline-output-transparency/spec.md`

## Summary

Improve terminal output clarity across the R pipeline by making changes exclusively inside the pipeline functions (`0_index.R`, `2_codebook_label.R`, `3_psychds_convert.R`, `helper.R`). All runners call these functions — improvements made here apply universally. No changes to runners, CSV schemas, or LLM prompts.

## Technical Context

**Language/Version**: R 4.5 (base R only — no new packages)  
**Primary Dependencies**: `helper.R`, `prompts.R` — both already present; no additions  
**Storage**: CSV files — no schema changes; terminal/console output only  
**Testing**: `runners/run_tests.R` + `runners/report_tests.R`  
**Target Platform**: Local CLI / terminal  
**Project Type**: CLI data pipeline  
**Performance Goals**: No measurable impact — string formatting only  
**Constraints**: No new LLM calls; no new R packages; no CSV column additions; no runner changes

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I — Crash Resilience | ✅ PASS | Output-only changes; no effect on incremental write logic |
| II — Paper ID Preservation | ✅ PASS | No new `read.csv()` calls |
| III — Resource Limits | ✅ PASS | No new LLM calls introduced |
| IV — Centralised Helpers | ✅ PASS | No new shared helpers needed; formatting is local to each function |
| V — Structured Error Codes | ✅ PASS | Plain-language translations wrap existing error codes; CSV output unchanged |
| VI — Source-Aware Storage | ✅ PASS | No path construction changes |

## Architecture Constraint

**All output changes are inside pipeline functions only:**

| Function | File | What it prints |
|----------|------|----------------|
| `run_index()` | `pipeline/0_index.R` | File classification, granularity, column extraction, final index summary |
| `run_codebook_label()` | `pipeline/2_codebook_label.R` | Codebook parsing, coverage summary |
| `convert_psychds()` | `pipeline/3_psychds_convert.R` | Study conversion per-study results |
| `llm_batch()` | `pipeline/helper.R` | LLM progress, retries |

Runners (`run_single.R`, `run_0_index_bulk.R`, etc.) are NOT modified. They call these functions — improvements propagate automatically.

## Project Structure

### Documentation (this feature)

```text
specs/041-pipeline-output-transparency/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── tasks.md
```

### Source Code (files modified)

```text
pipeline/
├── 0_index.R           # US2 (method labels), US4.2 (zero-col explanation),
│                       # US5 (legends) — already partially done
├── 2_codebook_label.R  # US1 (stage verdict), US4.1 (coverage % format)
├── 3_psychds_convert.R # US3.4 (error translation) — already done
└── helper.R            # US3.3 (retry reason) — already done

runners/                # NOT modified
```
