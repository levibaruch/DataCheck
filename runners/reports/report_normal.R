# report_normal.R
# ─────────────────────────────────────────────────────────────────────────────
# Generates a classification evaluation report for all "normal" (non-test)
# papers in outputs/ that have BOTH:
#   - outputs/<paper_id>/structure.csv  (stage 0 / indexing done)
#   - ground_truth/<paper_id>.csv       (manual annotations)
#
# Outputs:
#   results/normal_report_<date>.md
#   results/normal_report_<date>_metrics.png          file-pooled per-class P/R/F1
#   results/normal_report_<date>_metrics_pa.png       paper-averaged per-class F1 (box)
#   results/normal_report_<date>_confusion.png        file-pooled type confusion matrix
#   results/normal_report_<date>_confusion_pa.png     paper-averaged type confusion matrix
#   results/normal_report_<date>_paper_dist.png       per-paper accuracy distribution
#   results/normal_report_<date>_paper_scatter.png    paper size vs accuracy scatter
#   results/normal_report_<date>_kappa_dist.png       per-paper kappa distribution
#   results/normal_report_<date>_summary_compare.png  paper-avg vs file-pooled comparison
#   results/normal_report_<date>_fp_fn.png            top FP/FN confusion pairs
#   results/normal_report_<date>_ext_errors.png       error rate by file extension
#   results/normal_report_<date>_group_conf.png       group confusion matrix heatmap
#   results/normal_report_<date>_dg_conf.png          data_granularity confusion heatmap
#   results/normal_report_<date>_df_conf.png           data_format confusion heatmap
#   results/normal_report_<date>_corpus_repo_sizes.png ranked dot plot of files per paper
#   results/normal_report_<date>_corpus_type_dist.png  ground truth file type distribution
#   results/normal_report_<date>_corpus_data_dist.png       granularity + format heatmap (data files)
#   results/normal_report_<date>_corpus_paper_prevalence.png % repos with each data subcategory
#
# Usage (interactive):  source("runners/report_normal.R")
# Usage (CLI):          Rscript runners/report_normal.R
# ─────────────────────────────────────────────────────────────────────────────

OUTPUTS_DIR      <- "./outputs"
GT_DIR           <- "./tests/ground_truth"
REPORT_DIR       <- "./results"
SOURCE_CORPUS_DIR <- "/Volumes/Models/expanded_xml"   # path to MetaCheck XML corpus; set NA to skip

# ── Helpers ───────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

pct     <- function(n, d) if (d == 0L) "n/a" else sprintf("%.1f%%", 100 * n / d)
pct_num <- function(n, d) if (d == 0L) NA_real_ else 100 * n / d
fmt1    <- function(x) if (is.na(x)) "n/a" else sprintf("%.1f%%", x)
fmt3    <- function(x) if (is.na(x)) "n/a" else sprintf("%.3f", x)

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

# compute kappa, macro-F1, MCC from a confusion matrix
cm_stats <- function(cm_m) {
  N <- sum(cm_m)
  if (N == 0) return(list(kappa = NA_real_, macro_f1 = NA_real_, mcc = NA_real_, accuracy = NA_real_))
  rs  <- rowSums(cm_m)
  cs  <- colSums(cm_m)
  p_o <- sum(diag(cm_m)) / N
  p_e <- sum(rs * cs) / N^2
  kap <- if (p_e < 1) (p_o - p_e) / (1 - p_e) else NA_real_

  all_t  <- rownames(cm_m)
  f1s <- sapply(all_t, function(cls) {
    tp <- cm_m[cls, cls]
    fp <- sum(cm_m[, cls]) - tp
    fn <- sum(cm_m[cls, ]) - tp
    p  <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
    r  <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
    if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
  })
  mf1 <- mean(f1s, na.rm = TRUE) * 100

  mcc_n <- N * sum(diag(cm_m)) - sum(rs * cs)
  mcc_d <- sqrt((N^2 - sum(cs^2)) * (N^2 - sum(rs^2)))
  mcc   <- if (mcc_d > 0) mcc_n / mcc_d else NA_real_

  list(kappa = kap, macro_f1 = mf1, mcc = mcc, accuracy = p_o * 100,
       f1s = f1s * 100)
}

heatmap_plot <- function(mat, title, xlab = "Predicted", ylab = "Ground truth",
                         subtitle = NULL) {
  n        <- nrow(mat)
  row_sums <- rowSums(mat)
  norm     <- mat / ifelse(row_sums == 0, 1, row_sums)
  col_ramp <- colorRampPalette(c("white", "#2171b5"))(100)
  lbls     <- rownames(mat)
  top_mar  <- if (!is.null(subtitle)) 4 else 3
  old_par  <- par(mar = c(7, 7, top_mar, 2))
  image(seq_len(n), seq_len(n), t(norm)[, n:1],
        col = col_ramp, axes = FALSE, xlab = "", ylab = "", main = title)
  if (!is.null(subtitle))
    mtext(subtitle, side = 3, line = 0.2, cex = 0.8, col = "grey40")
  axis(1, at = seq_len(n), labels = lbls,      las = 2, cex.axis = 0.85)
  axis(2, at = seq_len(n), labels = rev(lbls), las = 1, cex.axis = 0.85)
  mtext(xlab, side = 1, line = 5.5, cex = 0.9)
  mtext(ylab, side = 2, line = 5.5, cex = 0.9)
  for (i in seq_len(n))
    for (j in seq_len(n)) {
      v <- mat[n + 1 - j, i]
      if (v > 0) text(i, j, if (v < 1) sprintf("%.2f", v) else as.character(round(v)),
                      col = if (norm[n + 1 - j, i] > 0.6) "white" else "black",
                      cex = 0.75)
    }
  par(old_par)
}

# ── Discover eligible papers ──────────────────────────────────────────────────

gt_ids <- sub("\\.csv$", "", list.files(file.path(GT_DIR, "osf"), pattern = "\\.csv$"))

eligible <- Filter(function(pid) {
  file.exists(file.path(OUTPUTS_DIR, "osf", pid, "structure.csv"))
}, gt_ids)

if (length(eligible) == 0) {
  cat("No papers found with both structure.csv and a ground-truth file.\n")
  quit(status = 0)
}

cat(sprintf("Found %d eligible papers.\n", length(eligible)))

# ── Load and merge GT + structure ─────────────────────────────────────────────

acc_list <- list()
for (pid in eligible) {
  gt_path  <- file.path(GT_DIR,      "osf", paste0(pid, ".csv"))
  str_path <- file.path(OUTPUTS_DIR, "osf", pid, "structure.csv")

  gt  <- tryCatch(
    read.csv(gt_path,  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE),
    error = function(e) { message("[WARN] could not read ", gt_path); NULL }
  )
  str <- tryCatch(
    read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE),
    error = function(e) { message("[WARN] could not read ", str_path); NULL }
  )

  if (is.null(gt) || is.null(str) || nrow(gt) == 0) next

  # Skip partially annotated papers — only include papers where every file
  # in structure.csv has a corresponding GT row, and vice versa
  if (!all(str$rel_path %in% gt$rel_path) || !all(gt$rel_path %in% str$rel_path)) next

  keep_str <- intersect(
    c("rel_path", "type", "group", "data_granularity", "data_format",
      "type_source", "granularity_source"),
    names(str)
  )
  m <- merge(
    gt[, intersect(c("rel_path", "type_gt", "group_gt", "data_granularity_gt", "data_format_gt"), names(gt))],
    str[, keep_str],
    by = "rel_path", all.x = TRUE
  )
  m$paper_id <- pid
  acc_list[[pid]] <- m
}

# Normalize column sets — different papers may have different optional cols
# (e.g. type_source/granularity_source added in newer structure.csv schemas).
# Fill missing cols with NA so rbind succeeds.
if (length(acc_list) > 0) {
  all_cols <- unique(unlist(lapply(acc_list, names)))
  acc_list <- lapply(acc_list, function(d) {
    miss <- setdiff(all_cols, names(d))
    for (cn in miss) d[[cn]] <- NA
    d[, all_cols, drop = FALSE]
  })
}
acc     <- if (length(acc_list) > 0) do.call(rbind, acc_list) else NULL
has_acc <- !is.null(acc) && nrow(acc) > 0

if (!has_acc) {
  cat("No accuracy data could be built — check GT and structure files.\n")
  quit(status = 0)
}

# ── File-pooled metrics ───────────────────────────────────────────────────────

valid     <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]
all_types <- sort(unique(c(valid$type_gt, valid$type)))

class_metrics <- do.call(rbind, lapply(all_types, function(cls) {
  tp <- sum(valid$type_gt == cls & valid$type == cls)
  fp <- sum(valid$type_gt != cls & valid$type == cls)
  fn <- sum(valid$type_gt == cls & valid$type != cls)
  tn <- sum(valid$type_gt != cls & valid$type != cls)

  prec <- pct_num(tp, tp + fp)
  rec  <- pct_num(tp, tp + fn)
  f1   <- if (!is.na(prec) && !is.na(rec) && (prec + rec) > 0)
             2 * prec * rec / (prec + rec) else NA_real_
  fpr  <- pct_num(fp, fp + tn)
  fnr  <- pct_num(fn, tp + fn)

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

# File-pooled confusion matrix + global stats
ctypes <- sort(unique(c(valid$type_gt, valid$type)))
cm     <- as.data.frame.matrix(
  table(gt   = factor(valid$type_gt, levels = ctypes),
        pred = factor(valid$type,    levels = ctypes))
)
fp_stats   <- cm_stats(as.matrix(cm))
macro_f1   <- fp_stats$macro_f1
kappa      <- fp_stats$kappa
mcc        <- fp_stats$mcc

micro_tp <- sum(class_metrics$tp)
micro_fp <- sum(class_metrics$fp)
micro_fn <- sum(class_metrics$fn)
micro_p  <- micro_tp / (micro_tp + micro_fp)
micro_r  <- micro_tp / (micro_tp + micro_fn)
micro_f1 <- if ((micro_p + micro_r) > 0) 2 * micro_p * micro_r / (micro_p + micro_r) * 100 else NA_real_

# ── Per-paper metrics (κ, macro F1, MCC, accuracy, per-class F1) ─────────────

per_paper_full <- do.call(rbind, Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
  v <- valid[valid$paper_id == pid, ]
  if (nrow(v) < 2) return(NULL)

  all_t <- sort(unique(c(v$type_gt, v$type)))
  cm_p  <- as.matrix(table(
    gt   = factor(v$type_gt, levels = all_t),
    pred = factor(v$type,    levels = all_t)
  ))
  s <- cm_stats(cm_p)

  a  <- acc[acc$paper_id == pid, ]
  da <- a[!is.na(a$type_gt) & a$type_gt == "data", ]
  dg <- da[!is.na(da$data_granularity_gt), ]
  df <- da[!is.na(da$data_format_gt), ]
  n_group <- sum(!is.na(a$group_gt))
  n_dg    <- nrow(dg)
  n_df    <- nrow(df)

  w <- v[v$type_gt != v$type, ]
  top_err <- if (nrow(w) > 0) {
    pk  <- paste0(w$type_gt, "→", w$type)
    tbl <- sort(table(pk), decreasing = TRUE)
    sprintf("%s (%d)", names(tbl)[1], tbl[[1]])
  } else "—"
  top_ext <- if (nrow(w) > 0) {
    names(sort(table(get_ext(w$rel_path)), decreasing = TRUE))[1]
  } else "—"

  data.frame(
    paper_id  = pid,
    n_files   = nrow(v),
    kappa     = s$kappa,
    macro_f1  = s$macro_f1,
    mcc       = s$mcc,
    type_acc  = s$accuracy,
    group_acc = pct_num(sum(!is.na(a$group_gt) & !is.na(a$group) & a$group_gt == a$group), n_group),
    dg_acc    = pct_num(sum(!is.na(dg$data_granularity) & dg$data_granularity_gt == dg$data_granularity), n_dg),
    df_acc    = pct_num(sum(!is.na(df$data_format) & df$data_format_gt == df$data_format), n_df),
    top_err   = top_err,
    top_ext   = top_ext,
    stringsAsFactors = FALSE
  )
})))

# Paper-averaged summary scalars
pa_kappa      <- mean(per_paper_full$kappa,     na.rm = TRUE)
pa_macro_f1   <- mean(per_paper_full$macro_f1,  na.rm = TRUE)
pa_mcc        <- mean(per_paper_full$mcc,        na.rm = TRUE)
pa_accuracy   <- mean(per_paper_full$type_acc,   na.rm = TRUE)
pa_group_acc  <- mean(per_paper_full$group_acc,  na.rm = TRUE)
pa_dg_acc     <- mean(per_paper_full$dg_acc,     na.rm = TRUE)
pa_df_acc     <- mean(per_paper_full$df_acc,     na.rm = TRUE)
n_papers_group <- sum(!is.na(per_paper_full$group_acc))
n_papers_dg    <- sum(!is.na(per_paper_full$dg_acc))
n_papers_df    <- sum(!is.na(per_paper_full$df_acc))

# Per-paper per-class F1 (for box plots and paper-averaged per-class table)
per_paper_class_f1 <- do.call(rbind, Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
  v <- valid[valid$paper_id == pid, ]
  if (nrow(v) < 2) return(NULL)
  do.call(rbind, Filter(Negate(is.null), lapply(all_types, function(cls) {
    n_gt <- sum(v$type_gt == cls)
    if (n_gt == 0) return(NULL)
    tp <- sum(v$type_gt == cls & v$type == cls)
    fp <- sum(v$type_gt != cls & v$type == cls)
    fn <- sum(v$type_gt == cls & v$type != cls)
    p  <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
    r  <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
    f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r)*100 else NA_real_
    data.frame(paper_id = pid, class = cls, f1 = f1, n_gt = n_gt,
               stringsAsFactors = FALSE)
  })))
})))

# Paper-averaged per-class F1
pa_class_metrics <- do.call(rbind, lapply(all_types, function(cls) {
  rows <- per_paper_class_f1[per_paper_class_f1$class == cls, ]
  data.frame(
    class    = cls,
    pa_f1    = mean(rows$f1, na.rm = TRUE),
    pa_f1_sd = sd(rows$f1,   na.rm = TRUE),
    n_papers = sum(!is.na(rows$f1)),
    fp_f1    = class_metrics$f1[class_metrics$class == cls],
    stringsAsFactors = FALSE
  )
}))

