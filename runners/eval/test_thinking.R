# test_thinking.R
# Pre-flight check: run full classification on GambleWalker (0956797615620784)
# for each model and write inspectable output to results/eval/test_thinking/.
# Stops with an error if any model fails to classify or produce content.

source("pipeline/prompts.R")
source("pipeline/0_index.R")
source("runners/eval/eval_helpers.R")

TEST_PID    <- "0956797615620784"   # GambleWalker
TEST_SRC    <- "osf"
TEST_OUT    <- file.path(EVAL_RESULTS_DIR, "test_thinking")
REPORT_PATH <- file.path(TEST_OUT, "test_thinking_report.md")

dir.create(TEST_OUT, recursive = TRUE, showWarnings = FALSE)

CHECKS <- list(
  list(model = "groq/llama-3.1-8b-instant",  think = NULL,     label = "llama3.1-8b"),
  list(model = "ollama/gpt-oss:20b-cloud",   think = "low",    label = "gpt-oss-20b-low"),
  list(model = "ollama/gpt-oss:120b-cloud",  think = "medium", label = "gpt-oss-120b-medium"),
  list(model = "ollama/qwen3-vl:235b-cloud", think = TRUE,     label = "qwen3-vl-235b-on")
)

lines   <- character(0)
L  <- function(...) lines <<- c(lines, paste0(...))
BR <- function()    lines <<- c(lines, "")

L("# Thinking Pre-flight Report — GambleWalker (", TEST_PID, ")")
L("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
BR()

gt <- read_gt(TEST_PID, TEST_SRC)

all_ok <- TRUE

for (chk in CHECKS) {
  cat(sprintf("\n── Model: %s | think: %s\n", chk$label, as.character(chk$think %||% "NULL")))

  LLM_MODEL       <<- chk$model
  LLM_TEMPERATURE <<- 0
  LLM_THINK_LEVEL <<- chk$think %||% FALSE
  CAPTURE_THINKING <<- TRUE
  llm_model(LLM_MODEL)

  out_dir <- file.path(TEST_OUT, chk$label)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")

  skipped <- paper_done(out_dir)
  if (skipped) {
    cat("  [SKIP] structure.csv exists — reading existing output\n")
    elapsed <- NA
    result  <- list(success = TRUE)
  } else {
    t0 <- proc.time()[["elapsed"]]
    result <- tryCatch(
      run_index(paper_id = TEST_PID, download = FALSE, output_dir = out_dir),
      error = function(e) { cat(sprintf("  ERROR: %s\n", e$message)); NULL }
    )
    elapsed <- round(proc.time()[["elapsed"]] - t0, 1)
  }

  L("## ", chk$label)
  BR()
  L("**think:** `", as.character(chk$think %||% "NULL"), "`  ",
    "**temp:** 0  ",
    if (!is.na(elapsed)) paste0("**elapsed:** ", elapsed, "s") else "**elapsed:** (skipped)")
  BR()

  if (is.null(result) || !isTRUE(result$success)) {
    cat("  FAILED\n")
    L("**Status:** FAILED")
    BR()
    all_ok <- FALSE
    next
  }

  cat(sprintf("  OK (%.1fs)\n", elapsed))

  # Classification results vs GT
  str_path <- file.path(out_dir, "structure.csv")
  if (file.exists(str_path)) {
    str <- read.csv(str_path, stringsAsFactors = FALSE)
    metrics <- eval_paper(TEST_PID, out_dir, TEST_SRC)

    L("**Status:** OK  |  ",
      "**Files:** ", nrow(str), "  |  ",
      "**macro_f1:** ", if (!is.null(metrics)) sprintf("%.1f%%", metrics$macro_f1) else "n/a", "  |  ",
      "**kappa:** ",    if (!is.null(metrics)) sprintf("%.3f",   metrics$kappa)    else "n/a")
    BR()

    # Classification table
    L("### Classification output")
    BR()
    tbl_cols <- intersect(c("rel_path", "type", "group", "type_source"), names(str))
    if (!is.null(gt)) {
      merged <- merge(gt[, c("rel_path", "type_gt")], str[, tbl_cols],
                      by = "rel_path", all.x = TRUE)
      merged$match <- ifelse(!is.na(merged$type) & merged$type_gt == merged$type, "OK", "DIFF")
      L("| rel_path | type_gt | type | match |")
      L("|---|---|---|---|")
      for (j in seq_len(nrow(merged))) {
        r <- merged[j, ]
        L("| `", r$rel_path, "` | ", r$type_gt, " | ", r$type %||% "—", " | **", r$match, "** |")
      }
    } else {
      L("| rel_path | type | group |")
      L("|---|---|---|")
      for (j in seq_len(nrow(str))) {
        r <- str[j, ]
        L("| `", r$rel_path, "` | ", r$type, " | ", r$group, " |")
      }
    }
    BR()
  }

  # Thinking traces
  thinking_path <- file.path(out_dir, "thinking_traces.csv")
  if (file.exists(thinking_path)) {
    traces <- read.csv(thinking_path, stringsAsFactors = FALSE)
    n_traces <- nrow(traces)
    n_with_thinking <- if ("thinking" %in% names(traces))
      sum(nzchar(trimws(traces$thinking)), na.rm = TRUE) else 0

    cat(sprintf("  Thinking traces: %d calls, %d with trace\n", n_traces, n_with_thinking))
    L("### Thinking traces")
    BR()
    L("**Calls:** ", n_traces, "  |  **With trace:** ", n_with_thinking)
    BR()

    if ("thinking" %in% names(traces) && n_with_thinking > 0) {
      for (j in seq_len(min(n_traces, 3))) {  # show up to 3 traces
        tr <- traces[j, ]
        thinking_text <- tr$thinking %||% ""
        if (is.na(thinking_text)) thinking_text <- ""
        if (!nzchar(trimws(thinking_text))) next
        n_chars <- nchar(thinking_text)
        L("**Trace ", j, "** (", n_chars, " chars, ",
          tr$n_thinking_words %||% "?", " words):")
        BR()
        L("```")
        L(substr(thinking_text, 1, 800))
        if (n_chars > 800) L("... [truncated]")
        L("```")
        BR()
      }
    }
  } else if (!is.null(chk$think) && !isFALSE(chk$think)) {
    L("**WARN:** thinking enabled but no thinking_traces.csv written")
    BR()
  }

  L("---")
  BR()
}

writeLines(lines, REPORT_PATH)
cat(sprintf("\nReport written to: %s\n", REPORT_PATH))

if (!all_ok) stop("Pre-flight thinking test FAILED. Fix errors above before running eval.")
cat("All checks passed.\n")
