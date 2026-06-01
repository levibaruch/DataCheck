# calibrate_tokens.R
# Runs the pipeline on a spread of repo sizes to get empirical token-per-call data.
# Results are used to calibrate BASE_TOKENS_IN / AVG_TOKENS_IN_PER_FILE in estimate_tokens.R.
# Set LLM_MODEL before sourcing, e.g.:
#   LLM_MODEL <<- "groq/llama-3.1-8b-instant"; source("runners/eval/calibrate_tokens.R")

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")

SKIP_COLUMNS     <<- TRUE
CAPTURE_THINKING <<- TRUE

CAL_OUT_DIR      <- file.path(EVAL_RESULTS_DIR, "calibration")
THINKING_LOG_PATH <<- file.path(CAL_OUT_DIR, "cal_thinking_traces.csv")
dir.create(CAL_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Pick papers that span the size range — all GT papers with data on disk.
# Use find -maxdepth 3 to avoid crawling 100K-file stimulus folders.
DATA_ROOT <- "./data/osf"
GT_ROOT   <- "./tests/ground_truth/osf"
gt_ids    <- tools::file_path_sans_ext(list.files(GT_ROOT, pattern = "\\.csv$"))
gt_ids    <- gt_ids[dir.exists(file.path(DATA_ROOT, gt_ids))]

count_files <- function(pid) {
  d <- file.path(DATA_ROOT, pid)
  length(system2("find", c(shQuote(d), "-maxdepth", "3", "-type", "f"),
                 stdout = TRUE, stderr = FALSE))
}
cat(sprintf("Counting files in %d GT papers...\n", length(gt_ids)))
counts <- sapply(gt_ids, count_files)
df <- data.frame(pid = gt_ids, n = counts, stringsAsFactors = FALSE)
df <- df[df$n > 0, ]

set.seed(42)
pick <- function(lo, hi, k = 2) {
  sub <- df[df$n >= lo & df$n <= hi, ]
  if (nrow(sub) == 0) return(character(0))
  sub$pid[sample(seq_len(nrow(sub)), min(k, nrow(sub)))]
}

sample_pids <- c(
  pick(1,   5),    # tiny
  pick(6,  15),    # small
  pick(16, 30),    # medium
  pick(31, 80),    # large
  pick(81, 300)    # xlarge
)
sample_pids <- unique(sample_pids)
cat(sprintf("Calibration sample: %d papers\n\n", length(sample_pids)))

for (pid in sample_pids) {
  out_dir <- file.path(CAL_OUT_DIR, "outputs", pid)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  n_files <- length(list.files(file.path(DATA_ROOT, pid), recursive = TRUE))
  cat(sprintf("── %s  (%d files) ... ", pid, n_files))

  if (paper_done(out_dir)) { cat("[SKIP]\n"); next }

  result <- tryCatch(
    run_index(paper_id = pid, download = FALSE, output_dir = out_dir),
    error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
  )
  cat(if (!is.null(result) && isTRUE(result$success)) "ok\n" else "FAILED\n")
}

# ── Fit model from traces ─────────────────────────────────────────────────────
cat("\n── Calibration results ──────────────────────────────────────────────────\n")

trace_files <- list.files(CAL_OUT_DIR, pattern = "thinking_traces.csv",
                          recursive = TRUE, full.names = TRUE)
dfs <- lapply(trace_files, function(f)
  tryCatch(read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL))
traces <- do.call(rbind, Filter(Negate(is.null), dfs))
traces <- traces[!is.na(traces$tokens_in) & traces$tokens_in > 0, ]

if (nrow(traces) < 2) {
  cat("Not enough token data to fit — check that CAPTURE_THINKING is working.\n")
  quit(save = "no")
}

cat(sprintf("%-6s  %-5s  %-6s  %-5s  %s\n", "paths", "in", "out", "ratio", "stage"))
for (i in order(traces$n_paths)) {
  r <- traces[i, ]
  cat(sprintf("%-6d  %-5d  %-5d  %-5.1f  %s\n",
              r$n_paths, r$tokens_in, r$tokens_out,
              r$tokens_in / max(r$n_paths, 1),
              r$stage_name))
}

fit_in  <- lm(tokens_in  ~ n_paths, data = traces)
fit_out <- lm(tokens_out ~ n_paths, data = traces)

base_in  <- round(coef(fit_in)[1])
rate_in  <- round(coef(fit_in)[2])
base_out <- round(coef(fit_out)[1])
rate_out <- round(coef(fit_out)[2])

cat(sprintf("\nFitted constants (copy into estimate_tokens.R):\n"))
cat(sprintf("  BASE_TOKENS_IN          <- %dL\n", base_in))
cat(sprintf("  AVG_TOKENS_IN_PER_FILE  <- %dL\n", rate_in))
cat(sprintf("  BASE_TOKENS_OUT         <- %dL\n", base_out))
cat(sprintf("  AVG_TOKENS_OUT_PER_FILE <- %dL\n", rate_out))
cat(sprintf("\n  R² in=%.3f  R² out=%.3f  (n=%d calls)\n",
            summary(fit_in)$r.squared, summary(fit_out)$r.squared, nrow(traces)))
