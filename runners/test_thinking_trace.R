# test_thinking_trace.R
# ─────────────────────────────────────────────────────────────────────────────
# Verify thinking traces by sending the full 18-file GT batch in one call,
# mirroring real pipeline behavior.  For each setting (think level / temp):
#   - captures the reasoning trace from message.thinking
#   - scores the JSON answer against ground truth
#   - prints thinking trace + per-file predictions side by side
#
# Section 1 — think sweep  (fixed temp)
# Section 2 — temperature sweep  (fixed think=low)
#
# Usage:  source("data_check/runners/test_thinking_trace.R")
# ─────────────────────────────────────────────────────────────────────────────

library(metacheck)
source("data_check/pipeline/helper.R")
source("data_check/pipeline/prompts.R")

llm_use(TRUE)
llm_max_calls(200)

OLLAMA_MODEL <- "ollama/gpt-oss:20b-cloud"
llm_model(OLLAMA_MODEL)

THINK_LEVELS <- list(NULL, "low", "medium", "high")
TEMPERATURES <- c(0.0, 0.3, 0.7, 1.0)

SWEEP_TEMP  <- 0.3
SWEEP_THINK <- "low"

# ── Ground truth (same 18 items as test_llm_params.R) ─────────────────────────

GT <- data.frame(
  path = c(
    "data/participants_study1.sav",
    "scripts/analysis_main.R",
    "docs/variable_codebook.pdf",
    "README.md",
    "figures/results_fig2_scatter.png",
    "stimuli/Stroop_word_red.jpg",
    "study_documents/consent_form_signed_v2.docx",
    "Experiment 2/data/study2_questionnaire_responses.xlsx",
    "admin/IRB_approval_2022.pdf",
    "output/regression_notebook_rendered.html",
    "coding_manual.xlsx",
    "bfi10_items_and_scoring_key.csv",
    "tables/t_test_results_full_sample.csv",
    "Supplementary Materials/Table_S3_participant_demographics.csv",
    "Study 1/open_ended_responses_wave2.csv",
    "merge_diagnostics_run3.log",
    "Experiment 1/effect_sizes_cohens_d.csv",
    "eprime_raw/subject_042_task_B.edat2"
  ),
  type_gt = c(
    "data", "code", "codebook", "readme", "output",
    "asset", "supplemental", "data", "supplemental", "output",
    "codebook", "codebook", "output", "supplemental", "data",
    "output", "output", "data"
  ),
  difficulty = c(rep("easy", 5), rep("medium", 5), rep("hard", 8)),
  stringsAsFactors = FALSE
)

SYSTEM_PROMPT  <- STRUCTURE_PROMPT
PROMPT_BODY    <- paste(seq_len(nrow(GT)), GT$path, sep = ". ", collapse = "\n")

# ── Core call ─────────────────────────────────────────────────────────────────
# Sends the full 18-path batch in one /api/chat call and returns both
# the thinking trace and the JSON answer.

call_batch <- function(think_level, temperature,
                       base_url = "http://localhost:11434") {
  ollama_model <- sub("^ollama/", "", OLLAMA_MODEL)

  body <- list(
    model    = ollama_model,
    messages = list(
      list(role = "system", content = SYSTEM_PROMPT),
      list(role = "user",   content = PROMPT_BODY)
    ),
    stream  = FALSE,
    options = list(temperature = temperature)
  )
  if (!is.null(think_level)) body$think <- think_level

  t0 <- proc.time()[["elapsed"]]
  resp <- tryCatch(
    request(paste0(base_url, "/api/chat")) |>
      req_body_json(body) |>
      req_timeout(600) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(),
    error = function(e) stop(sprintf("Request failed: %s", e$message))
  )
  elapsed <- round(proc.time()[["elapsed"]] - t0, 1)

  if (resp_status(resp) >= 400) {
    err <- tryCatch(resp_body_string(resp), error = \(e) "<unreadable>")
    return(list(thinking = NULL, answer = NULL, elapsed = elapsed,
                error = sprintf("HTTP %d: %s", resp_status(resp), err)))
  }

  parsed <- resp_body_json(resp)
  list(
    thinking = parsed$message$thinking,
    answer   = parsed$message$content,
    elapsed  = elapsed,
    error    = NULL
  )
}

# ── Scoring ───────────────────────────────────────────────────────────────────

