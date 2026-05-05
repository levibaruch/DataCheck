#!/usr/bin/env Rscript
# Quick verification script for Feature 036 validation logic
# Tests TYPO_MAP, validate_type(), is_valid_type(), is_valid_group()
# WITHOUT running the full pipeline

source("pipeline/helper.R")

cat("\n=== Feature 036 Validation Verification ===\n\n")

# Test 1: TYPO_MAP coverage
cat("1. TYPO_MAP contents:\n")
print(TYPO_MAP)
cat("\n")

# Test 2: validate_type() with known inputs
cat("2. validate_type() tests:\n")
test_cases <- list(
  list(input = "code",           expected = "code",           desc = "valid type unchanged"),
  list(input = "coden",          expected = "code",           desc = "typo corrected"),
  list(input = "Code",           expected = "code",           desc = "case variation corrected"),
  list(input = "supplimental",   expected = "supplemental",   desc = "misspelling corrected"),
  list(input = "xyz_invalid",    expected = "xyz_invalid",    desc = "unknown typo unchanged"),
  list(input = NA_character_,    expected = NA_character_,    desc = "NA handled")
)

for (test in test_cases) {
  result <- validate_type(test$input)
  status <- if (identical(result, test$expected)) "✓" else "✗"
  cat(sprintf("  %s %-25s → %s (expected %s)\n", status, test$input, result, test$expected))
}
cat("\n")

# Test 3: is_valid_type() with mapped and unmapped values
cat("3. is_valid_type() tests (post-mapping):\n")
already_valid <- c("code", "data", "asset", "supplemental", "llm_error")
mapped_typos <- c("coden", "Code", "supplimental")
unmapped_invalid <- c("xyz_invalid")

cat("  Already valid (should return TRUE):\n")
for (t in already_valid) {
  mapped <- validate_type(t)
  valid <- is_valid_type(mapped)
  status <- if (valid) "✓" else "✗"
  cat(sprintf("    %s %s → valid=%s\n", status, t, valid))
}

cat("  Typos that map to valid (should return TRUE after mapping):\n")
for (t in mapped_typos) {
  mapped <- validate_type(t)
  valid <- is_valid_type(mapped)
  status <- if (valid) "✓" else "✗"
  cat(sprintf("    %s %s → maps to %s → valid=%s\n", status, t, mapped, valid))
}

cat("  Unmapped invalid (should return FALSE after mapping):\n")
for (t in unmapped_invalid) {
  mapped <- validate_type(t)
  valid <- is_valid_type(mapped)
  status <- if (!valid) "✓" else "✗"
  cat(sprintf("    %s %s → valid=%s\n", status, t, valid))
}
cat("\n")

# Test 4: is_valid_group()
cat("4. is_valid_group() tests:\n")
group_tests <- list(
  list(input = "ex1",        expected = TRUE,  desc = "standard experiment"),
  list(input = "ex2a",       expected = TRUE,  desc = "experiment with letter suffix"),
  list(input = "ex4_a",      expected = TRUE,  desc = "experiment with underscore + letter"),
  list(input = "ex1ab",      expected = TRUE,  desc = "experiment with multi-char suffix"),
  list(input = "pilot1",     expected = TRUE,  desc = "pilot study"),
  list(input = "pilot1a",    expected = TRUE,  desc = "pilot with suffix"),
  list(input = "pilot2_3",   expected = TRUE,  desc = "pilot with multi-char suffix"),
  list(input = "shared",     expected = TRUE,  desc = "shared group"),
  list(input = "ex1.5",      expected = FALSE, desc = "invalid format (dot not word char)"),
  list(input = "other",      expected = FALSE, desc = "not a valid group"),
  list(input = "NA",         expected = FALSE, desc = "string NA (not actual NA)"),
  list(input = NA_character_, expected = FALSE, desc = "actual NA handled")
)

for (test in group_tests) {
  result <- is_valid_group(test$input)
  status <- if (identical(result, test$expected)) "✓" else "✗"
  cat(sprintf("  %s %-20s → %s (expected %s)\n", status, test$input, result, test$expected))
}
cat("\n")

# Test 5: Simulate what happens in llm_batch() with mixed valid/invalid response
cat("5. Simulated llm_batch() scenario (mixed valid/invalid types):\n")
mock_response <- data.frame(
  path = c("file1.csv", "file2.csv", "file3.csv", "file4.csv"),
  type = c("code", "coden", "xyz_invalid", "data"),
  group = c("ex1", "invalid_group", "shared", "ex2a"),
  stringsAsFactors = FALSE
)

cat("  Input (from LLM):\n")
print(mock_response)
cat("\n")

# Apply validation as llm_batch() does
mock_response$type <- vapply(mock_response$type, validate_type, character(1L))
cat("  After typo mapping:\n")
print(mock_response)
cat("\n")

# Check validity
invalid_mask <- !vapply(mock_response$type, is_valid_type, logical(1L))
cat("  Invalid types (would trigger retry):", paste(mock_response$type[invalid_mask], collapse = ", "), "\n")
cat("  Would retry?", any(invalid_mask), "\n\n")

# Group sanitization
invalid_groups <- !vapply(mock_response$group, is_valid_group, logical(1L))
mock_response$group[invalid_groups] <- "shared"
cat("  After group sanitization:\n")
print(mock_response)
cat("\n")

cat("=== Verification Complete ===\n\n")
