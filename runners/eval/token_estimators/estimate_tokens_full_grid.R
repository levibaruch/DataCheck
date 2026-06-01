# estimate_tokens_full_grid.R
# Cost/token estimate for full cartesian grid:
#   6 model configs x 3 prompts x 3 temperatures x 10 stability runs per paper
# No LLM calls — deterministic from file counts on disk.

source("runners/eval/eval_helpers.R")

DATA_ROOT       <- "./data/osf"
GT_ROOT         <- "./tests/ground_truth/osf"
LLM_BATCH_SIZE  <- 30L
AGG_THRESHOLD   <- 20L

N_STABILITY     <- 10L   # stability runs per (model x prompt x temp x paper)

# ── Token fits (from probe_tokens.R) ─────────────────────────────────────────
TOKEN_FITS <- list(
  "groq/llama-3.1-8b-instant"  = list(base_in = 2377L, rate_in = 24L, base_out = -15L, rate_out = 45L),
  "ollama/gpt-oss:20b-cloud"   = list(base_in = 2415L, rate_in = 24L, base_out = 255L, rate_out = 46L),
  "ollama/gpt-oss:120b-cloud"  = list(base_in = 2415L, rate_in = 24L, base_out = 161L, rate_out = 52L),
  "ollama/qwen3-vl:235b-cloud" = list(base_in = 2383L, rate_in = 25L, base_out = 760L, rate_out = 129L)
)
TOKEN_FITS_DEFAULT <- list(base_in = 2400L, rate_in = 24L, base_out = 300L, rate_out = 60L)

PRICING <- list(
  "groq/llama-3.1-8b-instant"  = list(price_in = 0.05,  price_out = 0.08),
  "ollama/gpt-oss:20b-cloud"   = list(price_in = 0.075, price_out = 0.30),
  "ollama/gpt-oss:120b-cloud"  = list(price_in = 0.15,  price_out = 0.60),
  "ollama/qwen3-vl:235b-cloud" = list(price_in = 0.071, price_out = 0.10)
)

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