parse_and_score <- function(raw_answer) {
  if (is.null(raw_answer) || is.na(raw_answer)) return(NULL)
  tryCatch({
    parsed <- jsonlite::fromJSON(extract_json(raw_answer), flatten = TRUE)
    if (!is.data.frame(parsed) || !all(c("path", "type") %in% names(parsed)))
      return(NULL)

    merged <- merge(GT, parsed[, c("path", "type")], by = "path", all.x = TRUE)
    merged$pred <- ifelse(is.na(merged$type), "MISSING", merged$type)
    merged$ok   <- merged$pred == merged$type_gt

    list(
      merged      = merged,
      n_correct   = sum(merged$ok),
      n_total     = nrow(merged),
      n_path_miss = sum(merged$pred == "MISSING"),
      easy_acc    = mean(merged$ok[merged$difficulty == "easy"]),
      medium_acc  = mean(merged$ok[merged$difficulty == "medium"]),
      hard_acc    = mean(merged$ok[merged$difficulty == "hard"])
    )
  }, error = function(e) NULL)
}

frac <- function(n, d) sprintf("%d/%d", as.integer(round(n * d)), as.integer(d))
pct  <- function(x) sprintf("%3.0f%%", x * 100)
wc   <- function(txt) {
  if (is.null(txt) || !nzchar(trimws(as.character(txt)))) return(0L)
  length(strsplit(trimws(txt), "\\s+")[[1]])
}

# ── Display ───────────────────────────────────────────────────────────────────

# Print thinking trace — full text, wrapped at 90 chars.
# Prints the whole thing; no truncation. That's the point of this script.
print_thinking <- function(thinking) {
  if (is.null(thinking) || !nzchar(trimws(thinking))) {
    cat("  ┌─ THINKING ── ABSENT ──────────────────────────────────────────────\n")
    cat("  │  (model did not emit a thinking field)\n")
    cat("  └───────────────────────────────────────────────────────────────────\n\n")
    return(invisible(NULL))
  }
  txt <- trimws(thinking)
  cat(sprintf("  ┌─ THINKING ── %d words / %d chars ─────────────────────────────────\n",
              wc(txt), nchar(txt)))
  lines <- unlist(strsplit(txt, "\n", fixed = TRUE))
  for (ln in lines) {
    repeat {
      cat(sprintf("  │  %s\n", substr(ln, 1L, 90L)))
      if (nchar(ln) <= 90L) break
      ln <- substr(ln, 91L, nchar(ln))
    }
  }
  cat("  └───────────────────────────────────────────────────────────────────\n\n")
}

# Print per-file prediction table with GT comparison.
print_predictions <- function(sc) {
  if (is.null(sc)) {
    cat("  [predictions] PARSE FAILED — no valid JSON returned\n\n")
    return(invisible(NULL))
  }
  m <- sc$merged
  cat(sprintf("  ┌─ PREDICTIONS ── %d/%d correct ────────────────────────────────────\n",
              sc$n_correct, sc$n_total))
  cat(sprintf("  │  %-50s  %-12s  %-12s  %s\n",
              "path", "predicted", "GT", "ok?"))
  cat(sprintf("  │  %s\n", paste(rep("-", 90), collapse = "")))
  for (i in seq_len(nrow(m))) {
    marker <- if (isTRUE(m$ok[i])) "  " else "✗ "
    cat(sprintf("  │  %s%-50s  %-12s  %-12s\n",
                marker,
                substr(m$path[i], 1L, 50L),
                m$pred[i], m$type_gt[i]))
  }
  cat(sprintf("  │\n  │  easy=%s  medium=%s  hard=%s\n",
              pct(sc$easy_acc), pct(sc$medium_acc), pct(sc$hard_acc)))
  cat("  └───────────────────────────────────────────────────────────────────\n\n")
}

divider  <- paste(rep("─", 72), collapse = "")
divider2 <- paste(rep("═", 72), collapse = "")

# ── Section 1: Think sweep ────────────────────────────────────────────────────

cat(sprintf("\n%s\n  SECTION 1 — Think level sweep\n  model=%s  temp=%.1f  files=%d\n%s\n",
            divider2, OLLAMA_MODEL, SWEEP_TEMP, nrow(GT), divider2))

s1 <- list()

