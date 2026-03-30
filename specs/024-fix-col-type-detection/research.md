# Research: Fix Column Type Detection

## Decision 1: `constant` rule placement — before or after ID rule?

**Decision**: `constant` rule fires AFTER the ID name-pattern check. ID name takes precedence.

**Rationale**: The spec edge case "Column named `id` with only 1 unique value → should be `id`, not `constant`" requires ID name precedence.

**Alternatives considered**: Constant rule before ID rule — rejected because it would absorb single-session experiment IDs into `constant`.

---

## Decision 2: ID regex expansion strategy

**Decision**: Comprehensive pattern covering standalone root words (`participant`, `subject`, `subj`, `sub`, `respondent`, `pp`, `ppt`, `pid`), standalone `id`, suffix patterns (`_id`, `_number`, `_nr`, `_no`, `_code`), compound forms (`responseid`, `subjectnumber`, `recordid`, etc.), BIDS `sub-\d+`, and root + numeric suffix (`participant01`, `sub_01`).

**Rationale**: The current pattern misses `ResponseId`, BIDS `sub-01`, `subjectNumber`, standalone `Participant`, etc. Word-boundary matching on root words alone causes false positives (`subject_condition`); the suffix-based approach avoids this.

**Exclusions**: `RecordedDate` does not match (no `recordid` substring). `subject_condition` does not match (no id/number/nr suffix, not a standalone root word).

---

## Decision 3: Remove "all whole numbers" constraint from ID rule

**Decision**: ID rule hard-classifies as `id` directly — no LLM routing, no value-type constraint (clarify session 1).

**Rationale**: FR-002 requires this. Alphanumeric IDs like `R_1a2b3c` are common and currently escape detection. Hard-classifying removes any risk of LLM returning `unknown` for ID-named columns.

---

## Decision 4: Character columns — LLM routing replaces rules 9/10

**Decision**: All character columns not caught by deterministic rules (1–8) route to a dedicated second LLM batch using `CHAR_COLUMN_TYPE_PROMPT` (clarify session 2, Option B).

**Rationale**: Rules 9/10 (hardcode `categorical` for ≤10 unique short values, `text` otherwise) are too blunt. Psychology columns encoded as strings (ordinal scales like "low"/"medium"/"high", condition labels) benefit from LLM judgment. The long-string rule (Rule 6, median `nchar > 40`) stays deterministic — very long strings are unambiguously free text.

**What stays deterministic**: Rule 6 (long strings → `text`), comma-decimal rules (7/8), date rule (5), empty (1), ID (2), constant (3), binary (4).

**Alternatives considered**: Bundle with numeric batch — rejected because character columns need different prompt and more samples; a unified prompt degrades quality for both. Keep rules 9/10 — rejected (user decision).

---

## Decision 5: Sample count for character LLM batch

**Decision**: Up to 20 unique non-NA values sampled from the in-memory column for char-ambiguous columns (vs. 10 for numeric-ambiguous) (clarify session 2, Option B).

**Rationale**: Character columns benefit from more examples to distinguish `categorical` (few consistent labels) from `text` (varied responses) or `ordinal` (ordered labels). `N_DATA_READ = 5` rows remain unchanged — the 20-sample cap draws more unique values from the existing in-memory data without re-reading files.

**Implementation**: In `sample_values_unique` computation, use `cap = if (isTRUE(is_numeric_vec[i])) 10L else 20L`.

---

## Decision 6: Separate resource cap for character LLM batch

**Decision**: New constant `MAX_CHAR_COL_TYPE_LLM_CALLS` (default: 3) independent of `MAX_COL_TYPE_LLM_CALLS = 5` (clarify session 2, Option A).

**Rationale**: Shared budget creates unpredictable truncation depending on column mix. Separate constants make each batch independently auditable. Requires a MINOR constitution amendment (Principle III).

**Default value 3**: Covers 90 character columns per paper at `LLM_BATCH_SIZE = 30`. Psychology datasets with large numbers of string columns are uncommon; 90 covers typical cases without excessive API cost.

---

## Decision 7: `CHAR_COLUMN_TYPE_PROMPT` type list

**Decision**: `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown`. Excludes `continuous` (clarify session 2 — keep `id` for edge cases).

**Rationale**: Character columns cannot be `continuous` (numeric type). `ordinal` is needed for string-encoded ordered scales. `id` is retained for edge cases where alphanumeric identifiers slip through the name-pattern rule.

---

## Decision 8: Invalid-type handling for character batch

**Decision**: Invalid LLM responses for the character batch fall back to `"text"` (not `"unknown"`), then log the remapping. `"unknown"` responses from the LLM also fall back to `"text"`.

**Rationale**: `"text"` is the most conservative safe default for character columns — it's never wrong to call an unclassifiable string column text. Using `"unknown"` as intermediate would require a second fallback step.

---

## Decision 9: Constitution amendment scope

**Decision**: MINOR version bump (1.2.0 → 1.3.0) — new resource limit added to Principle III; no existing limits changed.

**Rationale**: Per constitution versioning policy, adding a new section or material guidance expansion = MINOR. The existing `MAX_COL_TYPE_LLM_CALLS = 5` limit is unchanged.

---

## Files changed (complete list)

| File | Changes |
|------|---------|
| `pipeline/helper.R` | ID rule expanded + hard-classify; constant rule; binary narrowed; rules 9/10 → char-ambiguous routing |
| `pipeline/0_index.R` | `VALID_COL_TYPES` + constant; `MAX_CHAR_COL_TYPE_LLM_CALLS`; 20-sample cap; split LLM batches; invalid-type logging; text fallback for char unknown |
| `pipeline/prompts.R` | `COLUMN_TYPE_PROMPT` narrowed (already done); new `CHAR_COLUMN_TYPE_PROMPT` |
| `docs/output-schemas.md` | `constant` added (already done) |
| `.specify/memory/constitution.md` | Principle III + constants table + version bump |
