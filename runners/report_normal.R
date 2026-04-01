# report_normal.R
# ─────────────────────────────────────────────────────────────────────────────
# Generates a classification accuracy report for all "normal" (non-test)
# papers in outputs/ that have BOTH:
#   - outputs/<paper_id>/structure.csv  (stage 0 / indexing done)
#   - ground_truth/<paper_id>.csv       (manual annotations)
#
# Outputs:
#   results/normal_report_<date>.md
#   results/normal_report_<date>_metrics.png        per-class precision/recall/F1
#   results/normal_report_<date>_confusion.png      type confusion matrix heatmap
#   results/normal_report_<date>_paper_dist.png     per-paper accuracy distribution
#   results/normal_report_<date>_fp_fn.png          top FP/FN confusion pairs
#   results/normal_report_<date>_ext_errors.png     error rate by file extension
#   results/normal_report_<date>_group_conf.png     group confusion matrix heatmap
#   results/normal_report_<date>_dg_conf.png        data_granularity confusion heatmap
#
# Usage (interactive):  source("data_check/runners/report_normal.R")
# Usage (CLI):          Rscript data_check/runners/report_normal.R
# ─────────────────────────────────────────────────────────────────────────────

OUTPUTS_DIR  <- "./data_check/outputs"
GT_DIR       <- "./data_check/ground_truth"
REPORT_DIR   <- "./data_check/results"

# ── Helpers ───────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

pct     <- function(n, d) if (d == 0L) "n/a" else sprintf("%.1f%%", 100 * n / d)
pct_num <- function(n, d) if (d == 0L) NA_real_ else 100 * n / d
fmt1    <- function(x) if (is.na(x)) "n/a" else sprintf("%.1f%%", x)

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

get_ext <- function(path) {
  base    <- basename(path)
  has_dot <- grepl("\\.", base)
  tolower(ifelse(has_dot, sub(".*\\.", "", base), "(none)"))
}

heatmap_plot <- function(mat, title, xlab = "Predicted", ylab = "Ground truth") {
  n        <- nrow(mat)
  row_sums <- rowSums(mat)
  norm     <- mat / ifelse(row_sums == 0, 1, row_sums)
  col_ramp <- colorRampPalette(c("white", "#2171b5"))(100)
  lbls     <- rownames(mat)
  old_par  <- par(mar = c(7, 7, 3, 2))
  image(seq_len(n), seq_len(n), t(norm)[, n:1],
        col = col_ramp, axes = FALSE, xlab = "", ylab = "", main = title)
  axis(1, at = seq_len(n), labels = lbls,      las = 2, cex.axis = 0.85)
  axis(2, at = seq_len(n), labels = rev(lbls), las = 1, cex.axis = 0.85)
  mtext(xlab, side = 1, line = 5.5, cex = 0.9)
  mtext(ylab, side = 2, line = 5.5, cex = 0.9)
  for (i in seq_len(n))
    for (j in seq_len(n)) {
      v <- mat[n + 1 - j, i]
      if (v > 0) text(i, j, v,
                      col = if (norm[n + 1 - j, i] > 0.6) "white" else "black",
                      cex = 0.75)
    }
  par(old_par)
}

# ── Discover eligible papers ──────────────────────────────────────────────────

gt_ids <- sub("\\.csv$", "", list.files(GT_DIR, pattern = "\\.csv$"))

eligible <- Filter(function(pid) {
  file.exists(file.path(OUTPUTS_DIR, pid, "structure.csv"))
}, gt_ids)

if (length(eligible) == 0) {
  cat("No papers found with both structure.csv and a ground-truth file.\n")
  quit(status = 0)
}

cat(sprintf("Found %d eligible papers.\n", length(eligible)))

# ── Load and merge GT + structure ─────────────────────────────────────────────

acc_list <- list()
for (pid in eligible) {
  gt_path  <- file.path(GT_DIR,      paste0(pid, ".csv"))
  str_path <- file.path(OUTPUTS_DIR, pid, "structure.csv")

  gt  <- tryCatch(
    read.csv(gt_path,  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE),
    error = function(e) { message("[WARN] could not read ", gt_path); NULL }
  )
  str <- tryCatch(
    read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE),
    error = function(e) { message("[WARN] could not read ", str_path); NULL }
  )

  if (is.null(gt) || is.null(str) || nrow(gt) == 0) next

  keep_str <- intersect(
    c("rel_path", "type", "group", "data_granularity", "type_source"),
    names(str)
  )
  m <- merge(
    gt[, intersect(c("rel_path", "type_gt", "group_gt", "data_granularity_gt"), names(gt))],
    str[, keep_str],
    by = "rel_path", all.x = TRUE
  )
  m$paper_id <- pid
  acc_list[[pid]] <- m
}