for (think_val in THINK_LEVELS) {
  lbl <- if (is.null(think_val)) "NULL" else think_val
  cat(sprintf("\n%s\n  think = %s\n%s\n\n", divider, lbl, divider))

  out <- call_batch(think_level = think_val, temperature = SWEEP_TEMP)

  if (!is.null(out$error)) {
    cat(sprintf("  ERROR: %s\n", out$error))
    s1[[lbl]] <- list(out = out, sc = NULL)
    next
  }

  cat(sprintf("  elapsed: %.1fs\n\n", out$elapsed))
  print_thinking(out$thinking)

  sc <- parse_and_score(out$answer)
  print_predictions(sc)

  s1[[lbl]] <- list(out = out, sc = sc)
}

# Section 1 summary
cat(sprintf("\n%s\n  SECTION 1 SUMMARY  (temp=%.1f)\n%s\n", divider2, SWEEP_TEMP, divider2))
cat(sprintf("  %-8s  %8s  %13s  %13s  %8s  %8s  %8s  %8s\n",
            "think", "elapsed", "think_words", "answer_words",
            "all", "easy", "medium", "hard"))
cat(sprintf("  %s\n", paste(rep("-", 82), collapse = "")))

for (lbl in names(s1)) {
  r  <- s1[[lbl]]
  sc <- r$sc
  if (!is.null(r$out$error)) { cat(sprintf("  %-8s  ERROR\n", lbl)); next }
  cat(sprintf("  %-8s  %7.1fs  %13d  %13d  %8s  %8s  %8s  %8s\n",
              lbl, r$out$elapsed,
              wc(r$out$thinking), wc(r$out$answer),
              if (is.null(sc)) "FAIL"
                else sprintf("%d/%d", sc$n_correct, sc$n_total),
              if (is.null(sc)) "" else pct(sc$easy_acc),
              if (is.null(sc)) "" else pct(sc$medium_acc),
              if (is.null(sc)) "" else pct(sc$hard_acc)))
}

# ── Section 2: Temperature sweep ─────────────────────────────────────────────

cat(sprintf("\n\n%s\n  SECTION 2 — Temperature sweep\n  model=%s  think=%s  files=%d\n%s\n",
            divider2, OLLAMA_MODEL, SWEEP_THINK, nrow(GT), divider2))

s2 <- list()

for (temp_val in TEMPERATURES) {
  lbl <- sprintf("%.1f", temp_val)
  cat(sprintf("\n%s\n  temperature = %s\n%s\n\n", divider, lbl, divider))

  out <- call_batch(think_level = SWEEP_THINK, temperature = temp_val)

  if (!is.null(out$error)) {
    cat(sprintf("  ERROR: %s\n", out$error))
    s2[[lbl]] <- list(out = out, sc = NULL)
    next
  }

  cat(sprintf("  elapsed: %.1fs\n\n", out$elapsed))
  print_thinking(out$thinking)

  sc <- parse_and_score(out$answer)
  print_predictions(sc)

  s2[[lbl]] <- list(out = out, sc = sc)
}

# Section 2 summary
cat(sprintf("\n%s\n  SECTION 2 SUMMARY  (think=%s)\n%s\n", divider2, SWEEP_THINK, divider2))
cat(sprintf("  %-8s  %8s  %13s  %13s  %8s  %8s  %8s  %8s\n",
            "temp", "elapsed", "think_words", "answer_words",
            "all", "easy", "medium", "hard"))
cat(sprintf("  %s\n", paste(rep("-", 82), collapse = "")))

for (lbl in names(s2)) {
  r  <- s2[[lbl]]
  sc <- r$sc
  if (!is.null(r$out$error)) { cat(sprintf("  %-8s  ERROR\n", lbl)); next }
  cat(sprintf("  %-8s  %7.1fs  %13d  %13d  %8s  %8s  %8s  %8s\n",
              lbl, r$out$elapsed,
              wc(r$out$thinking), wc(r$out$answer),
              if (is.null(sc)) "FAIL"
                else sprintf("%d/%d", sc$n_correct, sc$n_total),
              if (is.null(sc)) "" else pct(sc$easy_acc),
              if (is.null(sc)) "" else pct(sc$medium_acc),
              if (is.null(sc)) "" else pct(sc$hard_acc)))
}

cat(sprintf("\n%s\n  Done.\n%s\n\n", divider2, divider2))
