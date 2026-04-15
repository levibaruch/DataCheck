# Feature Specification: Sanitize LLM Outputs

**Feature Branch**: `036-sanitize-llm-outputs`  
**Created**: 2026-04-15  
**Status**: Draft  
**Input**: LLM file type classification outputs are not validated, causing invalid values like 'coden' to slip into structure.csv. Validation should integrate into the existing retry mechanism: if type/group are invalid, retry the LLM call. Map common typos during retry to aid recovery. Increase retry limit from 3 to 4 to account for validation failures.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Robust LLM Integration (Priority: P1)

A researcher runs the pipeline on a paper where the LLM returns malformed type/group values (e.g., `"coden"` instead of `"code"`, or an entirely invalid type). The pipeline should automatically retry the problematic batch, and if retries succeed, use the corrected classification. Only after all retries fail does the file get marked `llm_error`.

**Why this priority**: Transient or systematic LLM errors should trigger retry, not silent acceptance. This improves success rate and prevents data corruption.

**Independent Test**: Run pipeline on paper `0956797614535937`; verify that invalid type values trigger retries; confirm that successful retries (e.g., LLM corrects `"coden"` → `"code"` on 2nd attempt) result in correct classification written to `structure.csv`, not `llm_error`.

**Acceptance Scenarios**:

1. **Given** LLM returns `"coden"` on attempt 1, **When** validation fails, **Then** the batch is retried (attempts 2-4 available)
2. **Given** LLM returns invalid type on all 4 attempts, **When** retries are exhausted, **Then** the file is classified as `type = "llm_error"` and logged
3. **Given** LLM returns valid type on attempt 2 (after invalid on attempt 1), **When** validation passes, **Then** the valid type is written to `structure.csv` (no llm_error)
4. **Given** LLM returns `"Code"` (uppercase) on all attempts but mapping rule maps it to `"code"`, **When** mapped value is valid, **Then** the file is classified as `"code"` and written to `structure.csv`

---

### User Story 2 - Diagnostics & Resilience (Priority: P2)

A developer investigates a paper that experienced LLM retries. The logs should clearly show: which batch items triggered retries, what validation errors were encountered, which retries succeeded (and with what values), and which ultimately failed.

**Why this priority**: Transparent retry tracking enables debugging and LLM prompt refinement.

**Independent Test**: Run pipeline on paper with invalid LLM outputs; inspect error log for retry events with: batch index, original value, validation error, retry attempt count, final outcome.

**Acceptance Scenarios**:

1. **Given** a batch with invalid type/group values, **When** validation fails and retries occur, **Then** each retry attempt is logged with: attempt number, raw LLM response, validation error reason
2. **Given** a retry succeeds after N attempts, **When** the file is written to `structure.csv`, **Then** the error log notes "retry succeeded on attempt N" with the corrected value

---

### Edge Cases

- What happens if all 4 retries return invalid values? (File marked `llm_error`; logged with all 4 attempt details)
- What if a typo mapping rule could apply but validation still fails? (Retry again; mapping is not a fallback, only aid for recovery)
- What if LLM returns valid type but invalid group across all retries? (Type is kept; group is set to `"shared"` fallback during final write)
- What if mixed valid/invalid in a batch? (Only invalid items are included in retry; valid items proceed to output)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST validate all LLM-returned `type` values against the closed set: `data`, `codebook`, `code`, `software`, `output`, `supplemental`, `readme`, `asset`, `other`, `llm_error`
- **FR-002**: System MUST validate all LLM-returned `group` values against the pattern: `ex<N>`, `pilot<N>`, or `shared` (where `<N>` is numeric or alphanumeric suffix)
- **FR-003**: System MUST integrate validation into the LLM retry loop: if type/group validation fails, mark the batch item for retry (not an automatic fallback)
- **FR-004**: System MUST increase the LLM retry limit from 3 to 4 attempts to accommodate validation failures
- **FR-005**: System MUST apply a typo mapping table (`"coden"` → `"code"`, `"supplimental"` → `"supplemental"`, etc.) to aid LLM recovery during retries (mapping is applied before the retry is sent)
- **FR-006**: System MUST log each retry attempt with: attempt number, validation error reason, raw LLM response, any applied mappings
- **FR-007**: System MUST classify files as `type = "llm_error"` only after all 4 retries are exhausted with invalid values
- **FR-008**: System MUST set invalid `group` values to `group = "shared"` during final CSV write (not during retries; retries only target type validation)

### Key Entities

- **LLM Batch Response**: Set of file classifications with `type` and `group` fields
- **Validation Check**: Checks type/group against allowed values and patterns
- **Retry Loop**: Existing retry mechanism (feature 027) extended from 3 to 4 attempts
- **Typo Mapping**: Lookup table applied to aid recovery before retrying the batch

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of `structure.csv` rows contain valid file type values (no invalid types in output)
- **SC-002**: 100% of `structure.csv` rows contain valid group values (no invalid groups in output)
- **SC-003**: Retry loop successfully recovers from at least 3 types of LLM errors (e.g., consistent typo, case variation, whitespace)
- **SC-004**: Retry limit of 4 is documented and enforced (LLM calls increased from 10 to 11 max per paper: 5 file-classification batches × 4 retries)
- **SC-005**: All retry attempts are logged; researcher can reconstruct the full retry history for any file
- **SC-006**: Zero regression: test pipeline on existing test papers; all outputs unchanged (only affects previously-invalid rows)

## Assumptions

- Valid types and groups are fixed and defined in `docs/output-schemas.md` (infrequent-change enums per constitution)
- Retry mechanism is effective: same LLM call may succeed on retry (e.g., due to temperature variation or model internal state)
- Typo mapping table covers the most common LLM mistakes; new entries can be added empirically
- Increasing retry limit from 3 to 4 does not exceed constitutional resource limits (max 11 file-classification calls still well within 10 GB download limit and typical paper size)
- Final CSV write can handle `group = "shared"` fallback for initially-invalid groups (no schema changes needed)