acc     <- if (length(acc_list) > 0) do.call(rbind, acc_list) else NULL
has_acc <- !is.null(acc) && nrow(acc) > 0

if (!has_acc) {
  cat("No accuracy data could be built — check GT and structure files.\n")
  quit(status = 0)
}

# ── Per-paper numeric accuracy ────────────────────────────────────────────────

per_paper_stats <- do.call(rbind, lapply(sort(unique(acc$paper_id)), function(pid) {
  a  <- acc[acc$paper_id == pid, ]
  da <- a[!is.na(a$type_gt) & a$type_gt == "data", ]
  dg <- da[!is.na(da$data_granularity_gt), ]

  n_type  <- sum(!is.na(a$type_gt))
  n_group <- sum(!is.na(da$group_gt))
  n_dg    <- nrow(dg)

  # dominant error pair for this paper
  w <- a[!is.na(a$type_gt) & !is.na(a$type) & a$type_gt != a$type, ]
  top_err <- if (nrow(w) > 0) {
    pk  <- paste0(w$type_gt, "→", w$type)
    tbl <- sort(table(pk), decreasing = TRUE)
    sprintf("%s (%d)", names(tbl)[1], tbl[[1]])
  } else "—"

  # top extension among misclassified files for this paper
  top_ext <- if (nrow(w) > 0) {
    exts <- get_ext(w$rel_path)
    names(sort(table(exts), decreasing = TRUE))[1]
  } else "—"

  data.frame(
    paper_id  = pid,
    n_files   = n_type,
    type_acc  = pct_num(sum(!is.na(a$type_gt) & !is.na(a$type) & a$type_gt == a$type), n_type),
    group_acc = pct_num(sum(!is.na(da$group_gt) & !is.na(da$group) & da$group_gt == da$group), n_group),
    dg_acc    = pct_num(sum(!is.na(dg$data_granularity) & dg$data_granularity_gt == dg$data_granularity), n_dg),
    top_err   = top_err,
    top_ext   = top_ext,
    stringsAsFactors = FALSE
  )
}))

# ── Per-class metrics (TP/FP/FN + P/R/F1/FPR/FNR) ────────────────────────────

valid     <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]
all_types <- sort(unique(c(valid$type_gt, valid$type)))

class_metrics <- do.call(rbind, lapply(all_types, function(cls) {
  tp <- sum(valid$type_gt == cls & valid$type == cls)
  fp <- sum(valid$type_gt != cls & valid$type == cls)
  fn <- sum(valid$type_gt == cls & valid$type != cls)
  tn <- sum(valid$type_gt != cls & valid$type != cls)

  prec   <- pct_num(tp, tp + fp)
  rec    <- pct_num(tp, tp + fn)
  f1     <- if (!is.na(prec) && !is.na(rec) && (prec + rec) > 0)
               2 * prec * rec / (prec + rec) else NA_real_
  fpr    <- pct_num(fp, fp + tn)
  fnr    <- pct_num(fn, tp + fn)

  fp_rows <- valid[valid$type_gt != cls & valid$type == cls, ]
  fn_rows <- valid[valid$type_gt == cls & valid$type != cls, ]

  data.frame(
    class         = cls, tp = tp, fp = fp, fn = fn, tn = tn,
    precision     = prec, recall = rec, f1 = f1, fpr = fpr, fnr = fnr,
    top_fp_source = (if (nrow(fp_rows) > 0) names(sort(table(fp_rows$type_gt), decreasing=TRUE))[1] else NA_character_) %||% NA_character_,
    top_fn_dest   = (if (nrow(fn_rows) > 0) names(sort(table(fn_rows$type),    decreasing=TRUE))[1] else NA_character_) %||% NA_character_,
    stringsAsFactors = FALSE
  )
}))

macro_f1 <- mean(class_metrics$f1, na.rm = TRUE)

# ── Type confusion matrix ─────────────────────────────────────────────────────

