# test_llm_params.R
# ─────────────────────────────────────────────────────────────────────────────
# Benchmark llm_ollama() across think levels and temperatures using a
# 18-item test set with ground truth, spanning easy / medium / hard
# classification cases.
#
# Outputs per-setting accuracy tables (easy / medium / hard / total),
# latency, and stability (same answer across reps).
#
# Usage:  source("runners/test_llm_params.R")
#
# Config knobs at top:
#   OLLAMA_MODEL  — swap to 120b-cloud for higher-quality sweep
#   N_REPS        — reps per setting; ≥3 gives reliable stability signal
#   SWEEP_TEMP    — fixed temperature for think sweep
#   SWEEP_THINK   — fixed think level for temperature sweep
# ─────────────────────────────────────────────────────────────────────────────

library(metacheck)
source("pipeline/helper.R")
source("pipeline/prompts.R")

llm_use(TRUE)
llm_max_calls(500)

# ── Configuration ─────────────────────────────────────────────────────────────

OLLAMA_MODEL <- "ollama/gpt-oss:20b-cloud"   # swap to 120b-cloud for higher-quality sweep
llm_model(OLLAMA_MODEL)

THINK_LEVELS <- list(NULL, "low", "medium", "high")
TEMPERATURES <- c(0.0, 0.3, 0.5, 0.7, 1.0)
N_REPS       <- 5     # per setting — 3 gives a reliable stability signal

SWEEP_TEMP  <- 0.3    # fixed temperature used during the think sweep
SWEEP_THINK <- "low"  # fixed think level used during the temperature sweep

# ── Ground truth ──────────────────────────────────────────────────────────────
# 18 cases: 5 easy / 5 medium / 8 hard
# "hard" cases have misleading extensions, require domain knowledge, or need
# folder-context reasoning to classify correctly.
#
# difficulty legend:
#   easy   — obvious from extension + name alone
#   medium — requires one inferential step (folder, keyword, format)
#   hard   — requires domain knowledge, context overrides extension,
#             or a common heuristic leads to the wrong answer

GT <- data.frame(
  path = c(
    # ── Easy (5) ──────────────────────────────────────────────────────────────
    "data/participants_study1.sav",
    "scripts/analysis_main.R",
    "docs/variable_codebook.pdf",
    "README.md",
    "figures/results_fig2_scatter.png",

    # ── Medium (5) ────────────────────────────────────────────────────────────
    # stimuli image inside a stimuli/ folder
    "stimuli/Stroop_word_red.jpg",
    # consent form - looks like a doc but is supplemental
    "study_documents/consent_form_signed_v2.docx",
    # response data buried under Experiment 2
    "Experiment 2/data/study2_questionnaire_responses.xlsx",
    # IRB letter - official document, not data or code
    "admin/IRB_approval_2022.pdf",
    # rendered HTML from Rmd - output, not data
    "output/regression_notebook_rendered.html",

    # ── Hard (8) ──────────────────────────────────────────────────────────────
    # coding_manual is a CODEBOOK, not raw data — despite .xlsx
    "coding_manual.xlsx",
    # BFI items + scoring = variable definitions = CODEBOOK, not data
    "bfi10_items_and_scoring_key.csv",
    # t-test results = computed statistics = OUTPUT, not raw data
    "tables/t_test_results_full_sample.csv",
    # explicitly in Supplementary Materials folder → supplemental
    "Supplementary Materials/Table_S3_participant_demographics.csv",
    # open-ended text responses ARE data (not supplemental)
    "Study 1/open_ended_responses_wave2.csv",
    # .log extension = output (per schema); merge log from script
    "merge_diagnostics_run3.log",
    # Cohen's d effect sizes = computed statistics = output, not data
    "Experiment 1/effect_sizes_cohens_d.csv",
    # E-Prime .edat2 data file — raw participant trial log = data
    "eprime_raw/subject_042_task_B.edat2"
  ),
  type_gt = c(
    # easy
    "data", "code", "codebook", "readme", "output",
    # medium
    "asset", "supplemental", "data", "supplemental", "output",
    # hard
    "codebook", "codebook", "output", "supplemental", "data",
    "output", "output", "data"
  ),
  difficulty = c(
    rep("easy",   5),
    rep("medium", 5),
    rep("hard",   8)
  ),
  stringsAsFactors = FALSE
)

