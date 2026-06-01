# estimate_tokens.R
# Calculates exact LLM call counts and token/cost estimates for a full eval run.
# No LLM calls made — purely deterministic from file counts on disk.
#
# Call model per paper:
#   Phase 1 (file type):     ceil(n_non_agg_files / LLM_BATCH_SIZE)
#   Phase 2 (aggregates):    ceil(n_agg_groups    / LLM_BATCH_SIZE)  [if any]
#   Phase 3 (granularity):   1 call per combined-data paper           [heuristic]
# SKIP_COLUMNS = TRUE in all eval runners, so col_type calls are excluded.

source("runners/eval/eval_helpers.R")

DATA_ROOT       <- "./data/osf"
GT_ROOT         <- "./tests/ground_truth/osf"
SUBSET_PATH     <- file.path(EVAL_RESULTS_DIR, "tuning_subset.csv")
LLM_BATCH_SIZE  <- 30L
AGG_THRESHOLD   <- 20L   # folders with > this many files become aggregate groups

# ── Pricing table (per 1M tokens) ────────────────────────────────────────────
MODELS_GROQ <- list(
  list(id = "openai/gpt-oss-120b", label = "GPT-OSS 120B",
       price_in = 0.15, price_out = 0.60),
  list(id = "openai/gpt-oss-20b",  label = "GPT-OSS 20B",
       price_in = 0.075, price_out = 0.30),
  list(id = "llama-3.1-8b-instant", label = "llama-3.1-8b",
       price_in = 0.05,  price_out = 0.08)
)

# Per-model token fits from probe_tokens.R (tokens = base + rate * n_paths).
TOKEN_FITS <- list(
  "groq/llama-3.1-8b-instant"  = list(base_in = 2377L, rate_in = 24L, base_out = -15L, rate_out = 45L),
  "ollama/gpt-oss:20b-cloud"   = list(base_in = 2415L, rate_in = 24L, base_out = 255L, rate_out = 46L),
  "ollama/gpt-oss:120b-cloud"  = list(base_in = 2415L, rate_in = 24L, base_out = 161L, rate_out = 52L),
  "ollama/qwen3-vl:235b-cloud" = list(base_in = 2383L, rate_in = 25L, base_out = 760L, rate_out = 129L)
)
TOKEN_FITS_DEFAULT <- list(base_in = 2400L, rate_in = 24L, base_out = 300L, rate_out = 60L)

tokens_in_for_call <- function(n, model_id = NULL) {
  f <- if (!is.null(model_id) && model_id %in% names(TOKEN_FITS))
    TOKEN_FITS[[model_id]] else TOKEN_FITS_DEFAULT
  f$base_in + n * f$rate_in
}
tokens_out_for_call <- function(n, model_id = NULL) {
  f <- if (!is.null(model_id) && model_id %in% names(TOKEN_FITS))
    TOKEN_FITS[[model_id]] else TOKEN_FITS_DEFAULT
  pmax(0L, f$base_out + n * f$rate_out)
}

# ── Per-paper call counter ────────────────────────────────────────────────────
paper_call_profile <- function(pid, src = "osf") {
  data_dir <- file.path(DATA_ROOT, pid)
  if (!dir.exists(data_dir)) return(NULL)

  all_files <- list.files(data_dir, recursive = TRUE, all.files = FALSE)
  if (length(all_files) == 0) return(NULL)

  # Detect aggregate groups: subdirectories with > AGG_THRESHOLD files inside them
  subdirs <- unique(dirname(all_files))
  subdirs <- subdirs[subdirs != "."]
  agg_groups <- Filter(function(d) {
    n <- length(list.files(file.path(data_dir, d), recursive = TRUE))
    n > AGG_THRESHOLD
  }, subdirs)

  # Files not in an aggregate group are sent to Phase 1
  agg_prefixes   <- if (length(agg_groups) > 0)
    paste0(agg_groups, "/") else character(0)
  in_agg <- if (length(agg_prefixes) > 0)
    Vectorize(function(f) any(startsWith(f, agg_prefixes)))(all_files)
  else
    rep(FALSE, length(all_files))

  n_p1  <- sum(!in_agg)
  n_agg <- length(agg_groups)

  p1_calls  <- ceiling(max(n_p1,  1L) / LLM_BATCH_SIZE)
  agg_calls <- if (n_agg > 0) ceiling(n_agg / LLM_BATCH_SIZE) else 0L

  # Granularity: heuristic — called when there are multiple data-like files.
  # We approximate: if >= 2 files look like data (csv/sav/xlsx/dat/txt) → 1 call.
  data_ext <- c("csv", "sav", "dta", "sas7bdat", "xlsx", "xls", "dat", "tsv")
  n_data <- sum(tools::file_ext(tolower(all_files)) %in% data_ext)
  gran_calls <- if (n_data >= 2L) 1L else 0L

  list(
    paper_id    = pid,
    n_files     = length(all_files),
    n_p1        = n_p1,
    n_agg       = n_agg,
    p1_calls    = p1_calls,
    agg_calls   = agg_calls,
    gran_calls  = gran_calls,
    total_calls = p1_calls + agg_calls + gran_calls
  )
}

