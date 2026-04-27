# run_tests.R
# ─────────────────────────────────────────────────────────────────────────────
# Runs the full pipeline (index → codebook label → psychds) on the hard-dataset
# papers (tests/test_papers.csv) and writes a quality report.
#
# All papers must already be downloaded (data_check/data/<paper_id>/).
# Outputs are written to:
#   data_check/tests/outputs/<paper_id>/     (stages 1 & 2)
#   data_check/tests/psychds/<paper_id>/     (stage 3)
#   data_check/tests/test_log.csv            (one row per paper, appended each run)
#   data_check/results/test_report_<date>.md (generated after each run)
#
# Usage (interactive):  source("data_check/runners/run_tests.R")
# Usage (CLI):          Rscript data_check/runners/run_tests.R
#
# Set REPORT_ONLY <- TRUE to regenerate the report from the last run without
# re-running the pipeline.
# ─────────────────────────────────────────────────────────────────────────────


REPORT_ONLY <- FALSE
if (!exists("REPORT_ONLY")) REPORT_ONLY <- FALSE
FULL_RUN <- TRUE


# ── Paths ──────────────────────────────────────────────────────────────────────

TEST_DIR         <- "./data_check/tests"
TEST_OUTPUT_DIR  <- file.path(TEST_DIR, "outputs")
TEST_PSYCHDS_DIR <- file.path(TEST_DIR, "psychds")
TEST_LOG_PATH    <- file.path(TEST_DIR, "test_log.csv")
REPORT_DIR       <- "./data_check/results"
GT_DIR           <- "./data_check/ground_truth"

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
# ── Pipeline sources (only needed for full run) ────────────────────────────────
source("data_check/pipeline/prompts.R", local = TRUE)
source("data_check/pipeline/0_index.R")
source("data_check/pipeline/2_codebook_label.R")
source("data_check/pipeline/3_psychds_convert.R")

LLM_TEMPERATURE  <- 0.7
LLM_THINK_LEVEL  <- "low"
CAPTURE_THINKING <- TRUE   # write one row per prompt call to thinking_traces.csv
LLM_MODEL        <- "ollama/gpt-oss:120b-cloud"
llm_model(LLM_MODEL)
TEST_TITLE       <- sprintf("_%s_MD_V2_THINK_%s_TEMP_%s", "120b", LLM_THINK_LEVEL, LLM_TEMPERATURE) #MD stands for the markdown Prompt
STRUCTURE_PROMPT <- STRUCTURE_PROMPT_MD_V2

# ── Report helpers ─────────────────────────────────────────────────────────────

pct <- function(n, d) if (d == 0L) "n/a" else sprintf("%.1f%%", 100 * n / d)

fmt_s <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  if (is.na(x)) "—" else sprintf("%.1f", x)
}

is_true <- function(x) !is.na(x) & as.logical(x)

na_dash <- function(x) ifelse(is.na(x) | x == "NA", "—", as.character(x))

md_table <- function(df) {
  df[] <- lapply(df, na_dash)
  hdr  <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep  <- paste0("| ", paste(rep("---", ncol(df)), collapse = " | "), " |")
  rows <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
  paste(c(hdr, sep, rows), collapse = "\n")
}

most_common <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_character_)
  names(sort(table(x), decreasing = TRUE))[1]
}

pct_num <- function(n, d) if (d == 0L || is.na(d)) NA_real_ else 100 * n / d
fmt1    <- function(x) if (is.na(x)) "n/a" else sprintf("%.1f%%", x)
fmt3    <- function(x) if (is.na(x)) "n/a" else sprintf("%.3f", x)

get_ext <- function(path) {
  base    <- basename(path)
  has_dot <- grepl("\\.", base)
  tolower(ifelse(has_dot, sub(".*\\.", "", base), "(none)"))
}

cm_stats <- function(cm_m) {
  N <- sum(cm_m)
  if (N == 0) return(list(kappa = NA_real_, macro_f1 = NA_real_, mcc = NA_real_, accuracy = NA_real_))
  rs  <- rowSums(cm_m); cs <- colSums(cm_m)
  p_o <- sum(diag(cm_m)) / N
  p_e <- sum(rs * cs) / N^2
  kap <- if (p_e < 1) (p_o - p_e) / (1 - p_e) else NA_real_
  all_t <- rownames(cm_m)
  f1s <- sapply(all_t, function(cls) {
    tp <- cm_m[cls, cls]; fp <- sum(cm_m[, cls]) - tp; fn <- sum(cm_m[cls, ]) - tp
    p  <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
    r  <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
    if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
  })
  mf1   <- mean(f1s, na.rm = TRUE) * 100
  mcc_n <- N * sum(diag(cm_m)) - sum(rs * cs)
  mcc_d <- sqrt((N^2 - sum(cs^2)) * (N^2 - sum(rs^2)))
  mcc   <- if (mcc_d > 0) mcc_n / mcc_d else NA_real_
  list(kappa = kap, macro_f1 = mf1, mcc = mcc, accuracy = p_o * 100, f1s = f1s * 100)
}

kappa_interp <- function(k) {
  if (is.na(k))   return("n/a")
  if (k < 0)      return("poor (< 0)")
  if (k < 0.20)   return("slight (0.00–0.20)")
  if (k < 0.40)   return("fair (0.20–0.40)")
  if (k < 0.60)   return("moderate (0.40–0.60)")
  if (k < 0.80)   return("substantial (0.60–0.80)")
  return("almost perfect (0.80–1.00)")
}

# ── Report generator ───────────────────────────────────────────────────────────