# Paper-averaged confusion matrix (average of per-paper row-normalised matrices)
# Each paper's CM is row-normalised (rows sum to 1 for classes the paper has).
# We then average row-wise across only the papers that contained each class,
# so the final matrix also has rows summing to 1 (for classes with >= 1 paper).
pa_cm_sum <- Reduce("+", Filter(Negate(is.null), lapply(sort(unique(acc$paper_id)), function(pid) {
  v <- valid[valid$paper_id == pid, ]
  if (nrow(v) < 2) return(NULL)
  cm_p <- as.matrix(table(
    gt   = factor(v$type_gt, levels = ctypes),
    pred = factor(v$type,    levels = ctypes)
  ))
  rs <- rowSums(cm_p)
  cm_p / ifelse(rs == 0, 1, rs)   # row-normalise; rows with no files stay 0
})))
# rowSums(pa_cm_sum)[i] == number of papers that had at least one file of class i
pa_cm_row_n <- rowSums(pa_cm_sum)
pa_cm_norm  <- pa_cm_sum / ifelse(pa_cm_row_n == 0, 1, pa_cm_row_n)

# ── Per-paper accuracy (legacy alias) ────────────────────────────────────────
type_vals  <- per_paper_full$type_acc[!is.na(per_paper_full$type_acc)]
group_vals <- per_paper_full$group_acc[!is.na(per_paper_full$group_acc)]
dg_vals    <- per_paper_full$dg_acc[!is.na(per_paper_full$dg_acc)]

# ── Top confusion pairs ───────────────────────────────────────────────────────

wrong       <- valid[valid$type_gt != valid$type, ]
pair_key    <- paste0(wrong$type_gt, " → ", wrong$type)
pair_counts <- sort(table(pair_key), decreasing = TRUE)
top_pairs   <- head(pair_counts, 20)

# ── Extension-level error analysis ───────────────────────────────────────────

acc$ext   <- get_ext(acc$rel_path)
valid_ext <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]

ext_stats <- do.call(rbind, Filter(Negate(is.null), lapply(sort(unique(valid_ext$ext)), function(e) {
  rows  <- valid_ext[valid_ext$ext == e, ]
  n     <- nrow(rows)
  wrong_rows <- rows[rows$type_gt != rows$type, ]
  n_wrong <- nrow(wrong_rows)
  if (n < 5) return(NULL)
  top_pair <- if (n_wrong > 0) {
    pk  <- paste0(wrong_rows$type_gt, "→", wrong_rows$type)
    tbl <- sort(table(pk), decreasing = TRUE)
    sprintf("%s (%d)", names(tbl)[1], tbl[[1]])
  } else "—"
  data.frame(ext = e, n_files = n, n_errors = n_wrong,
             error_rate = pct_num(n_wrong, n), top_pair = top_pair,
             stringsAsFactors = FALSE)
})))
ext_stats <- ext_stats[order(-ext_stats$n_errors), ]

# ── Group confusion matrix ────────────────────────────────────────────────────

grp_valid <- acc[
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
  !is.na(acc$type_gt) & acc$type_gt == "data" &
  !is.na(acc$type)    & acc$type    == "data" &
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

# Paper-weighted confusion matrix builder.
# For each GT level, computes the mean of per-paper row-stochastic
# distributions (one paper = one vote). Rows sum to 1; large papers no
# longer dominate the cell counts.
paper_weighted_cm <- function(df, gt_col, pred_col, levels) {
  papers <- unique(df$paper_id)
  cm        <- matrix(0, length(levels), length(levels),
                      dimnames = list(levels, levels))
  n_per_row <- setNames(rep(0L, length(levels)), levels)
  for (pid in papers) {
    pdf <- df[df$paper_id == pid, ]
    for (gtl in levels) {
      rows <- pdf[!is.na(pdf[[gt_col]]) & pdf[[gt_col]] == gtl, ]
      if (nrow(rows) == 0) next
      pr <- table(factor(rows[[pred_col]], levels = levels)) / nrow(rows)
      cm[gtl, ]      <- cm[gtl, ] + as.numeric(pr)
      n_per_row[gtl] <- n_per_row[gtl] + 1L
    }
  }
  for (gtl in levels) if (n_per_row[gtl] > 0L)
    cm[gtl, ] <- cm[gtl, ] / n_per_row[gtl]
  list(cm = cm, n_per_row = n_per_row)
}

cm_dg_pw <- if (!is.null(cm_dg)) {
  paper_weighted_cm(dg_valid, "data_granularity_gt", "data_granularity", dg_levels)
} else NULL

# ── data_format confusion matrix ─────────────────────────────────────────────

df_valid <- acc[
  !is.na(acc$type_gt) & acc$type_gt == "data" &
  !is.na(acc$type)    & acc$type    == "data" &
  !is.na(acc$data_format_gt) & !is.na(acc$data_format), ]

if (nrow(df_valid) > 0) {
  df_levels <- sort(unique(c(df_valid$data_format_gt, df_valid$data_format)))
  cm_df <- as.matrix(table(
    gt   = factor(df_valid$data_format_gt, levels = df_levels),
    pred = factor(df_valid$data_format,    levels = df_levels)
  ))
  cm_df_pw <- paper_weighted_cm(df_valid, "data_format_gt", "data_format", df_levels)
} else {
  cm_df_pw <- NULL
  cm_df <- NULL
}

# ── Downstream FP/FN impact on `data` ────────────────────────────────────────

data_fp <- valid[valid$type_gt != "data" & valid$type == "data", ]
data_fn <- valid[valid$type_gt == "data" & valid$type != "data", ]

# ── Kappa interpretation ──────────────────────────────────────────────────────

kappa_interp <- function(k) {
  if (is.na(k))  return("n/a")
  if (k < 0)     return("poor (< 0)")
  if (k < 0.20)  return("slight (0.00–0.20)")
  if (k < 0.40)  return("fair (0.20–0.40)")
  if (k < 0.60)  return("moderate (0.40–0.60)")
  if (k < 0.80)  return("substantial (0.60–0.80)")
  return("almost perfect (0.80–1.00)")
}

# ── Corpus distribution stats ─────────────────────────────────────────────────

corpus_repo_sizes  <- sort(table(acc$paper_id), decreasing = TRUE)
corpus_type_counts      <- sort(table(acc$type_gt), decreasing = TRUE)
small_papers            <- names(corpus_repo_sizes)[as.numeric(corpus_repo_sizes) <= 500]
corpus_type_counts_sm   <- sort(table(acc$type_gt[acc$paper_id %in% small_papers]), decreasing = TRUE)

data_only <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]
corpus_dg_counts  <- sort(table(data_only$data_granularity_gt), decreasing = TRUE)
corpus_df_counts  <- sort(table(data_only$data_format_gt),      decreasing = TRUE)

# ── Build report ──────────────────────────────────────────────────────────────

lines <- character(0)
L  <- function(...) { lines <<- c(lines, paste0(...)) }
BR <- function()    { lines <<- c(lines, "") }

date_str <- format(Sys.Date(), "%Y-%m-%d")
now_str  <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
n_papers <- length(unique(acc$paper_id))
tn_total <- sum(!is.na(acc$type_gt))

# ── Metric Glossary ───────────────────────────────────────────────────────────

L("# LLM Classification Evaluation Report — ", date_str)
BR()
L("**Papers:** ", n_papers, "  |  **Annotated files:** ", tn_total, "  |  **Generated:** ", now_str)
BR()
L("_Compares LLM-predicted file classifications against human-annotated ground truth for all indexed papers with annotation files._")
BR()

L("---")
BR()
L("## Metric Glossary")
BR()
L("The following metrics are standard in both the AI classification literature and psychology inter-rater agreement research. All apply to the comparison between the LLM's output and a human-labelled ground truth.")
BR()
L("| Metric | What it measures | Range | Notes |")
L("|---|---|---|---|")
L("| **Accuracy** | Fraction of all files classified correctly | 0–100% | Simple but misleading when class sizes are unequal — a model that always guesses the most common class can score high |")
L("| **Precision** | Of all files the model labelled as class X, how many truly are X | 0–100% | Low precision → many false alarms for that class |")
L("| **Recall** | Of all files that truly are class X, how many did the model catch | 0–100% | Low recall → the model misses many real instances of that class |")
L("| **F1** | Harmonic mean of Precision and Recall: `2·P·R / (P+R)` | 0–100% | Collapses to near zero if either P or R is poor; useful single-number summary per class |")
L("| **Macro F1** | Unweighted average of per-class F1 scores | 0–100% | Treats every class equally regardless of how many files it has; penalises poor performance on rare classes |")
L("| **Micro F1** | F1 computed from pooled TP/FP/FN across all classes | 0–100% | Weighted by class frequency; equals overall accuracy in multi-class settings. Compare to Macro F1: a large gap signals that rare classes drive errors |")
L("| **Cohen's κ** | Agreement between LLM and human annotator beyond what chance alone would produce | −1 to 1 | The standard inter-rater reliability statistic in psychology. κ = 0 means agreement no better than random guessing; κ = 1 is perfect agreement. Landis & Koch (1977) benchmarks: < 0.20 slight, 0.20–0.40 fair, 0.40–0.60 moderate, 0.60–0.80 substantial, > 0.80 almost perfect |")
L("| **MCC** | Matthews Correlation Coefficient — single scalar summarising the full confusion matrix | −1 to 1 | More robust than F1 or accuracy when classes are imbalanced. MCC = 1 is perfect, 0 is random, −1 is perfectly inverted. Recommended by Chicco & Jurman (2020) as the most informative single metric for classification |")
L("| **FPR** | False positive rate: fraction of true-negative files incorrectly labelled as class X | 0–100% | Measures contamination — how often the model cries wolf |")
L("| **FNR** | False negative rate: fraction of true class-X files the model missed (= 1 − Recall) | 0–100% | Measures miss rate |")
BR()
L("**File-pooled vs. paper-averaged:** all metrics appear in two forms throughout this report.")
BR()
L("- _File-pooled_: computed across all files at once. A paper with 2000 files contributes 2000 votes; a paper with 10 contributes 10. Reflects overall pipeline throughput.")
L("- _Paper-averaged_: each metric is computed per paper, then averaged across papers. Every paper contributes equally regardless of size. This is the primary metric — it treats each study as one replication unit, consistent with how psychology research is aggregated.")
BR()
L("---")
BR()

# ── 0. Ground Truth Corpus ───────────────────────────────────────────────────

L("## 0. Ground Truth Corpus")
BR()
L("_Distribution of the ", tn_total, " annotated files across ", n_papers, " papers._")
BR()
L("### Repository sizes")
BR()
L("![Files per paper](corpus_repo_sizes.png)")
BR()
{
  large <- sort(as.numeric(corpus_repo_sizes)[as.numeric(corpus_repo_sizes) > 500], decreasing = TRUE)
  if (length(large) > 0)
    L("_", length(large), " paper(s) above 500 files excluded from plot: ", paste(large, collapse = ", "), "_")
}
BR()
L("### File type distribution")
BR()
L("![type_gt distribution — all papers](corpus_type_dist.png)")
BR()
L("![type_gt distribution — papers ≤500 files](corpus_type_dist_sm.png)")
BR()
L("### Data granularity and format _(data files only)_")
BR()
L("![data granularity and format distribution](corpus_data_dist.png)")
BR()
L("### Repositories containing each data subcategory")
BR()
L("![paper-level subcategory prevalence](corpus_paper_prevalence.png)")
BR()
L("### LaTeX table source")
BR()
L("_Requires `values.tex` imported. Copy-paste into Overleaf._")
BR()
{
  tbl_path <- "docs/corpus_tables.txt"
  if (file.exists(tbl_path)) {
    tbl_src <- paste(readLines(tbl_path, warn = FALSE), collapse = "\n")
    L("```latex")
    L(tbl_src)
    L("```")
  }
}
BR()
L("---")
BR()

# ── 1. Executive Summary ──────────────────────────────────────────────────────

tc   <- sum(!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt == acc$type)
tn_n <- sum(!is.na(acc$type_gt))

data_acc_rows <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]
dg_acc_rows   <- data_acc_rows[!is.na(data_acc_rows$data_granularity_gt), ]
df_acc_rows   <- data_acc_rows[!is.na(data_acc_rows$data_format_gt), ]
gc <- sum(!is.na(acc$group_gt) & !is.na(acc$group) & acc$group_gt == acc$group)
gn <- sum(!is.na(acc$group_gt))
dc <- sum(!is.na(dg_acc_rows$data_granularity) & dg_acc_rows$data_granularity_gt == dg_acc_rows$data_granularity)
dn <- nrow(dg_acc_rows)
dfc <- sum(!is.na(df_acc_rows$data_format) & df_acc_rows$data_format_gt == df_acc_rows$data_format)
dfn <- nrow(df_acc_rows)

L("## 1. Executive Summary")
BR()
L("_Based on **", tn_n, " annotated files** across **", n_papers, " papers**._")
BR()
L("| Metric | **Paper-averaged** (primary) | File-pooled (secondary) |")
L("|---|---|---|")
L(sprintf("| **Cohen's κ** | **%s** (%s) | %s (%s) |",
  fmt3(pa_kappa), kappa_interp(pa_kappa), fmt3(kappa), kappa_interp(kappa)))
L(sprintf("| **Macro F1** | **%s** | %s |", fmt1(pa_macro_f1), fmt1(macro_f1)))
L(sprintf("| **Micro F1** | — | %s |", fmt1(micro_f1)))
L(sprintf("| **MCC** | **%s** | %s |", fmt3(pa_mcc), fmt3(mcc)))
L(sprintf("| **Overall accuracy** | **%s** | %s (%d / %d files) |",
  fmt1(pa_accuracy), pct(tc, tn_n), tc, tn_n))
BR()
L("_Paper-averaged and file-pooled metrics diverge when a small number of large repositories dominate the corpus. When they differ substantially, the paper-averaged figure is the more reliable estimate of generalised classification quality._")
BR()
L("![Paper-averaged vs file-pooled summary](summary_compare.png)")
BR()
L("**Subfield performance:**")
BR()
L("| Task | **Paper-averaged** | File-pooled | N files | N papers |")
L("|---|---|---|---|---|")
L(sprintf("| Group classification | **%s** | %s | %d | %d |",
  fmt1(pa_group_acc), pct(gc, gn), gn, n_papers_group))
L(sprintf("| data_granularity classification | **%s** | %s | %d | %d |",
  fmt1(pa_dg_acc), pct(dc, dn), dn, n_papers_dg))
L(sprintf("| data_format (raw vs tabular) | **%s** | %s | %d | %d |",
  fmt1(pa_df_acc), pct(dfc, dfn), dfn, n_papers_df))
BR()
L("---")
BR()

