# probe_tokens.R
# Reads all existing thinking_traces.csv files and reports empirical
# token usage so estimate_tokens.R constants can be calibrated.

source("runners/eval/eval_helpers.R")

files <- list.files("results/eval/outputs", pattern = "thinking_traces.csv",
                    recursive = TRUE, full.names = TRUE)

if (length(files) == 0) stop("No thinking_traces.csv files found yet.")

dfs <- lapply(files, function(f) {
  df <- tryCatch(read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(df)) return(NULL)
  df$src_file <- f
  df
})
df <- do.call(rbind, Filter(Negate(is.null), dfs))

df <- df[!is.na(df$tokens_in) & df$tokens_in > 0, ]
cat(sprintf("Total rows with token data: %d across %d files\n\n",
            nrow(df), length(unique(df$src_file))))

# Per-call: n_paths vs tokens
cat("── Per-call detail (n_paths | tokens_in | tokens_out | stage) ──\n")
df_sorted <- df[order(df$n_paths), ]
for (i in seq_len(nrow(df_sorted))) {
  r <- df_sorted[i, ]
  cat(sprintf("  n_paths=%2d  in=%5d  out=%4d  stage=%-30s  model=%s\n",
              r$n_paths, r$tokens_in, r$tokens_out,
              substr(r$stage_name, 1, 30), substr(r$model, 1, 30)))
}

# Fit: tokens_in = BASE + RATE * n_paths
if (nrow(df) >= 2) {
  fit <- lm(tokens_in ~ n_paths, data = df)
  base <- round(coef(fit)[1])
  rate <- round(coef(fit)[2])
  cat(sprintf("\n── Linear fit: tokens_in = %d + %d * n_paths  (R²=%.3f)\n",
              base, rate, summary(fit)$r.squared))
  fit_out <- lm(tokens_out ~ n_paths, data = df)
  cat(sprintf("── Linear fit: tokens_out = %d + %d * n_paths  (R²=%.3f)\n",
              round(coef(fit_out)[1]), round(coef(fit_out)[2]),
              summary(fit_out)$r.squared))
}

# Per-paper totals
pp <- aggregate(cbind(tokens_in, tokens_out, total_calls = n_paths > -999) ~ paper_id,
                data = transform(df, total_calls = 1), FUN = sum)
names(pp)[4] <- "n_calls"
cat(sprintf("\n── Per-paper totals (%d papers) ──\n", nrow(pp)))
for (i in seq_len(nrow(pp))) {
  r <- pp[i, ]
  cat(sprintf("  %-25s  calls=%d  in=%6d  out=%5d\n",
              r$paper_id, r$n_calls, r$tokens_in, r$tokens_out))
}
cat(sprintf("\nMedian per paper:  in=%d  out=%d\n",
            median(pp$tokens_in), median(pp$tokens_out)))
cat(sprintf("Mean   per paper:  in=%.0f  out=%.0f\n",
            mean(pp$tokens_in), mean(pp$tokens_out)))
