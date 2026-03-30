# Feature Specification: Fix Column Type Detection

**Feature Branch**: `024-fix-col-type-detection`
**Created**: 2026-03-27
**Status**: Draft
**Input**: User description: "the column labelling is idiotic right now. Statistics: binary=42.7%, continuous=30.1%, unknown=10.3%, other=8.8%, categorical=4.3%, text=3.7%, date=0.2%, id=0.0%. The ID type is clearly not working. There are too many unknowns. The binary rate may be inflated."

## Context

Across ~306k classified columns, the current distribution looks broken in at least three ways:

| Problem | Evidence | Likely Cause |
|---------|----------|--------------|
| `id` effectively never fires | Only 4 detections (~0%) | ID name regex too narrow; LLM may override to `continuous` or `categorical` |
| `unknown` too high | 10.3% (~31k columns) | LLM returns "unknown" for columns that are clearly classifiable; no fallback for character columns |
| `binary` likely inflated | 42.7% (~130k) | Rule fires for ≤2 unique non-NA values — catches constant (1-value) columns that should be a distinct type |
| `other` appears in output | 8.8% (~26k) | Not a recognised type — LLM output leaking past validation |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - ID Columns Are Reliably Detected (Priority: P1)

A researcher running the pipeline on a psychology dataset wants participant/subject columns labelled as `id` so downstream analyses can exclude them from statistical summaries.

**Why this priority**: ID columns have zero analytic value yet are currently mislabelled as `continuous` or `categorical`, polluting descriptive statistics and making the distribution of scientifically meaningful column types unreliable.

**Independent Test**: Run the pipeline on a known dataset containing participant ID columns with common naming conventions (`participant_id`, `ResponseId`, `subjectNumber`, `ID`, `sub-01`, etc.). Verify they receive `col_type = "id"`.

**Acceptance Scenarios**:

1. **Given** a column named `participant_id` containing sequential integers, **When** the pipeline classifies it, **Then** `col_type = "id"`.
2. **Given** a column named `ResponseId` containing alphanumeric strings like `R_1a2b3c`, **When** the pipeline classifies it, **Then** `col_type = "id"`.
3. **Given** a column named `Participant` where all values are unique integers, **When** the pipeline classifies it, **Then** `col_type = "id"`.
4. **Given** a column named `age` with values `[21, 23, 25, 22]`, **When** the pipeline classifies it, **Then** `col_type` is NOT `"id"`.
5. **Given** a column named `id` with only 1–2 unique values (single-session experiment), **When** the pipeline classifies it, **Then** `col_type = "id"` not `"binary"`.

---

### User Story 2 - Unknown Rate Is Substantially Reduced (Priority: P1)

A researcher reviewing pipeline output wants near-zero `unknown` classifications — every column should have a best-effort type assignment rather than an unresolvable "don't know".

**Why this priority**: `unknown` at 10.3% means ~31k columns have no assigned meaning. Any downstream analysis that branches on `col_type` silently drops them.

**Independent Test**: Run the full pipeline on a representative sample of 20 papers. Confirm `unknown` drops below 3% of total column count.

**Acceptance Scenarios**:

1. **Given** a numeric column where the LLM returns "unknown", **When** the pipeline finalises the type, **Then** it is reclassified as `continuous` (existing fallback confirmed working — verify it fires consistently).
2. **Given** a character column that was routed to LLM and came back "unknown", **When** the pipeline finalises the type, **Then** it receives a rule-based fallback (`categorical` if ≤10 unique values, `text` otherwise) rather than remaining `"unknown"`.
3. **Given** a column whose LLM call failed or timed out, **When** the pipeline finalises the type, **Then** a rule-based fallback is applied rather than leaving the value as `"unknown"`.

---

### User Story 3 - Constant Columns Are Separated from Binary (Priority: P2)

A researcher using `binary` counts to enumerate condition-indicator columns wants the count to reflect genuine two-option columns only, not degenerate single-value columns.

**Why this priority**: Constant columns (all-same value) are fundamentally different from binary indicators. Merging them inflates `binary` by an unknown amount and hides a data quality signal (constant columns often indicate data entry errors or placeholder columns).

**Independent Test**: Run the pipeline on a dataset containing known constant columns (e.g., a fixed block identifier column). Verify they are not classified as `binary`.

**Acceptance Scenarios**:

1. **Given** a column with exactly 1 unique non-NA value (e.g., all zeros), **When** classified, **Then** `col_type = "constant"`, not `"binary"`.
2. **Given** a column with exactly 2 unique non-NA values (e.g., `[0, 1]`), **When** classified, **Then** `col_type = "binary"`.
3. **Given** a full pipeline run, **When** the `col_type` distribution is inspected, **Then** `binary` rate is lower than the 42.7% baseline and `constant` appears as a populated new type.