# ── 2. Type Confusion Matrices ────────────────────────────────────────────────

L("## 2. Type Confusion Matrices")
BR()
L("_Rows = ground truth, columns = predicted. Diagonal = correct. Off-diagonal cells are errors: row tells you what the file was, column tells you what the LLM called it._")
BR()

L("### 2a. File-pooled (raw counts)")
BR()
L("_Each file contributes one count. Large repositories dominate._")
BR()
if (nrow(valid) > 0) {
  L(md_table(cbind(data.frame(`type \\ pred` = rownames(cm), check.names = FALSE), cm)))
} else {
  L("_Insufficient data._")
}
BR()
L("![File-pooled type confusion matrix](confusion.png)")
BR()

L("### 2b. Paper-averaged (mean row-normalised proportions)")
BR()
L("_Each paper's confusion matrix is row-normalised (rows sum to 1.0) then averaged across papers. Every paper contributes equally. Values are proportions, not counts._")
BR()
if (!is.null(pa_cm_norm) && nrow(pa_cm_norm) > 0) {
  pa_cm_df <- as.data.frame(round(pa_cm_norm, 3))
  L(md_table(cbind(data.frame(`type \\ pred` = rownames(pa_cm_df), check.names = FALSE), pa_cm_df)))
} else {
  L("_Insufficient data._")
}
BR()
L("![Paper-averaged type confusion matrix](confusion_pa.png)")
BR()
L("---")
BR()

# ── 3. Per-Class Metrics ──────────────────────────────────────────────────────

L("## 3. Per-Class Metrics")
BR()
L("_**Paper-avg F1** = mean F1 across papers that contain at least one file of that class (each paper weighted equally). **File-pooled F1** = F1 computed on the full pool. **SD** = standard deviation of paper-level F1 scores — high SD means performance varies considerably across papers. N papers = number of papers where this class appears._")
BR()
L("_TP/FP/FN are file-pooled counts. Precision/Recall/FPR/FNR are file-pooled._")
BR()

divergence <- pa_class_metrics$pa_f1 - pa_class_metrics$fp_f1
pa_metrics_tbl <- data.frame(
  Class          = pa_class_metrics$class,
  `Paper-avg F1` = sapply(pa_class_metrics$pa_f1, fmt1),
  SD             = sapply(pa_class_metrics$pa_f1_sd, fmt1),
  `N papers`     = pa_class_metrics$n_papers,
  `File-pool F1` = sapply(pa_class_metrics$fp_f1, fmt1),
  `Δ (pa−fp)`    = sapply(divergence, function(d) if (is.na(d)) "—" else sprintf("%+.1f pp", d)),
  TP             = class_metrics$tp,
  FP             = class_metrics$fp,
  FN             = class_metrics$fn,
  Precision      = sapply(class_metrics$precision, fmt1),
  Recall         = sapply(class_metrics$recall,    fmt1),
  FPR            = sapply(class_metrics$fpr,       fmt1),
  FNR            = sapply(class_metrics$fnr,       fmt1),
  `Top FP src`   = ifelse(is.na(class_metrics$top_fp_source), "—", class_metrics$top_fp_source),
  `Top FN dest`  = ifelse(is.na(class_metrics$top_fn_dest),   "—", class_metrics$top_fn_dest),
  check.names    = FALSE, stringsAsFactors = FALSE
)
L(md_table(pa_metrics_tbl))
BR()
L("![File-pooled per-class Precision / Recall / F1](metrics.png)")
BR()
L("![Paper-averaged per-class F1 with distribution](metrics_pa.png)")
BR()
L("---")
BR()

# ── 4. Subfield Breakdowns ────────────────────────────────────────────────────

L("## 4. Subfield Classification")
BR()
L("_Group classification applies to all files. data_granularity and data_format apply only to files with type = data._")
BR()

L("### 4a. Group confusion matrix")
BR()
if (!is.null(cm_grp) && nrow(cm_grp) > 0) {
  cm_grp_df <- as.data.frame.matrix(cm_grp)
  L(md_table(cbind(data.frame(`group \\ pred` = rownames(cm_grp_df), check.names = FALSE), cm_grp_df)))
  BR()
  L("![Group confusion matrix](group_conf.png)")
} else {
  L("_Insufficient data._")
}
BR()

L("### 4a-ii. Group accuracy by file type")
BR()
L("_For each file type, fraction of files where the predicted group matches ground truth._")
BR()
if (nrow(grp_valid) > 0) {
  type_grp_metrics <- do.call(rbind, lapply(sort(unique(grp_valid$type_gt)), function(tp) {
    rows <- grp_valid[grp_valid$type_gt == tp, ]
    n    <- nrow(rows)
    # File-level accuracy
    file_acc <- 100 * sum(rows$group_gt == rows$group, na.rm = TRUE) / n
    # Paper-level accuracy: per-paper mean
    paper_accs <- sapply(unique(rows$paper_id), function(pid) {
      pr <- rows[rows$paper_id == pid, ]
      if (nrow(pr) == 0) return(NA_real_)
      100 * sum(pr$group_gt == pr$group, na.rm = TRUE) / nrow(pr)
    })
    pa_acc  <- mean(paper_accs, na.rm = TRUE)
    n_papers_tp <- sum(!is.na(paper_accs))
    data.frame(`File type` = tp, `N files` = n, `N papers` = n_papers_tp,
               `Paper-avg group acc` = fmt1(pa_acc),
               `File-pooled group acc` = fmt1(file_acc),
               stringsAsFactors = FALSE, check.names = FALSE)
  }))
  type_grp_metrics <- type_grp_metrics[order(-type_grp_metrics[["N files"]]), ]
  L(md_table(type_grp_metrics))
} else {
  L("_Insufficient data._")
}
BR()

# Render a paper-weighted CM as percentage strings (rows sum to 100%),
# with a trailing N-papers column.
render_pw_cm <- function(pw, row_label) {
  cm <- pw$cm
  pct <- apply(cm, c(1, 2), function(x) sprintf("%.1f%%", 100 * x))
  out <- as.data.frame(pct, stringsAsFactors = FALSE)
  out[["N papers"]] <- as.integer(pw$n_per_row[rownames(cm)])
  cbind(setNames(data.frame(rownames(cm), check.names = FALSE), row_label),
        out)
}

L("### 4b. data_granularity confusion matrix (file-pooled)")
BR()
L("_Raw file counts across all papers. Large papers dominate; see 4b' for paper-weighted view._")
BR()
if (!is.null(cm_dg) && nrow(cm_dg) > 0) {
  cm_dg_df <- as.data.frame.matrix(cm_dg)
  L(md_table(cbind(data.frame(`dg \\ pred` = rownames(cm_dg_df), check.names = FALSE), cm_dg_df)))
  BR()
  L("![DG confusion matrix](dg_conf.png)")
} else {
  L("_Insufficient data._")
}
BR()

L("### 4b'. data_granularity confusion matrix (paper-weighted)")
BR()
L("_Each paper's row-stochastic confusion is averaged across papers (one paper = one vote). Rows sum to 100%. Cells show the typical per-paper proportion of GT-row files predicted as each column class; the `N papers` column is the number of papers contributing that row._")
BR()
if (!is.null(cm_dg_pw) && sum(cm_dg_pw$n_per_row) > 0) {
  L(md_table(render_pw_cm(cm_dg_pw, "dg \\ pred")))
} else {
  L("_Insufficient data._")
}
BR()

L("### 4c. data_format confusion matrix (raw vs tabular, file-pooled)")
BR()
if (!is.null(cm_df) && nrow(cm_df) > 0) {
  cm_df_df <- as.data.frame.matrix(cm_df)
  L(md_table(cbind(data.frame(`format \\ pred` = rownames(cm_df_df), check.names = FALSE), cm_df_df)))
  BR()
  L("![data_format confusion matrix](df_conf.png)")
} else {
  L("_Insufficient data._")
}
BR()

L("### 4c'. data_format confusion matrix (paper-weighted)")
BR()
if (!is.null(cm_df_pw) && sum(cm_df_pw$n_per_row) > 0) {
  L(md_table(render_pw_cm(cm_df_pw, "format \\ pred")))
} else {
  L("_Insufficient data._")
}
BR()
L("---")
BR()

# ── 4d. Accuracy by type_source ──────────────────────────────────────────────

L("### 4d. Accuracy by classification method (type_source)")
BR()
L("_Paper-averaged = mean of per-paper accuracies (each paper equal weight). File-pooled = raw counts across all files._")
BR()

src_data_4d <- list()  # store for heatmap