# ── Build paper profiles ──────────────────────────────────────────────────────
all_gt_ids <- tools::file_path_sans_ext(
  list.files(GT_ROOT, pattern = "\\.csv$"))

tuning_ids <- if (file.exists(SUBSET_PATH)) {
  df <- read.csv(SUBSET_PATH, colClasses = c(id = "character"), stringsAsFactors = FALSE)
  df$id
} else {
  message("tuning_subset.csv not found — using test_papers.csv as fallback")
  df <- read.csv("tests/test_papers.csv", colClasses = c(id = "character"),
                 stringsAsFactors = FALSE)
  df$id
}

data_dirs    <- list.dirs(DATA_ROOT, recursive = FALSE, full.names = FALSE)
gt_with_data <- intersect(all_gt_ids, data_dirs)
tuning_avail <- intersect(tuning_ids, data_dirs)

cat(sprintf("Tuning subset: %d papers (%d with data on disk)\n",
            length(tuning_ids), length(tuning_avail)))
cat(sprintf("Full GT set:   %d papers (%d with data on disk)\n",
            length(all_gt_ids), length(gt_with_data)))

build_profiles <- function(ids) {
  profs <- lapply(ids, paper_call_profile)
  profs <- Filter(Negate(is.null), profs)
  do.call(rbind, lapply(profs, as.data.frame, stringsAsFactors = FALSE))
}

cat("\nProfiling papers...\n")
tuning_df <- build_profiles(tuning_avail)
gt_df     <- build_profiles(gt_with_data)

# Tokens for all papers in df for a single model_id
step_model_tokens <- function(df, model_id) {
  toks <- lapply(seq_len(nrow(df)), function(i) {
    r <- as.list(df[i, ])
    list(
      tokens_in  = tokens_in_for_call(r$n_p1,  model_id) * r$p1_calls  +
                   tokens_in_for_call(r$n_agg, model_id) * r$agg_calls +
                   tokens_in_for_call(3L,       model_id) * r$gran_calls,
      tokens_out = tokens_out_for_call(r$n_p1,  model_id) * r$p1_calls  +
                   tokens_out_for_call(r$n_agg, model_id) * r$agg_calls +
                   tokens_out_for_call(3L,       model_id) * r$gran_calls
    )
  })
  list(
    tokens_in  = sum(sapply(toks, `[[`, "tokens_in")),
    tokens_out = sum(sapply(toks, `[[`, "tokens_out"))
  )
}

# Pricing per 1M tokens keyed by model id
PRICING <- list(
  "groq/llama-3.1-8b-instant"  = list(price_in = 0.05,  price_out = 0.08),
  "ollama/gpt-oss:20b-cloud"   = list(price_in = 0.075, price_out = 0.30),
  "ollama/gpt-oss:120b-cloud"  = list(price_in = 0.15,  price_out = 0.60),
  "ollama/qwen3-vl:235b-cloud" = list(price_in = 0.071, price_out = 0.10)
)

# ── Eval step definitions ─────────────────────────────────────────────────────
# Each step: how many times each paper-run is executed.
n_model_configs <- length(EVAL_MODELS)              # 7
n_temps         <- length(EVAL_TEMPS)               # 3
n_prompt_fmts   <- length(EVAL_PROMPTS)             # 3
n_stability_runs <- 5L

steps <- list(
  list(label = "Step 1  Grid  7 (model x think) x 3 temps x 220 papers",
       df = gt_df, multiplier = n_model_configs * n_temps),
  list(label = "Step 2  Prompts  7 models x 3 formats x 220 papers",
       df = gt_df, multiplier = n_model_configs * n_prompt_fmts),
  list(label = "Step 3  Full GT  7 models x 220 papers",
       df = gt_df, multiplier = n_model_configs),
  list(label = "Step 4  Stability  7 models x 5 runs x 220 papers",
       df = gt_df, multiplier = n_model_configs * n_stability_runs)
)