ctypes <- sort(unique(c(valid$type_gt, valid$type)))
cm     <- as.data.frame.matrix(
  table(gt   = factor(valid$type_gt, levels = ctypes),
        pred = factor(valid$type,    levels = ctypes))
)

# ── Top confusion pairs ───────────────────────────────────────────────────────

wrong      <- valid[valid$type_gt != valid$type, ]
pair_key   <- paste0(wrong$type_gt, " → ", wrong$type)
pair_counts <- sort(table(pair_key), decreasing = TRUE)
top_pairs  <- head(pair_counts, 20)

# ── Extension-level error analysis ───────────────────────────────────────────

acc$ext <- get_ext(acc$rel_path)
valid_ext <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]

ext_stats <- do.call(rbind, lapply(sort(unique(valid_ext$ext)), function(e) {
  rows  <- valid_ext[valid_ext$ext == e, ]
  n     <- nrow(rows)
  wrong_rows <- rows[rows$type_gt != rows$type, ]
  n_wrong <- nrow(wrong_rows)
  if (n < 5) return(NULL)   # skip rare extensions
  top_pair <- if (n_wrong > 0) {
    pk  <- paste0(wrong_rows$type_gt, "→", wrong_rows$type)
    tbl <- sort(table(pk), decreasing = TRUE)
    sprintf("%s (%d)", names(tbl)[1], tbl[[1]])
  } else "—"
  data.frame(ext = e, n_files = n, n_errors = n_wrong,
             error_rate = pct_num(n_wrong, n), top_pair = top_pair,
             stringsAsFactors = FALSE)
}))
ext_stats <- ext_stats[order(-ext_stats$n_errors), ]

# ── Group confusion matrix ────────────────────────────────────────────────────

grp_valid <- acc[
  !is.na(acc$type_gt)  & acc$type_gt == "data" &
  !is.na(acc$type)     & acc$type    == "data" &
  !is.na(acc$group_gt) & !is.na(acc$group), ]

if (nrow(grp_valid) > 0) {
  grp_levels <- sort(unique(c(grp_valid$group_gt, grp_valid$group)))
  cm_grp <- as.matrix(table(
    gt   = factor(grp_valid$group_gt, levels = grp_levels),
    pred = factor(grp_valid$group,    levels = grp_levels)
  ))
} else {
  cm_grp <- NULL
}

# ── DG confusion matrix ───────────────────────────────────────────────────────

dg_valid <- acc[
  !is.na(acc$type_gt)  & acc$type_gt == "data" &
  !is.na(acc$type)     & acc$type    == "data" &
  !is.na(acc$data_granularity_gt) & !is.na(acc$data_granularity), ]

if (nrow(dg_valid) > 0) {
  dg_levels <- sort(unique(c(dg_valid$data_granularity_gt, dg_valid$data_granularity)))
  cm_dg <- as.matrix(table(
    gt   = factor(dg_valid$data_granularity_gt, levels = dg_levels),
    pred = factor(dg_valid$data_granularity,    levels = dg_levels)
  ))
} else {
  cm_dg <- NULL
}

# ── Downstream FP/FN impact on `data` ────────────────────────────────────────

# FP: predicted data but GT != data  → column extraction runs on wrong file
data_fp <- valid[valid$type_gt != "data" & valid$type == "data", ]
# FN: GT data but predicted != data  → dataset missed entirely
data_fn <- valid[valid$type_gt == "data" & valid$type != "data", ]

# ── Build report ──────────────────────────────────────────────────────────────

lines <- character(0)
L  <- function(...) { lines <<- c(lines, paste0(...)) }
BR <- function()    { lines <<- c(lines, "") }

date_str <- format(Sys.Date(), "%Y-%m-%d")
now_str  <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
n_papers <- length(unique(acc$paper_id))
tn_total <- sum(!is.na(acc$type_gt))

L("# Normal-Paper Classification Report — ", date_str)
BR()
L("**Papers:** ", n_papers, "  |  **Annotated files:** ", tn_total, "  |  **Generated:** ", now_str)
BR()
L("_Covers all papers in `outputs/` that have been indexed (stage 0) and have a ground-truth annotation file._")
BR()
L("---")
BR()

# ── 1. Overall accuracy ───────────────────────────────────────────────────────

L("## 1. Overall Classification Accuracy")
BR()