---

### User Story 4 - "other" Type Is Eliminated (Priority: P2)

A researcher filtering output CSVs on `col_type` discovers `other` appearing as a value with no documented meaning. It should never appear in outputs.

**Why this priority**: Undocumented type values corrupt any downstream pipeline that switches on `col_type`. 8.8% is a substantial contamination rate.

**Independent Test**: Run the pipeline on a full batch. Confirm zero rows with `col_type = "other"` in any `columns.csv`.

**Acceptance Scenarios**:

1. **Given** an LLM response of `"other"` for any column, **When** the pipeline validates the response, **Then** it is rejected and a fallback type is assigned.
2. **Given** any completed `columns.csv`, **When** the `col_type` column is inspected, **Then** no value of `"other"` appears.

---

### Edge Cases

- Column named `id` with only 1 unique value: should be `id`, not `constant` — name pattern takes precedence.
- Columns with meaningful names like `score` or `rating` but all identical values: `constant`.
- String IDs in BIDS format (`sub-01`, `ses-01`): should be caught by expanded ID patterns.
- Qualtrics export IDs (`ResponseId`, `RecordedDate` — the latter is a date, not an ID): regex must not over-match.
- Columns with all NA plus 1 unique non-NA value where that value is "0" or "1": still `constant` (1 unique non-NA value), not `binary`.
- Large datasets where all rows have unique values in a non-ID column (e.g., a SHA hash): LLM sees samples — should classify as `text` or `id` depending on name.

## Clarifications

### Session 2026-03-28

- Q: When name matches ID pattern, should the column go to LLM or be hard-classified? → A: Hard-classify as `id` directly — no LLM routing. The guard and LLM path for ID-named columns are removed entirely.
- Q: Is FR-005 (character column unknown fallback) still needed after the ID fix? → A: Keep it as a safety net for future rule changes even though no character columns currently reach the LLM.
- Q: Should `COLUMN_TYPE_PROMPT` be narrowed to types the LLM actually classifies? → A: Yes — narrow to `continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown` only; remove `date`, `text`, `constant`, `empty`, etc.
- Q: Should historical `"other"` rows in existing `columns.csv` files be retroactively fixed? → A: No — fix forward only; historical data cleanup is out of scope.

### Session 2026-03-28 (second pass — character column LLM routing)

- Q: How should character `unknown` columns be resolved? → A: Separate LLM call with more sample values (not rule-based hardcoding).
- Q: Which character columns get the second LLM call? → A: All character columns that rules can't deterministically classify — replaces rules 9/10 routing entirely.
- Q: Sample strategy for second LLM call? → A: Up to 20 unique values sampled from the in-memory column; no re-read, no global `N_DATA_READ` change.
- Q: Budget for character column LLM call? → A: Separate cap — new constant `MAX_CHAR_COL_TYPE_LLM_CALLS` independent of `MAX_COL_TYPE_LLM_CALLS`.
- Q: Which types should the character LLM prompt include? → A: New `CHAR_COLUMN_TYPE_PROMPT` with `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown` (`id` retained for edge cases; `continuous` removed).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST classify a column as `id` when its name matches an expanded set of common psychology/survey/BIDS ID naming patterns (must include at minimum: `id`, `ID`, `participant`, `subject`, `subj`, `ResponseId`, `respondent`, `pp`, `ppt`, `pid`, `subjectNumber`, `sub`, `SUBJECTID`, and common variants with underscores/numbers/suffixes).
- **FR-002**: The ID name-pattern rule MUST hard-classify matching columns as `id` directly — no LLM routing. The current "all whole numbers" guard and LLM-routing behaviour for ID-named columns are both removed. Columns whose names match the expanded ID pattern are deterministically classified as `id` regardless of value type.
- **FR-003**: The `COLUMN_TYPE_PROMPT` MUST be narrowed to only the types the LLM needs to resolve: `continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown`. Types handled deterministically by rules (`date`, `text`, `empty`, `constant`, `continuous_comma_decimal`, `continuous_outliers_excluded`) MUST be removed from the prompt to reduce hallucination surface.
- **FR-004**: The pipeline MUST introduce a new `constant` col_type for columns with exactly 1 unique non-NA value, inserted as a rule that fires before the binary rule.
- **FR-005**: Character columns that `classify_col_type_rules()` cannot deterministically classify (i.e., those that would fall through to rules 9/10) MUST be routed to a dedicated second LLM batch call instead of being hard-classified by rules. This replaces the former rule-based `categorical`/`text` fallback entirely.
- **FR-006**: The LLM response validation MUST reject any col_type value not in VALID_COL_TYPES (including `"other"`) and apply a `text` fallback for character columns as a last resort.
- **FR-007**: `constant` MUST be added to VALID_COL_TYPES in `0_index.R` and documented in `docs/output-schemas.md`.
- **FR-008**: Numeric statistics MUST remain suppressed for `constant` columns (same as for `binary`, `categorical`, `ordinal`, `date`, `text`, `empty`, `unknown`).
- **FR-009**: `docs/output-schemas.md` MUST be updated to document the `constant` type and remove any implicit reference to `other` as a valid value.
- **FR-010**: The second LLM batch for character columns MUST use a new `CHAR_COLUMN_TYPE_PROMPT` defined in `prompts.R`. The prompt MUST list exactly these types: `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown`. The `continuous` type MUST be excluded. `id` MUST be retained as an edge-case option.
- **FR-011**: For the character LLM batch, the descriptor MUST sample up to 20 unique non-NA values from the in-memory column (not re-reading the file). The sample count for `sample_values_unique` MUST be increased from 10 to 20 for character-ambiguous columns.
- **FR-012**: A new constant `MAX_CHAR_COL_TYPE_LLM_CALLS` MUST be introduced in `0_index.R` and enforced independently of `MAX_COL_TYPE_LLM_CALLS`. The character batch MUST be truncated to `MAX_CHAR_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE` columns when `FULL_RUN = FALSE`. The constitution (Principle III) MUST be updated to document this new limit.

