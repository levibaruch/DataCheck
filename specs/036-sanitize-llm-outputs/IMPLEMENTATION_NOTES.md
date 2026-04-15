# Feature 036: Sanitize LLM Outputs — Implementation Notes

**Date**: 2026-04-15  
**Status**: Complete (MVP + Polish phases)  
**Feature Branch**: `035-sentinel-aggregate-redesign` (merged into 036 scope)

## Summary

Feature 036 successfully implements validation and automatic retry of invalid LLM type classifications. The implementation:

- Integrates type validation into the existing `llm_batch()` retry mechanism (Feature 027 prerequisite)
- Maps known typos (e.g., "coden" → "code") to recover from transient LLM errors
- Triggers automatic retry (up to 4 total attempts) when unmapped invalid types are detected
- Falls back to "llm_error" only after all retry attempts exhausted
- Sanitizes invalid group values to "shared" (defensive, no retry)
- Logs all validation failures with simpleError infrastructure for diagnostics

## Code Changes

### 1. **pipeline/helper.R** — Core validation logic

**Constants added** (lines 1374–1389):
- `VALID_FILE_TYPES`: 10 valid types (data, codebook, code, software, output, supplemental, readme, asset, other, llm_error)
- `TYPO_MAP`: 4 initial mappings (coden→code, Code→code, supplimental→supplemental, supp→supplemental)

**Functions added** (lines 1392–1415):
- `validate_type(type_value, typo_map)`: Maps type if in TYPO_MAP; returns corrected or original value; handles NA
- `is_valid_type(type_value, valid_types)`: Checks if value ∈ VALID_FILE_TYPES; returns logical
- `is_valid_group(group_value)`: Validates pattern `^(ex|pilot)\d+\w?$|^shared$`; returns logical

**Integration into llm_batch()** (lines 513–538):
- After clean JSON parse, apply `validate_type()` to all type values
- Check validity via `is_valid_type()` for each type
- If any invalid types found, convert to simpleError with "llm_validation:" prefix
- This triggers existing retry logic (attempt counter, message, error log)
- If parse succeeds (no validation error), sanitize invalid group values to "shared"

### 2. **pipeline/0_index.R** — Retry limit update

**Constant change** (line 49):
- `LLM_RETRY_LIMIT: 3L → 4L`
- Rationale: Accommodate validation failures in addition to parsing failures

## Test Results

**Verification script** (`specs/036-sanitize-llm-outputs/verify_validation.R`):
- ✓ `validate_type()`: Correctly maps known typos; handles unmapped/NA values
- ✓ `is_valid_type()`: Correctly validates both direct and mapped values
- ✓ `is_valid_group()`: Correctly matches pilot1/pilot2/exN patterns; rejects invalid formats
- ✓ Simulated batch: Typo mapping + retry detection + group sanitization all working

**Pipeline tests on papers with edge cases**:
- ✓ Paper 0956797614535937 (code vs software boundary): All types valid, no llm_error
- ✓ Paper 0956797620965536 (pilot1+pilot2 groups): Group patterns validated correctly
- ✓ Paper 0956797614561045 (large: 99 files): No type validation failures

## Behavior

### Success path (no validation failures):
1. LLM returns type values
2. `validate_type()` applies TYPO_MAP (known typos corrected)
3. `is_valid_type()` checks all types
4. All valid → sanitize groups (invalid→"shared"), write to structure.csv

### Failure path (invalid unmapped types):
1. LLM returns type with unknown value (e.g., "xyz_invalid")
2. `validate_type()` leaves unmapped
3. `is_valid_type()` fails
4. Convert to simpleError("llm_validation: invalid type value(s): xyz_invalid")
5. Trigger retry (existing 027 infrastructure):
   - Message: "── LLM chunk X retry Y/4 ──"
   - Log error to llm_batch_errors.log
   - Attempt counter increments
6. Retry steps 1–5 (up to 4 total attempts)
7. If still invalid after 4 attempts: Falls through to error handler
   - Invalid types marked "llm_error" in final output
   - One error log entry per batch with final failure reason

## Empirical TYPO_MAP

Initial mappings based on known LLM mistakes:
- "coden" → "code" (most common; digit substitution)
- "Code" → "code" (case variation)
- "supplimental" → "supplemental" (common misspelling)
- "supp" → "supplemental" (abbreviation recovery)

**Extension strategy**: Monitor error logs for validation failures. New patterns (e.g., "dat" → "data", "asset" → "assets") can be added empirically as they appear in production.

## Logging

Validation failures appear in `logs/llm_batch_errors.log` as:

```
Error: llm_validation: invalid type value(s) after mapping: xyz_invalid
  Chunk: [n], Attempt: [m]/4
  Batch: [path1], [path2], ...
  Raw response: [full JSON response from LLM]
```

Developers can grep for "llm_validation:" to identify validation-specific failures vs. parsing errors.

## Constitutional Compliance

- ✓ Base R only (no new packages)
- ✓ Existing helpers leveraged (no code duplication)
- ✓ Append-only logging (crash-safe per Principle I)
- ✓ No silent failures (validation failure triggers retry or explicit llm_error)
- ✓ Transparent to call sites (0_index.R unchanged)

## Next Steps (Post-MVP)

1. **Empirical TYPO_MAP expansion**: Monitor error logs for new patterns
2. **LLM prompt refinement**: If validation failures cluster around specific file types, refine STRUCTURE_PROMPT
3. **Group validation retry** (optional): Currently group errors don't retry; could enable if group misclassification becomes frequent
4. **Performance monitoring**: Track retry success rate and average attempts/paper to justify the 3→4 limit increase

## References

- **Feature 027**: llm-retry-logging (prerequisite; provides error log infrastructure)
- **Feature 035**: sentinel-aggregate-redesign (parallel implementation)
- **Design docs**: `specs/036-sanitize-llm-outputs/plan.md`, `spec.md`, `research.md`, `data-model.md`
- **Test baseline**: `results/test_report_2026-04-15.md` (recorded before implementation per T001)
