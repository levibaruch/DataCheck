# Quickstart: Sanitize LLM Outputs

**For**: Implementation of feature 036  
**Audience**: Developers integrating validation into the existing retry loop  
**Key**: Validation occurs *during* retries, not after

## Architecture: Validation in Retry Loop

Validation is integrated into `llm_batch()` retry mechanism (feature 027), **not** as a separate post-processing step.

```
llm_batch() retry loop (feature 027):
  for attempt in 1:4 {
    response ← LLM call
    
    NEW: Validate & map type/group
    ├─ Apply typo mapping
    ├─ Check if all rows valid
    └─ If valid → return; if invalid & attempts < 4 → retry; if invalid & attempts = 4 → mark llm_error
    
    Log retry event if validation failed
  }
```

## Changes to `llm_batch()` in helper.R

### 1. Add Data: `TYPO_MAP`

```r
TYPO_MAP <- c(
  "coden"        = "code",
  "Code"         = "code",           # case variation
  "supplimental" = "supplemental",
  "supp"         = "supplemental"
  # [Extensible; add more empirically]
)
```

### 2. Add Helper: `validate_type()`

```r
validate_type <- function(type_value, typo_map = TYPO_MAP) {
  # Apply typo mapping if applicable
  if (type_value %in% names(typo_map)) {
    type_value <- typo_map[[type_value]]
  }
  return(type_value)
}
```

**Note**: Returns the value (possibly corrected); caller checks validity.

### 3. Add Helper: `is_valid_type()`

```r
is_valid_type <- function(type_value, valid_types = VALID_FILE_TYPES) {
  type_value %in% valid_types
}
```

### 4. Modify: Retry Loop in `llm_batch()`

In the retry loop (currently handles parsing failures), add validation:

```r
for (attempt in 1:4) {  # Changed from 1:3 to 1:4
  
  # LLM call
  raw_response <- llm_api_call(...)
  
  # Try to parse response
  tryCatch({
    response <- jsonlite::fromJSON(raw_response, ...)
    
    # NEW: Validate & map type values
    response$type <- sapply(response$type, validate_type)
    
    # Check if all rows have valid type
    all_types_valid <- all(sapply(response$type, is_valid_type))
    
    if (!all_types_valid) {
      # Validation failed; trigger retry if attempts remain
      if (attempt < 4) {
        log_event(
          event = "llm_validation_retry",
          paper_id = paper_id,
          attempt = attempt,
          reason = "invalid type or group in response",
          invalid_types = response$type[!sapply(response$type, is_valid_type)],
          raw_response = raw_response
        )
        next  # Continue to next retry attempt
      } else {
        # Last attempt; mark invalid types as llm_error
        response$type[!sapply(response$type, is_valid_type)] <- "llm_error"
        return(response)
      }
    }
    
    # All types valid; set invalid groups to "shared" and return
    response$group[!sapply(response$group, is_valid_group)] <- "shared"
    return(response)
    
  }, error = function(e) {
    # Existing parsing error handling (unchanged)
    # Retry or fail per feature 027 logic
  })
}
```

### 5. Add Helper: `is_valid_group()` (for logging/diagnostics)

```r
is_valid_group <- function(group_value) {
  valid_pattern <- "^(ex|pilot)\\d+\\w?$|^shared$"
  grepl(valid_pattern, group_value, ignore.case = FALSE)
}
```

## Integration Point: No Changes to 0_index.R Call Site

The call to `llm_batch()` in `0_index.R` is unchanged. Validation is transparent:

```r
# Existing code (no changes needed)
structure_parsed <- llm_batch(
  paths = llm_paths,
  batch_size = LLM_BATCH_SIZE,
  paper_id = paper_id,
  stage_name = "file_classification",
  sentinel_cols = NULL
)

# structure_parsed now has validated & mapped type/group values
# Invalid types are marked llm_error
# Invalid groups are set to "shared"
```

## Logging

Add retry events to `logs/llm_batch_errors.log` (existing infrastructure):

```
{timestamp} | {paper_id} | llm_validation_retry | attempt={N} | reason="invalid type or group" | invalid_types={list} | raw_response={response}
```

Use same format as feature 027 parsing retry events.

## Resource Impact

- **LLM Calls**: Max increases from 10 to ~11 per paper (only papers with validation failures retry)
- **Retry Limit**: 3 → 4 (accommodates validation failures)
- **Constitutional Compliance**: Still within resource limits (10 GB download, ~200 max paths)

## Testing Checklist

- [ ] Test paper 0956797614535937: verify `"coden"` triggers retry; successful retry results in `"code"`, not `llm_error`
- [ ] Test with all 4 retries returning invalid values: verify file marked `llm_error` and fully logged
- [ ] Test with mixed valid/invalid in batch: verify only invalid items are revalidated
- [ ] Test typo mapping: `"Code"` → `"code"`, `"supplimental"` → `"supplemental"` all succeed
- [ ] Run full test suite on all 20 papers: no regressions on previously-valid types
- [ ] Verify error log format matches feature 027
- [ ] Verify all retry attempts are logged with raw response

## Files to Modify

1. **`pipeline/helper.R`**: Add `TYPO_MAP`, `validate_type()`, `is_valid_type()`, `is_valid_group()`
2. **`pipeline/helper.R`** (in `llm_batch()` retry loop): Add validation check & retry logic; increase limit 3→4
3. **`logs/llm_batch_errors.log`**: Append validation retry events (existing infrastructure)
4. **`pipeline/0_index.R`**: No changes (call site unchanged; validation is internal to `llm_batch()`)

## No Schema Changes

- No new columns in `structure.csv`
- No new file types or groups
- Uses existing `llm_error` type
- No updates to `docs/output-schemas.md`
