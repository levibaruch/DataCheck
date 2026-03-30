# Research: Add Output File Type

**Branch**: `026-add-output-file-type` | **Date**: 2026-03-30

---

## Decision 1: How file types flow through the pipeline

**Decision**: File type classification for individual files goes through `classify_by_rules()` (helper.R) → LLM (`STRUCTURE_PROMPT`) for ambiguous cases. Aggregate sentinel files go through `SENTINEL_PROMPT`. There is no `VALID_FILE_TYPES` enum enforced in code — only `VALID_COL_TYPES` is checked. The pipeline routes on `type == "data"` to decide what gets column-extracted; any other type (including a new `output`) is automatically skipped.

**Rationale**: No code changes needed to the routing logic in `0_index.R`. Adding `output` to the LLM prompt is sufficient to produce `output`-typed rows in `structure.csv`; those rows will not match `type == "data"` and will not enter column extraction.

**Alternatives considered**: Adding a `VALID_FILE_TYPES` constant and validation check — unnecessary complexity; no current enforcement exists and the fallback is already handled by LLM prompt design.

---

## Decision 2: Extension rules (`AGGREGATE_EXT_OVERRIDE`) — images

**Decision**: Image extensions (`jpg`, `png`, `svg`, `eps`, etc.) remain in `AGGREGATE_EXT_OVERRIDE` mapped to `"asset"`. No `output` entry is added. Per Q3 clarification, images must always be resolved by LLM semantic context (they can be `output`, `asset`, or `supplemental`); extension alone is insufficient.

**Rationale**: `AGGREGATE_EXT_OVERRIDE` is applied post-sentinel-expansion for unambiguous file kinds. Images are not unambiguous — they have three valid destination types. Leaving image extensions as `asset` in the override maintains existing aggregate behaviour for stimulus image series (common case) without introducing false `output` classifications.

**Alternatives considered**: Removing image extensions from `AGGREGATE_EXT_OVERRIDE` entirely to force LLM resolution in all aggregate cases — deferred as a separate concern; out of scope for this feature.

---

## Decision 3: `.rds` / `.rda` plot objects

**Decision**: `.rds`/`.rda` files remain classified as `data`. The LLM prompt hard-case rule `".rds/.rdata/.rda → data unless filename contains 'plot', 'figure', or 'graph'"` is updated: the destination for the "unless" branch changes from `supplemental` to `output`. Classification of these files will be validated empirically post-implementation (Q4 answer).

**Rationale**: The user chose empirical validation over upfront LLM reclassification. Updating the "unless" branch from `supplemental` → `output` is a minimal, correct change consistent with adding the `output` type; it doesn't change which files are reclassified, only the label they receive.

**Alternatives considered**: Removing the "unless" clause entirely (always `data`) — conservative but loses an existing classification signal; deferred.

---

## Decision 4: HTML files

**Decision**: `.html` files are ambiguous (already in LLM path, not in `AGGREGATE_EXT_OVERRIDE`). The `STRUCTURE_PROMPT` gains a hard-case rule: "`.html` → `output` if it appears to be a rendered notebook (co-located with or sharing a basename with an `.Rmd`/`.qmd`/`.ipynb` script, or located in a script output folder); otherwise `supplemental`."

**Rationale**: HTML is currently classified by the LLM on a case-by-case basis. Adding an explicit rule clarifies the intent and gives the LLM a strong signal. Standalone HTML documents (e.g. supplemental materials submitted as HTML) remain `supplemental`.

---

## Decision 5: Constitution amendment required

**Decision**: The constitution's Technical Standards section states: "LLM MUST classify [plot objects] as `supplemental`". This must be updated to `output` for consistency. This is a **PATCH** amendment (1.3.0 → 1.3.1) — wording updated to reflect the new type; no principle or limit changed.

**Rationale**: Leaving the constitution with the old instruction would make it a source of misinformation for future implementers.

---

## Scope of changes — confirmed

| File | Change | Reason |
|---|---|---|
| `pipeline/prompts.R` — `STRUCTURE_PROMPT` | Add `output` type; update `supplemental`; update hard cases | Primary classification mechanism |
| `pipeline/prompts.R` — `SENTINEL_PROMPT` | Add `output` type; update `supplemental` | Aggregate classification |
| `docs/output-schemas.md` | Add `output` to File Types; narrow `supplemental` | Documentation sync |
| `docs/pipeline.md` | Add `output` to type list | Documentation sync |
| `.specify/memory/constitution.md` | Update plot-object guidance; PATCH bump | Consistency |
| `0_index.R` | None | No routing logic change needed |
| `helper.R` | None | No extension rule change needed |
| `AGGREGATE_EXT_OVERRIDE` | None | Images stay `asset`; no `output` extension rule |