generate_report <- function() {
  if (!file.exists(TEST_LOG_PATH)) {
    cat("  [report] test_log.csv not found — skipping report\n")
    return(invisible(NULL))
  }

  log_all    <- read.csv(TEST_LOG_PATH,
                         colClasses       = c(paper_id = "character"),
                         stringsAsFactors = FALSE)
  latest_run <- if (nrow(log_all) > 0) tail(sort(unique(log_all$run_id)), 1) else "—"

  papers_df    <- read.csv(file.path(TEST_DIR, "test_papers.csv"),
                           colClasses = c(id = "character", source = "character"),
                           stringsAsFactors = FALSE)
  if (!"source" %in% names(papers_df)) papers_df$source <- "osf"
  paper_labels  <- setNames(papers_df$label,  papers_df$id)
  paper_sources <- setNames(papers_df$source, papers_df$id)

  # Build run_log: most recent entry per paper (across all runs).
  # Papers never run get an all-NA placeholder row so the report lists them.
  run_log <- do.call(rbind, lapply(papers_df$id, function(pid) {
    rows <- log_all[log_all$paper_id == pid, ]
    if (nrow(rows) == 0) {
      r <- as.data.frame(
        setNames(as.list(rep(NA_character_, ncol(log_all))), names(log_all)),
        stringsAsFactors = FALSE
      )
      r$paper_id <- pid
      return(r)
    }
    rows[tail(order(rows$run_id), 1L), , drop = FALSE]
  }))

  short_label <- function(pid) {
    lbl <- paper_labels[pid]
    if (is.na(lbl)) pid else substr(lbl, 1L, 55L)
  }

  # Load GT + structure, merge into one accuracy frame
  acc_list <- list()
  for (pid in run_log$paper_id) {
    src      <- if (pid %in% papers_df$id) {
      row_src <- papers_df$source[papers_df$id == pid]
      if (length(row_src) > 0 && !is.na(row_src[1])) row_src[1] else "osf"
    } else "osf"
    gt_path  <- file.path(GT_DIR, src, paste0(pid, ".csv"))
    str_path <- file.path(TEST_DIR, "outputs", src, pid, "structure.csv")
    if (!file.exists(gt_path) || !file.exists(str_path)) next
    gt  <- read.csv(gt_path,  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
    str <- read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
    if (nrow(gt) == 0) next
    keep_str <- intersect(c("rel_path", "type", "group", "data_granularity", "type_source"),
                          names(str))
    m <- merge(gt[, c("rel_path", "type_gt", "group_gt", "data_granularity_gt")],
               str[, keep_str], by = "rel_path", all.x = TRUE)
    m$paper_id <- pid
    acc_list[[pid]] <- m
  }
  acc     <- if (length(acc_list) > 0) do.call(rbind, acc_list) else NULL
  has_acc <- !is.null(acc) && nrow(acc) > 0

  # Build lines
  lines    <- character(0)
  L  <- function(...) { lines <<- c(lines, paste0(...)) }
  BR <- function()    { lines <<- c(lines, "") }

  date_str <- format(Sys.Date(), "%Y-%m-%d")
  now_str  <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  n_papers <- nrow(run_log)

  L("# Test Report — ", date_str)
  BR()
  L("**Latest run:** `", latest_run, "`  |  **Papers:** ", n_papers,
    " (most recent result per paper)  |  **Generated:** ", now_str)
  BR()
  L("---")
  BR()

  # ── 1. Run Summary ───────────────────────────────────────────────────────────
  L("## 1. Run Summary")
  BR()
  summary_rows <- do.call(rbind, lapply(seq_len(n_papers), function(i) {
    r <- run_log[i, ]
    data.frame(
      Paper    = r$paper_id,
      Label    = short_label(r$paper_id),
      Index    = ifelse(is_true(r$index_success),    "ok", paste0("FAIL: ", r$index_error)),
      Codebook = ifelse(is_true(r$codebook_success), "ok", paste0("FAIL: ", r$codebook_error)),
      PsychDS  = ifelse(is_true(r$psychds_success),  "ok", paste0("FAIL: ", r$psychds_error)),
      stringsAsFactors = FALSE
    )
  }))
  L(md_table(summary_rows))
  BR()
  L(sprintf("Index: **%d/%d ok**  |  Codebook: **%d/%d ok**  |  PsychDS: **%d/%d ok**",
    sum(is_true(run_log$index_success)),    n_papers,
    sum(is_true(run_log$codebook_success)), n_papers,
    sum(is_true(run_log$psychds_success)),  n_papers))
  BR()
  L("---")
  BR()

  # ── 2. Timing ────────────────────────────────────────────────────────────────
  L("## 2. Timing")
  BR()
  timing_rows <- do.call(rbind, lapply(seq_len(n_papers), function(i) {
    r   <- run_log[i, ]
    idx <- suppressWarnings(as.numeric(r$index_elapsed_sec))
    cb  <- suppressWarnings(as.numeric(r$codebook_elapsed_sec))
    ps  <- suppressWarnings(as.numeric(r$psychds_elapsed_sec))
    data.frame(
      Paper          = r$paper_id,
      Label          = short_label(r$paper_id),
      `Index (s)`    = fmt_s(idx),
      `Codebook (s)` = fmt_s(cb),
      `PsychDS (s)`  = fmt_s(ps),
      `Total (s)`    = sprintf("%.1f", sum(c(idx, cb, ps), na.rm = TRUE)),
      check.names    = FALSE, stringsAsFactors = FALSE
    )
  }))
  num <- function(col) suppressWarnings(as.numeric(run_log[[col]]))
  tot_idx <- sum(num("index_elapsed_sec"),   na.rm = TRUE)
  tot_cb  <- sum(num("codebook_elapsed_sec"), na.rm = TRUE)
  tot_ps  <- sum(num("psychds_elapsed_sec"),  na.rm = TRUE)
  totals <- data.frame(
    Paper = "**TOTAL**", Label = "",
    `Index (s)`    = sprintf("%.1f", tot_idx),
    `Codebook (s)` = sprintf("%.1f", tot_cb),
    `PsychDS (s)`  = sprintf("%.1f", tot_ps),
    `Total (s)`    = sprintf("%.1f", tot_idx + tot_cb + tot_ps),
    check.names = FALSE, stringsAsFactors = FALSE
  )
  means <- data.frame(
    Paper = "**MEAN**", Label = "",
    `Index (s)`    = fmt_s(mean(num("index_elapsed_sec"),   na.rm = TRUE)),
    `Codebook (s)` = fmt_s(mean(num("codebook_elapsed_sec"), na.rm = TRUE)),
    `PsychDS (s)`  = fmt_s(mean(num("psychds_elapsed_sec"),  na.rm = TRUE)),
    `Total (s)`    = fmt_s(mean(rowSums(suppressWarnings(
      cbind(num("index_elapsed_sec"), num("codebook_elapsed_sec"), num("psychds_elapsed_sec"))
    ), na.rm = TRUE))),
    check.names = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(rbind(timing_rows, totals, means)))
  BR()
  L("---")
  BR()

  # ── 3. Classification Accuracy ────────────────────────────────────────────────
  L("## 3. Classification Accuracy")
  BR()
  if (!has_acc) {
    L("_No ground truth found. Run `runners/run_test_validation_gui.R` to annotate._")
    BR()
  } else {
    n_gt      <- nrow(acc)
    n_gt_paps <- length(unique(acc$paper_id))
    valid     <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]
    all_types <- sort(unique(c(valid$type_gt, valid$type)))

    data_acc <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]
    dg_acc   <- data_acc[!is.na(data_acc$data_granularity_gt), ]
    df_acc   <- data_acc[!is.na(data_acc$data_format_gt), ]

    # ── File-pooled confusion matrix + global stats ──────────────────────────
    ctypes <- sort(unique(c(valid$type_gt, valid$type)))
    cm_mat <- if (nrow(valid) > 0) {
      as.matrix(table(
        gt   = factor(valid$type_gt, levels = ctypes),
        pred = factor(valid$type,    levels = ctypes)
      ))
    } else NULL

    fp_stats <- if (!is.null(cm_mat)) cm_stats(cm_mat) else
      list(kappa = NA_real_, macro_f1 = NA_real_, mcc = NA_real_, accuracy = NA_real_)

    tc  <- sum(!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt == acc$type)
    tn  <- sum(!is.na(acc$type_gt))
    gc  <- sum(!is.na(data_acc$group_gt) & !is.na(data_acc$group) & data_acc$group_gt == data_acc$group)
    gn  <- sum(!is.na(data_acc$group_gt))
    dc  <- sum(!is.na(dg_acc$data_granularity) & dg_acc$data_granularity_gt == dg_acc$data_granularity)
    dn  <- nrow(dg_acc)
    dfc <- sum(!is.na(df_acc$data_format) & df_acc$data_format_gt == df_acc$data_format)
    dfn <- nrow(df_acc)

    # Per-class file-pooled P/R/F1
    class_metrics <- do.call(rbind, lapply(all_types, function(cls) {
      tp <- sum(valid$type_gt == cls & valid$type == cls)
      fp <- sum(valid$type_gt != cls & valid$type == cls)
      fn <- sum(valid$type_gt == cls & valid$type != cls)
      tn_c <- sum(valid$type_gt != cls & valid$type != cls)
      prec <- pct_num(tp, tp + fp); rec <- pct_num(tp, tp + fn)
      f1   <- if (!is.na(prec) && !is.na(rec) && (prec + rec) > 0) 2*prec*rec/(prec+rec) else NA_real_
      fpr  <- pct_num(fp, fp + tn_c); fnr <- pct_num(fn, tp + fn)
      fp_rows <- valid[valid$type_gt != cls & valid$type == cls, ]
      fn_rows <- valid[valid$type_gt == cls & valid$type != cls, ]
      data.frame(
        class = cls, tp = tp, fp = fp, fn = fn,
        precision = prec, recall = rec, f1 = f1, fpr = fpr, fnr = fnr,
        top_fp_src = { mc <- most_common(fp_rows$type_gt); if (is.na(mc)) "—" else mc },
        top_fn_dst = { mc <- most_common(fn_rows$type);    if (is.na(mc)) "—" else mc },
        stringsAsFactors = FALSE
      )
    }))

    micro_tp <- sum(class_metrics$tp); micro_fp <- sum(class_metrics$fp); micro_fn <- sum(class_metrics$fn)
    micro_p  <- if ((micro_tp + micro_fp) > 0) micro_tp / (micro_tp + micro_fp) else NA_real_
    micro_r  <- if ((micro_tp + micro_fn) > 0) micro_tp / (micro_tp + micro_fn) else NA_real_
    micro_f1 <- if (!is.na(micro_p) && !is.na(micro_r) && (micro_p + micro_r) > 0)
      2 * micro_p * micro_r / (micro_p + micro_r) * 100 else NA_real_

    # ── Per-paper metrics (kappa, macro_f1, MCC) ──────────────────────────────
    per_paper_full <- do.call(rbind, Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
      v <- valid[valid$paper_id == pid, ]
      if (nrow(v) < 2) return(NULL)
      all_t <- sort(unique(c(v$type_gt, v$type)))
      cm_p  <- as.matrix(table(
        gt   = factor(v$type_gt, levels = all_t),
        pred = factor(v$type,    levels = all_t)
      ))
      s  <- cm_stats(cm_p)
      a  <- acc[acc$paper_id == pid, ]
      da <- a[!is.na(a$type_gt) & a$type_gt == "data", ]
      dg <- da[!is.na(da$data_granularity_gt), ]
      df <- da[!is.na(da$data_format_gt), ]
      n_group <- sum(!is.na(a$group_gt)); n_dg <- nrow(dg); n_df <- nrow(df)
      w <- v[v$type_gt != v$type, ]
      top_err <- if (nrow(w) > 0) {
        pk <- paste0(w$type_gt, "→", w$type)
        tbl <- sort(table(pk), decreasing = TRUE)
        sprintf("%s (%d)", names(tbl)[1], tbl[[1]])
      } else "—"
      data.frame(
        paper_id  = pid, n_files = nrow(v),
        kappa     = s$kappa, macro_f1 = s$macro_f1, mcc = s$mcc, type_acc = s$accuracy,
        group_acc = pct_num(sum(!is.na(a$group_gt) & !is.na(a$group) & a$group_gt == a$group), n_group),
        dg_acc    = pct_num(sum(!is.na(dg$data_granularity) & dg$data_granularity_gt == dg$data_granularity), n_dg),
        df_acc    = pct_num(sum(!is.na(df$data_format) & df$data_format_gt == df$data_format), n_df),
        top_err   = top_err,
        stringsAsFactors = FALSE
      )
    })))

    pa_kappa    <- mean(per_paper_full$kappa,    na.rm = TRUE)
    pa_macro_f1 <- mean(per_paper_full$macro_f1, na.rm = TRUE)
    pa_mcc      <- mean(per_paper_full$mcc,      na.rm = TRUE)
    pa_accuracy <- mean(per_paper_full$type_acc, na.rm = TRUE)
    pa_grp_acc  <- mean(per_paper_full$group_acc, na.rm = TRUE)
    pa_dg_acc   <- mean(per_paper_full$dg_acc,   na.rm = TRUE)
    pa_df_acc   <- mean(per_paper_full$df_acc,   na.rm = TRUE)

    # Paper-averaged confusion matrix (row-normalised per paper, then averaged)
    pa_cm_sum <- Reduce("+", Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
      v <- valid[valid$paper_id == pid, ]
      if (nrow(v) < 2) return(NULL)
      cm_p <- as.matrix(table(
        gt   = factor(v$type_gt, levels = ctypes),
        pred = factor(v$type,    levels = ctypes)
      ))
      rs <- rowSums(cm_p)
      cm_p / ifelse(rs == 0, 1, rs)
    })))
    pa_cm_norm <- if (!is.null(pa_cm_sum)) {
      pa_n <- rowSums(pa_cm_sum)
      pa_cm_sum / ifelse(pa_n == 0, 1, pa_n)
    } else NULL

    # Group / DG / data_format confusion matrices
    grp_valid <- acc[!is.na(acc$group_gt) & !is.na(acc$group), ]
    cm_grp <- if (nrow(grp_valid) > 0) {
      grp_lvl <- sort(unique(c(grp_valid$group_gt, grp_valid$group)))
      as.matrix(table(gt = factor(grp_valid$group_gt, levels = grp_lvl),
                      pred = factor(grp_valid$group,  levels = grp_lvl)))
    } else NULL

    dg_valid <- acc[!is.na(acc$type_gt) & acc$type_gt == "data" &
                    !is.na(acc$type) & acc$type == "data" &
                    !is.na(acc$data_granularity_gt) & !is.na(acc$data_granularity), ]
    cm_dg <- if (nrow(dg_valid) > 0) {
      dg_lvl <- sort(unique(c(dg_valid$data_granularity_gt, dg_valid$data_granularity)))
      as.matrix(table(gt = factor(dg_valid$data_granularity_gt, levels = dg_lvl),
                      pred = factor(dg_valid$data_granularity,  levels = dg_lvl)))
    } else NULL

    df_valid2 <- acc[!is.na(acc$type_gt) & acc$type_gt == "data" &
                     !is.na(acc$type) & acc$type == "data" &
                     !is.na(acc$data_format_gt) & !is.na(acc$data_format), ]
    cm_df2 <- if (nrow(df_valid2) > 0) {
      df_lvl <- sort(unique(c(df_valid2$data_format_gt, df_valid2$data_format)))
      as.matrix(table(gt = factor(df_valid2$data_format_gt, levels = df_lvl),
                      pred = factor(df_valid2$data_format,  levels = df_lvl)))
    } else NULL

    # Extension error analysis
    acc$ext <- get_ext(acc$rel_path)
    valid_ext <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]
    ext_stats <- do.call(rbind, Filter(Negate(is.null), lapply(sort(unique(valid_ext$ext)), function(e) {
      rows <- valid_ext[valid_ext$ext == e, ]
      n <- nrow(rows); wrong <- rows[rows$type_gt != rows$type, ]
      if (n < 3) return(NULL)
      pk <- paste0(wrong$type_gt, "→", wrong$type)
      tbl <- sort(table(pk), decreasing = TRUE)
      top_pair <- if (length(tbl) > 0) sprintf("%s (%d)", names(tbl)[1], tbl[[1]]) else "—"
      data.frame(ext = e, `N files` = n, `N errors` = nrow(wrong),
                 `Error %` = pct(nrow(wrong), n), `Top confusion` = top_pair,
                 check.names = FALSE, stringsAsFactors = FALSE)
    })))
    if (!is.null(ext_stats) && nrow(ext_stats) > 0)
      ext_stats <- ext_stats[order(-ext_stats[["N errors"]]), ]

    # ── Metric glossary ───────────────────────────────────────────────────────
    L("### 3.0 Metric Glossary")
    BR()
    L("| Metric | What it measures | Range |")
    L("|---|---|---|")
    L("| **Accuracy** | Fraction of files classified correctly | 0–100% |")
    L("| **Precision** | Of files labelled class X, how many truly are X | 0–100% |")
    L("| **Recall** | Of files truly class X, how many did the model catch | 0–100% |")
    L("| **F1** | Harmonic mean of P and R: `2·P·R/(P+R)` | 0–100% |")
    L("| **Macro F1** | Unweighted average of per-class F1 (equal weight per class) | 0–100% |")
    L("| **Micro F1** | F1 from pooled TP/FP/FN (= accuracy in multi-class) | 0–100% |")
    L("| **Cohen's κ** | Agreement beyond chance (inter-rater stat) — < 0.20 slight, 0.20–0.40 fair, 0.40–0.60 moderate, 0.60–0.80 substantial, > 0.80 almost perfect | −1 to 1 |")
    L("| **MCC** | Matthews Correlation Coefficient — robust to class imbalance | −1 to 1 |")
    L("| **FPR / FNR** | False positive / false negative rate per class | 0–100% |")
    BR()
    L("_**File-pooled**: all files counted once — large repos dominate. **Paper-averaged**: metric computed per paper then averaged — each paper is one replication unit (primary metric)._")
    BR()

    # ── Executive summary ─────────────────────────────────────────────────────
    L("### 3.1 Executive Summary")
    BR()
    L(sprintf("_Based on **%d annotated files** across **%d papers**_", n_gt, n_gt_paps))
    BR()
    L("| Metric | **Paper-averaged** (primary) | File-pooled (secondary) |")
    L("|---|---|---|")
    L(sprintf("| **Cohen's κ** | **%s** (%s) | %s (%s) |",
      fmt3(pa_kappa), kappa_interp(pa_kappa), fmt3(fp_stats$kappa), kappa_interp(fp_stats$kappa)))
    L(sprintf("| **Macro F1** | **%s** | %s |", fmt1(pa_macro_f1), fmt1(fp_stats$macro_f1)))
    L(sprintf("| **Micro F1** | — | %s |", fmt1(micro_f1)))
    L(sprintf("| **MCC** | **%s** | %s |", fmt3(pa_mcc), fmt3(fp_stats$mcc)))
    L(sprintf("| **Overall accuracy** | **%s** | %s (%d / %d files) |",
      fmt1(pa_accuracy), pct(tc, tn), tc, tn))
    BR()
    L("**Subfield performance:**")
    BR()
    L("| Task | **Paper-averaged** | File-pooled | N files |")
    L("|---|---|---|---|")
    L(sprintf("| Group classification | **%s** | %s | %d |", fmt1(pa_grp_acc), pct(gc, gn), gn))
    L(sprintf("| data_granularity | **%s** | %s | %d |",    fmt1(pa_dg_acc),  pct(dc, dn), dn))
    L(sprintf("| data_format | **%s** | %s | %d |",         fmt1(pa_df_acc),  pct(dfc, dfn), dfn))
    BR()

    # ── Legacy accuracy table (for cross-report comparison) ───────────────────
    L("### 3.2 Accuracy Summary (legacy — cross-report comparable)")
    BR()
    L("_Simple correct/total counts — matches older report format._")
    BR()
    L("| Metric | Correct | Total | Accuracy |")
    L("|---|---|---|---|")
    L(sprintf("| **File type** | %d | %d | **%s** |", tc, tn, pct(tc, tn)))
    L(sprintf("| **Group** (data files only) | %d | %d | **%s** |", gc, gn, pct(gc, gn)))
    L(sprintf("| **data_granularity** (data files only) | %d | %d | **%s** |", dc, dn, pct(dc, dn)))
    BR()

    # ── Per-paper summary ─────────────────────────────────────────────────────
    L("### 3.3 Per-Paper")
    BR()
    per_paper_tbl <- do.call(rbind, lapply(unique(acc$paper_id), function(pid) {
      a  <- acc[acc$paper_id == pid, ]
      da <- a[!is.na(a$type_gt) & a$type_gt == "data", ]
      dg <- da[!is.na(da$data_granularity_gt), ]
      n  <- sum(!is.na(a$type_gt))
      # Grab kappa/MCC from per_paper_full if available
      ppf <- if (!is.null(per_paper_full) && pid %in% per_paper_full$paper_id)
        per_paper_full[per_paper_full$paper_id == pid, ] else NULL
      data.frame(
        Paper       = pid,
        Label       = short_label(pid),
        `Files GT`  = n,
        `Type acc`  = pct(sum(!is.na(a$type_gt) & !is.na(a$type) & a$type_gt == a$type), n),
        `κ`         = if (!is.null(ppf)) fmt3(ppf$kappa[1])    else "—",
        `Macro F1`  = if (!is.null(ppf)) fmt1(ppf$macro_f1[1]) else "—",
        `MCC`       = if (!is.null(ppf)) fmt3(ppf$mcc[1])      else "—",
        `Group acc` = { gn2 <- sum(!is.na(da$group_gt)); if (gn2 > 0) pct(sum(!is.na(da$group) & da$group_gt == da$group), gn2) else "—" },
        `DG acc`    = { dn2 <- nrow(dg); if (dn2 > 0) pct(sum(!is.na(dg$data_granularity) & dg$data_granularity_gt == dg$data_granularity), dn2) else "—" },
        `Top error` = if (!is.null(ppf)) ppf$top_err[1] else "—",
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(per_paper_tbl))
    BR()

    # ── Per-class P/R/F1 ─────────────────────────────────────────────────────
    L("### 3.4 Per-Class Metrics (file-pooled)")
    BR()
    L("_How often each true type was correctly identified. TP/FP/FN are file-pooled counts._")
    BR()
    cm_tbl <- do.call(rbind, lapply(seq_len(nrow(class_metrics)), function(i) {
      cm <- class_metrics[i, ]
      data.frame(
        Type           = cm$class,
        TP             = cm$tp, FP = cm$fp, FN = cm$fn,
        Precision      = fmt1(cm$precision),
        Recall         = fmt1(cm$recall),
        F1             = fmt1(cm$f1),
        FPR            = fmt1(cm$fpr),
        FNR            = fmt1(cm$fnr),
        `Top FP src`   = cm$top_fp_src,
        `Top FN dest`  = cm$top_fn_dst,
        check.names    = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(cm_tbl))
    BR()

    # ── Paper-averaged per-class P/R/F1 ──────────────────────────────────────
    L("### 3.5 Per-Class Metrics (paper-averaged)")
    BR()
    L("_Each metric computed per paper then averaged across papers — every paper weighted equally. Only papers where the class appears in GT contribute. SD = standard deviation across papers._")
    BR()
    pa_class_rows <- do.call(rbind, lapply(all_types, function(cls) {
      vals <- Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
        v <- valid[valid$paper_id == pid, ]
        if (sum(v$type_gt == cls) == 0) return(NULL)
        tp <- sum(v$type_gt == cls & v$type == cls)
        fp <- sum(v$type_gt != cls & v$type == cls)
        fn <- sum(v$type_gt == cls & v$type != cls)
        p  <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
        r  <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
        f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r)*100 else NA_real_
        list(p = if (!is.na(p)) p*100 else NA_real_, r = if (!is.na(r)) r*100 else NA_real_, f1 = f1)
      }))
      ps  <- sapply(vals, `[[`, "p");  rs <- sapply(vals, `[[`, "r");  f1s <- sapply(vals, `[[`, "f1")
      data.frame(
        Class         = cls,
        `N papers`    = length(vals),
        `PA Precision`= fmt1(mean(ps,  na.rm = TRUE)),
        `PA Recall`   = fmt1(mean(rs,  na.rm = TRUE)),
        `PA F1`       = fmt1(mean(f1s, na.rm = TRUE)),
        `SD F1`       = fmt1(sd(f1s,   na.rm = TRUE)),
        `FP F1`       = fmt1(class_metrics$f1[class_metrics$class == cls]),
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(pa_class_rows))
    BR()

    # ── type_source accuracy (legacy — cross-report comparable) ──────────────
    if ("type_source" %in% names(acc)) {
      L("### 3.6 Accuracy by type_source")
      BR()
      per_src <- do.call(rbind, lapply(sort(unique(acc$type_source[!is.na(acc$type_source)])), function(s) {
        rows <- acc[!is.na(acc$type_source) & acc$type_source == s, ]
        n    <- sum(!is.na(rows$type_gt))
        corr <- sum(!is.na(rows$type_gt) & !is.na(rows$type) & rows$type_gt == rows$type)
        data.frame(`type_source` = s, `N files` = n, Correct = corr,
                   Accuracy = pct(corr, n), check.names = FALSE, stringsAsFactors = FALSE)
      }))
      L(md_table(per_src))
      BR()
    }

    # ── Confusion matrices ────────────────────────────────────────────────────
    L("### 3.7 Type Confusion Matrices")
    BR()
    L("_Rows = ground truth, columns = predicted. Diagonal = correct._")
    BR()
    L("**File-pooled (raw counts):**")
    BR()
    if (!is.null(cm_mat) && nrow(cm_mat) > 0) {
      cm_df <- as.data.frame.matrix(cm_mat)
      L(md_table(cbind(data.frame(`type \\ pred` = rownames(cm_df), check.names = FALSE), cm_df)))
    } else {
      L("_Insufficient data._")
    }
    BR()
    L("**Paper-averaged (mean row-normalised proportions):**")
    BR()
    if (!is.null(pa_cm_norm) && nrow(pa_cm_norm) > 0) {
      pa_df <- as.data.frame(round(pa_cm_norm, 3))
      L(md_table(cbind(data.frame(`type \\ pred` = rownames(pa_df), check.names = FALSE), pa_df)))
    } else {
      L("_Insufficient data._")
    }
    BR()

    # ── Group / DG / data_format confusion ────────────────────────────────────
    L("### 3.8 Group Confusion Matrix")
    BR()
    if (!is.null(cm_grp) && nrow(cm_grp) > 0) {
      cm_grp_df <- as.data.frame.matrix(cm_grp)
      L(md_table(cbind(data.frame(`group \\ pred` = rownames(cm_grp_df), check.names = FALSE), cm_grp_df)))
    } else { L("_Insufficient data._") }
    BR()

    L("### 3.9 data_granularity Confusion Matrix")
    BR()
    if (!is.null(cm_dg) && nrow(cm_dg) > 0) {
      cm_dg_df <- as.data.frame.matrix(cm_dg)
      L(md_table(cbind(data.frame(`dg \\ pred` = rownames(cm_dg_df), check.names = FALSE), cm_dg_df)))
    } else { L("_Insufficient data._") }
    BR()

    if ("data_format_gt" %in% names(acc)) {
      L("### 3.10 data_format Confusion Matrix")
      BR()
      if (!is.null(cm_df2) && nrow(cm_df2) > 0) {
        cm_df2_df <- as.data.frame.matrix(cm_df2)
        L(md_table(cbind(data.frame(`format \\ pred` = rownames(cm_df2_df), check.names = FALSE), cm_df2_df)))
      } else { L("_Insufficient data._") }
      BR()
    }

    # ── Extension error analysis ──────────────────────────────────────────────
    L("### 3.11 Error Rate by File Extension")
    BR()
    L("_Extensions with >= 3 annotated files, sorted by error count._")
    BR()
    if (!is.null(ext_stats) && nrow(ext_stats) > 0) {
      L(md_table(ext_stats))
    } else {
      L("_Insufficient data._")
    }
    BR()
  }
  L("---")
  BR()

  # ── 4. Codebook Labelling ────────────────────────────────────────────────────
  L("## 4. Codebook Labelling")
  BR()

  # Load columns + labels + coverage for every paper that has them
  col_frames <- list()
  cov_frames <- list()
  for (pid in run_log$paper_id) {
    pid_src  <- if (pid %in% names(paper_sources)) paper_sources[[pid]] else "osf"
    col_path <- file.path(TEST_DIR, "outputs", pid_src, pid, "columns.csv")
    lbl_path <- file.path(TEST_DIR, "outputs", pid_src, pid, "labels.csv")
    cov_path <- file.path(TEST_DIR, "outputs", pid_src, pid, "codebook_coverage.csv")
    if (!file.exists(col_path)) next
    cols <- read.csv(col_path, colClasses = c(paper_id = "character"),
                     stringsAsFactors = FALSE)
    cols$paper_id <- pid
    if (file.exists(lbl_path)) {
      lbls <- read.csv(lbl_path, colClasses = c(paper_id = "character"),
                       stringsAsFactors = FALSE)
      lbl_keep <- intersect(c("source_file", "column_name", "label_status", "label_method"),
                            names(lbls))
      cols <- merge(cols, lbls[, lbl_keep],
                    by = c("source_file", "column_name"), all.x = TRUE)
    } else {
      cols$label_status  <- NA_character_
      cols$label_method  <- NA_character_
    }
    col_frames[[pid]] <- cols
    if (file.exists(cov_path)) {
      cov <- read.csv(cov_path, colClasses = c(paper_id = "character"),
                      stringsAsFactors = FALSE)
      if (nrow(cov) > 0) {
        cov$paper_id <- pid
        cov_frames[[pid]] <- cov
      }
    }
  }
  col_all <- if (length(col_frames) > 0) do.call(rbind, col_frames) else NULL
  cov_all <- if (length(cov_frames) > 0) do.call(rbind, cov_frames) else NULL

  # Per-paper summary
  L("### Per-Paper")
  BR()
  L(md_table(do.call(rbind, lapply(seq_len(n_papers), function(i) {
    r   <- run_log[i, ]
    pid <- r$paper_id
    nl  <- suppressWarnings(as.integer(r$n_labelled))
    nu  <- suppressWarnings(as.integer(r$n_unlabelled))
    tot <- sum(c(nl, nu), na.rm = TRUE)

    # col_type summary from columns.csv
    ct_str <- "—"
    if (!is.null(col_frames[[pid]])) {
      ct <- sort(table(col_frames[[pid]]$col_type), decreasing = TRUE)
      ct_str <- paste(sprintf("%s:%d", names(ct), as.integer(ct)), collapse = " ")
    }

    data.frame(
      Paper         = pid,
      Label         = short_label(pid),
      Status        = na_dash(r$label_status),
      Labelled      = na_dash(r$n_labelled),
      Unlabelled    = na_dash(r$n_unlabelled),
      `Labelled %`  = if (tot > 0) pct(nl, tot) else "—",
      `Col types`   = ct_str,
      `Elapsed (s)` = fmt_s(r$codebook_elapsed_sec),
      check.names   = FALSE, stringsAsFactors = FALSE
    )
  }))))
  BR()

  if (!is.null(col_all) && nrow(col_all) > 0) {

    # col_type distribution across all test papers
    L("### Col_type Distribution")
    BR()
    all_ct <- sort(table(col_all$col_type), decreasing = TRUE)
    ct_dist <- do.call(rbind, lapply(names(all_ct), function(t) {
      n_paps <- length(unique(col_all$paper_id[col_all$col_type == t]))
      data.frame(
        col_type   = t,
        `N papers` = n_paps,
        `N cols`   = as.integer(all_ct[[t]]),
        `% of cols` = pct(as.integer(all_ct[[t]]), nrow(col_all)),
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(ct_dist))
    BR()

    # col_type vs labelling rate (papers with labels only)
    labelled_cols <- col_all[!is.na(col_all$label_status), ]
    if (nrow(labelled_cols) > 0) {
      L("### Labelling Rate by Col_type")
      BR()
      L("_Across papers where codebook labelling ran. Shows which column types are more likely to go unlabelled._")
      BR()
      ct_lbl <- do.call(rbind, lapply(sort(unique(labelled_cols$col_type)), function(t) {
        rows <- labelled_cols[labelled_cols$col_type == t, ]
        n    <- nrow(rows)
        nlbl <- sum(rows$label_status %in% c("labelled", "llm"), na.rm = TRUE)
        data.frame(
          col_type     = t,
          `N cols`     = n,
          Labelled     = nlbl,
          Unlabelled   = n - nlbl,
          `Labelled %` = pct(nlbl, n),
          check.names  = FALSE, stringsAsFactors = FALSE
        )
      }))
      # Sort by labelled % ascending so problem types float to top
      ct_lbl <- ct_lbl[order(suppressWarnings(
        as.numeric(sub("%", "", ct_lbl[["Labelled %"]]))
      ), na.last = TRUE, decreasing = FALSE), ]
      L(md_table(ct_lbl))
      BR()
    }
  }

  # Codebook coverage per paper
  if (!is.null(cov_all) && nrow(cov_all) > 0) {
    L("### Codebook Coverage per Paper")
    BR()
    L("_How many codebook entries were extracted and how many matched a data column._")
    BR()
    cov_paper <- do.call(rbind, lapply(run_log$paper_id, function(pid) {
      cv <- cov_all[cov_all$paper_id == pid, ]
      if (nrow(cv) == 0) {
        return(data.frame(
          Paper = pid, Label = short_label(pid),
          `CB entries` = "—", Matched = "—", Unmatched = "—", `Match %` = "—",
          `Match statuses` = "—",
          check.names = FALSE, stringsAsFactors = FALSE
        ))
      }
      n_tot   <- nrow(cv)
      n_match <- sum(cv$match_status == "matched", na.rm = TRUE)
      n_unmatch <- n_tot - n_match
      status_tbl <- sort(table(cv$match_status), decreasing = TRUE)
      status_str <- paste(sprintf("%s:%d", names(status_tbl), as.integer(status_tbl)), collapse = " ")
      data.frame(
        Paper = pid, Label = short_label(pid),
        `CB entries` = n_tot,
        Matched      = n_match,
        Unmatched    = n_unmatch,
        `Match %`    = pct(n_match, n_tot),
        `Match statuses` = status_str,
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(cov_paper))
    BR()
  }

  # label_method breakdown per paper
  if (!is.null(col_all) && "label_method" %in% names(col_all)) {
    lm_rows <- col_all[!is.na(col_all$label_status) & col_all$label_status %in% c("labelled", "llm") &
                         !is.na(col_all$label_method), ]
    if (nrow(lm_rows) > 0) {
      L("### Label Method per Paper")
      BR()
      L("_For labelled columns only: how many were matched by rules vs LLM._")
      BR()
      lm_paper <- do.call(rbind, lapply(run_log$paper_id, function(pid) {
        rows <- lm_rows[lm_rows$paper_id == pid, ]
        if (nrow(rows) == 0) return(data.frame(
          Paper = pid, Label = short_label(pid),
          Rules = "—", LLM = "—", `Rules %` = "—",
          check.names = FALSE, stringsAsFactors = FALSE
        ))
        n_rules <- sum(rows$label_method == "rules", na.rm = TRUE)
        n_llm   <- sum(rows$label_method == "llm",   na.rm = TRUE)
        n_tot   <- nrow(rows)
        data.frame(
          Paper    = pid, Label = short_label(pid),
          Rules    = n_rules,
          LLM      = n_llm,
          `Rules %` = pct(n_rules, n_tot),
          check.names = FALSE, stringsAsFactors = FALSE
        )
      }))
      L(md_table(lm_paper))
      BR()
    }
  }

  # Unlabelled columns per paper
  if (!is.null(col_all) && "label_status" %in% names(col_all)) {
    unlbl <- col_all[!is.na(col_all$label_status) & !col_all$label_status %in% c("labelled", "llm"), ]
    if (nrow(unlbl) > 0) {
      L("### Unlabelled Columns")
      BR()
      L("_Columns that ran through codebook labelling but received no label._")
      BR()
      for (pid in unique(unlbl$paper_id)) {
        rows <- unlbl[unlbl$paper_id == pid, ]
        L(sprintf("**%s** — %s (%d unlabelled)", pid, short_label(pid), nrow(rows)))
        BR()
        ul_tbl <- data.frame(
          `Source file`   = basename(rows$source_file),
          Column          = rows$column_name,
          `Col type`      = rows$col_type,
          `Sample values` = substr(rows$sample_values %||% "", 1L, 40L),
          check.names     = FALSE, stringsAsFactors = FALSE
        )
        L(md_table(ul_tbl))
        BR()
      }
    }
  }

  L("---")
  BR()

  # ── 5. PsychDS Conversion ────────────────────────────────────────────────────
  L("## 5. PsychDS Conversion")
  BR()
  L(md_table(do.call(rbind, lapply(seq_len(n_papers), function(i) {
    r <- run_log[i, ]
    data.frame(Paper = r$paper_id, Label = short_label(r$paper_id),
               Studies = na_dash(r$psychds_studies),
               Variables = na_dash(r$psychds_vars), Labelled = na_dash(r$psychds_labelled),
               `Elapsed (s)` = fmt_s(r$psychds_elapsed_sec),
               check.names = FALSE, stringsAsFactors = FALSE)
  }))))
  BR()

  # ── Appendix: STRUCTURE_PROMPT ──────────────────────────────────────────────
  L("---")
  BR()
  L("## Appendix: STRUCTURE_PROMPT (File Classification System Prompt)")
  BR()
  L("This prompt was used for Phase 1 LLM file classification in this test run.")
  L("Include for future comparison and prompt iteration.")
  BR()
  L("```")
  # Extract just the STRUCTURE_PROMPT string (first element)
  prompt_lines <- strsplit(STRUCTURE_PROMPT, "\n")[[1]]
  L(prompt_lines)
  L("```")
  BR()

  # Write
  dir.create(REPORT_DIR, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(REPORT_DIR, paste0("test_report_", date_str, TEST_TITLE, ".md"))
  writeLines(lines, out_path)
  cat(sprintf("  [report] written to: %s\n", out_path))
  invisible(out_path)
}

# ── Early exit for report-only mode ───────────────────────────────────────────

if (REPORT_ONLY) {
  generate_report()
  invisible(NULL)
} else {


dir.create(TEST_OUTPUT_DIR,  recursive = TRUE, showWarnings = FALSE)
dir.create(TEST_PSYCHDS_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Test papers ────────────────────────────────────────────────────────────────

test_papers_df <- read.csv(
  file.path(TEST_DIR, "test_papers.csv"),
  colClasses       = c(id = "character", source = "character"),
  stringsAsFactors = FALSE
)
if (!"source" %in% names(test_papers_df))
  test_papers_df$source <- "osf"
TEST_PAPERS <- lapply(seq_len(nrow(test_papers_df)), function(i)
  list(id     = test_papers_df$id[i],
       source = test_papers_df$source[i],
       label  = test_papers_df$label[i])
)

# ── Log ────────────────────────────────────────────────────────────────────────

LOG_COLS <- c(
  "run_id", "paper_id", "label",
  "index_success",   "index_error",
  "codebook_success", "codebook_error",
  "psychds_success",  "psychds_error",
  "n_files", "n_data_files", "n_columns", "n_agg_dirs",
  "file_types", "data_groups", "col_types",
  "index_elapsed_sec",
  "label_status", "n_labelled", "n_unlabelled", "coverage",
  "codebook_elapsed_sec",
  "psychds_studies", "psychds_vars", "psychds_labelled",
  "psychds_elapsed_sec"
)

write_log_row <- function(row) {
  for (col in LOG_COLS) if (is.null(row[[col]])) row[[col]] <- NA_character_
  df <- as.data.frame(row, stringsAsFactors = FALSE)[, LOG_COLS]
  write.table(df,
    file      = TEST_LOG_PATH,
    sep       = ",",
    col.names = !file.exists(TEST_LOG_PATH),
    row.names = FALSE,
    append    = TRUE,
    qmethod   = "double"
  )
}

tbl_str <- function(tbl) {
  if (length(tbl) == 0) return("")
  paste(sprintf("%s=%d", names(tbl), as.integer(tbl)), collapse = " ")
}

tbl_json <- function(tbl) {
  if (length(tbl) == 0) return("{}")
  pairs <- paste(sprintf('"%s":%d', names(tbl), as.integer(tbl)), collapse = ",")
  sprintf("{%s}", pairs)
}

divider   <- paste0(rep("─", 72), collapse = "")
divider_h <- paste0(rep("═", 72), collapse = "")

# ── PsychDS helper ─────────────────────────────────────────────────────────────

run_psychds_test <- function(pid, source = "osf") {
  test_dir <- normalizePath(file.path(TEST_OUTPUT_DIR, source, pid), mustWork = TRUE)
  prod_dir <- paper_path("outputs", source, pid)

  used_symlink <- FALSE
  if (!file.exists(prod_dir)) {
    dir.create(dirname(prod_dir), recursive = TRUE, showWarnings = FALSE)
    if (!file.symlink(test_dir, prod_dir)) {
      cat("  [psychds] could not symlink test outputs — skipped\n")
      return(list(success = FALSE, error = "symlink_failed"))
    }
    used_symlink <- TRUE
  }

  old_psychds_dir <- PSYCHDS_OUT_DIR
  PSYCHDS_OUT_DIR <<- TEST_PSYCHDS_DIR

  t_start <- proc.time()[["elapsed"]]
  results <- tryCatch(
    convert_psychds(pid),
    error = function(e) list(list(success = FALSE, error = conditionMessage(e),
                                  study_group = "all"))
  )
  elapsed <- round(proc.time()[["elapsed"]] - t_start, 1)

  PSYCHDS_OUT_DIR <<- old_psychds_dir
  if (used_symlink) unlink(prod_dir)

  n_ok <- 0L; n_fail <- 0L; errors <- character(0)
  total_vars <- 0L; total_labelled <- 0L

  for (r in results) {
    sg <- r$study_group %||% "?"
    if (!isTRUE(r$success)) {
      n_fail <- n_fail + 1L
      errors <- c(errors, sprintf("%s:%s", sg, r$error %||% "unknown"))
      cat(sprintf("  [psychds] %-10s  ERROR: %s\n", sg, r$error %||% "unknown"))
    } else {
      n_ok <- n_ok + 1L
      total_vars     <- total_vars     + (r$n_variables %||% 0L)
      total_labelled <- total_labelled + (r$n_labelled  %||% 0L)
      cat(sprintf(
        "  [psychds] %-10s  data=%d  raw=%d  vars=%d  labelled=%d  meta=%s  gt=%s\n",
        sg, r$n_data_files %||% 0L, r$n_raw_files %||% 0L,
        r$n_variables %||% 0L, r$n_labelled %||% 0L,
        if (isTRUE(r$has_paper_metadata)) "GROBID" else "fallback",
        if (isTRUE(r$has_ground_truth))   "yes"    else "no"
      ))
    }
  }
  cat(sprintf("  [psychds] elapsed=%.1fs\n", elapsed))

  list(
    success        = n_fail == 0L,
    error          = if (length(errors) > 0) paste(errors, collapse = "; ") else NA,
    studies        = sprintf("ok=%d fail=%d", n_ok, n_fail),
    total_vars     = total_vars,
    total_labelled = total_labelled,
    elapsed        = elapsed
  )
}

# ── Main loop ──────────────────────────────────────────────────────────────────

RUN_ID <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")

cat(sprintf("\n%s\n  TEST RUN %s — %d papers\n%s\n",
  divider_h, RUN_ID, length(TEST_PAPERS), divider_h))

for (tp in TEST_PAPERS) {
  pid         <- tp$id
  src         <- tp$source %||% "osf"
  label       <- tp$label
  pid_out_dir <- file.path(TEST_OUTPUT_DIR, src, pid)

  cat(sprintf("\n%s\n  %s\n  %s\n%s\n", divider, pid, label, divider))

  row <- list(run_id = RUN_ID, paper_id = pid, label = label)

  # Stage 1: index
  cat("Stage 1: index\n")
  t_start <- proc.time()[["elapsed"]]
  s1 <- tryCatch(
    run_index(paper_id = pid, download = FALSE, output_dir = pid_out_dir),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )
  row$index_elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)

  if (!isTRUE(s1$success)) {
    cat(sprintf("  ERROR: %s\n", s1$error))
    row$index_success    <- FALSE
    row$index_error      <- s1$error
    row$codebook_success <- FALSE
    row$codebook_error   <- "skipped_index_failed"
    row$psychds_success  <- FALSE
    row$psychds_error    <- "skipped_index_failed"
    write_log_row(row)
    next
  }

  type_tbl  <- sort(table(s1$file_df$type), decreasing = TRUE)
  group_tbl <- sort(table(s1$file_df$group[s1$file_df$type == "data"]), decreasing = TRUE)
  ct_tbl    <- if (!is.null(s1$columns_df) && nrow(s1$columns_df) > 0)
    sort(table(s1$columns_df$col_type), decreasing = TRUE) else table(character(0))

  cat(sprintf("  files=%d  data=%d  columns=%d  agg_dirs=%d  elapsed=%.1fs\n",
    s1$n_files, s1$n_data_files, s1$n_columns,
    s1$n_agg_dirs %||% 0L, row$index_elapsed_sec))
  cat(sprintf("  file types:  %s\n", tbl_str(type_tbl)))
  cat(sprintf("  data groups: %s\n", tbl_str(group_tbl)))
  if (!is.null(s1$columns_df) && nrow(s1$columns_df) > 0)
    cat(sprintf("  col_types:   %s\n", tbl_str(ct_tbl)))

  row$index_success <- TRUE
  row$n_files       <- s1$n_files
  row$n_data_files  <- s1$n_data_files
  row$n_columns     <- s1$n_columns
  row$n_agg_dirs    <- s1$n_agg_dirs %||% 0L
  row$file_types    <- tbl_json(type_tbl)
  row$data_groups   <- tbl_json(group_tbl)
  row$col_types     <- tbl_json(ct_tbl)

  # Stage 2: codebook label
  cat("Stage 2: codebook label\n")
  if (!file.exists(file.path(pid_out_dir, "columns.csv"))) {
    cat("  skipped — no columns.csv\n")
    row$codebook_success <- TRUE
    row$label_status     <- "skipped_no_columns"
  } else {
    t_start <- proc.time()[["elapsed"]]
    s2 <- tryCatch(
      run_codebook_label(paper_id = pid, output_dir = pid_out_dir),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    row$codebook_elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)

    if (is.null(s2$label_status)) {
      cat(sprintf("  ERROR: %s\n", s2$error %||% "unknown"))
      row$codebook_success <- FALSE
      row$codebook_error   <- s2$error %||% "unknown"
    } else {
      cov_str  <- ""
      cov_path <- file.path(pid_out_dir, "codebook_coverage.csv")
      if (file.exists(cov_path)) {
        cov_df  <- read.csv(cov_path, stringsAsFactors = FALSE,
                            colClasses = c(paper_id = "character"))
        cov_tbl <- sort(table(cov_df$match_status), decreasing = TRUE)
        cov_str <- tbl_json(cov_tbl)
        cat(sprintf("  coverage:    %s\n", cov_str))
      }
      cat(sprintf("  status=%-12s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n",
        s2$label_status %||% "NA", s2$n_labelled %||% "NA",
        s2$n_unlabelled %||% "NA", row$codebook_elapsed_sec))
      row$codebook_success <- TRUE
      row$label_status     <- s2$label_status %||% NA
      row$n_labelled       <- s2$n_labelled   %||% NA
      row$n_unlabelled     <- s2$n_unlabelled %||% NA
      row$coverage         <- cov_str
    }
  }

  # Stage 3: psychds
  cat("Stage 3: psychds\n")
  p3 <- run_psychds_test(pid, src)
  row$psychds_success     <- p3$success
  row$psychds_error       <- p3$error
  row$psychds_studies     <- p3$studies
  row$psychds_vars        <- p3$total_vars
  row$psychds_labelled    <- p3$total_labelled
  row$psychds_elapsed_sec <- p3$elapsed

  write_log_row(row)
}

cat(sprintf("\n%s\n  Done  [%s]\n  outputs: %s\n  psychds: %s\n  log:     %s\n%s\n\n",
  divider_h, RUN_ID,
  TEST_OUTPUT_DIR, TEST_PSYCHDS_DIR, TEST_LOG_PATH,
  divider_h))

generate_report()

} # end !REPORT_ONLY