# ── System prompt (mirrors pipeline's Phase 1 prompt) ─────────────────────────

TEST_SYSTEM_PROMPT <- STRUCTURE_PROMPT_MD

# Build user-turn input: numbered path list (same format as llm_batch)
TEST_PROMPT_BODY <- paste(seq_len(nrow(GT)), GT$path, sep = ". ", collapse = "\n")

`%||%` <- function(x, y) if (is.null(x)) y else x

# ── Scoring helpers ───────────────────────────────────────────────────────────

# Parse a raw LLM JSON answer and return a data.frame with columns path + type.
# Returns NULL on parse failure.
parse_response <- function(raw_answer) {
  if (is.na(raw_answer)) return(NULL)
  tryCatch({
    parsed <- jsonlite::fromJSON(extract_json(raw_answer), flatten = TRUE)
    if (!is.data.frame(parsed)) return(NULL)
    if (!all(c("path", "type") %in% names(parsed))) return(NULL)
    parsed[, c("path", "type")]
  }, error = function(e) NULL)
}

# Score a parsed response against GT.  Returns a list:
#   $n_correct, $n_total,
#   $easy_correct / $easy_total,
#   $medium_correct / $medium_total,
#   $hard_correct / $hard_total,
#   $wrong — data.frame of wrong predictions for drill-down
score <- function(parsed) {
  if (is.null(parsed)) {
    return(list(
      n_correct = 0L, n_total = nrow(GT),
      easy_correct = 0L,   easy_total   = sum(GT$difficulty == "easy"),
      medium_correct = 0L, medium_total = sum(GT$difficulty == "medium"),
      hard_correct = 0L,   hard_total   = sum(GT$difficulty == "hard"),
      parse_fail = TRUE, n_path_miss = nrow(GT), pred_sig = NA_character_,
      wrong = GT
    ))
  }

  # left-join predicted type onto GT; unmatched paths = wrong
  merged <- merge(GT, parsed, by = "path", all.x = TRUE)
  merged$pred_type <- ifelse(is.na(merged$type), "MISSING", merged$type)

  merged$correct <- !is.na(merged$pred_type) &
                    merged$pred_type == merged$type_gt

  score_diff <- function(diff) {
    rows <- merged[merged$difficulty == diff, ]
    list(correct = sum(rows$correct), total = nrow(rows))
  }

  easy_s   <- score_diff("easy")
  medium_s <- score_diff("medium")
  hard_s   <- score_diff("hard")

  wrong <- merged[!merged$correct,
                  c("path", "difficulty", "type_gt", "pred_type"),
                  drop = FALSE]

  # Canonical prediction fingerprint: sorted "path=type" pairs.
  # Used by summarise_runs() for stability checks — immune to JSON whitespace.
  pred_sig <- paste(sort(paste0(merged$path, "=", merged$pred_type)),
                    collapse = "\n")

  # Count paths the model returned that matched no GT path (path scrambling).
  n_path_miss <- sum(merged$pred_type == "MISSING")

  list(
    n_correct      = sum(merged$correct),
    n_total        = nrow(merged),
    easy_correct   = easy_s$correct,   easy_total   = easy_s$total,
    medium_correct = medium_s$correct, medium_total = medium_s$total,
    hard_correct   = hard_s$correct,   hard_total   = hard_s$total,
    parse_fail     = FALSE,
    n_path_miss    = n_path_miss,
    pred_sig       = pred_sig,
    wrong          = wrong
  )
}