data_acc_rows <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]
dg_acc_rows   <- data_acc_rows[!is.na(data_acc_rows$data_granularity_gt), ]

tc   <- sum(!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt == acc$type)
tn_n <- sum(!is.na(acc$type_gt))
gc   <- sum(!is.na(data_acc_rows$group_gt) & !is.na(data_acc_rows$group) & data_acc_rows$group_gt == data_acc_rows$group)
gn   <- sum(!is.na(data_acc_rows$group_gt))
dc   <- sum(!is.na(dg_acc_rows$data_granularity) & dg_acc_rows$data_granularity_gt == dg_acc_rows$data_granularity)
dn   <- nrow(dg_acc_rows)

L(sprintf("_Based on **%d annotated files** across **%d papers**_", tn_n, n_papers))
BR()
L("| Metric | Correct | Total | Accuracy | Macro F1 |")
L("|---|---|---|---|---|")
L(sprintf("| **File type** | %d | %d | **%s** | **%s** |", tc, tn_n, pct(tc, tn_n), fmt1(macro_f1)))
L(sprintf("| **Group** (data files only) | %d | %d | **%s** | — |", gc, gn, pct(gc, gn)))
L(sprintf("| **data_granularity** (data files only) | %d | %d | **%s** | — |", dc, dn, pct(dc, dn)))
BR()
L("_Macro F1 is the unweighted mean of per-class F1 scores — treats all classes equally regardless of size._")
BR()

# ── 2. Per-Class Metrics ──────────────────────────────────────────────────────

L("## 2. Per-Class Metrics")
BR()
L("_**Precision** = of all files predicted as this class, how many actually are (`TP / (TP + FP)`).  ")
L("**Recall** = of all files that actually are this class, how many were caught (`TP / (TP + FN)`).  ")
L("**F1** = harmonic mean of precision and recall: `2 × (P × R) / (P + R)`. Punishes imbalance — if either is near zero, F1 collapses regardless of the other.  ")
L("**FPR** = false positive rate (fraction of true negatives incorrectly predicted as this class).  ")
L("**FNR** = false negative rate (fraction of true positives missed = 1 − recall).  ")
L("**Top FP src** = the GT class most often wrongly predicted as this class.  ")
L("**Top FN dest** = what this class is most often mispredicted as._")
BR()

metrics_tbl <- data.frame(
  Class         = class_metrics$class,
  TP            = class_metrics$tp,
  FP            = class_metrics$fp,
  FN            = class_metrics$fn,
  Precision     = sapply(class_metrics$precision, fmt1),
  Recall        = sapply(class_metrics$recall,    fmt1),
  F1            = sapply(class_metrics$f1,        fmt1),
  FPR           = sapply(class_metrics$fpr,       fmt1),
  FNR           = sapply(class_metrics$fnr,       fmt1),
  `Top FP src`  = ifelse(is.na(class_metrics$top_fp_source), "—", class_metrics$top_fp_source),
  `Top FN dest` = ifelse(is.na(class_metrics$top_fn_dest),   "—", class_metrics$top_fn_dest),
  check.names   = FALSE, stringsAsFactors = FALSE
)
L(md_table(metrics_tbl))
BR()
L(sprintf("![Per-class Precision / Recall / F1](normal_report_%s_metrics.png)", date_str))
BR()
L("---")
BR()

# ── 3. Paper-Level Accuracy ───────────────────────────────────────────────────

L("## 3. Paper-Level Accuracy")
BR()

type_vals  <- per_paper_stats$type_acc[!is.na(per_paper_stats$type_acc)]
group_vals <- per_paper_stats$group_acc[!is.na(per_paper_stats$group_acc)]
dg_vals    <- per_paper_stats$dg_acc[!is.na(per_paper_stats$dg_acc)]

L("_Statistics computed across papers (each paper weighted equally, regardless of file count)._")
BR()
L("| Metric | Mean | Median | Min | Max | Papers with 100% |")
L("|---|---|---|---|---|---|")
L(sprintf("| **Type accuracy** | %s | %s | %s | %s | %d / %d |",
  fmt1(mean(type_vals)), fmt1(median(type_vals)),
  fmt1(min(type_vals)),  fmt1(max(type_vals)),
  sum(type_vals == 100), length(type_vals)))
