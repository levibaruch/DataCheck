# Research: LLM Prompt Refinements

**Feature**: 033-llm-prompt-refinements
**Date**: 2026-04-09

## Summary

No external research required. All decisions are resolved from existing codebase knowledge and GT annotation observations.

## Findings

### Existing `.log` rule coverage

The current `STRUCTURE_PROMPT` already handles `.log` with participant ID → `data`. The gap is `.log` files in experiment data folders that lack a participant ID in their filename (common in PsychoPy and E-Prime when one log file covers a full session). Fix: extend the existing rule with a folder-context signal.

### Intermediate results taxonomy

The current prompt definition for `output` includes "log files, computational byproducts" and the disambiguation section says tabular files with "graph/figure/plot" → `output`. There is no affirmative rule protecting tabular files with "scores/results" names from being pulled into `output`. The LLM's bias toward calling anything result-adjacent an output is well-documented in the error analysis log (`pipeline/prompt_error_analysis.log`). Fix: add an affirmative rule in the hard cases section.

### Pretest vs. pilot

The current `pilot<N>` rule triggers on "pilot", "pre-pilot", "prepilot", "preliminary study". "pretest" is not listed but is a substring of "pre-pilot" — the LLM may be fuzzy-matching it. Explicit exclusion is the correct fix.

### Config file coverage

The current prompt handles `.json` config (→ `other` for `package.json`/`*rc.json`/`*config.json`) and compiled binaries (→ `software`). No rule covers `.yaml`, `.cfg`, `.ini`, `.toml`. These are common in jsPsych, OpenSesame, and PsychoPy experiment configurations. Decision: folder context determines software vs. other vs. code.

### SQL in psychology repos

Verified against corpus: SQL files in downloaded OSF repos are database dumps (REDCap exports, SPSS exports via SQL scripts, SQLite database snapshots). None are query procedures. The override in `AGGREGATE_EXT_OVERRIDE` already flags `sql = "code"` for aggregate sentinels — this will be corrected in feature 034. The prompt rule for Phase 1 files is addressed here.