### Key Entities

- **col_type**: The classification label per column. Valid values post-feature: `continuous`, `binary`, `categorical`, `ordinal`, `date`, `id`, `text`, `continuous_comma_decimal`, `continuous_outliers_excluded`, `empty`, `constant`, `unknown`.
- **classify_col_type_rules()**: Rule-based classifier in `helper.R`. Returns col_type directly (including `id`, `constant`, `binary`, `date`, `text` via long-string rule, comma-decimal types) or signals LLM routing for: (a) integer columns with 3–20 unique values (`is_numeric = TRUE`), or (b) character columns that fall through to where rules 9/10 formerly fired (`is_numeric = FALSE`, new `is_char_ambiguous = TRUE` flag).
- **COLUMN_TYPE_PROMPT**: LLM prompt in `prompts.R`; resolves integer-numeric ambiguous columns. Types: `continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown`.
- **CHAR_COLUMN_TYPE_PROMPT**: New LLM prompt in `prompts.R`; resolves character-ambiguous columns. Types: `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown`. No `continuous`.
- **MAX_CHAR_COL_TYPE_LLM_CALLS**: New constant in `0_index.R`; caps the second (character) LLM batch independently of `MAX_COL_TYPE_LLM_CALLS`.
- **VALID_COL_TYPES**: Allowlist in `0_index.R`; LLM responses outside this list are rejected; character columns fall back to `text` as last resort.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `id` columns account for at least 1% of classified columns in a representative batch (up from ~0%).
- **SC-002**: `unknown` columns drop below 3% of total classified columns (down from 10.3%).
- **SC-003**: `binary` decreases by at least 5 percentage points relative to baseline, with the reduction accounted for by the new `constant` type.
- **SC-004**: Zero rows with `col_type = "other"` appear in any output `columns.csv` after a full pipeline run.
- **SC-005**: A manually verified sample of 50 columns (10 each spanning known IDs, constants, genuine binaries, unknowns, and categorical columns) achieves ≥90% correct classification under the updated rules.

## Assumptions

- The `"other"` values currently in the data are entirely due to unvalidated LLM output leaking through — not a legacy type from an older pipeline version.
- Character columns that were formerly classified by rules 9/10 (few unique values → `categorical`, fallback → `text`) will now go through a dedicated second LLM batch. Rules 9/10 are retired as classification endpoints; the second LLM call replaces them, with `text` as a last-resort fallback only when the LLM returns `unknown`.
- Psychology datasets commonly use ID patterns not currently caught by the regex (e.g., Qualtrics `ResponseId`, BIDS `sub-01`, SPSS exports with `subjectNumber`).
- Introducing `constant` is a purely additive change that will not break downstream code unless that code explicitly enumerates col_type values; any such code must be updated.
- The `"other"` classification in existing output CSVs is historical contamination; this feature fixes it for new runs only. Retroactive cleanup of existing `columns.csv` files is out of scope.