L(sprintf("| **Group accuracy** | %s | %s | %s | %s | %d / %d |",
  fmt1(mean(group_vals)), fmt1(median(group_vals)),
  fmt1(min(group_vals)),  fmt1(max(group_vals)),
  sum(group_vals == 100, na.rm = TRUE), length(group_vals)))
L(sprintf("| **DG accuracy** | %s | %s | %s | %s | %d / %d |",
  fmt1(mean(dg_vals)), fmt1(median(dg_vals)),
  fmt1(min(dg_vals)),  fmt1(max(dg_vals)),
  sum(dg_vals == 100, na.rm = TRUE), length(dg_vals)))
BR()

breaks <- c(0, 50, 70, 85, 95, 100)
labels <- c("<50%", "50–70%", "70–85%", "85–95%", "95–100%")
bucket <- cut(type_vals, breaks = breaks, include.lowest = TRUE, right = TRUE, labels = labels)
bucket_counts <- table(factor(bucket, levels = labels))

L("**Type accuracy distribution across papers:**")
BR()
L("| Bucket | Papers |")
L("|---|---|")
for (i in seq_along(labels))
  L(sprintf("| %s | %d |", labels[i], bucket_counts[[labels[i]]]))
BR()
L(sprintf("![Per-paper type accuracy distribution](normal_report_%s_paper_dist.png)", date_str))
BR()

# ── 3a. Bad paper diagnosis ───────────────────────────────────────────────────

bad_papers <- per_paper_stats[!is.na(per_paper_stats$type_acc) & per_paper_stats$type_acc < 50, ]
bad_papers <- bad_papers[order(bad_papers$type_acc), ]

L("### 3a. Low-accuracy papers (<50% type accuracy)")
BR()
L(sprintf("_%d papers fall below 50%%. Top error pair and top misclassified extension shown for each._",
  nrow(bad_papers)))
BR()

if (nrow(bad_papers) == 0) {
  L("_None._")
} else {
  bp_tbl <- data.frame(
    Paper        = bad_papers$paper_id,
    `Files GT`   = bad_papers$n_files,
    `Type acc`   = sapply(bad_papers$type_acc, fmt1),
    `Top error`  = bad_papers$top_err,
    `Top ext`    = bad_papers$top_ext,
    check.names  = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(bp_tbl))
}
BR()
L("---")
BR()

# ── 4. Top Confusion Pairs ────────────────────────────────────────────────────

L("## 4. Top Confusion Pairs")
BR()
L("_All misclassifications ranked by frequency. `GT → Predicted` shows the direction of error._")
BR()

if (length(top_pairs) == 0) {
  L("_No misclassifications found._")
} else {
  conf_tbl <- data.frame(
    `GT → Predicted` = names(top_pairs),
    Count            = as.integer(top_pairs),
    check.names      = FALSE, stringsAsFactors = FALSE
  )
  total_wrong <- sum(conf_tbl$Count)
  conf_tbl$`% of errors` <- sapply(conf_tbl$Count, function(n) pct(n, total_wrong))
  L(md_table(conf_tbl))
  BR()
  L(sprintf("![Top misclassification patterns](normal_report_%s_fp_fn.png)", date_str))
}
BR()
L("---")
BR()

# ── 5. Extension-Level Error Analysis ────────────────────────────────────────

L("## 5. Extension-Level Error Analysis")
BR()
L("_Error rate per file extension (extensions with fewer than 5 annotated files excluded).  ")
L("Sorted by total error count. Helps identify whether specific extensions drive confusion._")
BR()

if (is.null(ext_stats) || nrow(ext_stats) == 0) {
  L("_No extension data available._")
} else {
  ext_tbl <- data.frame(
    Extension    = ext_stats$ext,
    `N files`    = ext_stats$n_files,
    `N errors`   = ext_stats$n_errors,
    `Error rate` = sapply(ext_stats$error_rate, fmt1),
    `Top pair`   = ext_stats$top_pair,
    check.names  = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(ext_tbl))
  BR()
  L(sprintf("![Error rate by file extension](normal_report_%s_ext_errors.png)", date_str))
}
BR()
L("---")
BR()

# ── 6. Downstream Impact — False Positives & Negatives in `data` ──────────────

L("## 6. Downstream Impact on `data` Classification")
BR()
L("_Misclassifications in the `data` class have direct pipeline consequences:  ")
L("**False positives** (non-data predicted as `data`) trigger unnecessary column extraction.  ")
L("**False negatives** (data predicted as something else) cause datasets to be silently skipped._")
BR()

