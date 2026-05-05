# Research: Software File Type (029)

**Date**: 2026-04-02  
**Status**: Complete — all unknowns resolved via spec clarification

## Decisions

### 1. Core Distinction: Purpose-Based vs Form-Based

**Decision**: Use purpose as the primary signal — `code` generates analyses/outputs; `software` runs the experiment.

**Rationale**: A PsychoPy `.py` task script is functionally software even though it is source code. Classifying by form (source vs. compiled) would leave it as `code`, which misleads researchers reviewing the pipeline output.

**Alternatives considered**: Extension-only classification (source → `code`, compiled → `software`) — rejected because it misclassifies source-language experiment scripts.

---

### 2. Classification Path for Source Files

**Decision**: For non-aggregate files, the LLM is the only classifier. The LLM already receives full relative paths (e.g., `experiment/run_task.py`), so no additional rule-based folder-heuristic layer is needed. The prompt update is sufficient.

**Rationale**: Adding a keyword-matching rule layer would duplicate the LLM's existing path-context capability and add fragile maintenance surface.

**Alternatives considered**: Rule-based folder signals (`task/`, `paradigm/`, `experiment/`) → rejected as duplicative.

---

### 3. Aggregate Override Map Scope

**Decision**: Only compiled-binary/installer extensions (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`) are added to `AGGREGATE_EXT_OVERRIDE`. Existing source-language entries remain mapped to `"code"`.

**Rationale**: `AGGREGATE_EXT_OVERRIDE` cannot inspect filenames or folder paths — it's extension-only. Adding source extensions to point to `"software"` would over-classify all `.py`, `.R`, etc. files inside aggregates as software, producing worse results than the current `code` default.

**Alternatives considered**: Removing source entries from the map entirely and letting the LLM handle aggregates — rejected as out of scope; deferred to a future feature.

---

### 4. Notebooks

**Decision**: Notebooks (`.ipynb`, `.Rmd`, `.qmd`) are always `code`, never `software`.

**Rationale**: Clean, unambiguous rule. Notebooks are analysis artefacts even when they incidentally present stimuli.

---

### 5. Keyboard Shortcut

**Decision**: Key `"9"` for the new `software` button in the validation GUI.

**Rationale**: Keys 1–8 are already assigned to the existing 8 types. Key 9 is the natural next slot and is visible on a standard keyboard without a mode switch.

---

### 6. Filter Panel

**Decision**: `VALID_TYPES <- unname(TYPE_MAP)` — the filter panel derives directly from `TYPE_MAP`. Adding `"9" = "software"` to `TYPE_MAP` propagates to the filter automatically with no additional code.

---

## Implementation Touchpoints (confirmed)

| File | Location | Change |
|---|---|---|
| `pipeline/prompts.R` | `STRUCTURE_PROMPT` TYPE block + JSON enum + hard-cases section | Add `software` definition and disambiguation rules |
| `pipeline/prompts.R` | `SENTINEL_PROMPT` TYPE block | Add `software` one-liner |
| `pipeline/0_index.R` | `AGGREGATE_EXT_OVERRIDE` constants block (lines 30–41) | Add `.exe`, `.app`, `.jar`, `.msi`, `.dmg` → `"software"` |
| `tools/validation_gui/app.R` | `TYPE_MAP` (line 27) | Add `"9" = "software"` |
| `tools/validation_gui/app.R` | `TYPE_ABBREV` (line 33) | Add `software = "sfw"` |
| `tools/validation_gui/app.R` | CSS light/dark badge + active-button rules | Add 4 CSS rules (amber/brown tone) |
| `tools/validation_gui/app.R` | `observeEvent(input$key_press)` (line 795) | Add `"9"` case |
| `tools/validation_gui/app.R` | JS key allowlist (line 225) | Add `"9"` to array |
| `docs/output-schemas.md` | File Types table | Add `software` row |