if ("type_source" %in% names(acc)) {
  src_levels <- sort(unique(acc$type_source[!is.na(acc$type_source) &
                 !acc$type_source %in% c("extension_rule", "sentinel_llm")]))

  src_tbl <- do.call(rbind, lapply(src_levels, function(src) {
    rows <- acc[!is.na(acc$type_source) & acc$type_source == src, ]

    # File-pooled
    n_type   <- sum(!is.na(rows$type_gt) & !is.na(rows$type))
    fp_type  <- if (n_type > 0) 100 * sum(rows$type_gt == rows$type, na.rm = TRUE) / n_type else NA_real_
    grp_rows <- rows[!is.na(rows$group_gt) & !is.na(rows$group), ]
    fp_grp   <- if (nrow(grp_rows) > 0) 100 * sum(grp_rows$group_gt == grp_rows$group) / nrow(grp_rows) else NA_real_
    dg_rows  <- rows[!is.na(rows$data_granularity_gt) & !is.na(rows$data_granularity), ]
    fp_dg    <- if (nrow(dg_rows) > 0) 100 * sum(dg_rows$data_granularity_gt == dg_rows$data_granularity) / nrow(dg_rows) else NA_real_

    # Paper-averaged
    pids <- unique(rows$paper_id)
    pa_type <- mean(sapply(pids, function(p) {
      r <- rows[rows$paper_id == p & !is.na(rows$type_gt) & !is.na(rows$type), ]
      if (nrow(r) == 0) return(NA_real_)
      100 * sum(r$type_gt == r$type) / nrow(r)
    }), na.rm = TRUE)
    pa_grp <- mean(sapply(pids, function(p) {
      r <- rows[rows$paper_id == p & !is.na(rows$group_gt) & !is.na(rows$group), ]
      if (nrow(r) == 0) return(NA_real_)
      100 * sum(r$group_gt == r$group) / nrow(r)
    }), na.rm = TRUE)
    pa_dg <- mean(sapply(pids, function(p) {
      r <- rows[rows$paper_id == p & !is.na(rows$data_granularity_gt) & !is.na(rows$data_granularity), ]
      if (nrow(r) == 0) return(NA_real_)
      100 * sum(r$data_granularity_gt == r$data_granularity) / nrow(r)
    }), na.rm = TRUE)

    src_data_4d[[src]] <<- c(pa_type = pa_type, pa_grp = pa_grp, pa_dg = pa_dg,
                               fp_type = fp_type, fp_grp = fp_grp, fp_dg = fp_dg)

    data.frame(
      `Method`               = src,
      `N files`              = n_type,
      `N papers`             = length(pids),
      `Type — paper avg`     = fmt1(pa_type),
      `Type — file pool`     = fmt1(fp_type),
      `Group — paper avg`    = fmt1(pa_grp),
      `Group — file pool`    = fmt1(fp_grp),
      `Granularity — paper avg` = fmt1(pa_dg),
      `Granularity — file pool` = fmt1(fp_dg),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  }))
  L(md_table(src_tbl))
  BR()
  L("![Accuracy by type_source heatmap](src_heatmap.png)")
} else {
  L("_type_source column not available._")
}
BR()

if ("granularity_source" %in% names(acc)) {
  L("### 4e. Granularity accuracy by granularity_source")
  BR()
  L("_Applies only to data files with a granularity ground truth annotation._")
  BR()
  dg_all <- acc[!is.na(acc$data_granularity_gt) & !is.na(acc$data_granularity) &
                !is.na(acc$granularity_source), ]
  if (nrow(dg_all) > 0) {
    gsrc_levels <- sort(unique(dg_all$granularity_source))
    gsrc_tbl <- do.call(rbind, lapply(gsrc_levels, function(gs) {
      rows    <- dg_all[dg_all$granularity_source == gs, ]
      n       <- nrow(rows)
      fp_acc  <- 100 * sum(rows$data_granularity_gt == rows$data_granularity) / n
      pids_g  <- unique(rows$paper_id)
      pa_acc  <- mean(sapply(pids_g, function(p) {
        r <- rows[rows$paper_id == p, ]
        if (nrow(r) == 0) return(NA_real_)
        100 * sum(r$data_granularity_gt == r$data_granularity) / nrow(r)
      }), na.rm = TRUE)
      data.frame(
        `granularity_source`  = gs,
        `N files`             = n,
        `N papers`            = length(pids_g),
        `Paper-avg acc`       = fmt1(pa_acc),
        `File-pooled acc`     = fmt1(fp_acc),
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(gsrc_tbl))
    BR()
    L("![Granularity accuracy by source heatmap](gran_src_heatmap.png)")
  } else {
    L("_Insufficient data._")
  }
  BR()
}

L("### 4f. Type accuracy — file type × classification method")
BR()
L("_Paper-averaged accuracy for each combination of ground-truth file type and classification method. Reveals which file types suffer most under each method._")
BR()

if ("type_source" %in% names(acc)) {
  ft_src_srcs  <- sort(unique(acc$type_source[!is.na(acc$type_source) &
                   !acc$type_source %in% c("extension_rule", "sentinel_llm")]))
  ft_src_types <- sort(unique(acc$type_gt[!is.na(acc$type_gt)]))

  # Build paper-avg matrix (file types × methods)
  pa_mat <- matrix(NA_real_, nrow = length(ft_src_types), ncol = length(ft_src_srcs),
                   dimnames = list(ft_src_types, ft_src_srcs))
  fp_mat <- pa_mat
  n_mat  <- matrix(0L, nrow = length(ft_src_types), ncol = length(ft_src_srcs),
                   dimnames = list(ft_src_types, ft_src_srcs))

  for (tp in ft_src_types) {
    for (src in ft_src_srcs) {
      rows <- acc[!is.na(acc$type_gt) & acc$type_gt == tp &
                  !is.na(acc$type_source) & acc$type_source == src &
                  !is.na(acc$type), ]
      if (nrow(rows) == 0) next
      n_mat[tp, src]  <- nrow(rows)
      fp_mat[tp, src] <- 100 * sum(rows$type_gt == rows$type) / nrow(rows)
      pa_mat[tp, src] <- mean(sapply(unique(rows$paper_id), function(p) {
        r <- rows[rows$paper_id == p, ]
        if (nrow(r) == 0) return(NA_real_)
        100 * sum(r$type_gt == r$type) / nrow(r)
      }), na.rm = TRUE)
    }
  }

  # Markdown table: paper-avg with N in parentheses
  tbl_df <- as.data.frame(matrix("—", nrow = length(ft_src_types),
                                  ncol = length(ft_src_srcs),
                                  dimnames = list(ft_src_types, ft_src_srcs)))
  for (tp in ft_src_types)
    for (src in ft_src_srcs)
      if (!is.na(pa_mat[tp, src]))
        tbl_df[tp, src] <- sprintf("%s (n=%d)", fmt1(pa_mat[tp, src]), n_mat[tp, src])

  L(md_table(cbind(data.frame(`File type` = rownames(tbl_df), check.names = FALSE), tbl_df)))
  BR()
  L("![File type × method accuracy heatmap — paper avg](type_method_heatmap.png)")
} else {
  L("_type_source column not available._")
}
BR()

L("### 4g. Type accuracy — file type × classification method (file-pooled)")
BR()
L("_Same breakdown as 4f but file-pooled: each file contributes one vote. Large repositories dominate._")
BR()

if ("type_source" %in% names(acc) && exists("fp_mat")) {
  tbl_fp <- as.data.frame(matrix("—", nrow = length(ft_src_types),
                                  ncol = length(ft_src_srcs),
                                  dimnames = list(ft_src_types, ft_src_srcs)))
  for (tp in ft_src_types)
    for (src in ft_src_srcs)
      if (!is.na(fp_mat[tp, src]))
        tbl_fp[tp, src] <- sprintf("%s (n=%d)", fmt1(fp_mat[tp, src]), n_mat[tp, src])

  L(md_table(cbind(data.frame(`File type` = rownames(tbl_fp), check.names = FALSE), tbl_fp)))
  BR()
  L("![File type × method accuracy heatmap — file pool](type_method_heatmap_fp.png)")
} else {
  L("_type_source column not available._")
}
BR()

L("---")
BR()

# ── 5. Error Analysis ─────────────────────────────────────────────────────────

L("## 5. Error Analysis")
BR()

L("### 5a. Top confusion pairs")
BR()
L("_Every misclassification ranked by frequency (file-pooled). `GT → Predicted` reads: files truly GT were labelled Predicted._")
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
  L("![Top misclassification patterns](fp_fn.png)")
}
BR()

L("### 5b. Error rate by file extension")
BR()
L("_Extensions with fewer than 5 annotated files excluded. Sorted by total error count._")
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
  L("![Error rate by file extension](ext_errors.png)")
}
BR()
L("---")
BR()

# ── 6. Downstream Pipeline Impact ────────────────────────────────────────────

L("## 6. Downstream Pipeline Impact — `data` Classification")
BR()
L("- **False positives** (non-data predicted as `data`): column extraction runs on the wrong file.")
L("- **False negatives** (`data` predicted as something else): dataset silently skipped — the more costly error.")
BR()

L("### 6a. False positives — non-data files predicted as `data`")
BR()
L(sprintf("_**%d files** predicted as `data` but are not._", nrow(data_fp)))
BR()
if (nrow(data_fp) > 0) {
  fp_by_class <- sort(table(data_fp$type_gt), decreasing = TRUE)
  L(md_table(data.frame(
    `True class` = names(fp_by_class), Count = as.integer(fp_by_class),
    `% of FPs`   = sapply(as.integer(fp_by_class), function(n) pct(n, nrow(data_fp))),
    check.names  = FALSE, stringsAsFactors = FALSE
  )))
} else { L("_None._") }
BR()

L("### 6b. False negatives — `data` files missed")
BR()
L(sprintf("_**%d data files** not predicted as `data`, skipped by column extraction._", nrow(data_fn)))
BR()
if (nrow(data_fn) > 0) {
  fn_by_class <- sort(table(data_fn$type), decreasing = TRUE)
  L(md_table(data.frame(
    `Predicted as` = names(fn_by_class), Count = as.integer(fn_by_class),
    `% of FNs`     = sapply(as.integer(fn_by_class), function(n) pct(n, nrow(data_fn))),
    check.names    = FALSE, stringsAsFactors = FALSE
  )))
} else { L("_None._") }
BR()
L("---")
BR()

# ── 7. Paper-Level Reliability ────────────────────────────────────────────────

L("## 7. Paper-Level Reliability")
BR()
L("_Each paper weighted equally. SD = standard deviation across papers._")
BR()

kap_vals <- per_paper_full$kappa[!is.na(per_paper_full$kappa)]
f1_vals  <- per_paper_full$macro_f1[!is.na(per_paper_full$macro_f1)]
mcc_vals <- per_paper_full$mcc[!is.na(per_paper_full$mcc)]

L("| Metric | Mean | Median | SD | Min | Max |")
L("|---|---|---|---|---|---|")
L(sprintf("| **Cohen's κ** | %s | %s | %s | %s | %s |",
  fmt3(mean(kap_vals)), fmt3(median(kap_vals)), fmt3(sd(kap_vals)),
  fmt3(min(kap_vals)),  fmt3(max(kap_vals))))
L(sprintf("| **Macro F1** | %s | %s | %s | %s | %s |",
  fmt1(mean(f1_vals)),  fmt1(median(f1_vals)),  fmt1(sd(f1_vals)),
  fmt1(min(f1_vals)),   fmt1(max(f1_vals))))
L(sprintf("| **MCC** | %s | %s | %s | %s | %s |",
  fmt3(mean(mcc_vals)), fmt3(median(mcc_vals)), fmt3(sd(mcc_vals)),
  fmt3(min(mcc_vals)),  fmt3(max(mcc_vals))))
L(sprintf("| **Type accuracy** | %s | %s | %s | %s | %s |",
  fmt1(mean(type_vals)),  fmt1(median(type_vals)),  fmt1(sd(type_vals)),
  fmt1(min(type_vals)),   fmt1(max(type_vals))))
BR()
L("![Per-paper kappa distribution](kappa_dist.png)")
BR()
L("![Per-paper type accuracy distribution](paper_dist.png)")
BR()
L("![Paper size vs accuracy scatter](paper_scatter.png)")
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

bad_papers <- per_paper_full[!is.na(per_paper_full$type_acc) & per_paper_full$type_acc < 50, ]
bad_papers <- bad_papers[order(bad_papers$type_acc), ]
L("### 7a. Low-accuracy papers (<50% type accuracy)")
BR()
L(sprintf("_%d papers below 50%%._", nrow(bad_papers)))
BR()
if (nrow(bad_papers) == 0) {
  L("_None._")
} else {
  L(md_table(data.frame(
    Paper       = bad_papers$paper_id,
    `Files GT`  = bad_papers$n_files,
    `Type acc`  = sapply(bad_papers$type_acc, fmt1),
    `κ`         = sapply(bad_papers$kappa,    fmt3),
    `Top error` = bad_papers$top_err,
    `Top ext`   = bad_papers$top_ext,
    check.names = FALSE, stringsAsFactors = FALSE
  )))
}
BR()

L("### 7b. Top 20 papers by error count")
BR()
top_err_papers <- per_paper_full[order(-(per_paper_full$n_files * (1 - per_paper_full$type_acc / 100))), ]
top_err_papers <- head(top_err_papers, 20)
L(md_table(data.frame(
  Paper       = top_err_papers$paper_id,
  `N files`   = top_err_papers$n_files,
  `κ`         = sapply(top_err_papers$kappa,    fmt3),
  `Type acc`  = sapply(top_err_papers$type_acc, fmt1),
  `Group acc` = sapply(top_err_papers$group_acc, fmt1),
  `Top error` = top_err_papers$top_err,
  check.names = FALSE, stringsAsFactors = FALSE
)))
BR()
L("_Full per-paper breakdown in appendix.md._")
BR()
L("---")
BR()

# ── 8. Misclassified Files (top offenders only — full list in appendix) ───────

L("## 8. Misclassified Files — Top Offenders")
BR()
wrong_type <- acc[!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt != acc$type, ]
wrong_group <- acc[
  !is.na(acc$group_gt) & !is.na(acc$group) & acc$group_gt != acc$group &
  !is.na(acc$type_gt)  & acc$type_gt == acc$type, ]

L("### 8a. Type wrong — top 30 by error pair frequency")
BR()
if (nrow(wrong_type) == 0) {
  L("_No type misclassifications._")
} else {
  wrong_type$pair  <- paste0(wrong_type$type_gt, "→", wrong_type$type)
  sec8_pair_counts <- sort(table(wrong_type$pair), decreasing = TRUE)
  top_pair_names   <- names(head(sec8_pair_counts, 10))
  top_wrong        <- wrong_type[wrong_type$pair %in% top_pair_names, ]
  top_wrong       <- head(top_wrong[order(top_wrong$pair, top_wrong$paper_id), ], 30)
  wrong_tbl <- data.frame(
    Paper         = top_wrong$paper_id,
    File          = top_wrong$rel_path,
    `GT type`     = top_wrong$type_gt,
    `Pred type`   = top_wrong$type,
    `type_source` = if ("type_source" %in% names(top_wrong)) top_wrong$type_source else NA_character_,
    check.names   = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(wrong_tbl))
}
BR()

L("### 8b. Group wrong (type correct) — top 30")
BR()
if (nrow(wrong_group) == 0) {
  L("_No group misclassifications._")
} else {
  top_wg <- head(wrong_group[order(wrong_group$paper_id, wrong_group$group_gt), ], 30)
  wg_tbl <- data.frame(
    Paper        = top_wg$paper_id,
    File         = top_wg$rel_path,
    `GT type`    = top_wg$type_gt,
    `GT group`   = top_wg$group_gt,
    `Pred group` = top_wg$group,
    check.names  = FALSE, stringsAsFactors = FALSE
  )
  L(md_table(wg_tbl))
}
BR()
L("_Full misclassified file lists in appendix.md._")
BR()

# ── Write MD ──────────────────────────────────────────────────────────────────

run_dir  <- file.path(REPORT_DIR, paste0("normal_report_", date_str))
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(run_dir, "report.md")
writeLines(lines, out_path)

# ── Write appendix.md ─────────────────────────────────────────────────────────

app <- character(0)
A  <- function(...) { app <<- c(app, paste0(...)) }
AB <- function()    { app <<- c(app, "") }

A("# Appendix — ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
AB()
A("_Full tables omitted from main report to reduce file size._")
AB()
A("---")
AB()

A("## A1. Full Per-Paper Breakdown")
AB()
A(md_table(data.frame(
  Paper       = per_paper_full$paper_id,
  `N files`   = per_paper_full$n_files,
  `κ`         = sapply(per_paper_full$kappa,    fmt3),
  `Macro F1`  = sapply(per_paper_full$macro_f1, fmt1),
  `MCC`       = sapply(per_paper_full$mcc,      fmt3),
  `Type acc`  = sapply(per_paper_full$type_acc, fmt1),
  `Group acc` = sapply(per_paper_full$group_acc, fmt1),
  `DG acc`    = sapply(per_paper_full$dg_acc,    fmt1),
  `Top error` = per_paper_full$top_err,
  `Top ext`   = per_paper_full$top_ext,
  check.names = FALSE, stringsAsFactors = FALSE
)))
AB()
A("---")
AB()

A("## A2. All Type Misclassifications")
AB()
if (nrow(wrong_type) == 0) {
  A("_None._")
} else {
  wrong_tbl_full <- data.frame(
    Paper         = wrong_type$paper_id,
    File          = wrong_type$rel_path,
    `GT type`     = wrong_type$type_gt,
    `Pred type`   = wrong_type$type,
    `GT group`    = if ("group_gt"    %in% names(wrong_type)) wrong_type$group_gt    else NA_character_,
    `Pred group`  = if ("group"       %in% names(wrong_type)) wrong_type$group       else NA_character_,
    `type_source` = if ("type_source" %in% names(wrong_type)) wrong_type$type_source else NA_character_,
    check.names   = FALSE, stringsAsFactors = FALSE
  )
  A(md_table(wrong_tbl_full[order(wrong_tbl_full$Paper, wrong_tbl_full$`GT type`), ]))
}
AB()
A("---")
AB()

A("## A3. All Group Misclassifications (type correct)")
AB()
if (nrow(wrong_group) == 0) {
  A("_None._")
} else {
  wg_tbl_full <- data.frame(
    Paper        = wrong_group$paper_id,
    File         = wrong_group$rel_path,
    `GT type`    = wrong_group$type_gt,
    `GT group`   = wrong_group$group_gt,
    `Pred group` = wrong_group$group,
    check.names  = FALSE, stringsAsFactors = FALSE
  )
  A(md_table(wg_tbl_full[order(wg_tbl_full$Paper, wg_tbl_full$`GT group`), ]))
}
AB()

app_path <- file.path(run_dir, "appendix.md")
writeLines(app, app_path)
cat(sprintf("  [appendix] written to: %s\n", app_path))
cat(sprintf("  [report] written to: %s\n", out_path))

# ── LaTeX values export (for Overleaf \input{}) ───────────────────────────────

kappa_label_tex <- function(k) {
  if (is.na(k)) return("n/a")
  if (k < 0)    return("poor ($< 0$)")
  if (k < 0.20) return("slight ($< 0.20$)")
  if (k < 0.40) return("fair (0.20--0.40)")
  if (k < 0.60) return("moderate (0.40--0.60)")
  if (k < 0.80) return("substantial (0.60--0.80)")
  return("almost perfect (0.80--1.00)")
}

tex_cmd  <- function(name, value, label = NULL) {
  cmd <- sprintf("\\newcommand{\\dc%s}{%s}", name, value)
  if (!is.null(label)) cmd <- sprintf("%-60s %% %s", cmd, label)
  cmd
}
pct_tex  <- function(x, digits = 1) if (is.na(x)) "n/a" else sprintf(paste0("%.", digits, "f\\%%"), x)
num_tex  <- function(x, digits = 3) if (is.na(x)) "n/a" else sprintf(paste0("%.", digits, "f"), x)
int_tex  <- function(x) if (is.na(x)) "n/a" else as.character(as.integer(round(x)))
cls_name <- function(x) {
  s <- gsub("[^A-Za-z0-9]", "", tools::toTitleCase(x))
  for (p in list(c("0","Zero"),c("1","One"),c("2","Two"),c("3","Three"),c("4","Four"),
                 c("5","Five"),c("6","Six"),c("7","Seven"),c("8","Eight"),c("9","Nine")))
    s <- gsub(p[1], p[2], s, fixed = TRUE)
  s
}

T <- function(...) tex_lines <<- c(tex_lines, ...)   # append lines
S <- function(hdr) T("", paste0("% ── ", hdr, " ", strrep("─", max(0, 68 - nchar(hdr)))), "")

tex_lines <- c(
  "% Auto-generated by report_normal.R — do not edit by hand",
  sprintf("%% Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
)

# ── 1. Corpus description ─────────────────────────────────────────────────────
S("Corpus")

n_papers_total <- length(unique(valid$paper_id))
n_files_total  <- nrow(valid)

# Files per paper
files_per_paper <- table(valid$paper_id)
fpp <- as.integer(files_per_paper)
T(tex_cmd("NPapers",           int_tex(n_papers_total),     "Number of papers in corpus"),
  tex_cmd("NFiles",            int_tex(n_files_total),      "Total annotated files"),
  tex_cmd("FilesPerPaperMean", num_tex(mean(fpp), 1),       "Mean files per paper"),
  tex_cmd("FilesPerPaperMed",  num_tex(median(fpp), 1),     "Median files per paper"),
  tex_cmd("FilesPerPaperSD",   num_tex(sd(fpp), 1),         "SD files per paper"),
  tex_cmd("FilesPerPaperMin",  int_tex(min(fpp)),            "Min files in a paper"),
  tex_cmd("FilesPerPaperMax",  int_tex(max(fpp)),            "Max files in a paper"),
  tex_cmd("FilesPerPaperQone",   num_tex(quantile(fpp, 0.25), 1), "Q1 files per paper"),
  tex_cmd("FilesPerPaperQthree", num_tex(quantile(fpp, 0.75), 1), "Q3 files per paper"))

# Ground-truth file type counts & fractions
gt_type_tbl <- sort(table(valid$type_gt), decreasing = TRUE)
for (nm in names(gt_type_tbl)) {
  cn <- cls_name(nm)
  n  <- as.integer(gt_type_tbl[nm])
  T(tex_cmd(paste0("NFiles",   cn), int_tex(n),                          sprintf("N files of type '%s'", nm)),
    tex_cmd(paste0("PctFiles", cn), pct_tex(100 * n / n_files_total),    sprintf("%% of all files that are '%s'", nm)))
}

# N papers per file type (how many papers have >= 1 file of that type)
for (nm in names(gt_type_tbl)) {
  cn <- cls_name(nm)
  np <- length(unique(valid$paper_id[valid$type_gt == nm]))
  T(tex_cmd(paste0("NPapers", cn), int_tex(np), sprintf("Papers containing >= 1 '%s' file", nm)))
}

# Number of classes observed
T(tex_cmd("NClasses", int_tex(length(gt_type_tbl)), "Number of distinct file-type classes"))

# Source corpus size ──────────────────────────────────────────────────────────
src_n <- if (!is.na(SOURCE_CORPUS_DIR) && dir.exists(SOURCE_CORPUS_DIR)) {
  length(list.files(SOURCE_CORPUS_DIR, pattern = "\\.xml$"))
} else NA_integer_
T(tex_cmd("SourceCorpusN", int_tex(src_n), "Total papers in source MetaCheck XML corpus"))

# GT year distribution ────────────────────────────────────────────────────────
# IDs encode year as digits 8-9 of the 16-digit string: 09567976YY...
gt_ids_all   <- unique(valid$paper_id)
gt_year_raw  <- as.integer(substr(gt_ids_all, 9, 10))
# two-digit prefix maps: 13->2013 ... 24->2024; values >=13 assumed 20xx
gt_year      <- ifelse(gt_year_raw >= 13, 2000L + gt_year_raw, 2000L + gt_year_raw)
gt_year_tbl  <- sort(table(gt_year))

gt_year_min  <- min(gt_year)
gt_year_max  <- max(gt_year)
early_mask   <- gt_year >= 2014 & gt_year <= 2017
n_early      <- sum(early_mask)
pct_early    <- 100 * n_early / length(gt_year)

T(tex_cmd("GTYearMin",    int_tex(gt_year_min),  "Earliest publication year in GT corpus"),
  tex_cmd("GTYearMax",    int_tex(gt_year_max),  "Latest publication year in GT corpus"),
  tex_cmd("GTNEarly",     int_tex(n_early),      "GT papers from 2014-2017 (early open-data period)"),
  tex_cmd("GTPctEarly",   pct_tex(pct_early),    "% GT papers from 2014-2017"))

yr_words <- c("2013"="Thirteen","2014"="Fourteen","2015"="Fifteen","2016"="Sixteen",
              "2017"="Seventeen","2018"="Eighteen","2019"="Nineteen","2020"="Twenty",
              "2021"="TwentyOne","2022"="TwentyTwo","2023"="TwentyThree","2024"="TwentyFour")
for (yr in as.integer(names(gt_year_tbl))) {
  n_yr  <- as.integer(gt_year_tbl[as.character(yr)])
  wrd   <- yr_words[as.character(yr)]
  if (is.na(wrd)) next
  T(tex_cmd(paste0("GTNYear",   wrd), int_tex(n_yr),
            sprintf("GT papers from %d", yr)),
    tex_cmd(paste0("GTPctYear", wrd), pct_tex(100 * n_yr / length(gt_year)),
            sprintf("%% GT papers from %d", yr)))
}

# Corpus stats excluding large repos (> 500 files) ────────────────────────────
small_fpp     <- fpp[fpp <= 500]
sm_papers     <- names(files_per_paper)[files_per_paper <= 500]
sm_valid      <- valid[valid$paper_id %in% sm_papers, ]
sm_type_tbl   <- sort(table(sm_valid$type_gt), decreasing = TRUE)
n_sm_papers   <- length(sm_papers)
n_sm_files    <- nrow(sm_valid)
T(tex_cmd("NPapersSm",           int_tex(n_sm_papers),         "Papers with <= 500 files (outlier-removed)"),
  tex_cmd("NFilesSm",            int_tex(n_sm_files),          "Total files in outlier-removed corpus"),
  tex_cmd("FilesPerPaperMeanSm", num_tex(mean(small_fpp), 1),  "Mean files per paper (outlier-removed)"),
  tex_cmd("FilesPerPaperMedSm",  num_tex(median(small_fpp), 1),"Median files per paper (outlier-removed)"),
  tex_cmd("FilesPerPaperSDSm",   num_tex(sd(small_fpp), 1),    "SD files per paper (outlier-removed)"))
for (nm in names(sm_type_tbl)) {
  cn <- cls_name(nm)
  n  <- as.integer(sm_type_tbl[nm])
  np <- length(unique(sm_valid$paper_id[sm_valid$type_gt == nm]))
  T(tex_cmd(paste0("NFilesSm",   cn), int_tex(n),               sprintf("N files type '%s' (outlier-removed)", nm)),
    tex_cmd(paste0("PctFilesSm", cn), pct_tex(100 * n / n_sm_files), sprintf("%% files type '%s' (outlier-removed)", nm)),
    tex_cmd(paste0("NPapersSm",  cn), int_tex(np),              sprintf("Papers with >= 1 '%s' file (outlier-removed)", nm)))
}

# % papers containing >= 1 individual / combined data file ────────────────────
dg_ann      <- acc[!is.na(acc$type_gt) & acc$type_gt == "data" & !is.na(acc$data_granularity_gt), ]
n_dg_papers <- length(unique(dg_ann$paper_id))
for (lvl in c("individual", "combined")) {
  cn  <- cls_name(lvl)
  np  <- length(unique(dg_ann$paper_id[dg_ann$data_granularity_gt == lvl]))
  T(tex_cmd(paste0("NPapersHasDG", cn), int_tex(np),
            sprintf("Papers with >= 1 %s data file", lvl)),
    tex_cmd(paste0("PctPapersHasDG", cn), pct_tex(100 * np / n_dg_papers),
            sprintf("%% of DG-annotated papers with >= 1 %s data file", lvl)))
}

# % papers containing >= 1 raw / tabular data file ────────────────────────────
df_ann      <- acc[!is.na(acc$type_gt) & acc$type_gt == "data" & !is.na(acc$data_format_gt), ]
n_df_papers <- length(unique(df_ann$paper_id))
for (lvl in c("raw", "tabular")) {
  cn  <- cls_name(lvl)
  np  <- length(unique(df_ann$paper_id[df_ann$data_format_gt == lvl]))
  T(tex_cmd(paste0("NPapersHasDF", cn), int_tex(np),
            sprintf("Papers with >= 1 %s data file", lvl)),
    tex_cmd(paste0("PctPapersHasDF", cn), pct_tex(100 * np / n_df_papers),
            sprintf("%% of DF-annotated papers with >= 1 %s data file", lvl)))
}

# Data-subtype counts
n_dg_files <- sum(!is.na(acc$data_granularity_gt))
n_df_files <- sum(!is.na(acc$data_format_gt))
T(tex_cmd("NDGFiles",     int_tex(n_dg_files),       "Files with data_granularity annotation"),
  tex_cmd("NDFFiles",     int_tex(n_df_files),       "Files with data_format annotation"),
  tex_cmd("NDGPapers",    int_tex(n_papers_dg),      "Papers with data_granularity annotation"),
  tex_cmd("NDFPapers",    int_tex(n_papers_df),      "Papers with data_format annotation"),
  tex_cmd("NGroupFiles",  int_tex(gn),               "Files with group annotation"),
  tex_cmd("NGroupPapers", int_tex(n_papers_group),   "Papers with group annotation"))

# DG class breakdown
if (!is.null(cm_dg)) {
  dg_ann <- acc[!is.na(acc$data_granularity_gt), ]
  for (lvl in rownames(cm_dg)) {
    cn  <- cls_name(lvl)
    n   <- sum(cm_dg[lvl, ])
    np  <- length(unique(dg_ann$paper_id[dg_ann$data_granularity_gt == lvl]))
    npt <- length(unique(dg_ann$paper_id))
    T(tex_cmd(paste0("NDG",       cn), int_tex(n),                    sprintf("N data files with granularity = '%s'", lvl)),
      tex_cmd(paste0("PctDG",     cn), pct_tex(100 * n / sum(cm_dg)), sprintf("%% of granularity-annotated data files that are '%s'", lvl)),
      tex_cmd(paste0("NPapersDG", cn), int_tex(np),                   sprintf("Papers containing >= 1 data file with granularity = '%s'", lvl)),
      tex_cmd(paste0("PctPapersDG", cn), pct_tex(100 * np / npt),     sprintf("%% of DG-annotated papers with >= 1 '%s' data file", lvl)))
  }
}
# DF class breakdown
if (!is.null(cm_df)) {
  df_ann <- acc[!is.na(acc$data_format_gt), ]
  for (lvl in rownames(cm_df)) {
    cn  <- cls_name(lvl)
    n   <- sum(cm_df[lvl, ])
    np  <- length(unique(df_ann$paper_id[df_ann$data_format_gt == lvl]))
    npt <- length(unique(df_ann$paper_id))
    T(tex_cmd(paste0("NDF",       cn), int_tex(n),                    sprintf("N data files with format = '%s'", lvl)),
      tex_cmd(paste0("PctDF",     cn), pct_tex(100 * n / sum(cm_df)), sprintf("%% of format-annotated data files that are '%s'", lvl)),
      tex_cmd(paste0("NPapersDF", cn), int_tex(np),                   sprintf("Papers containing >= 1 data file with format = '%s'", lvl)),
      tex_cmd(paste0("PctPapersDF", cn), pct_tex(100 * np / npt),     sprintf("%% of DF-annotated papers with >= 1 '%s' data file", lvl)))
  }
}

# ── 2. Primary metrics: paper-averaged ────────────────────────────────────────
S("Paper-averaged (primary)")
T(tex_cmd("PaKappa",      num_tex(pa_kappa),           "Paper-avg Cohen's kappa"),
  tex_cmd("PaKappaLabel", kappa_label_tex(pa_kappa),   "Landis & Koch label for paper-avg kappa"),
  tex_cmd("PaMacroF",     pct_tex(pa_macro_f1),        "Paper-avg macro F1"),
  tex_cmd("PaMCC",        num_tex(pa_mcc),             "Paper-avg MCC"),
  tex_cmd("PaAccuracy",   pct_tex(pa_accuracy),        "Paper-avg type accuracy"),
  tex_cmd("PaGroupAcc",   pct_tex(pa_group_acc),       "Paper-avg group accuracy"),
  tex_cmd("PaDGAcc",      pct_tex(pa_dg_acc),          "Paper-avg data_granularity accuracy"),
  tex_cmd("PaDFAcc",      pct_tex(pa_df_acc),          "Paper-avg data_format accuracy"),
  tex_cmd("NPapersGroup", int_tex(n_papers_group),     "Papers with group ground truth"),
  tex_cmd("NPapersDG",    int_tex(n_papers_dg),        "Papers with data_granularity ground truth"),
  tex_cmd("NPapersDF",    int_tex(n_papers_df),        "Papers with data_format ground truth"))

# ── 3. File-pooled metrics ────────────────────────────────────────────────────
S("File-pooled (secondary)")
fp_overall_acc   <- sum(valid$type_gt == valid$type) / nrow(valid) * 100
fp_correct       <- sum(valid$type_gt == valid$type)
fp_group_correct <- sum(!is.na(grp_valid$group_gt) & grp_valid$group_gt == grp_valid$group)
fp_dg_correct    <- if (!is.null(cm_dg)) sum(diag(cm_dg)) else NA_integer_
fp_df_correct    <- if (!is.null(cm_df)) sum(diag(cm_df)) else NA_integer_
T(tex_cmd("FpKappa",        num_tex(kappa),             "File-pooled Cohen's kappa"),
  tex_cmd("FpKappaLabel",   kappa_label_tex(kappa),     "Landis & Koch label for file-pooled kappa"),
  tex_cmd("FpMacroF",       pct_tex(macro_f1),          "File-pooled macro F1"),
  tex_cmd("FpMicroF",       pct_tex(micro_f1),          "File-pooled micro F1 (= overall accuracy)"),
  tex_cmd("FpMCC",          num_tex(mcc),               "File-pooled MCC"),
  tex_cmd("FpAccuracy",     pct_tex(fp_overall_acc),    "File-pooled type accuracy"),
  tex_cmd("FpNCorrect",     int_tex(fp_correct),        "N files classified correctly (type)"),
  tex_cmd("FpNWrong",       int_tex(n_files_total - fp_correct), "N files misclassified (type)"),
  tex_cmd("FpGroupAcc",     pct_tex(100 * fp_group_correct / max(1L, gn)), "File-pooled group accuracy"),
  tex_cmd("FpGroupCorrect", int_tex(fp_group_correct),  "N files with correct group prediction"),
  tex_cmd("FpDGAcc",        pct_tex(if (!is.null(cm_dg)) 100 * fp_dg_correct / sum(cm_dg) else NA_real_), "File-pooled data_granularity accuracy"),
  tex_cmd("FpDGCorrect",    int_tex(fp_dg_correct),     "N data files with correct granularity prediction"),
  tex_cmd("FpDFAcc",        pct_tex(if (!is.null(cm_df)) 100 * fp_df_correct / sum(cm_df) else NA_real_), "File-pooled data_format accuracy"),
  tex_cmd("FpDFCorrect",    int_tex(fp_df_correct),     "N data files with correct format prediction"))

# ── 4. Per-paper distribution stats ───────────────────────────────────────────
S("Per-paper distribution stats")
kap_vals  <- per_paper_full$kappa[!is.na(per_paper_full$kappa)]
f1_vals   <- per_paper_full$macro_f1[!is.na(per_paper_full$macro_f1)]
mcc_vals2 <- per_paper_full$mcc[!is.na(per_paper_full$mcc)]
acc_vals  <- per_paper_full$type_acc[!is.na(per_paper_full$type_acc)]
grp_acc_v <- per_paper_full$group_acc[!is.na(per_paper_full$group_acc)]
dg_acc_v  <- per_paper_full$dg_acc[!is.na(per_paper_full$dg_acc)]
df_acc_v  <- per_paper_full$df_acc[!is.na(per_paper_full$df_acc)]

for (pair in list(
  list("Kappa",    kap_vals,  "num_tex", "Cohen's kappa"),
  list("MacroF",   f1_vals,   "pct_tex", "Macro F1"),
  list("MCC",      mcc_vals2, "num_tex", "MCC"),
  list("Acc",      acc_vals,  "pct_tex", "Type accuracy"),
  list("GroupAcc", grp_acc_v, "pct_tex", "Group accuracy"),
  list("DGAcc",    dg_acc_v,  "pct_tex", "Data granularity accuracy"),
  list("DFAcc",    df_acc_v,  "pct_tex", "Data format accuracy")
)) {
  pfx <- pair[[1]]; vals <- pair[[2]]; fn <- pair[[3]]; lbl <- pair[[4]]
  fmt <- if (fn == "pct_tex") pct_tex else num_tex
  T(tex_cmd(paste0(pfx, "Mean"),   fmt(mean(vals,           na.rm = TRUE)), paste("Per-paper", lbl, "mean")),
    tex_cmd(paste0(pfx, "Median"), fmt(median(vals,         na.rm = TRUE)), paste("Per-paper", lbl, "median")),
    tex_cmd(paste0(pfx, "SD"),     fmt(sd(vals,             na.rm = TRUE)), paste("Per-paper", lbl, "SD")),
    tex_cmd(paste0(pfx, "Min"),    fmt(min(vals,            na.rm = TRUE)), paste("Per-paper", lbl, "min")),
    tex_cmd(paste0(pfx, "Max"),    fmt(max(vals,            na.rm = TRUE)), paste("Per-paper", lbl, "max")),
    tex_cmd(paste0(pfx, "Qone"),   fmt(quantile(vals, 0.25, na.rm = TRUE)), paste("Per-paper", lbl, "Q1 (25th pct)")),
    tex_cmd(paste0(pfx, "Qthree"), fmt(quantile(vals, 0.75, na.rm = TRUE)), paste("Per-paper", lbl, "Q3 (75th pct)")))
}

# ── 5. Accuracy buckets ───────────────────────────────────────────────────────
S("Accuracy buckets across papers")
breaks    <- c(0, 50, 70, 85, 95, 100)
blabels   <- c("LtFifty", "FiftyToSeventy", "SeventyToEightyFive", "EightyFiveToNinetyFive", "NinetyFiveToHundred")
bdescs    <- c("< 50%", "50-70%", "70-85%", "85-95%", "95-100%")
bucket    <- cut(acc_vals, breaks = breaks, include.lowest = TRUE, right = TRUE, labels = bdescs)
bcounts   <- table(factor(bucket, levels = bdescs))
for (i in seq_along(blabels))
  T(tex_cmd(paste0("BucketN",   blabels[i]), int_tex(as.integer(bcounts[[i]])),
            sprintf("Papers with type accuracy %s", bdescs[i])),
    tex_cmd(paste0("BucketPct", blabels[i]), pct_tex(100 * as.integer(bcounts[[i]]) / length(acc_vals)),
            sprintf("%% of papers with type accuracy %s", bdescs[i])))
T(tex_cmd("NBadPapers",  int_tex(sum(acc_vals < 50,  na.rm = TRUE)), "Papers with type accuracy < 50%"),
  tex_cmd("NGoodPapers", int_tex(sum(acc_vals >= 95, na.rm = TRUE)), "Papers with type accuracy >= 95%"))

# ── 6. Per-class metrics ──────────────────────────────────────────────────────
S("Per-class F1 — paper-averaged")
for (i in seq_len(nrow(pa_class_metrics))) {
  cl <- pa_class_metrics$class[i]; cn <- cls_name(cl)
  T(tex_cmd(paste0("PaFscore",   cn), pct_tex(pa_class_metrics$pa_f1[i]),    sprintf("Paper-avg F1 for class '%s'", cl)),
    tex_cmd(paste0("PaFscoreSD", cn), pct_tex(pa_class_metrics$pa_f1_sd[i]), sprintf("SD of paper-level F1 for class '%s'", cl)))
}

S("Per-class metrics — file-pooled")
for (i in seq_len(nrow(class_metrics))) {
  cl <- class_metrics$class[i]; cn <- cls_name(cl); cm_i <- class_metrics[i, ]
  T(tex_cmd(paste0("FpFscore",     cn), pct_tex(cm_i$f1),        sprintf("File-pooled F1 for '%s'", cl)),
    tex_cmd(paste0("FpPrecision", cn), pct_tex(cm_i$precision), sprintf("File-pooled precision for '%s'", cl)),
    tex_cmd(paste0("FpRecall",    cn), pct_tex(cm_i$recall),    sprintf("File-pooled recall for '%s'", cl)),
    tex_cmd(paste0("FpFPR",       cn), pct_tex(cm_i$fpr),       sprintf("File-pooled FPR for '%s' (false alarm rate)", cl)),
    tex_cmd(paste0("FpFNR",       cn), pct_tex(cm_i$fnr),       sprintf("File-pooled FNR for '%s' (miss rate)", cl)),
    tex_cmd(paste0("TP",          cn), int_tex(cm_i$tp),        sprintf("True positives for '%s'", cl)),
    tex_cmd(paste0("FP",          cn), int_tex(cm_i$fp),        sprintf("False positives for '%s' (predicted as '%s' but not)", cl, cl)),
    tex_cmd(paste0("FN",          cn), int_tex(cm_i$fn),        sprintf("False negatives for '%s' (missed '%s' files)", cl, cl)))
}

# ── 7. DG and DF confusion cells ─────────────────────────────────────────────
S("DG confusion cells")
if (!is.null(cm_dg) && all(c("combined","individual") %in% rownames(cm_dg))) {
  T(tex_cmd("DGCombinedPredCombined",   int_tex(cm_dg["combined",   "combined"]),   "GT=combined, pred=combined (correct)"),
    tex_cmd("DGCombinedPredIndividual", int_tex(cm_dg["combined",   "individual"]), "GT=combined, pred=individual (FN for combined)"),
    tex_cmd("DGIndividualPredCombined", int_tex(cm_dg["individual", "combined"]),   "GT=individual, pred=combined (FN for individual)"),
    tex_cmd("DGIndividualPredIndiv",    int_tex(cm_dg["individual", "individual"]), "GT=individual, pred=individual (correct)"),
    tex_cmd("DGPrecisionCombined",      pct_tex(100 * cm_dg["combined",   "combined"] /
                                          max(1L, sum(cm_dg[, "combined"]))),    "Precision for combined granularity"),
    tex_cmd("DGRecallCombined",         pct_tex(100 * cm_dg["combined",   "combined"] /
                                          max(1L, sum(cm_dg["combined", ]))),    "Recall for combined granularity"),
    tex_cmd("DGPrecisionIndividual",    pct_tex(100 * cm_dg["individual", "individual"] /
                                          max(1L, sum(cm_dg[, "individual"]))), "Precision for individual granularity"),
    tex_cmd("DGRecallIndividual",       pct_tex(100 * cm_dg["individual", "individual"] /
                                          max(1L, sum(cm_dg["individual", ]))), "Recall for individual granularity"))
}

S("DF confusion cells")
if (!is.null(cm_df) && all(c("raw","tabular") %in% rownames(cm_df))) {
  T(tex_cmd("DFRawPredRaw",       int_tex(cm_df["raw",     "raw"]),     "GT=raw, pred=raw (correct)"),
    tex_cmd("DFRawPredTabular",   int_tex(cm_df["raw",     "tabular"]), "GT=raw, pred=tabular (FN for raw)"),
    tex_cmd("DFTabularPredRaw",   int_tex(cm_df["tabular", "raw"]),     "GT=tabular, pred=raw (FN for tabular)"),
    tex_cmd("DFTabularPredTab",   int_tex(cm_df["tabular", "tabular"]), "GT=tabular, pred=tabular (correct)"),
    tex_cmd("DFPrecisionRaw",     pct_tex(100 * cm_df["raw",     "raw"] /
                                    max(1L, sum(cm_df[, "raw"]))),      "Precision for raw format"),
    tex_cmd("DFRecallRaw",        pct_tex(100 * cm_df["raw",     "raw"] /
                                    max(1L, sum(cm_df["raw", ]))),      "Recall for raw format"),
    tex_cmd("DFPrecisionTabular", pct_tex(100 * cm_df["tabular", "tabular"] /
                                    max(1L, sum(cm_df[, "tabular"]))),  "Precision for tabular format"),
    tex_cmd("DFRecallTabular",    pct_tex(100 * cm_df["tabular", "tabular"] /
                                    max(1L, sum(cm_df["tabular", ]))),  "Recall for tabular format"))
}

# ── 8. Downstream data FP/FN ─────────────────────────────────────────────────
S("Downstream data FP/FN")
data_fp_out <- valid[valid$type_gt != "data" & valid$type == "data", ]
data_fn_out <- valid[valid$type_gt == "data" & valid$type != "data", ]
T(tex_cmd("DataFPTotal", int_tex(nrow(data_fp_out)),  "Non-data files predicted as data (false positives)"),
  tex_cmd("DataFNTotal", int_tex(nrow(data_fn_out)),  "Data files missed / not predicted as data (false negatives)"),
  tex_cmd("DataFPRate",  pct_tex(100 * nrow(data_fp_out) /
                           max(1L, sum(valid$type == "data"))),    "FP rate: FPs as % of all predicted-data files"),
  tex_cmd("DataFNRate",  pct_tex(100 * nrow(data_fn_out) /
                           max(1L, sum(valid$type_gt == "data"))), "FN rate: missed data files as % of all true data files"))

# Per-source FP breakdown
if (nrow(data_fp_out) > 0) {
  fp_src_tbl <- sort(table(data_fp_out$type_gt), decreasing = TRUE)
  for (nm in names(fp_src_tbl)) {
    cn <- cls_name(nm)
    T(tex_cmd(paste0("DataFPFrom",    cn), int_tex(as.integer(fp_src_tbl[nm])),
              sprintf("N '%s' files wrongly predicted as data (FPs)", nm)),
      tex_cmd(paste0("DataFPPctFrom", cn), pct_tex(100 * as.integer(fp_src_tbl[nm]) / nrow(data_fp_out)),
              sprintf("%% of data FPs that are actually '%s'", nm)))
  }
}
# Per-dest FN breakdown
if (nrow(data_fn_out) > 0) {
  fn_dest_tbl <- sort(table(data_fn_out$type), decreasing = TRUE)
  for (nm in names(fn_dest_tbl)) {
    cn <- cls_name(nm)
    T(tex_cmd(paste0("DataFNTo",    cn), int_tex(as.integer(fn_dest_tbl[nm])),
              sprintf("N data files misclassified as '%s' (FNs)", nm)),
      tex_cmd(paste0("DataFNPctTo", cn), pct_tex(100 * as.integer(fn_dest_tbl[nm]) / nrow(data_fn_out)),
              sprintf("%% of data FNs predicted as '%s'", nm)))
  }
}

# ── 9. Top confusion pairs ────────────────────────────────────────────────────
S("Top confusion pairs")
wrong_all   <- valid[valid$type_gt != valid$type, ]
total_wrong <- nrow(wrong_all)
T(tex_cmd("NTotalErrors", int_tex(total_wrong),                          "Total misclassified files (type)"),
  tex_cmd("ErrorRate",    pct_tex(100 * total_wrong / n_files_total),    "Overall error rate (type)"))

pair_tbl    <- sort(table(paste0(wrong_all$type_gt, "To", wrong_all$type)), decreasing = TRUE)
human_pairs <- gsub("([a-z])([A-Z])", "\\1 → \\2",
                    gsub("To([A-Z])", " → \\1", names(pair_tbl)))
for (i in seq_len(min(20L, length(pair_tbl)))) {
  nm      <- names(pair_tbl)[i]
  cnt     <- as.integer(pair_tbl[nm])
  safe_nm <- gsub("[^A-Za-z0-9]", "", nm)
  # Reconstruct readable label: "softwareTodata" → "software → data"
  readable <- sub("^(.*?)To([A-Z].*)$", "\\1 → \\2", nm)
  readable <- paste0(tolower(substring(readable, 1, 1)), substring(readable, 2))
  T(tex_cmd(paste0("Pair",    safe_nm), int_tex(cnt),
            sprintf("Confusion pair %s: count", readable)),
    tex_cmd(paste0("PairPct", safe_nm), pct_tex(100 * cnt / max(1L, total_wrong)),
            sprintf("Confusion pair %s: %% of all errors", readable)))
}

# ── 10. Type-source accuracy ──────────────────────────────────────────────────
S("Accuracy by classification method (type_source)")
if (exists("src_data_4d") && length(src_data_4d) > 0) {
  for (src in names(src_data_4d)) {
    sn  <- gsub("[^A-Za-z0-9]", "", tools::toTitleCase(src))
    d   <- src_data_4d[[src]]
    rows_src <- acc[!is.na(acc$type_source) & acc$type_source == src, ]
    T(tex_cmd(paste0("Src", sn, "NFiles"),  int_tex(sum(!is.na(rows_src$type_gt) & !is.na(rows_src$type))),
              sprintf("N files classified by method '%s'", src)),
      tex_cmd(paste0("Src", sn, "NPapers"), int_tex(length(unique(rows_src$paper_id))),
              sprintf("N papers using method '%s'", src)),
      tex_cmd(paste0("Src", sn, "PaType"),  pct_tex(d["pa_type"]),
              sprintf("Paper-avg type accuracy for method '%s'", src)),
      tex_cmd(paste0("Src", sn, "FpType"),  pct_tex(d["fp_type"]),
              sprintf("File-pooled type accuracy for method '%s'", src)),
      tex_cmd(paste0("Src", sn, "PaGroup"), pct_tex(d["pa_grp"]),
              sprintf("Paper-avg group accuracy for method '%s'", src)),
      tex_cmd(paste0("Src", sn, "FpGroup"), pct_tex(d["fp_grp"]),
              sprintf("File-pooled group accuracy for method '%s'", src)),
      tex_cmd(paste0("Src", sn, "PaDG"),    pct_tex(d["pa_dg"]),
              sprintf("Paper-avg data_granularity accuracy for method '%s'", src)),
      tex_cmd(paste0("Src", sn, "FpDG"),    pct_tex(d["fp_dg"]),
              sprintf("File-pooled data_granularity accuracy for method '%s'", src)))
  }
}

# ── 11. Granularity-source accuracy ──────────────────────────────────────────
S("Granularity accuracy by granularity_source")
if ("granularity_source" %in% names(acc)) {
  dg_all_gs <- acc[!is.na(acc$data_granularity_gt) & !is.na(acc$data_granularity) &
                   !is.na(acc$granularity_source), ]
  for (gs in sort(unique(dg_all_gs$granularity_source))) {
    sn   <- gsub("[^A-Za-z0-9]", "", tools::toTitleCase(gs))
    rows <- dg_all_gs[dg_all_gs$granularity_source == gs, ]
    fp_a <- 100 * sum(rows$data_granularity_gt == rows$data_granularity) / nrow(rows)
    pa_a <- mean(sapply(unique(rows$paper_id), function(p) {
      r <- rows[rows$paper_id == p, ]
      100 * sum(r$data_granularity_gt == r$data_granularity) / nrow(r)
    }), na.rm = TRUE)
    T(tex_cmd(paste0("GranSrc", sn, "NFiles"),  int_tex(nrow(rows)),
              sprintf("N data files with granularity_source = '%s'", gs)),
      tex_cmd(paste0("GranSrc", sn, "NPapers"), int_tex(length(unique(rows$paper_id))),
              sprintf("N papers with granularity_source = '%s'", gs)),
      tex_cmd(paste0("GranSrc", sn, "PaAcc"),   pct_tex(pa_a),
              sprintf("Paper-avg granularity accuracy for source '%s'", gs)),
      tex_cmd(paste0("GranSrc", sn, "FpAcc"),   pct_tex(fp_a),
              sprintf("File-pooled granularity accuracy for source '%s'", gs)))
  }
}

# ── 12. Extension error rates (top 20 by error count) ────────────────────────
S("Extension error rates (top 20)")
if (!is.null(ext_stats) && nrow(ext_stats) > 0) {
  top_ext20 <- head(ext_stats[order(-ext_stats$n_errors), ], 20)
  for (i in seq_len(nrow(top_ext20))) {
    raw_ext <- top_ext20$ext[i]
    en      <- cls_name(raw_ext)
    T(tex_cmd(paste0("Ext", en, "NFiles"),    int_tex(top_ext20$n_files[i]),
              sprintf("N annotated .%s files", raw_ext)),
      tex_cmd(paste0("Ext", en, "NErrors"),   int_tex(top_ext20$n_errors[i]),
              sprintf("N misclassified .%s files", raw_ext)),
      tex_cmd(paste0("Ext", en, "ErrorRate"), pct_tex(top_ext20$error_rate[i]),
              sprintf("Error rate for .%s files", raw_ext)))
  }
}

tex_path <- file.path(run_dir, "values.tex")
writeLines(tex_lines, tex_path)
cat(sprintf("  [latex]  written to: %s\n", tex_path))

# ── Visualisations ────────────────────────────────────────────────────────────

# ── Plot 1: File-pooled per-class P/R/F1 bar ─────────────────────────────────

png_metrics <- file.path(run_dir, "metrics.png")
png(png_metrics, width = 900, height = 500, res = 100)
cls_names <- class_metrics$class
mat <- rbind(class_metrics$precision / 100, class_metrics$recall / 100,
             class_metrics$f1 / 100)
mat[is.na(mat)] <- 0
old_par <- par(mar = c(6, 4.5, 3, 1))
barplot(mat, beside = TRUE, names.arg = cls_names, ylim = c(0, 1),
        col = c("#4C72B0", "#55A868", "#C44E52"), border = NA,
        ylab = "Score", main = "Per-Class Precision / Recall / F1 (file-pooled)", las = 2,
        cex.names = 0.85)
abline(h = seq(0, 1, 0.2), col = "grey85")
barplot(mat, beside = TRUE, col = c("#4C72B0", "#55A868", "#C44E52"),
        border = NA, add = TRUE, axes = FALSE, names.arg = rep("", length(cls_names)))
legend("topright", legend = c("Precision", "Recall", "F1"),
       fill = c("#4C72B0", "#55A868", "#C44E52"), border = NA, bty = "n")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_metrics))

# ── Plot 2: Paper-averaged per-class F1 box plots ────────────────────────────

png_metrics_pa <- file.path(run_dir, "metrics_pa.png")
png(png_metrics_pa, width = 900, height = 520, res = 100)
old_par <- par(mar = c(6, 4.5, 3.5, 1))
cls_order <- all_types
f1_by_class <- lapply(cls_order, function(cls) {
  per_paper_class_f1$f1[per_paper_class_f1$class == cls]
})
boxplot(f1_by_class, names = cls_order, ylim = c(0, 100),
        col = "#4C72B0", border = "#2a4a7f", pch = 19, cex = 0.6,
        ylab = "F1 (%)", main = "Per-Class F1 — Distribution Across Papers (paper-averaged)",
        las = 2, cex.names = 0.85, outline = TRUE)
# overlay file-pooled F1 as red points
fp_f1_ordered <- sapply(cls_order, function(cls)
  class_metrics$f1[class_metrics$class == cls])
points(seq_along(cls_order), fp_f1_ordered, pch = 18, col = "#C44E52", cex = 1.4)
# overlay paper-averaged mean as orange points
pa_f1_ordered <- sapply(cls_order, function(cls)
  pa_class_metrics$pa_f1[pa_class_metrics$class == cls])
points(seq_along(cls_order), pa_f1_ordered, pch = 23, bg = "#FF9500", col = "#CC7700", cex = 1.2)
abline(h = seq(0, 100, 20), col = "grey88", lty = 1)
legend("bottomright",
       legend = c("Paper distribution (box)", "Paper-avg mean", "File-pooled F1"),
       pch    = c(22, 23, 18),
       pt.bg  = c("#4C72B0", "#FF9500", NA),
       col    = c("#2a4a7f", "#CC7700", "#C44E52"),
       pt.cex = c(1.5, 1.2, 1.4), bty = "n", cex = 0.85)
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_metrics_pa))