# FP breakdown by GT class
L("### 6a. False positives — wrongly predicted as `data`")
BR()
L(sprintf("_**%d files** were predicted as `data` but are not. Column extraction ran on these unnecessarily._",
  nrow(data_fp)))
BR()
if (nrow(data_fp) > 0) {
  fp_by_class <- sort(table(data_fp$type_gt), decreasing = TRUE)
  fp_cls_tbl <- data.frame(
    `True class`  = names(fp_by_class),
    Count         = as.integer(fp_by_class),
    `% of FPs`    = sapply(as.integer(fp_by_class), function(n) pct(n, nrow(data_fp))),
    check.names   = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(fp_cls_tbl))
} else {
  L("_None._")
}
BR()

# FN breakdown by predicted class
L("### 6b. False negatives — `data` files missed")
BR()
L(sprintf("_**%d data files** were not predicted as `data` and were skipped by column extraction._",
  nrow(data_fn)))
BR()
if (nrow(data_fn) > 0) {
  fn_by_class <- sort(table(data_fn$type), decreasing = TRUE)
  fn_cls_tbl <- data.frame(
    `Predicted as` = names(fn_by_class),
    Count          = as.integer(fn_by_class),
    `% of FNs`     = sapply(as.integer(fn_by_class), function(n) pct(n, nrow(data_fn))),
    check.names    = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(fn_cls_tbl))
} else {
  L("_None._")
}
BR()
L("---")
BR()

# ── 7. Per-Type Recall ────────────────────────────────────────────────────────

L("## 7. Per-Type Recall")
BR()
L("_How often each true type was correctly identified._")
BR()

all_type_gt <- sort(unique(acc$type_gt[!is.na(acc$type_gt)]))
per_type <- do.call(rbind, lapply(all_type_gt, function(t) {
  rows  <- acc[!is.na(acc$type_gt) & acc$type_gt == t, ]
  n     <- nrow(rows)
  corr  <- sum(!is.na(rows$type) & rows$type == t)
  wrong <- rows$type[!is.na(rows$type) & rows$type != t]
  data.frame(
    Type            = t,
    `N files`       = n,
    Correct         = corr,
    Recall          = pct(corr, n),
    `Confused with` = { mc <- most_common(wrong); if (is.na(mc)) "—" else mc },
    check.names     = FALSE, stringsAsFactors = FALSE
  )
}))
L(md_table(per_type))
BR()
L("---")
BR()

# ── 8. Confusion Matrices ─────────────────────────────────────────────────────

L("## 8. Confusion Matrices")
BR()

L("### 8a. File type")
BR()
L("_Rows = ground truth, columns = predicted. Correct predictions on diagonal._")
BR()
if (nrow(valid) > 0) {
  L(md_table(cbind(data.frame(`type \\ pred` = rownames(cm), check.names = FALSE), cm)))
} else {
  L("_Insufficient data._")
}
BR()
L(sprintf("![Type confusion matrix](normal_report_%s_confusion.png)", date_str))
BR()

L("### 8b. Group (data files, type correct)")
BR()
if (!is.null(cm_grp) && nrow(cm_grp) > 0) {
  cm_grp_df <- as.data.frame.matrix(cm_grp)
  L(md_table(cbind(data.frame(`group \\ pred` = rownames(cm_grp_df), check.names = FALSE), cm_grp_df)))
  BR()
  L(sprintf("![Group confusion matrix](normal_report_%s_group_conf.png)", date_str))
} else {
  L("_Insufficient data._")
}
BR()

L("### 8c. data_granularity (data files, type correct)")
BR()
if (!is.null(cm_dg) && nrow(cm_dg) > 0) {
  cm_dg_df <- as.data.frame.matrix(cm_dg)
  L(md_table(cbind(data.frame(`dg \\ pred` = rownames(cm_dg_df), check.names = FALSE), cm_dg_df)))
  BR()
  L(sprintf("![DG confusion matrix](normal_report_%s_dg_conf.png)", date_str))
} else {
  L("_Insufficient data._")
}
BR()
L("---")
BR()

# ── 9. Per-Paper Table ────────────────────────────────────────────────────────

L("## 9. Per-Paper")
BR()