# Call llm_ollama, measure time, return list(answer, elapsed, score)
call_and_score <- function(think, temperature) {
  t0 <- proc.time()[["elapsed"]]
  result <- tryCatch(
    llm_ollama(
      text          = TEST_PROMPT_BODY,
      system_prompt = TEST_SYSTEM_PROMPT,
      params        = list(temperature = temperature),
      think         = think
    ),
    error = function(e) {
      data.frame(answer = sprintf("ERROR: %s", e$message),
                 stringsAsFactors = FALSE)
    }
  )
  elapsed <- round(proc.time()[["elapsed"]] - t0, 1)
  answer  <- if (is.data.frame(result) && "answer" %in% names(result))
               result$answer[1] else NA_character_
  s <- score(parse_response(answer))
  list(answer = answer, elapsed = elapsed, score = s,
       pred_sig = if (is.null(s$pred_sig)) NA_character_ else s$pred_sig)
}

# Format "correct/total" fraction string
frac <- function(c, t) sprintf("%d/%d", c, t)

divider  <- paste(rep("─", 72), collapse = "")
divider2 <- paste(rep("═", 72), collapse = "")

# ── Run sweeps ────────────────────────────────────────────────────────────────

# Storage: each entry is a list of N_REPS call_and_score() results
think_runs <- list()
temp_runs  <- list()

# ── Sweep 1: think levels ─────────────────────────────────────────────────────

cat(sprintf("\n%s\n  SWEEP 1 — think level  (temp=%.1f, model=%s)\n%s\n",
            divider2, SWEEP_TEMP, OLLAMA_MODEL, divider2))

for (think_val in THINK_LEVELS) {
  label <- if (is.null(think_val)) "NULL" else think_val
  cat(sprintf("\n%s\n  think = %s\n%s\n", divider, label, divider))
  reps <- vector("list", N_REPS)

  for (rep in seq_len(N_REPS)) {
    cat(sprintf("  rep %d/%d ... ", rep, N_REPS))
    out <- call_and_score(think = think_val, temperature = SWEEP_TEMP)
    reps[[rep]] <- out
    s <- out$score
    cat(sprintf("[%.1fs]  acc=%s  easy=%s  med=%s  hard=%s%s\n",
                out$elapsed,
                frac(s$n_correct, s$n_total),
                frac(s$easy_correct, s$easy_total),
                frac(s$medium_correct, s$medium_total),
                frac(s$hard_correct, s$hard_total),
                if (s$parse_fail) "  PARSE FAIL" else ""))
  }
  think_runs[[label]] <- reps
}

# ── Sweep 2: temperatures ─────────────────────────────────────────────────────

cat(sprintf("\n\n%s\n  SWEEP 2 — temperature  (think=%s, model=%s)\n%s\n",
            divider2, SWEEP_THINK, OLLAMA_MODEL, divider2))

for (temp_val in TEMPERATURES) {
  label <- sprintf("%.1f", temp_val)
  cat(sprintf("\n%s\n  temperature = %s\n%s\n", divider, label, divider))
  reps <- vector("list", N_REPS)

  for (rep in seq_len(N_REPS)) {
    cat(sprintf("  rep %d/%d ... ", rep, N_REPS))
    out <- call_and_score(think = SWEEP_THINK, temperature = temp_val)
    reps[[rep]] <- out
    s <- out$score
    cat(sprintf("[%.1fs]  acc=%s  easy=%s  med=%s  hard=%s%s\n",
                out$elapsed,
                frac(s$n_correct, s$n_total),
                frac(s$easy_correct, s$easy_total),
                frac(s$medium_correct, s$medium_total),
                frac(s$hard_correct, s$hard_total),
                if (s$parse_fail) "  PARSE FAIL" else ""))
  }
  temp_runs[[label]] <- reps
}

# ── Summary helpers ───────────────────────────────────────────────────────────