# ── Plot 3: File-pooled confusion matrix ─────────────────────────────────────

png_conf <- file.path(run_dir, "confusion.png")
png(png_conf, width = 700, height = 620, res = 100)
heatmap_plot(as.matrix(cm), "Type Confusion Matrix — File-pooled (row-normalised)",
             subtitle = "Each file weighted equally; large repos dominate")
invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_conf))

# ── Plot 4: Paper-averaged confusion matrix ───────────────────────────────────

png_conf_pa <- file.path(run_dir, "confusion_pa.png")
png(png_conf_pa, width = 700, height = 620, res = 100)
heatmap_plot(pa_cm_norm, "Type Confusion Matrix — Paper-averaged (mean row proportions)",
             subtitle = "Each paper weighted equally regardless of file count")
invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_conf_pa))

# ── Plot 5: Paper-averaged vs file-pooled summary comparison ─────────────────

png_compare <- file.path(run_dir, "summary_compare.png")
png(png_compare, width = 750, height = 480, res = 100)
old_par <- par(mar = c(5, 5, 3.5, 1))
metrics_lab <- c("Accuracy", "Macro F1", "κ × 100", "MCC × 100")
pa_vals  <- c(pa_accuracy, pa_macro_f1, pa_kappa * 100, pa_mcc * 100)
fp_vals  <- c(fp_stats$accuracy, macro_f1, kappa * 100, mcc * 100)
x <- barplot(rbind(pa_vals, fp_vals), beside = TRUE,
             names.arg = metrics_lab, ylim = c(0, 115),
             col = c("#4C72B0", "#C44E52"), border = NA,
             ylab = "Score (%, or ×100 for κ/MCC)",
             main = "Paper-averaged vs File-pooled — Summary Metrics",
             las = 1, cex.names = 0.9)