per_paper_tbl <- data.frame(
  Paper       = per_paper_stats$paper_id,
  `Files GT`  = per_paper_stats$n_files,
  `Type acc`  = sapply(per_paper_stats$type_acc,  fmt1),
  `Group acc` = sapply(per_paper_stats$group_acc, fmt1),
  `DG acc`    = sapply(per_paper_stats$dg_acc,    fmt1),
  check.names = FALSE, stringsAsFactors = FALSE
)
L(md_table(per_paper_tbl))
BR()
L("---")
BR()

# ── 10. Misclassified Files ───────────────────────────────────────────────────

L("## 10. Misclassified Files")
BR()

L("### 10a. Type wrong")
BR()
L("_Files where predicted type differs from ground truth._")
BR()

wrong_type <- acc[!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt != acc$type, ]
if (nrow(wrong_type) == 0) {
  L("_No type misclassifications._")
} else {
  wrong_tbl <- data.frame(
    Paper         = wrong_type$paper_id,
    File          = wrong_type$rel_path,
    `GT type`     = wrong_type$type_gt,
    `Pred type`   = wrong_type$type,
    `GT group`    = if ("group_gt" %in% names(wrong_type)) wrong_type$group_gt else NA_character_,
    `Pred group`  = if ("group"    %in% names(wrong_type)) wrong_type$group    else NA_character_,
    `type_source` = if ("type_source" %in% names(wrong_type)) wrong_type$type_source else NA_character_,
    check.names   = FALSE, stringsAsFactors = FALSE
  )
  wrong_tbl <- wrong_tbl[order(wrong_tbl$Paper, wrong_tbl$`GT type`), ]
  L(md_table(wrong_tbl))
}
BR()

L("### 10b. Group wrong (type correct)")
BR()
L("_Data files where type was correct but group differs from ground truth._")
BR()

wrong_group <- acc[
  !is.na(acc$type_gt) & acc$type_gt == "data" &
  !is.na(acc$type)    & acc$type    == "data" &
  !is.na(acc$group_gt) & !is.na(acc$group) &
  acc$group_gt != acc$group, ]
if (nrow(wrong_group) == 0) {
  L("_No group misclassifications._")
} else {
  wg_tbl <- data.frame(
    Paper         = wrong_group$paper_id,
    File          = wrong_group$rel_path,
    `GT group`    = wrong_group$group_gt,
    `Pred group`  = wrong_group$group,
    `type_source` = if ("type_source" %in% names(wrong_group)) wrong_group$type_source else NA_character_,
    check.names   = FALSE, stringsAsFactors = FALSE
  )
  wg_tbl <- wg_tbl[order(wg_tbl$Paper, wg_tbl$`GT group`), ]
  L(md_table(wg_tbl))
}
BR()

# ── Write MD ──────────────────────────────────────────────────────────────────

dir.create(REPORT_DIR, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(REPORT_DIR, paste0("normal_report_", date_str, ".md"))
writeLines(lines, out_path)
cat(sprintf("  [report] written to: %s\n", out_path))

# ── Visualisations ────────────────────────────────────────────────────────────

# ── Plot 1: Per-class Precision / Recall / F1 ─────────────────────────────────

png_metrics <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_metrics.png"))
png(png_metrics, width = 900, height = 500, res = 100)
cls_names <- class_metrics$class
mat       <- rbind(class_metrics$precision / 100,
                   class_metrics$recall    / 100,
                   class_metrics$f1        / 100)
mat[is.na(mat)] <- 0
old_par <- par(mar = c(6, 4.5, 3, 1))
barplot(mat, beside = TRUE, names.arg = cls_names, ylim = c(0, 1),
        col = c("#4C72B0", "#55A868", "#C44E52"), border = NA,
        ylab = "Score", main = "Per-Class Precision / Recall / F1", las = 2, cex.names = 0.85)
abline(h = seq(0, 1, 0.2), col = "grey85")
barplot(mat, beside = TRUE, col = c("#4C72B0", "#55A868", "#C44E52"),
        border = NA, add = TRUE, axes = FALSE, names.arg = rep("", length(cls_names)))
legend("topright", legend = c("Precision", "Recall", "F1"),
       fill = c("#4C72B0", "#55A868", "#C44E52"), border = NA, bty = "n")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_metrics))

# ── Plot 2: Type confusion matrix heatmap ─────────────────────────────────────