# Aggregate N_REPS runs into one summary row
summarise_runs <- function(reps) {
  times       <- vapply(reps, `[[`, numeric(1), "elapsed")
  n_correct   <- vapply(reps, function(r) r$score$n_correct,      integer(1))
  n_total     <- reps[[1]]$score$n_total
  easy_c      <- vapply(reps, function(r) r$score$easy_correct,   integer(1))
  easy_t      <- reps[[1]]$score$easy_total
  med_c       <- vapply(reps, function(r) r$score$medium_correct, integer(1))
  med_t       <- reps[[1]]$score$medium_total
  hard_c      <- vapply(reps, function(r) r$score$hard_correct,   integer(1))
  hard_t      <- reps[[1]]$score$hard_total
  pred_sigs   <- vapply(reps, `[[`, character(1), "pred_sig")
  n_path_miss <- vapply(reps, function(r) r$score$n_path_miss %||% 0L, integer(1))
  parse_fails <- vapply(reps, function(r) isTRUE(r$score$parse_fail),  logical(1))

  # Stability: same parsed classification on every rep (whitespace-immune).
  # Reps with parse failures or path scrambling are always unstable.
  valid_sigs <- pred_sigs[!parse_fails & n_path_miss < (n_total / 2)]
  stable     <- length(valid_sigs) == N_REPS && length(unique(valid_sigs)) == 1

  list(
    mean_s         = round(mean(times), 1),
    stable         = stable,
    n_parse_fail   = sum(parse_fails),
    n_scrambled    = sum(n_path_miss >= (n_total / 2) & !parse_fails),
    acc_mean       = round(mean(n_correct / n_total) * 100),
    acc_fracs      = sapply(seq_len(N_REPS),
                       function(i) frac(n_correct[i], n_total)),
    easy_mean      = round(mean(easy_c / easy_t) * 100),
    medium_mean    = round(mean(med_c  / med_t)  * 100),
    hard_mean      = round(mean(hard_c / hard_t) * 100),
    wrong_by_rep   = lapply(reps, function(r) r$score$wrong)
  )
}

# Print a summary table section
print_summary_table <- function(run_list, sweep_name, fixed_label) {
  summaries <- lapply(run_list, summarise_runs)

  # header
  cat(sprintf("\n  %s  (%s)\n", sweep_name, fixed_label))
  cat(sprintf("  %-10s  %8s  %8s  %6s  %6s  %9s  %9s  %9s  %9s\n",
              "setting", "mean_s", "stable?", "fails", "scram",
              "all", "easy", "medium", "hard"))
  cat(sprintf("  %s\n", paste(rep("-", 85), collapse = "")))

  for (lbl in names(summaries)) {
    s <- summaries[[lbl]]
    rep_str <- paste(s$acc_fracs, collapse = " ")
    flags   <- character(0)
    if (s$n_parse_fail > 0) flags <- c(flags, sprintf("%d parse-fail", s$n_parse_fail))
    if (s$n_scrambled  > 0) flags <- c(flags, sprintf("%d path-scramble", s$n_scrambled))
    flag_str <- if (length(flags) > 0) paste0("  ← ", paste(flags, collapse = ", ")) else ""

    cat(sprintf("  %-10s  %7.1fs  %8s  %6d  %6d  %8s%%  %8s%%  %8s%%  %8s%%%s\n",
                lbl, s$mean_s,
                if (s$stable) "YES" else "no",
                s$n_parse_fail, s$n_scrambled,
                s$acc_mean, s$easy_mean, s$medium_mean, s$hard_mean,
                flag_str))
    if (N_REPS > 1)
      cat(sprintf("  %-10s  %8s  %8s  %13s  %s\n", "", "", "", "", rep_str))
  }

  # drill-down: most common wrong predictions pooled across all reps & settings
  all_wrong <- do.call(rbind, unlist(
    lapply(summaries, function(s) s$wrong_by_rep), recursive = FALSE
  ))
  if (!is.null(all_wrong) && nrow(all_wrong) > 0) {
    cat(sprintf("\n  Most-missed files (%s):\n", sweep_name))
    cat(sprintf("  %-52s  %-10s  %-12s  %s\n",
                "path", "difficulty", "type_gt", "pred (most common)"))
    cat(sprintf("  %s\n", paste(rep("-", 95), collapse = "")))

    # count errors per path
    err_counts <- sort(table(all_wrong$path), decreasing = TRUE)
    max_show   <- min(8L, length(err_counts))
    for (i in seq_len(max_show)) {
      p    <- names(err_counts)[i]
      rows <- all_wrong[all_wrong$path == p, ]
      pred_mode <- names(sort(table(rows$pred_type), decreasing = TRUE))[1]
      cat(sprintf("  %-52s  %-10s  %-12s  %s  (missed %d/%d reps)\n",
                  substr(basename(p), 1, 52),
                  rows$difficulty[1],
                  rows$type_gt[1],
                  pred_mode,
                  as.integer(err_counts[i]),
                  length(summaries) * N_REPS))
    }
  }
}