abline(h = seq(0, 100, 20), col = "grey88")
text(x[1, ], pa_vals + 2.5, sprintf("%.1f", pa_vals), cex = 0.8, col = "#4C72B0")
text(x[2, ], fp_vals + 2.5, sprintf("%.1f", fp_vals), cex = 0.8, col = "#C44E52")
legend("topright", legend = c("Paper-averaged (primary)", "File-pooled (secondary)"),
       fill = c("#4C72B0", "#C44E52"), border = NA, bty = "n", cex = 0.9)
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_compare))

# ── Plot 6: Per-paper kappa distribution ─────────────────────────────────────

png_kappa <- file.path(run_dir, "kappa_dist.png")
png(png_kappa, width = 800, height = 480, res = 100)
old_par <- par(mar = c(5, 4, 3, 1))
# Compute break bounds dynamically so out-of-range kappa values (e.g. < -0.1
# when agreement is worse than chance) don't cause hist() to error.
kap_lo <- min(-0.1, floor(min(kap_vals, na.rm = TRUE) / 0.05) * 0.05)
kap_hi <- max(1.05, ceiling(max(kap_vals, na.rm = TRUE) / 0.05) * 0.05)
h_k <- hist(kap_vals, breaks = seq(kap_lo, kap_hi, by = 0.05), plot = FALSE)
plot(NULL, xlim = c(kap_lo, kap_hi), ylim = c(0, max(h_k$counts) + 1),
     xlab = "Cohen's κ (per paper)", ylab = "Number of papers",
     main = sprintf("Per-Paper Cohen's κ  (mean=%.3f  median=%.3f)",
                    mean(kap_vals), median(kap_vals)), las = 1)