png_conf <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_confusion.png"))
png(png_conf, width = 700, height = 620, res = 100)
heatmap_plot(as.matrix(cm), "Type Confusion Matrix (row-normalised)")
invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_conf))

# ── Plot 3: Per-paper type accuracy distribution ──────────────────────────────

png_dist <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_paper_dist.png"))
png(png_dist, width = 800, height = 480, res = 100)
old_par <- par(mar = c(5, 4, 3, 1))
h_dist <- hist(type_vals, breaks = seq(0, 100, by = 5), plot = FALSE)
plot(NULL, xlim = c(0, 100), ylim = c(0, max(h_dist$counts) + 1),
     xlab = "Type accuracy (%)", ylab = "Number of papers",
     main = sprintf("Per-Paper Type Accuracy  (mean=%.1f%%  median=%.1f%%)",
                    mean(type_vals), median(type_vals)),
     las = 1)
rect(h_dist$breaks[-length(h_dist$breaks)], 0, h_dist$breaks[-1], h_dist$counts,
     col = "#4C72B0", border = "white")
abline(v = mean(type_vals),   col = "#C44E52", lwd = 2, lty = 2)
abline(v = median(type_vals), col = "#55A868", lwd = 2, lty = 2)
legend("topleft",
       legend = c(sprintf("Mean   %.1f%%", mean(type_vals)),
                  sprintf("Median %.1f%%", median(type_vals))),
       col = c("#C44E52", "#55A868"), lwd = 2, lty = 2, bty = "n")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_dist))

# ── Plot 4: Top FP/FN confusion pairs ────────────────────────────────────────

if (length(top_pairs) > 0) {
  png_fp_fn <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_fp_fn.png"))
  n_show    <- min(15, length(top_pairs))
  png(png_fp_fn, width = 900, height = 400 + n_show * 20, res = 100)
  old_par <- par(mar = c(4, 14, 3, 2))
  barplot(as.integer(top_pairs[n_show:1]), names.arg = names(top_pairs)[n_show:1],
          horiz = TRUE, las = 1, col = "#C44E52", border = NA,
          xlab = "Count", main = "Top Misclassification Patterns (GT → Predicted)",
          cex.names = 0.82)
  par(old_par); invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_fp_fn))
}

# ── Plot 5: Extension error rate ──────────────────────────────────────────────

if (!is.null(ext_stats) && nrow(ext_stats) > 0) {
  png_ext <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_ext_errors.png"))
  n_show  <- min(20, nrow(ext_stats))
  top_ext <- ext_stats[seq_len(n_show), ]
  top_ext <- top_ext[order(top_ext$error_rate), ]   # sort by rate for horizontal bar
  png(png_ext, width = 900, height = 400 + n_show * 18, res = 100)
  old_par <- par(mar = c(4, 7, 3, 5))
  bp <- barplot(top_ext$error_rate, names.arg = top_ext$ext,
                horiz = TRUE, las = 1, col = "#DD8452", border = NA,
                xlab = "Error rate (%)", xlim = c(0, 100),
                main = "Error Rate by File Extension (top 20 by error count)",
                cex.names = 0.82)
  # annotate with raw counts
  text(x = top_ext$error_rate + 1.5, y = bp,
       labels = sprintf("%d/%d", top_ext$n_errors, top_ext$n_files),
       adj = 0, cex = 0.72, col = "grey30")
  par(old_par); invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_ext))
}

# ── Plot 6: Group confusion matrix ────────────────────────────────────────────

if (!is.null(cm_grp) && nrow(cm_grp) > 1) {
  png_grp <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_group_conf.png"))
  sz      <- max(500, 100 * nrow(cm_grp) + 200)
  png(png_grp, width = sz, height = sz, res = 100)
  heatmap_plot(cm_grp, "Group Confusion Matrix (row-normalised, data files only)")
  invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_grp))
}

# ── Plot 7: DG confusion matrix ───────────────────────────────────────────────

if (!is.null(cm_dg) && nrow(cm_dg) > 1) {
  png_dg <- file.path(REPORT_DIR, paste0("normal_report_", date_str, "_dg_conf.png"))
  sz     <- max(500, 100 * nrow(cm_dg) + 200)
  png(png_dg, width = sz, height = sz, res = 100)
  heatmap_plot(cm_dg, "data_granularity Confusion Matrix (row-normalised, data files only)")
  invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_dg))
}
