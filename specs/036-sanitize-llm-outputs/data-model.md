# Phase 1: Data Model & Design

**Feature**: Sanitize LLM Outputs  
**Status**: Complete  
**Created**: 2026-04-15

## Note on Architecture

This feature integrates validation into the existing LLM retry mechanism (feature 027). It is not a post-processing step; validation occurs *during* the retry loop in `llm_batch()`. If validation fails, the batch is queued for retry (attempts 2-4 available). Typo mapping is applied during validation to aid recovery.

## Data Structures

### Input: LLM Batch Response

**Source**: `llm_batch()` return value in `pipeline/0_index.R`

**Structure**: Data frame, one row per classified file, with columns:
- `path` (character): relative file path
- `type` (character): file type assigned by LLM **[validated by this feature]**
- `group` (character): experiment group assigned by LLM **[validated by this feature]**
- `[other columns]`: pass-through (not validated)

### Processing: Validation Rules

**Validation Scope**: Applied immediately after LLM returns a batch response, before rows are written to `structure.csv`.

#### Rule 1: Type Validation

```
Input: type_value (character)
Output: valid (logical) or invalid (logical)

Logic:
  IF type_value IN valid_types → TRUE (pass)
  ELSE IF type_value IN typo_map → apply mapping, validate mapped value → TRUE (recover)
  ELSE → FALSE (trigger retry)
```

**Valid Types** (closed set):
```
"data", "codebook", "code", "software", "output", "supplemental", "readme", "asset", "other", "llm_error"
```

**Typo Map** (aids recovery during retries):
```r
TYPO_MAP <- c(
  "coden"        = "code",
  "Code"         = "code",           # case variation
  "supplimental" = "supplemental",
  "supp"         = "supplemental",
  # [Add more empirically]
)
```

**Recovery**: If `type_value` maps to a valid type via typo map, apply the mapping and treat as valid (pass, not retry). If mapping produces an invalid type, still retry (rare case).

#### Rule 2: Group Validation

```
Input: group_value (character)
Output: valid (logical) or invalid (logical)

Logic:
  IF group_value matches pattern `^(ex|pilot)\d+\w?$` → TRUE (pass)
  ELSE IF group_value == "shared" → TRUE (pass)
  ELSE → FALSE (mark for fallback during final write, NOT retry)
```

**Valid Group Patterns**:
- `ex<N>` where N is numeric with optional letter suffix (e.g., ex1, ex2a, ex3b)
- `pilot<N>` where N is numeric with optional letter suffix (e.g., pilot1, pilot1a)
- `shared` literal

**Note**: Invalid group does not trigger retry. Instead, invalid group values are set to `"shared"` during final CSV write (post-retry). Type validation is critical; group validation is defensive.

### Retry Loop Integration

```
for (attempt in 1:4) {
  # Call LLM
  response <- llm_api_call(paths_batch, ...)
  
  # NEW: Validate response
  type_valid <- all(response$type %in% c(VALID_TYPES, names(TYPO_MAP)))
  group_valid <- all(response$group %in% VALID_GROUPS)
  
  # Apply typo mapping to aid recovery
  response$type <- sapply(response$type, function(t) {
    if (t %in% names(TYPO_MAP)) TYPO_MAP[[t]] else t
  })
  
  # Check if all rows now have valid type
  if (all(response$type %in% VALID_TYPES)) {
    return(response)  # Success
  }
  
  # If not valid and attempts remain, retry
  if (attempt < 4) {
    log_retry_event(attempt, response, "validation failed")
    continue
  }
  
  # After 4 attempts, mark invalid types as llm_error
  response$type[!(response$type %in% VALID_TYPES)] <- "llm_error"
  return(response)
}
```

## API Contracts

### Validation Helper: `validate_type(type_value, typo_map, valid_types)`

**Purpose**: Validate a single type value and apply typo mapping if applicable.

**Signature**:
```r
validate_type <- function(type_value, typo_map = TYPO_MAP, valid_types = VALID_FILE_TYPES) {
  # Apply typo mapping
  if (type_value %in% names(typo_map)) {
    type_value <- typo_map[[type_value]]
  }
  
  # Return input (possibly mapped)
  return(type_value)
}
```

**Purpose**: This is not a filter or fallback. It applies mapping, then returns the (possibly corrected) value. Validation (is it in valid_types?) is done by the caller.

**Use in retry loop**: 
```r
response$type <- sapply(response$type, validate_type)
is_valid <- all(response$type %in% VALID_FILE_TYPES)
if (!is_valid) {
  # Retry or fail
}
```

### Validation Helper: `validate_group(group_value, valid_pattern)`

**Purpose**: Check if a group value is valid without fallback.

**Signature**:
```r
validate_group <- function(group_value, valid_pattern = "^(ex|pilot)\\d+\\w?$|^shared$") {
  grepl(valid_pattern, group_value, ignore.case = FALSE)
}
```

**Returns** (logical): TRUE if valid, FALSE if invalid.

**Use**: Called only for logging and diagnostics during retry loop. Invalid groups are not retried; they trigger fallback during final write.

### Data: `TYPO_MAP`

**Type**: Named character vector (names = typos, values = canonical types)

**Scope**: Applied during validation *within* the retry loop; not a post-LLM fallback.

**Maintenance**: Review quarterly against `logs/llm_batch_errors.log` for new patterns.

## State Transitions

**Batch Validation States** (during retry loop):

```
LLM Returns
  ↓
Validate & Map
  ├─ All valid → Write to output (success)
  ├─ Some invalid, attempts < 4 → Log retry event, attempt again
  └─ Some invalid, attempts = 4 → Set type to "llm_error", write to output
```

**Per-File State** (in structure.csv output):

- `type = "code"` (or any valid type) → Successfully classified
- `type = "llm_error"` → Failed all 4 attempts; validation error details in error log
- `group = "shared"` → May be fallback if LLM returned invalid group; logged

## Assumptions & Dependencies

- **Assumption**: Retrying the same LLM batch may succeed (e.g., due to temperature variation or model state)
- **Assumption**: Most validation failures are recoverable typos, not fundamental misunderstandings
- **Assumption**: Typo mapping table covers 80%+ of LLM errors
- **Dependency**: Existing `llm_batch()` retry mechanism (feature 027)
- **Dependency**: Constitution allows ~11 max file-classification LLM calls per paper (from current 10)
- **Dependency**: Base R string functions (`grepl`, `sapply`, `%in%`)

## Validation Scope

| Entity | Validation | Scope |
|--------|-----------|-------|
| `type` | Must be in valid_types OR mappable via typo_map | **Critical**: triggers retry |
| `group` | Must match pattern or equal "shared" | **Defensive**: logged, no retry |
| Mapping | Typo map applied during validation | Aids recovery; not fallback |

## No New Entities or Schema Changes

This feature:
- ✅ Uses existing `llm_error` type (no new type added)
- ✅ Adds no new columns to `structure.csv`
- ✅ Leverages existing retry infrastructure
- ✅ Modifies only the validation layer within `llm_batch()`