# shade interpretation bands
rect(kap_lo, 0, 0.20, max(h_k$counts)+1, col = "#FFE5E5", border = NA)
rect( 0.20, 0, 0.40, max(h_k$counts)+1, col = "#FFF3CD", border = NA)
rect( 0.40, 0, 0.60, max(h_k$counts)+1, col = "#FFF9C4", border = NA)
rect( 0.60, 0, 0.80, max(h_k$counts)+1, col = "#E8F5E9", border = NA)
rect( 0.80, 0, 1.05, max(h_k$counts)+1, col = "#E3F2FD", border = NA)
rect(h_k$breaks[-length(h_k$breaks)], 0, h_k$breaks[-1], h_k$counts,
     col = "#4C72B0", border = "white")
abline(v = mean(kap_vals),   col = "#C44E52", lwd = 2, lty = 2)
abline(v = median(kap_vals), col = "#55A868", lwd = 2, lty = 2)
mtext(c("slight", "fair", "moderate", "substantial", "almost\nperfect"),
      side = 3, at = c(0.05, 0.30, 0.50, 0.70, 0.925),
      cex = 0.65, col = "grey50", line = -0.5)
legend("topleft",
       legend = c(sprintf("Mean   %.3f", mean(kap_vals)),
                  sprintf("Median %.3f", median(kap_vals))),
       col = c("#C44E52", "#55A868"), lwd = 2, lty = 2, bty = "n")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_kappa))

# ── Plot 7: Per-paper type accuracy distribution ──────────────────────────────

png_dist <- file.path(run_dir, "paper_dist.png")
png(png_dist, width = 800, height = 480, res = 100)
old_par <- par(mar = c(5, 4, 3, 1))
h_dist <- hist(type_vals, breaks = seq(0, 100, by = 5), plot = FALSE)
plot(NULL, xlim = c(0, 100), ylim = c(0, max(h_dist$counts) + 1),
     xlab = "Type accuracy (%)", ylab = "Number of papers",
     main = sprintf("Per-Paper Type Accuracy  (mean=%.1f%%  median=%.1f%%)",
                    mean(type_vals), median(type_vals)), las = 1)
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

# ── Plot 8: Paper size vs accuracy scatter ────────────────────────────────────

png_scatter <- file.path(run_dir, "paper_scatter.png")
png(png_scatter, width = 800, height = 500, res = 100)
old_par <- par(mar = c(5, 4.5, 3.5, 1))
plot(per_paper_full$n_files, per_paper_full$type_acc,
     pch = 19, col = "#4C72B080", cex = 1.1,
     xlab = "Number of annotated files (paper size)",
     ylab = "Type accuracy (%)",
     main = "Paper Size vs Classification Accuracy",
     las = 1)
# highlight the largest papers
thresh <- quantile(per_paper_full$n_files, 0.90)
big <- per_paper_full[per_paper_full$n_files >= thresh, ]
points(big$n_files, big$type_acc, pch = 19, col = "#C44E52", cex = 1.3)
text(big$n_files, big$type_acc, labels = big$n_files,
     pos = 3, cex = 0.7, col = "#C44E52")
abline(lm(type_acc ~ n_files, data = per_paper_full),
       col = "#55A868", lwd = 2, lty = 2)
legend("bottomright",
       legend = c("Paper", "Top 10% largest (labelled)", "Linear trend"),
       pch    = c(19, 19, NA), lty = c(NA, NA, 2),
       col    = c("#4C72B0", "#C44E52", "#55A868"),
       pt.cex = c(1.1, 1.3, NA), lwd = c(NA, NA, 2), bty = "n", cex = 0.85)
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_scatter))

# ── Plot 9: Top FP/FN confusion pairs ────────────────────────────────────────

