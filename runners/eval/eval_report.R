# eval_report.R
# Reads all results/eval/step*.csv and renders a markdown summary.
# Output: results/eval/eval_report_<date>.md
#
# Sections:
#   1. Step 1 — Hyperparameter grid (macro F1 by temp × think, per model)
#   2. Step 2 — Prompt format comparison
#   3. Step 3 — Cross-model accuracy (main thesis table)
#   4. Step 4 — Stability TARa@5

source("runners/eval/eval_helpers.R")

STEP1_PATH   <- file.path(EVAL_RESULTS_DIR, "step1_results.csv")
STEP2_PATH   <- file.path(EVAL_RESULTS_DIR, "step2_results.csv")
STEP3_PATH   <- file.path(EVAL_RESULTS_DIR, "step3_summary.csv")
STEP4_TARA   <- file.path(EVAL_RESULTS_DIR, "step4_tara.csv")
STEP4_SUM    <- file.path(EVAL_RESULTS_DIR, "step4_summary.csv")
REPORT_PATH  <- file.path(EVAL_RESULTS_DIR,
                           sprintf("eval_report_%s.md",
                                   format(Sys.time(), "%Y-%m-%d_%H-%M")))

# ── helpers ──────────────────────────────────────────────────────────────────

fmt <- function(x, digits = 1, suffix = "") {
  if (is.null(x) || all(is.na(x))) return("—")
  sprintf(paste0("%.", digits, "f%s"), x, suffix)
}

fmt_pct <- function(x, digits = 1) fmt(x, digits, "%")

md_table <- function(header, rows) {
  sep <- paste(rep("|---", length(header)), collapse = "") |> paste0("|")
  body <- vapply(rows, function(r) paste0("| ", paste(r, collapse = " | "), " |"),
                 character(1))
  c(paste0("| ", paste(header, collapse = " | "), " |"), sep, body)
}

lines <- character(0)
L  <- function(...) lines <<- c(lines, paste0(...))
BR <- function()    lines <<- c(lines, "")