# ── Print final summary ───────────────────────────────────────────────────────

cat(sprintf("\n\n%s\n  FINAL SUMMARY\n  model: %s\n  GT items: %d  (easy=%d  medium=%d  hard=%d)\n%s\n",
            divider2, OLLAMA_MODEL,
            nrow(GT),
            sum(GT$difficulty == "easy"),
            sum(GT$difficulty == "medium"),
            sum(GT$difficulty == "hard"),
            divider2))

print_summary_table(think_runs, "Think level sweep", sprintf("temp=%.1f", SWEEP_TEMP))
print_summary_table(temp_runs,  "Temperature sweep", sprintf("think=%s", SWEEP_THINK))

# ── Broken output dump ───────────────────────────────────────────────────────

print_broken_outputs <- function(run_list, sweep_name) {
  n_total <- nrow(GT)
  broken  <- list()

  for (setting_lbl in names(run_list)) {
    reps <- run_list[[setting_lbl]]
    for (rep_i in seq_along(reps)) {
      r    <- reps[[rep_i]]
      s    <- r$score
      fail <- isTRUE(s$parse_fail)
      scram <- !fail && (!is.null(s$n_path_miss)) && s$n_path_miss >= (n_total / 2)
      if (fail || scram) {
        broken[[length(broken) + 1]] <- list(
          setting = setting_lbl,
          rep     = rep_i,
          kind    = if (fail) "PARSE FAIL" else "PATH SCRAMBLE",
          elapsed = r$elapsed,
          answer  = r$answer
        )
      }
    }
  }

  if (length(broken) == 0) {
    cat(sprintf("\n  %s — no broken outputs.\n", sweep_name))
    return(invisible(NULL))
  }

  cat(sprintf("\n%s\n  BROKEN OUTPUTS — %s  (%d broken rep(s))\n%s\n",
              divider, sweep_name, length(broken), divider))

  for (b in broken) {
    cat(sprintf("\n  setting=%-8s  rep=%d  [%.1fs]  kind=%s\n",
                b$setting, b$rep, b$elapsed, b$kind))
    cat(sprintf("  %s\n", paste(rep("·", 68), collapse = "")))
    # Print full raw answer, wrapping long lines for readability
    raw <- if (is.na(b$answer)) "<NA — no answer returned>" else b$answer
    # show up to 120 chars per line, preserving newlines already in the text
    lines <- unlist(strsplit(raw, "\n", fixed = TRUE))
    for (ln in lines) {
      if (nchar(ln) <= 120) {
        cat(sprintf("  %s\n", ln))
      } else {
        # hard-wrap at 120 chars
        while (nchar(ln) > 0) {
          cat(sprintf("  %s\n", substr(ln, 1, 120)))
          ln <- if (nchar(ln) > 120) substr(ln, 121, nchar(ln)) else ""
        }
      }
    }
    cat(sprintf("  %s\n", paste(rep("·", 68), collapse = "")))
  }
}

print_broken_outputs(think_runs, "Think level sweep")
print_broken_outputs(temp_runs,  "Temperature sweep")

# ── Ground truth reference ────────────────────────────────────────────────────

cat(sprintf("\n\n%s\n  GROUND TRUTH REFERENCE\n%s\n", divider, divider))
cat(sprintf("  %-52s  %-10s  %-12s\n", "path (basename)", "difficulty", "type_gt"))
cat(sprintf("  %s\n", paste(rep("-", 78), collapse = "")))
for (i in seq_len(nrow(GT))) {
  cat(sprintf("  %-52s  %-10s  %-12s\n",
              basename(GT$path[i]), GT$difficulty[i], GT$type_gt[i]))
}

cat(sprintf("\n%s\n  Done.\n%s\n\n", divider2, divider2))
