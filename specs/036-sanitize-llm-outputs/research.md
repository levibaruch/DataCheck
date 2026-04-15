# Phase 0: Research & Analysis

**Feature**: Sanitize LLM Outputs  
**Status**: Complete (no unknowns identified)  
**Created**: 2026-04-15

## Unknowns Identified

None. The feature requirements are fully specified:
- Valid file types: hardcoded enum from `docs/output-schemas.md`
- Valid groups: pattern-based validation (ex<N>, pilot<N>, shared)
- Typo mapping: `"coden"` → `"code"`, `"supplimental"` → `"supplemental"` (extensible)
- Fallbacks: `llm_error` for unmappable types, `shared` for invalid groups
- Logging: existing `logs/llm_batch_errors.log` infrastructure (feature 027)

## Design Decisions

### 1. Validation in Retry Loop (Not Post-LLM Fallback)

**Decision**: Integrate validation into the existing `llm_batch()` retry mechanism (feature 027). If type/group validation fails, mark the batch for retry (up to 4 attempts). Only after all retries fail are rows marked `llm_error`.

**Rationale**:
- Retrying gives the LLM a second chance to correct mistakes (temperature variation may improve output)
- Validation failure is distinguishable from parsing failure; both trigger retry but different log entries
- Preserves data integrity: does not silently accept invalid values (unlike pure fallback approach)
- Transparent to call sites: `llm_batch()` returns validated data; 0_index.R unchanged

**Alternatives Considered**:
- Pure fallback (type → llm_error immediately on invalid): loses recovery opportunity; ~50% of transient LLM errors would be unnecessarily marked llm_error
- Post-processing in 0_index.R: violates principle of centralised helpers; harder to maintain
- Ignore validation (accept invalid values): corrupts data; defeats purpose of feature

### 2. Retry Limit: 3 → 4 Attempts

**Decision**: Increase LLM retry limit from 3 to 4 to accommodate validation failures (parsing failures + validation failures are now both possible).

**Rationale**:
- Feature 027 handles parsing failures with 3 retries; now validation failures also trigger retries
- 4 attempts accommodates both failure modes without overloading the LLM API
- Resource impact is minimal (max 11 calls/paper vs 10; still well within 10 GB constitutional limit)
- Justifiable by data integrity benefit

**Alternatives Considered**:
- Keep 3 retries: insufficient for both parsing + validation failures; many transient errors would fail
- Increase to 5 retries: marginal benefit for increased API burden; overkill

### 3. Typo Mapping: Aids Recovery, Not Fallback

**Decision**: Apply typo mapping *during* validation, before checking if value is valid. Mapping aids recovery, but invalid values still trigger retry (not silent fallback).

**Rationale**:
- `"coden"` → `"code"` mapping allows recovery within same retry attempt (no wasted retry)
- Explicit mapping is maintainable; empirically-driven from error logs
- Mapping is lossy (only handles known typos); unknown errors still retry

**Alternatives Considered**:
- No mapping: miss opportunity for immediate recovery; every typo costs a retry attempt
- Fallback on unmapped (no retry): loses data integrity; invalid values would persist

### 4. Group Validation: Defensive, No Retry

**Decision**: Invalid group values do not trigger retry. Instead, invalid groups are set to `"shared"` during final CSV write (post-retry).

**Rationale**:
- Group assignment is secondary; type is critical for downstream processing
- Invalid group (e.g., `"ex1.5"`) is less likely than invalid type to be a transient error
- `"shared"` is a safe fallback; files are still processed, just marked as non-experiment-specific
- Avoids retry inflation for group validation

**Alternatives Considered**:
- Retry on invalid group: wastes retries; group errors are unlikely to recover
- Reject file on invalid group: loses data; unnecessary harshness

### 5. Logging: Validation Retry Events in Error Log

**Decision**: Log each validation retry attempt to `logs/llm_batch_errors.log` (feature 027 infrastructure).

**Rationale**:
- Consistent with parsing retry events
- Enables post-hoc analysis: which papers had validation failures, which batches recovered on retry
- Atomic append is crash-safe per constitution Principle I
- Developer can refine LLM prompt based on logged failures

**Alternatives Considered**:
- Silent validation: loses diagnostics
- Separate log: violates centralised logging principle

## Implementation Summary

| Component | What | Where |
|-----------|------|-------|
| Data | `TYPO_MAP` lookup table | `pipeline/helper.R` (new) |
| Helpers | `validate_type()`, `is_valid_type()`, `is_valid_group()` | `pipeline/helper.R` (new) |
| Integration | Validation + mapping added to `llm_batch()` retry loop; increase limit 3 → 4 | `pipeline/helper.R` (modify `llm_batch()`) |
| Logging | Append validation retry events to error log | `pipeline/helper.R` (in `llm_batch()`) |
| Call site | No changes; validation is internal to `llm_batch()` | `pipeline/0_index.R` (no changes) |
| Testing | Run existing test suite on papers including 0956797614535937 | `runners/run_tests.R` (no changes) |
| Docs | No schema changes; `llm_error` type already documented | `docs/output-schemas.md` (no changes) |

## Risk Assessment

**Low risk** — Validation is integrated into existing retry mechanism:
- Valid LLM outputs pass through unchanged (no regression)
- Invalid outputs trigger retry (up to 3 additional attempts); only marked `llm_error` after exhaustion
- Typo mapping aids recovery; unknown errors still retry
- Error log enables visibility and debugging
- Falls back to established error types and groups (no new semantics)
- Fully testable on existing test suite
- Resource impact minimal (1 additional LLM call/paper on average)

**Identified edge cases** (all handled):
- Transient LLM error (type invalid on attempt 1, valid on attempt 2): retry recovers ✓
- Consistent LLM error (type invalid on all 4 attempts): marked `llm_error` after retries ✓
- Known typo (e.g., `"coden"`): mapped to `"code"` during validation ✓
- Unknown error (e.g., `"xyz_invalid"`): triggers retry; if still invalid after 4 attempts, marked `llm_error` ✓
- Invalid group: set to `"shared"` during final write (not retried) ✓
- Mixed valid/invalid in batch: only invalid items are subject to retry logic ✓
