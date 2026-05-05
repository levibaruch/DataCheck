# Quickstart: Testing LLM Retry and Failure Logging

**Feature**: `027-llm-retry-logging` | **Date**: 2026-03-30

---

## Smoke Test — Story 1 (failure logging)

Inject a bad response by temporarily overriding `llm()` to return malformed JSON:

```r
source("pipeline/helper.R")
source("pipeline/0_index.R")

# Override llm() to always return garbage
assignInNamespace("llm", function(...) list(answer = "NOT JSON AT ALL"), "metacheck")

# Set tiny retry limit to speed up
LLM_RETRY_LIMIT <- 0L
LLM_ERROR_LOG   <- "logs/test_llm_errors.log"

llm_batch(
  paths         = c("file1.csv", "file2.sav"),
  system_prompt = "test",
  user_prefix   = "test",
  key_col       = "path",
  extra_cols    = c("type", "group"),
  fallback_vals = list(type = "other", group = "shared"),
  sentinel_cols = "type",
  paper_id      = "TEST_PAPER_001",
  stage_name    = "smoke-test"
)

# Verify log was written
readLines("logs/test_llm_errors.log")
```

Expected: log file contains one entry with `paper_id=TEST_PAPER_001`, `stage=smoke-test`, `chunk=1`, `n_items=2`.

---

## Smoke Test — Story 2 (retry succeeds)

```r
# Return bad JSON on first call, good JSON on second
call_count <- 0L
assignInNamespace("llm", function(...) {
  call_count <<- call_count + 1L
  if (call_count == 1L) return(list(answer = "NOT JSON"))
  list(answer = '[{"path":"file1.csv","type":"data","group":"shared"}]')
}, "metacheck")

LLM_RETRY_LIMIT <- 3L
LLM_ERROR_LOG   <- "logs/test_llm_errors.log"
if (file.exists(LLM_ERROR_LOG)) file.remove(LLM_ERROR_LOG)

result <- llm_batch(
  paths         = "file1.csv",
  system_prompt = "test",
  user_prefix   = "test",
  key_col       = "path",
  extra_cols    = c("type", "group"),
  fallback_vals = list(type = "other", group = "shared"),
  sentinel_cols = "type",
  paper_id      = "TEST_PAPER_001",
  stage_name    = "smoke-test"
)

stopifnot(result$type == "data")          # correctly classified on retry
stopifnot(!file.exists(LLM_ERROR_LOG))    # no log entry written
```

---

## Smoke Test — Story 3 (sentinel in output)

```r
# Always fail
assignInNamespace("llm", function(...) list(answer = "GARBAGE"), "metacheck")

LLM_RETRY_LIMIT <- 2L
LLM_ERROR_LOG   <- "logs/test_llm_errors.log"
if (file.exists(LLM_ERROR_LOG)) file.remove(LLM_ERROR_LOG)

result <- llm_batch(
  paths         = c("a.csv", "b.sav"),
  system_prompt = "test",
  user_prefix   = "test",
  key_col       = "path",
  extra_cols    = c("type", "group"),
  fallback_vals = list(type = "other", group = "shared"),
  sentinel_cols = "type",
  paper_id      = "TEST_PAPER_002",
  stage_name    = "smoke-test"
)

stopifnot(all(result$type  == "llm_error"))  # sentinel applied
stopifnot(all(result$group == "shared"))     # non-sentinel col unchanged
stopifnot(file.exists(LLM_ERROR_LOG))       # log entry written
```

---

## Running the Full Test Suite

After implementation:

```r
source("runners/run_tests.R")
source("runners/report_tests.R")
```

Review `results/test_report_<date>.md` for regressions.

---

## Verifying Retry Limit = 0 is Backward-Compatible

```r
LLM_RETRY_LIMIT <- 0L
# Should behave identically to pre-feature behavior:
# one attempt, fallback/sentinel on failure, log entry written
```