# ── Per-paper call counter ───────────────────────────────────────────────────
paper_call_profile <- function(pid) {
  data_dir <- file.path(DATA_ROOT, pid)
  if (!dir.exists(data_dir)) return(NULL)

  all_files <- list.files(data_dir, recursive = TRUE, all.files = FALSE)
  if (length(all_files) == 0) return(NULL)

  subdirs <- unique(dirname(all_files))
  subdirs <- subdirs[subdirs != "."]
  agg_groups <- Filter(function(d) {
    n <- length(list.files(file.path(data_dir, d), recursive = TRUE))
    n > AGG_THRESHOLD
  }, subdirs)

  agg_prefixes <- if (length(agg_groups) > 0) paste0(agg_groups, "/") else character(0)
  in_agg <- if (length(agg_prefixes) > 0)
    Vectorize(function(f) any(startsWith(f, agg_prefixes)))(all_files)
  else
    rep(FALSE, length(all_files))

  n_p1  <- sum(!in_agg)
  n_agg <- length(agg_groups)

  p1_calls  <- ceiling(max(n_p1, 1L) / LLM_BATCH_SIZE)
  agg_calls <- if (n_agg > 0) ceiling(n_agg / LLM_BATCH_SIZE) else 0L

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

# Tokens for all papers in df for a single model_id (one pass / one run)
step_model_tokens <- function(df, model_id) {
  toks <- lapply(seq_len(nrow(df)), function(i) {
    r <- as.list(df[i, ])
    list(
      tokens_in  = tokens_in_for_call(r$n_p1,  model_id) * r$p1_calls  +
                   tokens_in_for_call(r$n_agg, model_id) * r$agg_calls +
                   tokens_in_for_call(3L,      model_id) * r$gran_calls,
      tokens_out = tokens_out_for_call(r$n_p1,  model_id) * r$p1_calls  +
                   tokens_out_for_call(r$n_agg, model_id) * r$agg_calls +
                   tokens_out_for_call(3L,      model_id) * r$gran_calls
    )
  })
  list(
    tokens_in  = sum(sapply(toks, `[[`, "tokens_in")),
    tokens_out = sum(sapply(toks, `[[`, "tokens_out"))
  )
}

# ── Build paper profiles ─────────────────────────────────────────────────────
all_gt_ids <- tools::file_path_sans_ext(list.files(GT_ROOT, pattern = "\\.csv$"))
data_dirs    <- list.dirs(DATA_ROOT, recursive = FALSE, full.names = FALSE)
gt_with_data <- intersect(all_gt_ids, data_dirs)

cat(sprintf("Full GT set: %d papers (%d with data on disk)\n",
            length(all_gt_ids), length(gt_with_data)))

cat("\nProfiling papers...\n")
profs <- Filter(Negate(is.null), lapply(gt_with_data, paper_call_profile))
gt_df <- do.call(rbind, lapply(profs, as.data.frame, stringsAsFactors = FALSE))

# ── Grid dimensions ──────────────────────────────────────────────────────────
n_models  <- length(EVAL_MODELS)   # 6
n_temps   <- length(EVAL_TEMPS)    # 3
n_prompts <- length(EVAL_PROMPTS)  # 3
n_stab    <- N_STABILITY           # 10

# Per (model, paper) pass count = prompts x temps x stability
runs_per_model_paper <- n_prompts * n_temps * n_stab
total_runs  <- nrow(gt_df) * n_models * runs_per_model_paper
total_calls <- sum(gt_df$total_calls) * n_models * runs_per_model_paper

W <- 78
divider <- paste0(rep("-", W), collapse = "")
cat(sprintf("\n%s\n  Full grid: %d models x %d prompts x %d temps x %d stability x %d papers\n%s\n",
            divider, n_models, n_prompts, n_temps, n_stab, nrow(gt_df), divider))
cat(sprintf("  runs:       %d\n", total_runs))
cat(sprintf("  LLM calls:  %d\n", total_calls))

# ── Per-model totals & costs ─────────────────────────────────────────────────
cat(sprintf("\n%s\n  Cost per model config (per-model multiplier = %d)\n%s\n",
            divider, runs_per_model_paper, divider))
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %10s\n",
            "Model config", "in (M)", "out (M)", "$/M in", "$/M out", "cost"))
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %10s\n",
            paste(rep("-", 30), collapse=""),
            "--------", "--------", "--------", "--------", "----------"))

grand_in <- 0; grand_out <- 0; grand_cost <- 0
for (mc in EVAL_MODELS) {
  tot <- step_model_tokens(gt_df, mc$model)
  tok_in  <- tot$tokens_in  * runs_per_model_paper
  tok_out <- tot$tokens_out * runs_per_model_paper
  pr <- if (mc$model %in% names(PRICING)) PRICING[[mc$model]] else list(price_in = 0, price_out = 0)
  cost <- tok_in / 1e6 * pr$price_in + tok_out / 1e6 * pr$price_out
  grand_in   <- grand_in + tok_in
  grand_out  <- grand_out + tok_out
  grand_cost <- grand_cost + cost
  cat(sprintf("  %-30s  %8.2f  %8.2f  %8s  %8s  %10s\n",
              mc$label, tok_in / 1e6, tok_out / 1e6,
              sprintf("$%.3f", pr$price_in),
              sprintf("$%.3f", pr$price_out),
              sprintf("$%.2f", cost)))
}
cat(sprintf("  %-30s  %8s  %8s  %8s  %8s  %10s\n",
            paste(rep("-", 30), collapse=""),
            "--------", "--------", "--------", "--------", "----------"))
cat(sprintf("  %-30s  %8.2f  %8.2f  %8s  %8s  %10s\n",
            "TOTAL", grand_in / 1e6, grand_out / 1e6, "", "",
            sprintf("$%.2f", grand_cost)))
cat(sprintf("%s\n", divider))