if (length(top_pairs) > 0) {
  png_fp_fn <- file.path(run_dir, "fp_fn.png")
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

# ── Plot 10: Extension error rate ─────────────────────────────────────────────

if (!is.null(ext_stats) && nrow(ext_stats) > 0) {
  png_ext <- file.path(run_dir, "ext_errors.png")
  n_show  <- min(20, nrow(ext_stats))
  top_ext <- ext_stats[seq_len(n_show), ]
  top_ext <- top_ext[order(top_ext$error_rate), ]
  png(png_ext, width = 900, height = 400 + n_show * 18, res = 100)
  old_par <- par(mar = c(4, 7, 3, 5))
  bp <- barplot(top_ext$error_rate, names.arg = top_ext$ext,
                horiz = TRUE, las = 1, col = "#DD8452", border = NA,
                xlab = "Error rate (%)", xlim = c(0, 100),
                main = "Error Rate by File Extension (top 20 by error count)",
                cex.names = 0.82)
  text(x = top_ext$error_rate + 1.5, y = bp,
       labels = sprintf("%d/%d", top_ext$n_errors, top_ext$n_files),
       adj = 0, cex = 0.72, col = "grey30")
  par(old_par); invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_ext))
}

# ── Plot 11: Group confusion matrix ───────────────────────────────────────────

if (!is.null(cm_grp) && nrow(cm_grp) > 1) {
  png_grp <- file.path(run_dir, "group_conf.png")
  sz      <- max(500, 100 * nrow(cm_grp) + 200)
  png(png_grp, width = sz, height = sz, res = 100)
  heatmap_plot(cm_grp, "Group Confusion Matrix (row-normalised, data files only)")
  invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_grp))
}

# ── Plot 12: DG confusion matrix ──────────────────────────────────────────────

if (!is.null(cm_dg) && nrow(cm_dg) > 1) {
  png_dg <- file.path(run_dir, "dg_conf.png")
  sz     <- max(500, 100 * nrow(cm_dg) + 200)
  png(png_dg, width = sz, height = sz, res = 100)
  heatmap_plot(cm_dg, "data_granularity Confusion Matrix (row-normalised, data files only)")
  invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_dg))
}

# ── Plot 13: data_format confusion matrix ─────────────────────────────────────

if (!is.null(cm_df) && nrow(cm_df) > 1) {
  png_df <- file.path(run_dir, "df_conf.png")
  sz     <- max(500, 100 * nrow(cm_df) + 200)
  png(png_df, width = sz, height = sz, res = 100)
  heatmap_plot(cm_df, "data_format Confusion Matrix (row-normalised, data files only)")
  invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_df))
}

# ── Plot 14: type_source accuracy heatmap ─────────────────────────────────────

if (length(src_data_4d) >= 2) {
  metrics_4d <- c("Type (paper avg)", "Type (file pool)",
                  "Group (paper avg)", "Group (file pool)",
                  "Granularity (paper avg)", "Granularity (file pool)")
  mat_4d <- do.call(rbind, lapply(src_data_4d, function(v)
    c(v["pa_type"], v["fp_type"], v["pa_grp"], v["fp_grp"], v["pa_dg"], v["fp_dg"])
  ))
  rownames(mat_4d) <- names(src_data_4d)
  colnames(mat_4d) <- metrics_4d
  mat_4d[is.na(mat_4d)] <- 0

  png_src <- file.path(run_dir, "src_heatmap.png")
  png(png_src, width = 800, height = 120 + nrow(mat_4d) * 80, res = 100)
  col_ramp <- colorRampPalette(c("#f7fbff", "#2171b5"))(100)
  old_par  <- par(mar = c(10, 12, 3, 2))
  image(t(mat_4d / 100)[, nrow(mat_4d):1], col = col_ramp, axes = FALSE,
        zlim = c(0, 1), main = "Accuracy by type_source — paper avg & file pool")
  axis(1, at = seq(0, 1, length.out = ncol(mat_4d)), labels = metrics_4d, las = 2, cex.axis = 0.85)
  axis(2, at = seq(1, 0, length.out = nrow(mat_4d)), labels = rownames(mat_4d), las = 1, cex.axis = 0.9)
  for (i in seq_len(nrow(mat_4d)))
    for (j in seq_len(ncol(mat_4d))) {
      xi <- (j - 1) / (ncol(mat_4d) - 1)
      yi <- 1 - (i - 1) / max(nrow(mat_4d) - 1, 1)
      text(xi, yi, sprintf("%.1f%%", mat_4d[i, j]), cex = 0.85,
           col = if (mat_4d[i, j] > 60) "white" else "black")
    }
  par(old_par); invisible(dev.off())
  cat(sprintf("  [plot]   written to: %s\n", png_src))
}

# ── Plot 15: granularity_source accuracy heatmap ──────────────────────────────

if ("granularity_source" %in% names(acc)) {
  dg_plot <- acc[!is.na(acc$data_granularity_gt) & !is.na(acc$data_granularity) &
                 !is.na(acc$granularity_source), ]
  if (nrow(dg_plot) > 0) {
    gsrcs <- sort(unique(dg_plot$granularity_source))
    gran_mat <- do.call(rbind, lapply(gsrcs, function(gs) {
      rows   <- dg_plot[dg_plot$granularity_source == gs, ]
      fp_acc <- 100 * sum(rows$data_granularity_gt == rows$data_granularity) / nrow(rows)
      pa_acc <- mean(sapply(unique(rows$paper_id), function(p) {
        r <- rows[rows$paper_id == p, ]
        if (nrow(r) == 0) return(NA_real_)
        100 * sum(r$data_granularity_gt == r$data_granularity) / nrow(r)
      }), na.rm = TRUE)
      c(pa = pa_acc, fp = fp_acc)
    }))
    rownames(gran_mat) <- gsrcs
    colnames(gran_mat) <- c("Paper avg", "File pool")

    png_gsrc <- file.path(run_dir, "gran_src_heatmap.png")
    png(png_gsrc, width = 500, height = 120 + nrow(gran_mat) * 80, res = 100)
    col_ramp <- colorRampPalette(c("#f7fbff", "#2171b5"))(100)
    old_par  <- par(mar = c(6, 16, 3, 2))
    image(t(gran_mat / 100)[, nrow(gran_mat):1], col = col_ramp, axes = FALSE,
          zlim = c(0, 1), main = "Granularity accuracy by source")
    axis(1, at = c(0, 1), labels = colnames(gran_mat), las = 1, cex.axis = 0.9)
    axis(2, at = seq(1, 0, length.out = nrow(gran_mat)), labels = rownames(gran_mat), las = 1, cex.axis = 0.85)
    for (i in seq_len(nrow(gran_mat)))
      for (j in seq_len(ncol(gran_mat))) {
        xi <- (j - 1) / max(ncol(gran_mat) - 1, 1)
        yi <- 1 - (i - 1) / max(nrow(gran_mat) - 1, 1)
        text(xi, yi, sprintf("%.1f%%", gran_mat[i, j]), cex = 0.9,
             col = if (gran_mat[i, j] > 60) "white" else "black")
      }
    par(old_par); invisible(dev.off())
    cat(sprintf("  [plot]   written to: %s\n", png_gsrc))
  }
}

# ── Plot 16: file type × method accuracy heatmap (paper-avg) ─────────────────

plot_type_method_heatmap <- function(mat, n_mat, title, filename) {
  keep_rows <- apply(mat, 1, function(r) any(!is.na(r)))
  pm <- mat[keep_rows, , drop = FALSE]
  nm <- n_mat[keep_rows, , drop = FALSE]
  pm[is.na(pm)] <- 0
  n_rows <- nrow(pm); n_cols <- ncol(pm)
  png(filename, width = 200 + n_cols * 200, height = 150 + n_rows * 60, res = 100)
  col_ramp <- colorRampPalette(c("#f7fbff", "#2171b5"))(100)
  old_par  <- par(mar = c(6, 12, 3, 2))
  image(t(pm / 100)[, n_rows:1], col = col_ramp, axes = FALSE,
        zlim = c(0, 1), main = title)
  axis(1, at = seq(0, 1, length.out = n_cols), labels = colnames(pm), las = 2, cex.axis = 0.85)
  axis(2, at = seq(1, 0, length.out = n_rows), labels = rownames(pm), las = 1, cex.axis = 0.85)
  for (i in seq_len(n_rows))
    for (j in seq_len(n_cols)) {
      xi  <- if (n_cols > 1) (j - 1) / (n_cols - 1) else 0.5
      yi  <- 1 - (i - 1) / max(n_rows - 1, 1)
      val <- pm[i, j]; n_v <- nm[i, j]
      lbl <- if (n_v > 0) sprintf("%.0f%%\nn=%d", val, n_v) else "—"
      text(xi, yi, lbl, cex = 0.75, col = if (val > 60) "white" else "black")
    }
  par(old_par); invisible(dev.off())
}

# ── Plot 16: file type × method — paper-avg ───────────────────────────────────

if (exists("pa_mat") && any(!is.na(pa_mat)) && ncol(pa_mat) >= 1) {
  png_tm <- file.path(run_dir, "type_method_heatmap.png")
  plot_type_method_heatmap(pa_mat, n_mat,
    "Type accuracy by file type × method (paper-avg)", png_tm)
  cat(sprintf("  [plot]   written to: %s\n", png_tm))
}

# ── Plot 17: file type × method — file-pooled ────────────────────────────────

if (exists("fp_mat") && any(!is.na(fp_mat)) && ncol(fp_mat) >= 1) {
  png_tm_fp <- file.path(run_dir, "type_method_heatmap_fp.png")
  plot_type_method_heatmap(fp_mat, n_mat,
    "Type accuracy by file type × method (file-pooled)", png_tm_fp)
  cat(sprintf("  [plot]   written to: %s\n", png_tm_fp))
}

# ── Plot 18: corpus repo sizes (histogram, large repos annotated) ─────────────

png_corpus_repo <- file.path(run_dir, "corpus_repo_sizes.png")
png(png_corpus_repo, width = 700, height = 460, res = 100)
old_par <- par(mar = c(5, 5, 4, 2))
sizes     <- as.numeric(corpus_repo_sizes)
threshold <- 500
shown     <- sizes[sizes <= threshold]
hist(shown, breaks = 20, col = "#4292c6", border = "white",
     xlab = "Annotated files per paper", ylab = "Number of papers",
     main = sprintf("Repository size distribution (n=%d)", length(shown)))
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_corpus_repo))

# ── Plot 19: type_gt distribution ────────────────────────────────────────────

png_corpus_type <- file.path(run_dir, "corpus_type_dist.png")
png(png_corpus_type, width = 700, height = 420, res = 100)
old_par <- par(mar = c(6, 4.5, 3, 1))
barplot(as.numeric(corpus_type_counts),
        names.arg = names(corpus_type_counts),
        las = 2, col = "#4292c6", border = NA,
        ylab = "Files", main = "File type distribution (all papers)")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_corpus_type))

# ── Plot 19b: type_gt distribution (papers ≤500 files) ───────────────────────

png_corpus_type_sm <- file.path(run_dir, "corpus_type_dist_sm.png")
png(png_corpus_type_sm, width = 700, height = 420, res = 100)
old_par <- par(mar = c(6, 4.5, 3, 1))
barplot(as.numeric(corpus_type_counts_sm),
        names.arg = names(corpus_type_counts_sm),
        las = 2, col = "#4292c6", border = NA,
        ylab = "Files", main = "File type distribution (papers ≤500 files)")
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_corpus_type_sm))

# ── Plot 20: granularity × format heatmap (data files only) ──────────────────

png_corpus_data <- file.path(run_dir, "corpus_data_dist.png")
ct_raw <- table(
  dg = data_only$data_granularity_gt[!is.na(data_only$data_granularity_gt) & !is.na(data_only$data_format_gt)],
  df = data_only$data_format_gt[     !is.na(data_only$data_granularity_gt) & !is.na(data_only$data_format_gt)]
)
dg_lvls <- rownames(ct_raw)
df_lvls <- colnames(ct_raw)
nr <- length(dg_lvls); nc <- length(df_lvls)
png(png_corpus_data, width = 200 + nc * 140, height = 220 + nr * 90, res = 100)
old_par <- par(mar = c(6, 9, 4, 2))
col_ramp <- colorRampPalette(c("white", "#2171b5"))(100)
image(seq_len(nc), seq_len(nr), t(ct_raw)[, nr:1],
      col = col_ramp, axes = FALSE, xlab = "", ylab = "",
      main = "Data file subcategorisations")
axis(1, at = seq_len(nc), labels = df_lvls,      las = 1, cex.axis = 1.0)
axis(2, at = seq_len(nr), labels = rev(dg_lvls), las = 1, cex.axis = 1.0)
mtext("Format",      side = 1, line = 3,   cex = 0.9)
mtext("Granularity", side = 2, line = 7.5, cex = 0.9)
for (i in seq_len(nr))
  for (j in seq_len(nc)) {
    v <- ct_raw[i, j]
    if (v > 0) text(j, nr + 1 - i, as.character(v), cex = 1.0,
                    col = if (ct_raw[i, j] / max(ct_raw) > 0.6) "white" else "black")
  }
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_corpus_data))

# ── Plot 21: paper-level subcategory prevalence ───────────────────────────────

png_corpus_prev <- file.path(run_dir, "corpus_paper_prevalence.png")
all_pids   <- unique(acc$paper_id)
n_all      <- length(all_pids)
data_acc   <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]

pct_has <- function(col, val) {
  pids_with <- unique(data_acc$paper_id[!is.na(data_acc[[col]]) & data_acc[[col]] == val])
  100 * length(pids_with) / n_all
}

prev_vals <- c(
  individual = pct_has("data_granularity_gt", "individual"),
  combined   = pct_has("data_granularity_gt", "combined"),
  raw        = pct_has("data_format_gt",       "raw"),
  tabular    = pct_has("data_format_gt",       "tabular")
)
prev_cols <- c(individual = "#9ecae1", combined = "#2171b5",
               raw        = "#fdae6b", tabular  = "#e6550d")

png(png_corpus_prev, width = 600, height = 460, res = 100)
old_par <- par(mar = c(5, 5, 3, 2))
bp <- barplot(prev_vals, col = prev_cols[names(prev_vals)], border = NA,
              ylim = c(0, 100), ylab = "Repositories (%)",
              main = "Repositories containing each data subcategory",
              names.arg = names(prev_vals), cex.names = 0.95)
text(bp, prev_vals + 2.5, sprintf("%.0f%%", prev_vals), cex = 0.85, col = "grey30")
abline(h = 50, col = "grey80", lty = 2)
par(old_par); invisible(dev.off())
cat(sprintf("  [plot]   written to: %s\n", png_corpus_prev))
