# estimate_groq_750.R
# Recalculates cost of the eval pipeline run on Groq for all GT papers.
# No LLM calls — deterministic from file counts on disk.
#
# Mirrors estimate_tokens_full220.R but scoped to a single Groq model
# config and the actual GT corpus that was evaluated.
#
# Call model per paper:
#   Phase 1 (file type):     ceil(n_non_agg_files / LLM_BATCH_SIZE)
#   Phase 2 (aggregates):    ceil(n_agg_groups    / LLM_BATCH_SIZE) [if any]
#   Phase 3 (granularity):   1 call per paper with >= 2 data-like files
# SKIP_COLUMNS = TRUE in eval runners; col_type calls excluded.

DATA_ROOTS     <- c("./data/osf", "./data/dataverse")
GT_ROOTS       <- c("./tests/ground_truth/osf", "./tests/ground_truth/dataverse")
LLM_BATCH_SIZE <- 30L
AGG_THRESHOLD  <- 20L

# ── Token fit for Groq llama-3.1-8b (from probe_tokens.R) ────────────────────
TOKEN_FIT <- list(base_in = 2377L, rate_in = 24L,
                  base_out = -15L, rate_out = 45L)

tokens_in_for_call  <- function(n) TOKEN_FIT$base_in  + n * TOKEN_FIT$rate_in
tokens_out_for_call <- function(n) pmax(0L, TOKEN_FIT$base_out + n * TOKEN_FIT$rate_out)

# ── Groq pricing per 1M tokens ───────────────────────────────────────────────
PRICING <- list(
  list(model = "llama-3.1-8b-instant", price_in = 0.05,  price_out = 0.08),
  list(model = "openai/gpt-oss-20b",   price_in = 0.075, price_out = 0.30),
  list(model = "openai/gpt-oss-120b",  price_in = 0.15,  price_out = 0.60)
)

# ── Per-paper call profile (same logic as estimate_tokens_full220.R) ─────────
paper_call_profile <- function(data_dir) {
  all_files <- list.files(data_dir, recursive = TRUE, all.files = FALSE)
  if (length(all_files) == 0) return(NULL)

  subdirs <- unique(dirname(all_files))
  subdirs <- subdirs[subdirs != "."]
  agg_groups <- Filter(function(d) {
    length(list.files(file.path(data_dir, d), recursive = TRUE)) > AGG_THRESHOLD
  }, subdirs)

  agg_prefixes <- if (length(agg_groups) > 0) paste0(agg_groups, "/") else character(0)
  in_agg <- if (length(agg_prefixes) > 0)
    vapply(all_files, function(f) any(startsWith(f, agg_prefixes)), logical(1))
  else
    rep(FALSE, length(all_files))

  n_p1  <- sum(!in_agg)
  n_agg <- length(agg_groups)

  p1_calls  <- ceiling(max(n_p1, 1L) / LLM_BATCH_SIZE)
  agg_calls <- if (n_agg > 0) ceiling(n_agg / LLM_BATCH_SIZE) else 0L

  data_ext <- c("csv", "sav", "dta", "sas7bdat", "xlsx", "xls", "dat", "tsv")
  n_data <- sum(tools::file_ext(tolower(all_files)) %in% data_ext)
  gran_calls <- if (n_data >= 2L) 1L else 0L

  list(n_files = length(all_files),
       n_p1 = n_p1, n_agg = n_agg,
       p1_calls = p1_calls, agg_calls = agg_calls, gran_calls = gran_calls,
       total_calls = p1_calls + agg_calls + gran_calls)
}

# ── Collect GT paper IDs that have data on disk ──────────────────────────────
gt_ids <- character(0)
for (gt_root in GT_ROOTS) {
  if (dir.exists(gt_root)) {
    ids <- tools::file_path_sans_ext(list.files(gt_root, pattern = "\\.csv$"))
    src <- basename(gt_root)
    gt_ids <- c(gt_ids, paste(src, ids, sep = "/"))
  }
}

paper_dirs <- character(0)
for (entry in gt_ids) {
  parts <- strsplit(entry, "/")[[1]]
  src <- parts[1]; pid <- parts[2]
  cand <- file.path("./data", src, pid)
  if (dir.exists(cand)) paper_dirs <- c(paper_dirs, cand)
}

cat(sprintf("GT corpus: %d papers (%d with data on disk)\n",
            length(gt_ids), length(paper_dirs)))

cat("Profiling papers...\n")
profs <- lapply(paper_dirs, paper_call_profile)
keep  <- !vapply(profs, is.null, logical(1))
profs <- profs[keep]
df <- do.call(rbind, lapply(profs, as.data.frame, stringsAsFactors = FALSE))

n_papers     <- nrow(df)
n_files      <- sum(df$n_files)
n_calls      <- sum(df$total_calls)
n_p1_calls   <- sum(df$p1_calls)
n_agg_calls  <- sum(df$agg_calls)
n_gran_calls <- sum(df$gran_calls)

# ── Tokens (sum across all calls of all papers) ──────────────────────────────
tok_in  <- sum(tokens_in_for_call(df$n_p1)  * df$p1_calls  +
               tokens_in_for_call(df$n_agg) * df$agg_calls +
               tokens_in_for_call(3L)       * df$gran_calls)
tok_out <- sum(tokens_out_for_call(df$n_p1)  * df$p1_calls  +
               tokens_out_for_call(df$n_agg) * df$agg_calls +
               tokens_out_for_call(3L)       * df$gran_calls)

# ── Report ───────────────────────────────────────────────────────────────────
W <- 78; divider <- paste0(rep("-", W), collapse = "")
cat(sprintf("\n%s\n  Groq pipeline run estimate (GT corpus)\n%s\n", divider, divider))
cat(sprintf("  Papers profiled:       %d\n",         n_papers))
cat(sprintf("  Total files:           %s\n",         format(n_files, big.mark=",")))
cat(sprintf("  Total LLM calls:       %s\n",         format(n_calls, big.mark=",")))
cat(sprintf("    Phase 1 (file type): %s\n",         format(n_p1_calls,   big.mark=",")))
cat(sprintf("    Phase 2 (aggregate): %s\n",         format(n_agg_calls,  big.mark=",")))
cat(sprintf("    Phase 3 (granular):  %s\n",         format(n_gran_calls, big.mark=",")))
cat(sprintf("  Tokens in:             %.2f M\n",     tok_in / 1e6))
cat(sprintf("  Tokens out:            %.2f M\n",     tok_out / 1e6))

cat(sprintf("\n%s\n  Cost by Groq model\n%s\n", divider, divider))
cat(sprintf("  %-26s  %8s  %8s  %8s  %8s\n",
            "Model", "$/M in", "$/M out", "in cost", "total"))
cat(sprintf("  %-26s  %8s  %8s  %8s  %8s\n",
            paste(rep("-", 26), collapse=""),
            "--------", "--------", "--------", "--------"))
for (p in PRICING) {
  ci <- tok_in  / 1e6 * p$price_in
  co <- tok_out / 1e6 * p$price_out
  cat(sprintf("  %-26s  %8s  %8s  %8s  %8s\n",
              p$model,
              sprintf("$%.3f", p$price_in),
              sprintf("$%.3f", p$price_out),
              sprintf("$%.2f", ci),
              sprintf("$%.2f", ci + co)))
}
cat(sprintf("%s\n", divider))