load_csv <- function(path, label) {
  if (!file.exists(path)) { message("Missing: ", path); return(NULL) }
  df <- tryCatch(read.csv(path, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(df)) { message("Could not read: ", path); return(NULL) }
  message(sprintf("Loaded %s: %d rows", label, nrow(df)))
  df
}

# ── header ────────────────────────────────────────────────────────────────────

L("# LLM Evaluation Report")
L("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
BR()

# ── STEP 1: Hyperparameter grid ───────────────────────────────────────────────

L("---")
BR()
L("## Step 1 — Hyperparameter Grid (macro F1 by temp × think)")
BR()
L("Best config per model is highlighted with **bold**.")
BR()

step1 <- load_csv(STEP1_PATH, "step1")

if (!is.null(step1)) {
  step1$model_label <- step1$model_label %||% step1$model
  for (mdl in unique(step1$model)) {
    sub  <- step1[step1$model == mdl, ]
    lbl  <- sub$model_label[1]
    best <- which.max(sub$macro_f1)

    L("### ", lbl)
    BR()

    thinks <- sort(unique(as.character(sub$think)))
    temps  <- sort(unique(as.numeric(sub$temp)))

    header <- c("temp \\ think", thinks)
    rows   <- lapply(temps, function(t) {
      cells <- sapply(thinks, function(tk) {
        row <- sub[abs(as.numeric(sub$temp) - t) < 1e-9 &
                   as.character(sub$think) == tk, ]
        if (nrow(row) == 0) return("—")
        val <- fmt_pct(row$macro_f1[1])
        idx <- which(sub$model == mdl &
                     abs(as.numeric(sub$temp) - t) < 1e-9 &
                     as.character(sub$think) == tk)
        if (length(idx) && idx[1] == best) paste0("**", val, "**") else val
      })
      c(as.character(t), cells)
    })

    for (ln in md_table(header, rows)) L(ln)
    BR()

    best_row <- sub[best, ]
    L("Best: think=`", best_row$think, "` temp=`", best_row$temp,
      "` → macro F1 ", fmt_pct(best_row$macro_f1),
      "  micro F1 ", fmt_pct(best_row$micro_f1),
      "  κ ", fmt(best_row$kappa, 3))
    BR()
  }
} else {
  L("> step1_results.csv not found — run step1_tune.R first.")
  BR()
}

# ── STEP 2: Prompt format comparison ──────────────────────────────────────────

L("---")
BR()
L("## Step 2 — Prompt Format Comparison")
BR()

step2 <- load_csv(STEP2_PATH, "step2")

if (!is.null(step2)) {
  step2$model_label <- step2$model_label %||% step2$model
  formats <- sort(unique(step2$prompt_format))

  header <- c("model", "think", "temp", formats, "best format")
  rows <- lapply(unique(step2$model), function(mdl) {
    sub <- step2[step2$model == mdl, ]
    lbl <- sub$model_label[1]
    tk  <- sub$think[1]
    tp  <- sub$temp[1]
    vals <- sapply(formats, function(fmt_name) {
      r <- sub[sub$prompt_format == fmt_name, ]
      if (nrow(r) == 0) "—" else fmt_pct(r$macro_f1[1])
    })
    f1s_num <- sapply(formats, function(fmt_name) {
      r <- sub[sub$prompt_format == fmt_name, ]
      if (nrow(r) == 0) NA_real_ else r$macro_f1[1]
    })
    best_fmt <- if (all(is.na(f1s_num))) "—" else formats[which.max(f1s_num)]
    c(lbl, as.character(tk), as.character(tp), vals, paste0("**", best_fmt, "**"))
  })

  for (ln in md_table(header, rows)) L(ln)
  BR()
} else {
  L("> step2_results.csv not found — run step2_prompt.R first.")
  BR()
}

# ── STEP 3: Cross-model accuracy (main thesis table) ──────────────────────────

L("---")
BR()
L("## Step 3 — Cross-Model Accuracy (Full GT)")
BR()

step3 <- load_csv(STEP3_PATH, "step3_summary")

if (!is.null(step3)) {
  step3$model_label <- step3$model_label %||% step3$model

  header <- c("model", "prompt", "think", "temp",
              "macro F1", "micro F1", "κ", "MCC", "accuracy", "retry %", "n papers")
  rows <- lapply(seq_len(nrow(step3)), function(i) {
    r <- step3[i, ]
    c(r$model_label,
      r$prompt_format %||% "—",
      as.character(r$think),
      as.character(r$temp),
      fmt_pct(r$macro_f1),
      fmt_pct(r$micro_f1),
      fmt(r$kappa, 3),
      fmt(r$mcc,   3),
      fmt_pct(r$accuracy),
      fmt_pct(r$retry_rate),
      as.character(r$n_papers %||% "—"))
  })

  for (ln in md_table(header, rows)) L(ln)
  BR()

  # Per-class F1 section — parse from step3_<model>.csv files if present
  step3_files <- list.files(EVAL_RESULTS_DIR,
                             pattern = "^step3_.+\\.csv$", full.names = TRUE)
  step3_files <- step3_files[!grepl("step3_summary", step3_files)]

  if (length(step3_files) > 0) {
    L("### Per-class F1 (from per-paper files)")
    BR()

    all_types <- character(0)
    per_model <- list()

    for (fp in step3_files) {
      df <- tryCatch(read.csv(fp, stringsAsFactors = FALSE), error = function(e) NULL)
      if (is.null(df) || nrow(df) == 0) next

      # Detect per_class_f1_* columns
      f1_cols <- grep("^per_class_f1_", names(df), value = TRUE)
      if (length(f1_cols) == 0) next

      lbl     <- unique(df$model_label %||% df$model)[1]
      types   <- sub("^per_class_f1_", "", f1_cols)
      all_types <- union(all_types, types)

      means <- sapply(f1_cols, function(col) mean(df[[col]], na.rm = TRUE))
      names(means) <- types
      per_model[[lbl]] <- means
    }

    if (length(per_model) > 0) {
      all_types <- sort(all_types)
      header_pc <- c("model", all_types)
      rows_pc   <- lapply(names(per_model), function(lbl) {
        vals <- sapply(all_types, function(t) {
          v <- per_model[[lbl]][t]
          if (is.null(v) || is.na(v)) "—" else fmt_pct(v)
        })
        c(lbl, vals)
      })
      for (ln in md_table(header_pc, rows_pc)) L(ln)
      BR()
    } else {
      L("> No per_class_f1_* columns found in step3 per-paper files.")
      L("> Re-run step3_final.R after adding per-class F1 saving to eval_helpers.R.")
      BR()
    }
  }
} else {
  L("> step3_summary.csv not found — run step3_final.R first.")
  BR()
}

# ── STEP 4: Stability (TARa@5) ────────────────────────────────────────────────

L("---")
BR()
L("## Step 4 — Stability (TARa@5)")
BR()
L("TARa@5 = proportion of files where all 5 repeated runs agree on type classification.")
BR()

step4_sum  <- load_csv(STEP4_SUM,  "step4_summary")
step4_tara <- load_csv(STEP4_TARA, "step4_tara")

if (!is.null(step4_sum)) {
  step4_sum$model_label <- step4_sum$model_label %||% step4_sum$model

  header <- c("model", "think", "temp", "prompt",
              "mean TARa@5", "SD", "min TARa@5", "worst paper", "n papers")
  rows <- lapply(seq_len(nrow(step4_sum)), function(i) {
    r <- step4_sum[i, ]
    c(r$model_label,
      as.character(r$think),
      as.character(r$temp),
      r$prompt_format %||% "—",
      fmt_pct(r$mean_tara5),
      fmt_pct(r$sd_tara5),
      fmt_pct(r$min_tara5),
      r$worst_paper %||% "—",
      as.character(r$n_papers %||% "—"))
  })

  for (ln in md_table(header, rows)) L(ln)
  BR()
} else {
  L("> step4_summary.csv not found — run step4_stability.R first.")
  BR()
}

# Per-paper TARa heatmap (models × papers)
if (!is.null(step4_tara) && nrow(step4_tara) > 0) {
  step4_tara$model_label <- step4_tara$model_label %||% step4_tara$model

  # Use latest run_id per model×paper in case of reruns
  latest <- do.call(rbind, lapply(
    split(step4_tara, list(step4_tara$model, step4_tara$paper_id)),
    function(g) g[which.max(g$run_id), ]
  ))

  models  <- sort(unique(latest$model_label))
  pids    <- sort(unique(latest$paper_id))

  if (length(models) > 1 || length(pids) > 1) {
    L("### Per-paper TARa@5 heatmap")
    BR()

    header_h <- c("paper_id", models)
    rows_h   <- lapply(pids, function(pid) {
      vals <- sapply(models, function(lbl) {
        r <- latest[latest$model_label == lbl & latest$paper_id == pid, ]
        if (nrow(r) == 0) "—" else fmt_pct(r$tara5[1])
      })
      c(pid, vals)
    })

    for (ln in md_table(header_h, rows_h)) L(ln)
    BR()
  }
}

# ── footer ────────────────────────────────────────────────────────────────────

L("---")
BR()
L("*Report generated by `runners/eval/eval_report.R`.*")

# ── write ─────────────────────────────────────────────────────────────────────

dir.create(EVAL_RESULTS_DIR, recursive = TRUE, showWarnings = FALSE)
writeLines(lines, REPORT_PATH)
cat(sprintf("\nReport written to: %s\n", REPORT_PATH))