# ── Summary table ─────────────────────────────────────────────────────────────
W <- 78
divider <- paste0(rep("-", W), collapse = "")
cat(sprintf("\n%s\n  LLM Call & Token Estimate\n%s\n", divider, divider))
cat(sprintf("  %-50s  %6s  %6s  %8s  %8s\n",
            "Step", "runs", "calls", "in (M)", "out (M)"))
cat(sprintf("  %-50s  %6s  %6s  %8s  %8s\n",
            paste(rep("-", 50), collapse=""),
            "------", "------", "--------", "--------"))

step_results <- lapply(steps, function(s) {
  n_runs  <- nrow(s$df) * s$multiplier
  n_calls <- sum(s$df$total_calls) * s$multiplier
  per_config_mult <- s$multiplier / n_model_configs
  model_ids <- sapply(EVAL_MODELS, `[[`, "model")
  tok_in  <- sum(sapply(model_ids, function(mid)
    step_model_tokens(s$df, mid)$tokens_in)) * per_config_mult
  tok_out <- sum(sapply(model_ids, function(mid)
    step_model_tokens(s$df, mid)$tokens_out)) * per_config_mult
  cat(sprintf("  %-50s  %6d  %6d  %8.2f  %8.2f\n",
              s$label, n_runs, n_calls,
              tok_in / 1e6, tok_out / 1e6))
  list(n_runs = n_runs, n_calls = n_calls, tok_in = tok_in, tok_out = tok_out)
})

grand_runs  <- sum(sapply(step_results, `[[`, "n_runs"))
grand_calls <- sum(sapply(step_results, `[[`, "n_calls"))
grand_in    <- sum(sapply(step_results, `[[`, "tok_in"))
grand_out   <- sum(sapply(step_results, `[[`, "tok_out"))

cat(sprintf("  %-50s  %6s  %6s  %8s  %8s\n",
            paste(rep("-", 50), collapse=""),
            "------", "------", "--------", "--------"))
cat(sprintf("  %-50s  %6d  %6d  %8.2f  %8.2f\n",
            "TOTAL", grand_runs, grand_calls,
            grand_in / 1e6, grand_out / 1e6))

# ── Per-paper breakdown (full 220 set) ────────────────────────────────────────
cat(sprintf("\n%s\n  Per-paper profile (full 220 set)\n%s\n", divider, divider))
cat(sprintf("  %-30s  %6s  %7s  %5s  %5s  %5s\n",
            "paper_id", "files", "calls", "p1", "agg", "gran"))
for (i in seq_len(nrow(gt_df))) {
  r <- gt_df[i, ]
  cat(sprintf("  %-30s  %6d  %7d  %5d  %5d  %5d\n",
              r$paper_id, r$n_files, r$total_calls,
              r$p1_calls, r$agg_calls, r$gran_calls))
}

# ── Cost table (per model config) ────────────────────────────────────────────
cat(sprintf("\n%s\n  Cost per model config  ($/M: price per million tokens)\n%s\n", divider, divider))
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %8s  %8s\n",
            "Model config", "in (M)", "out (M)", "$/M in", "$/M out", "in cost", "total"))
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %8s  %8s\n",
            paste(rep("-", 30), collapse=""),
            "--------", "--------", "--------", "--------", "--------", "--------"))

grand_cost <- 0
for (mc in EVAL_MODELS) {
  per_config_mult <- 1 / n_model_configs
  tok_in  <- sum(sapply(steps, function(s) {
    step_model_tokens(s$df, mc$model)$tokens_in  * s$multiplier * per_config_mult
  }))
  tok_out <- sum(sapply(steps, function(s) {
    step_model_tokens(s$df, mc$model)$tokens_out * s$multiplier * per_config_mult
  }))
  pr <- if (mc$model %in% names(PRICING)) PRICING[[mc$model]] else list(price_in = 0, price_out = 0)
  cost_in  <- tok_in  / 1e6 * pr$price_in
  cost_out <- tok_out / 1e6 * pr$price_out
  grand_cost <- grand_cost + cost_in + cost_out
  cat(sprintf("  %-30s  %8.2f  %8.2f  %8s  %8s  %8s  %8s\n",
              mc$label, tok_in / 1e6, tok_out / 1e6,
              sprintf("$%.3f", pr$price_in),
              sprintf("$%.3f", pr$price_out),
              sprintf("$%.2f", cost_in),
              sprintf("$%.2f", cost_in + cost_out)))
}
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %8s  %8s\n",
            paste(rep("-", 30), collapse=""),
            "--------", "--------", "--------", "--------", "--------", "--------"))
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %8s  %8s\n",
            "TOTAL", "", "", "", "", "", sprintf("$%.2f", grand_cost)))
cat(sprintf("%s\n", divider))
