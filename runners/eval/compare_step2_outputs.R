# compare_step2_outputs.R
# In-depth comparison of step2 raw outputs against ground truth, across
# every (model x prompt-format) configuration. Modelled on the depth of
# `runners/reports/report_normal.R` but pivoted to compare configs.
#
# Inputs : results/eval/outputs/step2/osf/<paper>/<config>/structure.csv
#          tests/ground_truth/osf/<paper>.csv
# Outputs: results/eval/outputs/step2/comparison/
#   - merged.csv                  long pred+GT (one row per file x config)
#   - headline_metrics.csv        per config: kappa, macro/micro F1, MCC, acc, retry
#   - per_class_<field>.csv       per config per class: TP/FP/FN/P/R/F1/FPR/FNR
#   - confusion_<field>_<cfg>.csv raw confusion (gt vs pred), one per config x field
#   - top_confusions.csv          top gt->pred error pairs per config (type)
#   - ext_errors.csv              per config: error rate by file extension
#   - per_paper.csv               per (config, paper) accuracy / kappa / macro F1
#   - paper_variability.csv       per config: mean/SD/min of paper accuracy
#   - missingness.csv             %NA + %sentinel per config per field
#   - cross_config.csv            pairwise agreement between configs per field
#   - report.md                   full human-readable report

source("runners/eval/eval_helpers.R")

ROOT     <- "results/eval/outputs/step2/osf"
OUT_DIR  <- "results/eval/outputs/step2/comparison"
SENTINEL <- "llm_error"

FIELD_MAP <- list(
  type             = "type_gt",
  group            = "group_gt",
  data_granularity = "data_granularity_gt",
  data_format      = "data_format_gt"
)
FIELDS <- names(FIELD_MAP)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
fmt1 <- function(x) if (is.na(x)) "—" else sprintf("%.1f", x)
fmt3 <- function(x) if (is.na(x)) "—" else sprintf("%.3f", x)

# ── load ─────────────────────────────────────────────────────────────────────

papers <- list.dirs(ROOT, recursive = FALSE, full.names = FALSE)
stopifnot(length(papers) > 0)

read_pred <- function(paper, cfg) {
  f <- file.path(ROOT, paper, cfg, "structure.csv")
  if (!file.exists(f)) return(NULL)
  d <- tryCatch(
    read.csv(f, colClasses = c(paper_id = "character"),
             stringsAsFactors = FALSE, na.strings = c("NA", "")),
    error = function(e) NULL
  )
  if (is.null(d) || nrow(d) == 0) return(NULL)
  d$config <- cfg
  d
}

merged_rows <- list()
for (p in papers) {
  gt <- read_gt(p, "osf")
  if (is.null(gt) || nrow(gt) == 0) next
  gt_keep <- intersect(c("paper_id", "rel_path",
                         unlist(FIELD_MAP, use.names = FALSE)), names(gt))
  gt <- gt[, gt_keep, drop = FALSE]
  cfgs <- list.dirs(file.path(ROOT, p), recursive = FALSE, full.names = FALSE)
  for (c in cfgs) {
    pr <- read_pred(p, c)
    if (is.null(pr)) next
    keep <- c("paper_id", "rel_path", "config", "ext",
              "type", "type_source", "group", "aggregate_folder",
              "data_granularity", "granularity_source", "data_format")
    for (k in keep) if (is.null(pr[[k]])) pr[[k]] <- NA
    pr <- pr[, keep, drop = FALSE]
    merged_rows[[length(merged_rows) + 1L]] <-
      merge(pr, gt, by = c("paper_id", "rel_path"), all.x = TRUE)
  }
}
merged <- do.call(rbind, merged_rows)
mm <- regmatches(merged$config, regexec("^(.*)_([^_]+)$", merged$config))
merged$model  <- vapply(mm, function(x) if (length(x) >= 3) x[2] else NA_character_, "")
merged$format <- vapply(mm, function(x) if (length(x) >= 3) x[3] else NA_character_, "")
write.csv(merged, file.path(OUT_DIR, "merged.csv"), row.names = FALSE, na = "")

configs <- sort(unique(merged$config))
cat(sprintf("Loaded %d rows · %d papers · %d configs:\n  %s\n\n",
            nrow(merged), length(unique(merged$paper_id)),
            length(configs), paste(configs, collapse = ", ")))

# ── core metric helpers ──────────────────────────────────────────────────────

scorable <- function(sub, field, gt_field) {
  pred <- sub[[field]]; gt <- sub[[gt_field]]
  ok <- !is.na(pred) & pred != SENTINEL & !is.na(gt)
  data.frame(pred = pred[ok], gt = gt[ok], stringsAsFactors = FALSE)
}

confusion <- function(sd) {
  if (nrow(sd) == 0) return(NULL)
  lev <- sort(unique(c(sd$gt, sd$pred)))
  as.matrix(table(
    gt   = factor(sd$gt,   levels = lev),
    pred = factor(sd$pred, levels = lev)
  ))
}

per_class_from_cm <- function(cm) {
  cls <- rownames(cm)
  N <- sum(cm)
  do.call(rbind, lapply(cls, function(c) {
    tp <- cm[c, c]; fp <- sum(cm[, c]) - tp
    fn <- sum(cm[c, ]) - tp; tn <- N - tp - fp - fn
    p  <- if ((tp + fp) > 0) tp / (tp + fp) * 100 else NA_real_
    r  <- if ((tp + fn) > 0) tp / (tp + fn) * 100 else NA_real_
    f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
    fpr <- if ((fp + tn) > 0) fp / (fp + tn) * 100 else NA_real_
    fnr <- if ((tp + fn) > 0) fn / (tp + fn) * 100 else NA_real_
    # top FP src (gt classes other than c, predicted as c)
    fp_src <- cm[setdiff(cls, c), c, drop = FALSE]
    top_fp <- if (sum(fp_src) > 0) names(which.max(rowSums(fp_src))) else NA
    # top FN dest (c gt rows predicted as something other than c)
    fn_dst <- cm[c, setdiff(cls, c), drop = FALSE]
    top_fn <- if (sum(fn_dst) > 0) names(which.max(colSums(fn_dst))) else NA
    data.frame(class = c, tp = tp, fp = fp, fn = fn,
               precision = p, recall = r, f1 = f1,
               fpr = fpr, fnr = fnr,
               top_fp_src = top_fp %||% NA_character_,
               top_fn_dst = top_fn %||% NA_character_,
               stringsAsFactors = FALSE)
  }))
}

# ── 1. headline metrics per config (type only — primary task) ────────────────

micro_f1_from_sd <- function(sd) {
  if (nrow(sd) == 0) return(NA_real_)
  classes <- sort(unique(c(sd$gt, sd$pred)))
  tp <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred == cl)))
  fp <- sum(sapply(classes, function(cl) sum(sd$gt != cl & sd$pred == cl)))
  fn <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred != cl)))
  p  <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
  r  <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
  if (!is.na(p) && !is.na(r) && (p + r) > 0) 2 * p * r / (p + r) * 100 else NA_real_
}

headline <- list()
per_paper_all <- list()
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, "type", "type_gt")
  cm  <- confusion(sd)
  s   <- if (!is.null(cm)) cm_stats(cm) else
         list(kappa = NA, macro_f1 = NA, mcc = NA, accuracy = NA, f1s = NULL)
  micro_f1_fp <- micro_f1_from_sd(sd)

  # "other"-excluded variants — "other" is the LLM fallback bucket and drags
  # macro down disproportionately
  sd_no <- sd[sd$gt != "other" & sd$pred != "other", , drop = FALSE]
  cm_no <- confusion(sd_no)
  s_no  <- if (!is.null(cm_no)) cm_stats(cm_no) else
           list(kappa = NA, macro_f1 = NA, mcc = NA, accuracy = NA)
  micro_f1_no_fp <- micro_f1_from_sd(sd_no)

  # micro F1
  N <- nrow(sd)
  acc <- if (N > 0) mean(sd$pred == sd$gt) * 100 else NA_real_
  # paper-averaged
  pa <- do.call(rbind, lapply(split(sd, sub$paper_id[
      !is.na(sub$type) & sub$type != SENTINEL & !is.na(sub$type_gt)
    ]), function(d) {
      if (nrow(d) == 0) return(NULL)
      lev <- sort(unique(c(d$gt, d$pred)))
      cmp <- as.matrix(table(
        gt   = factor(d$gt,   levels = lev),
        pred = factor(d$pred, levels = lev)
      ))
      sp <- cm_stats(cmp)
      mf <- micro_f1_from_sd(d)
      # no-other version per paper
      d2 <- d[d$gt != "other" & d$pred != "other", , drop = FALSE]
      if (nrow(d2) > 0) {
        lev2 <- sort(unique(c(d2$gt, d2$pred)))
        cmp2 <- as.matrix(table(
          gt   = factor(d2$gt,   levels = lev2),
          pred = factor(d2$pred, levels = lev2)
        ))
        sp2 <- cm_stats(cmp2)
        mf2 <- micro_f1_from_sd(d2)
      } else {
        sp2 <- list(macro_f1 = NA_real_); mf2 <- NA_real_
      }
      data.frame(n = nrow(d), acc = mean(d$gt == d$pred) * 100,
                 kappa = sp$kappa, macro_f1 = sp$macro_f1, mcc = sp$mcc,
                 micro_f1 = mf,
                 macro_f1_no_other = sp2$macro_f1,
                 micro_f1_no_other = mf2)
    }))
  if (!is.null(pa) && nrow(pa) > 0) {
    pa$config <- cfg
    per_paper_all[[length(per_paper_all) + 1L]] <- cbind(
      paper_id = rownames(pa), pa, stringsAsFactors = FALSE
    )
  }

  retry <- mean(sub$type == SENTINEL, na.rm = TRUE) * 100
  na_pred <- mean(is.na(sub$type)) * 100

  headline[[length(headline) + 1L]] <- data.frame(
    config = cfg, n_files = N,
    accuracy_fp   = acc,
    macro_f1_fp   = s$macro_f1,
    micro_f1_fp   = micro_f1_fp,
    kappa_fp      = s$kappa,
    mcc_fp        = s$mcc,
    macro_f1_no_other_fp = s_no$macro_f1,
    micro_f1_no_other_fp = micro_f1_no_fp,
    accuracy_pa   = if (!is.null(pa)) mean(pa$acc, na.rm = TRUE) else NA,
    macro_f1_pa   = if (!is.null(pa)) mean(pa$macro_f1, na.rm = TRUE) else NA,
    micro_f1_pa   = if (!is.null(pa)) mean(pa$micro_f1, na.rm = TRUE) else NA,
    kappa_pa      = if (!is.null(pa)) mean(pa$kappa, na.rm = TRUE) else NA,
    mcc_pa        = if (!is.null(pa)) mean(pa$mcc, na.rm = TRUE) else NA,
    macro_f1_no_other_pa = if (!is.null(pa)) mean(pa$macro_f1_no_other, na.rm = TRUE) else NA,
    micro_f1_no_other_pa = if (!is.null(pa)) mean(pa$micro_f1_no_other, na.rm = TRUE) else NA,
    pct_sentinel  = retry,
    pct_na_pred   = na_pred,
    stringsAsFactors = FALSE
  )
}
headline <- do.call(rbind, headline)
write.csv(headline, file.path(OUT_DIR, "headline_metrics.csv"),
          row.names = FALSE, na = "")

per_paper <- if (length(per_paper_all)) do.call(rbind, per_paper_all) else data.frame()
write.csv(per_paper, file.path(OUT_DIR, "per_paper.csv"),
          row.names = FALSE, na = "")

# paper variability
paper_var <- if (nrow(per_paper) > 0)
  do.call(rbind, lapply(split(per_paper, per_paper$config), function(d) {
    data.frame(
      config = d$config[1],
      n_papers = nrow(d),
      mean_acc = mean(d$acc, na.rm = TRUE),
      sd_acc   = sd(d$acc, na.rm = TRUE),
      min_acc  = min(d$acc, na.rm = TRUE),
      pct_below_50 = mean(d$acc < 50, na.rm = TRUE) * 100,
      mean_kappa   = mean(d$kappa, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  })) else data.frame()
write.csv(paper_var, file.path(OUT_DIR, "paper_variability.csv"),
          row.names = FALSE, na = "")

# ── 2. per-field per-config summary (acc, macro F1, %NA, %sentinel) ──────────

field_summary <- list()
for (cfg in configs) for (f in FIELDS) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, f, FIELD_MAP[[f]])
  cm  <- confusion(sd)
  s   <- if (!is.null(cm)) cm_stats(cm) else
         list(macro_f1 = NA, kappa = NA, accuracy = NA)

  # paper-averaged per-field metrics
  gt_field <- FIELD_MAP[[f]]
  scor_mask <- !is.na(sub[[f]]) & sub[[f]] != SENTINEL & !is.na(sub[[gt_field]])
  pa_rows <- if (any(scor_mask)) {
    sd_full <- sub[scor_mask, , drop = FALSE]
    do.call(rbind, lapply(split(sd_full, sd_full$paper_id), function(d) {
      if (nrow(d) == 0) return(NULL)
      pred_v <- d[[f]]; gt_v <- d[[gt_field]]
      lev <- sort(unique(c(pred_v, gt_v)))
      cmp <- as.matrix(table(
        gt   = factor(gt_v,   levels = lev),
        pred = factor(pred_v, levels = lev)
      ))
      sp <- cm_stats(cmp)
      data.frame(acc = mean(pred_v == gt_v) * 100,
                 macro_f1 = sp$macro_f1, kappa = sp$kappa,
                 stringsAsFactors = FALSE)
    }))
  } else NULL
  accuracy_pa <- if (!is.null(pa_rows)) mean(pa_rows$acc,      na.rm = TRUE) else NA_real_
  macro_f1_pa <- if (!is.null(pa_rows)) mean(pa_rows$macro_f1, na.rm = TRUE) else NA_real_
  kappa_pa    <- if (!is.null(pa_rows)) mean(pa_rows$kappa,    na.rm = TRUE) else NA_real_
  n_papers_pa <- if (!is.null(pa_rows)) nrow(pa_rows) else 0L

  field_summary[[length(field_summary) + 1L]] <- data.frame(
    config = cfg, field = f,
    n_scored = nrow(sd),
    n_papers = n_papers_pa,
    pct_na_pred  = round(mean(is.na(sub[[f]])) * 100, 2),
    pct_sentinel = round(mean(!is.na(sub[[f]]) & sub[[f]] == SENTINEL) * 100, 2),
    accuracy = round(if (nrow(sd) > 0) mean(sd$pred == sd$gt) * 100 else NA, 2),
    macro_f1 = round(s$macro_f1, 2),
    kappa    = round(s$kappa, 3),
    accuracy_pa = round(accuracy_pa, 2),
    macro_f1_pa = round(macro_f1_pa, 2),
    kappa_pa    = round(kappa_pa, 3),
    stringsAsFactors = FALSE
  )
}
field_summary <- do.call(rbind, field_summary)
write.csv(field_summary[, c("config","field","pct_na_pred","pct_sentinel")],
          file.path(OUT_DIR, "missingness.csv"), row.names = FALSE)

# ── 3. per-class metrics (file-pooled AND paper-averaged) ────────────────────
# Paper-averaged: compute P/R/F1 per paper (only papers where the class appears
# in GT contribute), then mean across papers — equal-weights every paper.

per_class_paper <- function(sub, field, gt_field) {
  # Returns rows: (paper_id, class, precision, recall, f1) per paper
  sd <- sub[!is.na(sub[[field]]) & sub[[field]] != SENTINEL &
            !is.na(sub[[gt_field]]), , drop = FALSE]
  if (nrow(sd) == 0) return(NULL)
  out <- list()
  for (pid in unique(sd$paper_id)) {
    d <- sd[sd$paper_id == pid, , drop = FALSE]
    lev <- sort(unique(c(d[[field]], d[[gt_field]])))
    if (length(lev) == 0) next
    cm <- as.matrix(table(
      gt   = factor(d[[gt_field]], levels = lev),
      pred = factor(d[[field]],    levels = lev)
    ))
    # Only score classes that appear in this paper's GT
    classes_in_gt <- lev[rowSums(cm) > 0]
    for (cl in classes_in_gt) {
      tp <- cm[cl, cl]; fp <- sum(cm[, cl]) - tp; fn <- sum(cm[cl, ]) - tp
      p <- if ((tp + fp) > 0) tp / (tp + fp) * 100 else NA_real_
      r <- if ((tp + fn) > 0) tp / (tp + fn) * 100 else NA_real_
      f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
      out[[length(out) + 1L]] <- data.frame(
        paper_id = pid, class = cl,
        precision = p, recall = r, f1 = f1,
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(out) == 0) return(NULL)
  do.call(rbind, out)
}

paper_avg_class <- function(pp) {
  do.call(rbind, lapply(split(pp, pp$class), function(d) {
    data.frame(
      class = d$class[1],
      n_papers   = nrow(d),
      precision_pa = mean(d$precision, na.rm = TRUE),
      recall_pa    = mean(d$recall,    na.rm = TRUE),
      f1_pa        = mean(d$f1,        na.rm = TRUE),
      sd_f1_pa     = sd(d$f1,          na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }))
}

per_class_type <- list()
per_class_type_paper_long <- list()  # per (config, paper, class) for boxplots/SDs
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, "type", "type_gt")
  cm  <- confusion(sd); if (is.null(cm)) next
  pc  <- per_class_from_cm(cm)                       # file-pooled
  pp  <- per_class_paper(sub, "type", "type_gt")     # per paper
  pa  <- if (!is.null(pp)) paper_avg_class(pp)
         else data.frame(class = character(),
                         precision_pa = double(), recall_pa = double(),
                         f1_pa = double(), sd_f1_pa = double(),
                         n_papers = integer())
  merged_row <- merge(pc, pa, by = "class", all.x = TRUE)
  merged_row$config <- cfg
  per_class_type[[length(per_class_type) + 1L]] <- merged_row
  if (!is.null(pp)) {
    pp$config <- cfg
    per_class_type_paper_long[[length(per_class_type_paper_long) + 1L]] <- pp
  }
  cmd <- as.data.frame.matrix(cm)
  cmd <- cbind(gt = rownames(cm), cmd)
  write.csv(cmd, file.path(OUT_DIR,
            sprintf("confusion_type_%s.csv", cfg)), row.names = FALSE)
}
per_class_type <- do.call(rbind, per_class_type)
write.csv(per_class_type, file.path(OUT_DIR, "per_class_type.csv"),
          row.names = FALSE, na = "")
per_class_type_paper_long <- if (length(per_class_type_paper_long))
  do.call(rbind, per_class_type_paper_long) else data.frame()
write.csv(per_class_type_paper_long,
          file.path(OUT_DIR, "per_class_type_per_paper.csv"),
          row.names = FALSE, na = "")

for (f in setdiff(FIELDS, "type")) {
  rows <- list()
  for (cfg in configs) {
    sub <- merged[merged$config == cfg, , drop = FALSE]
    sd  <- scorable(sub, f, FIELD_MAP[[f]])
    cm  <- confusion(sd); if (is.null(cm)) next
    pc  <- per_class_from_cm(cm)
    pp  <- per_class_paper(sub, f, FIELD_MAP[[f]])
    pa  <- if (!is.null(pp)) paper_avg_class(pp)
           else data.frame(class = character(),
                           precision_pa = double(), recall_pa = double(),
                           f1_pa = double(), sd_f1_pa = double(),
                           n_papers = integer())
    mr <- merge(pc, pa, by = "class", all.x = TRUE)
    mr$config <- cfg
    rows[[length(rows) + 1L]] <- mr
  }
  if (length(rows)) {
    pcdf <- do.call(rbind, rows)
    write.csv(pcdf, file.path(OUT_DIR, sprintf("per_class_%s.csv", f)),
              row.names = FALSE, na = "")
  }
}

# ── 4. top confusion pairs per config (type) ─────────────────────────────────

top_conf <- list()
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, "type", "type_gt")
  bad <- sd[sd$pred != sd$gt, ]
  if (nrow(bad) == 0) next
  tb <- as.data.frame(table(gt = bad$gt, pred = bad$pred),
                      stringsAsFactors = FALSE)
  tb <- tb[tb$Freq > 0, ]
  tb <- tb[order(-tb$Freq), ]
  tb$pair <- sprintf("%s→%s", tb$gt, tb$pred)
  tb$config <- cfg
  top_conf[[length(top_conf) + 1L]] <-
    head(tb[, c("config", "pair", "Freq")], 10)
}
top_conf <- do.call(rbind, top_conf)
write.csv(top_conf, file.path(OUT_DIR, "top_confusions.csv"),
          row.names = FALSE, na = "")

# ── 5. error rate by file extension (type) ───────────────────────────────────

ext_rows <- list()
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- sub[!is.na(sub$type) & sub$type != SENTINEL & !is.na(sub$type_gt), ]
  if (nrow(sd) == 0) next
  sd$ext <- tolower(sd$ext %||% "")
  agg <- aggregate(cbind(n = rep(1, nrow(sd)),
                         err = as.integer(sd$type != sd$type_gt)),
                   by = list(ext = sd$ext), FUN = sum)
  agg <- agg[agg$n >= 5, ]
  agg$err_pct <- round(agg$err / agg$n * 100, 1)
  agg$config <- cfg
  ext_rows[[length(ext_rows) + 1L]] <- agg
}
ext_errors <- do.call(rbind, ext_rows)
write.csv(ext_errors, file.path(OUT_DIR, "ext_errors.csv"),
          row.names = FALSE)

# ── 6. cross-config pairwise agreement (ignoring GT) ─────────────────────────

cross <- list()
merged$key <- paste(merged$paper_id, merged$rel_path, sep = "||")
keys <- unique(merged$key)
for (f in FIELDS) {
  M <- matrix(NA_character_, nrow = length(keys), ncol = length(configs),
              dimnames = list(keys, configs))
  for (cfg in configs) {
    s <- merged[merged$config == cfg, , drop = FALSE]
    M[s$key, cfg] <- as.character(s[[f]])
  }
  for (i in seq_along(configs)) for (j in seq_along(configs)) {
    if (j <= i) next
    a <- M[, i]; b <- M[, j]
    ok <- !is.na(a) & !is.na(b) & a != SENTINEL & b != SENTINEL
    if (!any(ok)) next
    cross[[length(cross) + 1L]] <- data.frame(
      field = f, config_a = configs[i], config_b = configs[j],
      n = sum(ok), pct_agree = round(mean(a[ok] == b[ok]) * 100, 2),
      stringsAsFactors = FALSE
    )
  }
}
cross_df <- do.call(rbind, cross)
write.csv(cross_df, file.path(OUT_DIR, "cross_config.csv"), row.names = FALSE)

# ── plots ────────────────────────────────────────────────────────────────────

PLOT_DIR <- file.path(OUT_DIR, "plots")
dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

# Distinct colours for configs
cfg_cols <- setNames(
  hcl.colors(length(configs), palette = "Dark 3"),
  configs
)

heatmap_pct <- function(mat, file, title, lo = 0, hi = 100,
                        palette = c("white", "#2171b5"), digits = 1,
                        width = 1400, height = 900) {
  png(file, width = width, height = height, res = 150)
  on.exit(dev.off())
  cols <- colorRampPalette(palette)(100)
  nr <- nrow(mat); nc <- ncol(mat)
  norm <- (mat - lo) / (hi - lo)
  norm[is.na(norm)] <- 0
  norm[norm < 0] <- 0; norm[norm > 1] <- 1
  par(mar = c(8, 10, 4, 2))
  image(seq_len(nc), seq_len(nr), t(norm)[, nr:1],
        col = cols, axes = FALSE, xlab = "", ylab = "", main = title)
  axis(1, at = seq_len(nc), labels = colnames(mat), las = 2, cex.axis = 0.85)
  axis(2, at = seq_len(nr), labels = rev(rownames(mat)), las = 1, cex.axis = 0.85)
  for (i in seq_len(nr)) for (j in seq_len(nc)) {
    v <- mat[nr + 1 - i, j]
    if (!is.na(v))
      text(j, i, sprintf(paste0("%.", digits, "f"), v),
           col = if (norm[nr + 1 - i, j] > 0.55) "white" else "black",
           cex = 0.75)
  }
}

# 1. Headline metrics — grouped bars per config
{
  png(file.path(PLOT_DIR, "headline_metrics.png"),
      width = 1600, height = 900, res = 150)
  metrics <- c("accuracy_fp", "accuracy_pa", "macro_f1_fp", "macro_f1_pa")
  labels  <- c("acc (file-pooled)", "acc (paper-avg)",
               "macro-F1 (fp)", "macro-F1 (pa)")
  M <- as.matrix(headline[, metrics]); rownames(M) <- headline$config
  par(mar = c(10, 5, 4, 2))
  bp <- barplot(t(M), beside = TRUE, las = 2,
                col = hcl.colors(length(metrics), "Set 2"),
                ylim = c(0, 105),
                ylab = "%", main = "Headline metrics by config (type classification)")
  legend("topright", labels, fill = hcl.colors(length(metrics), "Set 2"),
         bty = "n", cex = 0.85)
  dev.off()
}

# 2. Per-field accuracy heatmap (config × field)
{
  M <- matrix(NA_real_, nrow = length(configs), ncol = length(FIELDS),
              dimnames = list(configs, FIELDS))
  for (cfg in configs) for (f in FIELDS) {
    v <- field_summary$accuracy[field_summary$config == cfg & field_summary$field == f]
    if (length(v)) M[cfg, f] <- v
  }
  heatmap_pct(M, file.path(PLOT_DIR, "per_field_accuracy.png"),
              "Accuracy (%) — config × field")
}

# 3. Per-field macro-F1 heatmap
{
  M <- matrix(NA_real_, nrow = length(configs), ncol = length(FIELDS),
              dimnames = list(configs, FIELDS))
  for (cfg in configs) for (f in FIELDS) {
    v <- field_summary$macro_f1[field_summary$config == cfg & field_summary$field == f]
    if (length(v)) M[cfg, f] <- v
  }
  heatmap_pct(M, file.path(PLOT_DIR, "per_field_macro_f1.png"),
              "Macro-F1 (%) — config × field")
}

# 4. Per-class F1 / recall / precision heatmaps (type)
classes <- sort(unique(per_class_type$class))
build_class_mat <- function(metric) {
  M <- matrix(NA_real_, nrow = length(configs), ncol = length(classes),
              dimnames = list(configs, classes))
  for (cfg in configs) for (c in classes) {
    v <- per_class_type[per_class_type$config == cfg & per_class_type$class == c, metric]
    if (length(v)) M[cfg, c] <- v
  }
  M
}
heatmap_pct(build_class_mat("f1"),
            file.path(PLOT_DIR, "per_class_type_f1_fp.png"),
            "Per-class F1 (%) — type — file-pooled")
heatmap_pct(build_class_mat("recall"),
            file.path(PLOT_DIR, "per_class_type_recall_fp.png"),
            "Per-class recall (%) — type — file-pooled")
heatmap_pct(build_class_mat("precision"),
            file.path(PLOT_DIR, "per_class_type_precision_fp.png"),
            "Per-class precision (%) — type — file-pooled")
heatmap_pct(build_class_mat("f1_pa"),
            file.path(PLOT_DIR, "per_class_type_f1_pa.png"),
            "Per-class F1 (%) — type — paper-averaged")
heatmap_pct(build_class_mat("recall_pa"),
            file.path(PLOT_DIR, "per_class_type_recall_pa.png"),
            "Per-class recall (%) — type — paper-averaged")
heatmap_pct(build_class_mat("precision_pa"),
            file.path(PLOT_DIR, "per_class_type_precision_pa.png"),
            "Per-class precision (%) — type — paper-averaged")

# 5. Confusion matrix heatmap per config — file-pooled AND paper-averaged
# Paper-averaged: each paper's CM is row-normalised; then rows averaged across
# only the papers that contain that gt class (so large repos don't dominate).
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, "type", "type_gt")
  cm  <- confusion(sd); if (is.null(cm)) next
  rn  <- rowSums(cm)
  norm <- cm / ifelse(rn == 0, 1, rn) * 100
  heatmap_pct(norm,
              file.path(PLOT_DIR, sprintf("confusion_type_fp_%s.png", cfg)),
              sprintf("Type confusion (row-norm %%, file-pooled) — %s", cfg),
              palette = c("white", "#08519c"))

  # paper-averaged
  scor <- sub[!is.na(sub$type) & sub$type != SENTINEL & !is.na(sub$type_gt), ,
              drop = FALSE]
  if (nrow(scor) == 0) next
  lev <- sort(unique(c(scor$type, scor$type_gt)))
  pa_sum <- matrix(0, nrow = length(lev), ncol = length(lev),
                   dimnames = list(lev, lev))
  pa_n   <- setNames(integer(length(lev)), lev)
  for (pid in unique(scor$paper_id)) {
    d <- scor[scor$paper_id == pid, , drop = FALSE]
    cmp <- as.matrix(table(
      gt   = factor(d$type_gt, levels = lev),
      pred = factor(d$type,    levels = lev)
    ))
    rs <- rowSums(cmp)
    classes_here <- which(rs > 0)
    if (length(classes_here) == 0) next
    cmn <- cmp
    cmn[classes_here, ] <- cmp[classes_here, , drop = FALSE] /
                           rs[classes_here]
    pa_sum[classes_here, ] <- pa_sum[classes_here, , drop = FALSE] +
                              cmn[classes_here, , drop = FALSE]
    pa_n[classes_here] <- pa_n[classes_here] + 1L
  }
  pa_norm <- pa_sum / ifelse(pa_n == 0, 1, pa_n) * 100
  heatmap_pct(pa_norm,
              file.path(PLOT_DIR, sprintf("confusion_type_pa_%s.png", cfg)),
              sprintf("Type confusion (row-norm %%, paper-avg) — %s", cfg),
              palette = c("white", "#08519c"))
}

# 6. Missingness — sentinel rate on type (bar)
{
  png(file.path(PLOT_DIR, "sentinel_rate.png"),
      width = 1400, height = 800, res = 150)
  v <- headline$pct_sentinel; names(v) <- headline$config
  par(mar = c(10, 5, 4, 2))
  barplot(v, las = 2, col = cfg_cols[names(v)],
          ylab = "% sentinel (llm_error)",
          main = "Sentinel-error rate on type per config",
          ylim = c(0, max(v) * 1.15 + 1))
  text(seq_along(v) * 1.2 - 0.5, v, labels = sprintf("%.1f", v),
       pos = 3, cex = 0.8)
  dev.off()
}

# 7. Per-paper accuracy boxplot per config
if (nrow(per_paper) > 0) {
  png(file.path(PLOT_DIR, "per_paper_accuracy_box.png"),
      width = 1600, height = 900, res = 150)
  par(mar = c(10, 5, 4, 2))
  boxplot(acc ~ config, data = per_paper, las = 2,
          col = cfg_cols[sort(unique(per_paper$config))],
          ylab = "Per-paper type accuracy (%)",
          main = "Per-paper accuracy distribution by config",
          ylim = c(0, 100))
  dev.off()
}

# 9. Extension error heatmap (worst 15 extensions × configs)
{
  exts <- sort(unique(ext_errors$ext))
  worst <- sort(vapply(exts, function(e)
    max(ext_errors$err_pct[ext_errors$ext == e], na.rm = TRUE),
    numeric(1)), decreasing = TRUE)
  worst_ext <- names(head(worst, 15))
  M <- matrix(NA_real_, nrow = length(worst_ext), ncol = length(configs),
              dimnames = list(worst_ext, configs))
  for (e in worst_ext) for (cfg in configs) {
    v <- ext_errors$err_pct[ext_errors$ext == e & ext_errors$config == cfg]
    if (length(v)) M[e, cfg] <- v
  }
  heatmap_pct(M, file.path(PLOT_DIR, "ext_error_rate.png"),
              "Error rate (%) by file extension × config — worst 15",
              palette = c("white", "#cb181d"))
}

# 10. Cross-config agreement heatmaps per field
for (f in FIELDS) {
  s <- cross_df[cross_df$field == f, ]
  if (nrow(s) == 0) next
  M <- matrix(100, nrow = length(configs), ncol = length(configs),
              dimnames = list(configs, configs))
  for (i in seq_along(configs)) for (j in seq_along(configs)) {
    if (i == j) next
    v <- s$pct_agree[(s$config_a == configs[i] & s$config_b == configs[j]) |
                     (s$config_a == configs[j] & s$config_b == configs[i])]
    if (length(v)) M[i, j] <- v[1]
  }
  heatmap_pct(M, file.path(PLOT_DIR, sprintf("cross_config_%s.png", f)),
              sprintf("Cross-config pairwise agreement (%%) — %s", f),
              lo = min(M, na.rm = TRUE), hi = 100,
              palette = c("#fff5eb", "#08519c"))
}

# ── markdown report ──────────────────────────────────────────────────────────

md <- c(); add <- function(...) md <<- c(md, sprintf(...))

add("# Step 2 — in-depth comparison of configs against GT")
add("")
add("Source `%s`  ·  GT `tests/ground_truth/osf/`  ·  Generated %s",
    ROOT, format(Sys.time(), "%Y-%m-%d %H:%M"))
add("Papers **%d**  ·  Configs **%d**  ·  Merged rows **%d**",
    length(unique(merged$paper_id)), length(configs), nrow(merged))
add("")
add("Configs: %s", paste(configs, collapse = ", "))
add("")
add("Rows with `pred == NA` or `pred == %s` are excluded from accuracy / F1 / κ but counted in **missingness**.", SENTINEL)
add("")
add("All plots live in `plots/`; CSVs in the same dir feed every table below.")
add("")

# 1. Headline ---------------------------------------------------------------
add("## 1. Headline metrics (type classification)")
add("")
add("![headline](plots/headline_metrics.png)")
add("")
add("Both **file-pooled (fp)** — all files counted once — and **paper-averaged (pa)** — metric per paper then averaged.")
add("")
add("| config | n files | κ fp | κ pa | macro-F1 fp | macro-F1 pa | micro-F1 fp | micro-F1 pa | MCC fp | MCC pa | acc fp | acc pa | %% sentinel |")
add("|%s|", paste(rep("---", 13), collapse = "|"))
for (i in seq_len(nrow(headline))) {
  r <- headline[i, ]
  add("| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %.2f |",
      r$config, r$n_files,
      fmt3(r$kappa_fp), fmt3(r$kappa_pa),
      fmt1(r$macro_f1_fp), fmt1(r$macro_f1_pa),
      fmt1(r$micro_f1_fp), fmt1(r$micro_f1_pa),
      fmt3(r$mcc_fp), fmt3(r$mcc_pa),
      fmt1(r$accuracy_fp), fmt1(r$accuracy_pa),
      r$pct_sentinel)
}
add("")

add("### 1.1 Macro/micro-F1 excluding `other`")
add("")
add("`other` is the LLM fallback bucket — its F1 is near-zero and disproportionately drags macro-F1 down. Rows in which **either** GT or pred is `other` are excluded.")
add("")
add("| config | macro-F1 fp | macro-F1 pa | micro-F1 fp | micro-F1 pa |")
add("|---|---|---|---|---|")
for (i in seq_len(nrow(headline))) {
  r <- headline[i, ]
  add("| %s | %s | %s | %s | %s |",
      r$config,
      fmt1(r$macro_f1_no_other_fp), fmt1(r$macro_f1_no_other_pa),
      fmt1(r$micro_f1_no_other_fp), fmt1(r$micro_f1_no_other_pa))
}
add("")

# 2. Per-field summary -------------------------------------------------------
add("## 2. Per-field summary")
add("")
add("![accuracy heatmap](plots/per_field_accuracy.png)")
add("")
add("![macro-F1 heatmap](plots/per_field_macro_f1.png)")
add("")
pivot <- function(metric, dp = 1) {
  add("### %s", metric)
  add("")
  add("| config | %s |", paste(FIELDS, collapse = " | "))
  add("|%s|", paste(rep("---", length(FIELDS) + 1), collapse = "|"))
  for (cfg in configs) {
    vals <- vapply(FIELDS, function(f) {
      v <- field_summary[field_summary$config == cfg & field_summary$field == f, metric]
      if (length(v) == 0) NA_real_ else v
    }, numeric(1))
    add("| %s | %s |", cfg,
        paste(vapply(vals, function(v) if (is.na(v)) "—"
                     else sprintf(paste0("%.", dp, "f"), v), ""),
              collapse = " | "))
  }
  add("")
}
add("File-pooled (fp): all files counted once. Paper-averaged (pa): metric per paper, then mean across papers — large repos do not dominate.")
add("")
pivot("accuracy")
pivot("accuracy_pa")
pivot("macro_f1")
pivot("macro_f1_pa")
pivot("kappa", dp = 3)
pivot("kappa_pa", dp = 3)
pivot("pct_sentinel", dp = 2)
pivot("n_scored", dp = 0)
pivot("n_papers", dp = 0)

# 3. Per-class metrics (type) -----------------------------------------------
add("## 3. Per-class metrics — `type`")
add("")
add("![per-class F1 file-pooled](plots/per_class_type_f1_fp.png)")
add("")
add("![per-class recall file-pooled](plots/per_class_type_recall_fp.png)")
add("")
add("![per-class precision file-pooled](plots/per_class_type_precision_fp.png)")
add("")
add("![per-class F1 paper-averaged](plots/per_class_type_f1_pa.png)")
add("")
add("![per-class recall paper-averaged](plots/per_class_type_recall_pa.png)")
add("")
add("![per-class precision paper-averaged](plots/per_class_type_precision_pa.png)")
add("")
classes <- sort(unique(per_class_type$class))
add("### 3.1 Per-class F1 (%%) by config")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$f1[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg,
      paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.2 Per-class recall (%%) by config — how many true-class files were caught")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$recall[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.3 Per-class precision (%%) by config")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$precision[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

# Paper-averaged variants (per-paper metric → mean across papers; large
# repositories no longer dominate).
add("### 3.4 Per-class F1 (%%) by config — paper-averaged")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$f1_pa[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.5 Per-class recall (%%) by config — paper-averaged")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$recall_pa[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.6 Per-class precision (%%) by config — paper-averaged")
add("")
add("| config | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$precision_pa[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

# 4. Top confusions ----------------------------------------------------------
add("## 4. Top confusion pairs (gt → pred), `type`")
add("")
add("Row-normalised type confusion matrices (one per config) — file-pooled and paper-averaged.")
add("")
for (cfg in configs) {
  add("**%s — file-pooled**", cfg)
  add("")
  add("![confusion fp %s](plots/confusion_type_fp_%s.png)", cfg, cfg)
  add("")
  add("**%s — paper-averaged**", cfg)
  add("")
  add("![confusion pa %s](plots/confusion_type_pa_%s.png)", cfg, cfg)
  add("")
}
for (cfg in configs) {
  sub <- top_conf[top_conf$config == cfg, ]
  if (nrow(sub) == 0) next
  add("**%s**", cfg)
  for (i in seq_len(nrow(sub)))
    add("- %s (%d)", sub$pair[i], sub$Freq[i])
  add("")
}

# 5. Error rate by extension -------------------------------------------------
add("## 5. Error rate by file extension (`type`, ≥5 files)")
add("")
add("![extension errors](plots/ext_error_rate.png)")
add("")
exts <- sort(unique(ext_errors$ext))
# pick 12 worst by max error pct across configs
worst <- sort(vapply(exts, function(e)
  max(ext_errors$err_pct[ext_errors$ext == e], na.rm = TRUE),
  numeric(1)), decreasing = TRUE)
worst_ext <- names(head(worst, 12))
add("Showing the 12 extensions with highest worst-case error across configs.")
add("")
add("| ext | %s |", paste(configs, collapse = " | "))
add("|%s|", paste(rep("---", length(configs) + 1), collapse = "|"))
for (e in worst_ext) {
  vals <- vapply(configs, function(cfg) {
    v <- ext_errors$err_pct[ext_errors$ext == e & ext_errors$config == cfg]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  ns <- vapply(configs, function(cfg) {
    v <- ext_errors$n[ext_errors$ext == e & ext_errors$config == cfg]
    if (length(v) == 0) 0L else as.integer(v[1])
  }, integer(1))
  add("| %s (n≈%d) | %s |", e, max(ns),
      paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

# 6. Per-paper variability ---------------------------------------------------
add("## 6. Per-paper variability (`type` accuracy)")
add("")
add("![per-paper accuracy](plots/per_paper_accuracy_box.png)")
add("")
add("| config | n papers | mean acc | SD acc | min acc | %% papers <50%% | mean κ |")
add("|---|---|---|---|---|---|---|")
for (i in seq_len(nrow(paper_var))) {
  r <- paper_var[i, ]
  add("| %s | %d | %s | %s | %s | %s | %s |",
      r$config, r$n_papers,
      fmt1(r$mean_acc), fmt1(r$sd_acc), fmt1(r$min_acc),
      fmt1(r$pct_below_50), fmt3(r$mean_kappa))
}
add("")

# Worst papers per config
add("### 6.1 Worst 5 papers per config (`type` accuracy)")
add("")
for (cfg in configs) {
  d <- per_paper[per_paper$config == cfg, ]
  if (nrow(d) == 0) next
  d <- d[order(d$acc), ]
  add("**%s**", cfg)
  for (i in seq_len(min(5, nrow(d))))
    add("- %s: %.1f%% acc (n=%d, κ=%s)",
        d$paper_id[i], d$acc[i], d$n[i], fmt3(d$kappa[i]))
  add("")
}

# 7. Missingness ----------------------------------------------------------
add("## 7. Sentinel (`llm_error`) rate")
add("")
add("![sentinel rate](plots/sentinel_rate.png)")
add("")
add("Sentinel rate on `type` per config (NA only occurs on `data_granularity` / `data_format` for non-`data` files, which is structural — ignored).")
add("")
add("| config | %% sentinel on type |")
add("|---|---|")
for (i in seq_len(nrow(headline)))
  add("| %s | %.2f |", headline$config[i], headline$pct_sentinel[i])
add("")

# 8. Cross-config agreement -------------------------------------------------
add("## 8. Cross-config agreement (ignoring GT)")
add("")
for (f in FIELDS) {
  s <- cross_df[cross_df$field == f, ]
  if (nrow(s) == 0) next
  add("### %s — pairwise agreement (%%)", f)
  add("")
  add("![cross %s](plots/cross_config_%s.png)", f, f)
  add("")
  add("| | %s |", paste(configs, collapse = " | "))
  add("|%s|", paste(rep("---", length(configs) + 1), collapse = "|"))
  for (a in configs) {
    vals <- vapply(configs, function(b) {
      if (a == b) return(100)
      v <- s$pct_agree[(s$config_a == a & s$config_b == b) |
                       (s$config_a == b & s$config_b == a)]
      if (length(v) == 0) NA_real_ else v[1]
    }, numeric(1))
    add("| **%s** | %s |", a, paste(vapply(vals, fmt1, ""), collapse = " | "))
  }
  add("")
}

# 9. Format & model main effects --------------------------------------------
add("## 9. Format and model main effects on `type` accuracy")
add("")
models  <- sort(unique(merged$model))
formats <- c("json", "md", "plaintext")

main_effects_block <- function(metric_col, label) {
  add("### %s — Format effect within model", label)
  add("")
  add("| model | json | md | plaintext | spread |")
  add("|---|---|---|---|---|")
  for (mdl in models) {
    vals <- vapply(formats, function(fmt) {
      v <- headline[[metric_col]][headline$config == paste(mdl, fmt, sep = "_")]
      if (length(v) == 0) NA_real_ else v
    }, numeric(1))
    spr <- if (sum(!is.na(vals)) >= 2)
             max(vals, na.rm = TRUE) - min(vals, na.rm = TRUE) else NA
    add("| %s | %s | %s | %s | %s |", mdl,
        fmt1(vals[1]), fmt1(vals[2]), fmt1(vals[3]), fmt1(spr))
  }
  add("")

  add("### %s — Model effect within format", label)
  add("")
  add("| format | %s | diff |", paste(models, collapse = " | "))
  add("|%s|", paste(rep("---", length(models) + 2), collapse = "|"))
  for (fmt in formats) {
    vals <- vapply(models, function(mdl) {
      v <- headline[[metric_col]][headline$config == paste(mdl, fmt, sep = "_")]
      if (length(v) == 0) NA_real_ else v
    }, numeric(1))
    diff <- if (sum(!is.na(vals)) >= 2)
              max(vals, na.rm = TRUE) - min(vals, na.rm = TRUE) else NA
    add("| %s | %s | %s |", fmt,
        paste(vapply(vals, fmt1, ""), collapse = " | "),
        fmt1(diff))
  }
  add("")
}

main_effects_block("accuracy_fp", "File-pooled")
main_effects_block("accuracy_pa", "Paper-averaged")

writeLines(md, file.path(OUT_DIR, "report.md"))

# ── thesis report — 5 artifacts only ─────────────────────────────────────────
# Lean, claim-per-figure version for the thesis. No accuracy, no fp metrics in
# the headline; "other" excluded from F1.

# Winner = highest pa macro-F1 (≥80% paper coverage so a half-finished config
# can't win by sample bias)
n_papers_per_cfg <- vapply(configs, function(c)
  length(unique(merged$paper_id[merged$config == c])), integer(1))
eligible <- configs[n_papers_per_cfg >= 0.8 * max(n_papers_per_cfg)]
winner_idx <- which.max(headline$macro_f1_pa[headline$config %in% eligible])
winner <- headline$config[headline$config %in% eligible][winner_idx]

# Per-paper macro-F1 / micro-F1 / κ box plots
per_paper_box <- function(col, ylab, title, file, ylim = c(0, 100)) {
  png(file.path(PLOT_DIR, file), width = 1600, height = 900, res = 150)
  par(mar = c(10, 5, 4, 2))
  d <- per_paper
  d <- d[!is.na(d[[col]]), ]
  boxplot(d[[col]] ~ d$config, las = 2,
          col = cfg_cols[sort(unique(d$config))],
          ylab = ylab, main = title, ylim = ylim)
  dev.off()
}
if ("macro_f1" %in% names(per_paper)) {
  per_paper_box("macro_f1", "Per-paper macro-F1 %",
                "Per-paper macro-F1 distribution by config",
                "thesis_per_paper_macro_f1_box.png")
  per_paper_box("micro_f1", "Per-paper micro-F1 %",
                "Per-paper micro-F1 distribution by config",
                "thesis_per_paper_micro_f1_box.png")
  per_paper_box("kappa", "Per-paper κ",
                "Per-paper Cohen's κ distribution by config",
                "thesis_per_paper_kappa_box.png",
                ylim = c(-0.1, 1))
}

# Per-class F1 / recall / precision distribution (one box per class) for
# every config — paper-averaged distribution
if (nrow(per_class_type_paper_long) > 0) {
  cls_order <- sort(unique(per_class_type_paper_long$class))
  for (metric in c("f1", "recall", "precision")) {
    png(file.path(PLOT_DIR, sprintf("thesis_per_class_%s_box.png", metric)),
        width = 2200, height = 1100, res = 150)
    par(mar = c(11, 5, 4, 2))
    d <- per_class_type_paper_long
    d$grp <- paste(d$class, d$config, sep = " · ")
    grp_order <- as.vector(t(outer(cls_order, configs, paste, sep = " · ")))
    boxplot(d[[metric]] ~ factor(d$grp, levels = grp_order),
            las = 2, ylab = sprintf("Per-paper %s %%", metric),
            main = sprintf("Per-paper per-class %s — class × config", metric),
            col = rep(hcl.colors(length(cls_order), "Set 2"),
                      each = length(configs)),
            ylim = c(0, 100), cex.axis = 0.55)
    dev.off()
  }
}

# Top-3 deep-dive plots — κ / accuracy / macro-F1 histograms + size scatter,
# Landis–Koch shading on κ.
top3 <- headline$config[order(-headline$macro_f1_pa)][1:3]

plot_kappa_hist <- function(vals, file, title_suffix) {
  vals <- vals[!is.na(vals)]
  if (length(vals) == 0) return()
  png(file, width = 1200, height = 700, res = 150)
  on.exit(dev.off())
  par(mar = c(5, 4, 3, 1))
  kap_lo <- min(-0.1, floor(min(vals) / 0.05) * 0.05)
  kap_hi <- max(1.05, ceiling(max(vals) / 0.05) * 0.05)
  h <- hist(vals, breaks = seq(kap_lo, kap_hi, by = 0.05), plot = FALSE)
  ymax <- max(h$counts) + 1
  plot(NULL, xlim = c(kap_lo, kap_hi), ylim = c(0, ymax),
       xlab = "Cohen's κ (per paper)", ylab = "Number of papers",
       main = sprintf("%s  (mean=%.3f  median=%.3f)",
                      title_suffix, mean(vals), median(vals)), las = 1)
  rect(kap_lo, 0, 0.20, ymax, col = "#FFE5E5", border = NA)
  rect( 0.20, 0, 0.40, ymax, col = "#FFF3CD", border = NA)
  rect( 0.40, 0, 0.60, ymax, col = "#FFF9C4", border = NA)
  rect( 0.60, 0, 0.80, ymax, col = "#E8F5E9", border = NA)
  rect( 0.80, 0, 1.05, ymax, col = "#E3F2FD", border = NA)
  rect(h$breaks[-length(h$breaks)], 0, h$breaks[-1], h$counts,
       col = "#4C72B0", border = "white")
  abline(v = mean(vals),   col = "#C44E52", lwd = 2, lty = 2)
  abline(v = median(vals), col = "#55A868", lwd = 2, lty = 2)
  mtext(c("slight", "fair", "moderate", "substantial", "almost\nperfect"),
        side = 3, at = c(0.05, 0.30, 0.50, 0.70, 0.925),
        cex = 0.65, col = "grey50", line = -0.5)
  legend("topleft",
         legend = c(sprintf("Mean   %.3f", mean(vals)),
                    sprintf("Median %.3f", median(vals))),
         col = c("#C44E52", "#55A868"), lwd = 2, lty = 2, bty = "n")
}

plot_pct_hist <- function(vals, file, xlab, title_suffix) {
  vals <- vals[!is.na(vals)]
  if (length(vals) == 0) return()
  png(file, width = 1200, height = 700, res = 150)
  on.exit(dev.off())
  par(mar = c(5, 4, 3, 1))
  h <- hist(vals, breaks = seq(0, 100, by = 5), plot = FALSE)
  plot(NULL, xlim = c(0, 100), ylim = c(0, max(h$counts) + 1),
       xlab = xlab, ylab = "Number of papers",
       main = sprintf("%s  (mean=%.1f%%  median=%.1f%%)",
                      title_suffix, mean(vals), median(vals)), las = 1)
  rect(h$breaks[-length(h$breaks)], 0, h$breaks[-1], h$counts,
       col = "#4C72B0", border = "white")
  abline(v = mean(vals),   col = "#C44E52", lwd = 2, lty = 2)
  abline(v = median(vals), col = "#55A868", lwd = 2, lty = 2)
  legend("topleft",
         legend = c(sprintf("Mean   %.1f%%", mean(vals)),
                    sprintf("Median %.1f%%", median(vals))),
         col = c("#C44E52", "#55A868"), lwd = 2, lty = 2, bty = "n")
}

plot_size_vs_acc <- function(n_files, acc, file, title_suffix) {
  ok <- !is.na(n_files) & !is.na(acc)
  if (sum(ok) == 0) return()
  n_files <- n_files[ok]; acc <- acc[ok]
  png(file, width = 1200, height = 700, res = 150)
  on.exit(dev.off())
  par(mar = c(5, 4.5, 3.5, 1))
  plot(n_files, acc, log = "x", pch = 19, col = "#4C72B080", cex = 1.1,
       xlab = "Paper size (n files, log)", ylab = "Type accuracy (%)",
       main = title_suffix, las = 1, ylim = c(0, 100))
  abline(h = mean(acc), col = "#C44E52", lwd = 2, lty = 2)
  if (length(unique(n_files)) > 2) {
    lo <- tryCatch(loess(acc ~ log10(n_files)), error = function(e) NULL)
    if (!is.null(lo)) {
      xs <- exp(seq(log(min(n_files)), log(max(n_files)), length.out = 100))
      lines(xs, predict(lo, newdata = data.frame(n_files = xs)),
            col = "#55A868", lwd = 2)
    }
  }
}

for (cfg in top3) {
  d <- per_paper[per_paper$config == cfg, ]
  if (nrow(d) == 0) next
  safe <- safe_label(cfg)
  plot_kappa_hist(d$kappa,
                  file.path(PLOT_DIR, sprintf("thesis_kappa_dist_%s.png", safe)),
                  sprintf("Per-paper Cohen's κ — %s", cfg))
  plot_pct_hist(d$acc,
                file.path(PLOT_DIR, sprintf("thesis_acc_dist_%s.png", safe)),
                "Type accuracy (%)",
                sprintf("Per-paper type accuracy — %s", cfg))
  plot_pct_hist(d$macro_f1,
                file.path(PLOT_DIR, sprintf("thesis_macro_f1_dist_%s.png", safe)),
                "Per-paper macro-F1 (%)",
                sprintf("Per-paper macro-F1 — %s", cfg))
  plot_size_vs_acc(d$n, d$acc,
                   file.path(PLOT_DIR, sprintf("thesis_size_vs_acc_%s.png", safe)),
                   sprintf("Paper size vs type accuracy — %s", cfg))
}

tmd <- c(); tadd <- function(...) tmd <<- c(tmd, sprintf(...))

tadd("# Thesis report — type classification")
tadd("")
tadd("Generated %s. Paper-averaged (pa) metrics primary. All classes included (incl. `other`, which is the pool for non-research items, not just an LLM fallback).",
     format(Sys.time(), "%Y-%m-%d %H:%M"))
tadd("")

# 1. Headline ----------------------------------------------------------------
tadd("## 1. Headline — paper-averaged")
tadd("")
tadd("Decision unit = paper. Each paper contributes one score; large repositories do not dominate. Error rate = %% of files where the LLM returned the `llm_error` sentinel (parse failure / retry exhausted).")
tadd("")
tadd("| model | prompt | n papers | macro-F1 pa | micro-F1 pa | κ pa | error rate %% |")
tadd("|---|---|---|---|---|---|---|")
# Order: best-model first (by mean macro-F1 across its formats), then format
# (md → plaintext → json) inside each model
fmt_levels <- c("md", "plaintext", "json")
headline$model_lbl  <- sub("_[^_]+$", "", headline$config)
headline$fmt_lbl    <- sub("^.*_", "", headline$config)
mean_by_model <- tapply(headline$macro_f1_pa, headline$model_lbl, mean,
                        na.rm = TRUE)
model_order <- names(sort(mean_by_model, decreasing = TRUE))
for (mdl in model_order) {
  sub <- headline[headline$model_lbl == mdl, , drop = FALSE]
  sub <- sub[match(fmt_levels, sub$fmt_lbl), , drop = FALSE]
  sub <- sub[!is.na(sub$config), , drop = FALSE]
  for (i in seq_len(nrow(sub))) {
    r <- sub[i, ]
    tadd("| %s | %s | %d | %s | %s | %s | %.2f |",
         mdl, r$fmt_lbl, n_papers_per_cfg[r$config],
         fmt1(r$macro_f1_pa), fmt1(r$micro_f1_pa),
         fmt3(r$kappa_pa), r$pct_sentinel)
  }
}
tadd("")
tadd("**Best (≥80%% paper coverage): `%s`**", winner)
tadd("")

# 1.1 Prompt-format effect --------------------------------------------------
tadd("### 1.1 Prompt-format effect (macro-F1 pa)")
tadd("")
tadd("For every model, the three prompt formats are compared on the same 250-paper corpus. **Δ** = best-format minus worst-format within the model — measures how much format choice moves the score, holding the model fixed.")
tadd("")
tadd("| model | md | plaintext | json | best | worst | Δ |")
tadd("|---|---|---|---|---|---|---|")
fmt_eff <- data.frame()
for (mdl in model_order) {
  vals <- vapply(fmt_levels, function(f) {
    v <- headline$macro_f1_pa[headline$config == paste(mdl, f, sep = "_")]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  if (sum(!is.na(vals)) < 2) next
  best_f  <- fmt_levels[which.max(vals)]
  worst_f <- fmt_levels[which.min(vals)]
  delta   <- max(vals, na.rm = TRUE) - min(vals, na.rm = TRUE)
  tadd("| %s | %s | %s | %s | %s | %s | %s |",
       mdl, fmt1(vals[1]), fmt1(vals[2]), fmt1(vals[3]),
       best_f, worst_f, fmt1(delta))
  fmt_eff <- rbind(fmt_eff, data.frame(model = mdl, md = vals[1],
                                       plaintext = vals[2], json = vals[3],
                                       stringsAsFactors = FALSE))
}
tadd("")

if (nrow(fmt_eff) >= 2) {
  # Mean format effect: average each format's deviation from the within-model
  # mean. Removes the model-level baseline so only the format contribution
  # remains.
  fmt_eff$within_mean <- rowMeans(fmt_eff[, fmt_levels], na.rm = TRUE)
  fmt_dev <- sapply(fmt_levels, function(f) fmt_eff[[f]] - fmt_eff$within_mean)
  mean_dev <- colMeans(fmt_dev, na.rm = TRUE)
  sd_dev   <- apply(fmt_dev, 2, sd,  na.rm = TRUE)

  tadd("**Aggregated format effect across models** (deviation from each model's own mean macro-F1 pa):")
  tadd("")
  tadd("| format | mean Δ vs model-mean | SD |")
  tadd("|---|---|---|")
  for (f in fmt_levels) {
    tadd("| %s | %+.2f | %.2f |", f, mean_dev[f], sd_dev[f])
  }
  tadd("")

  # Stability of ranking — same best format across all models?
  best_by_model <- vapply(seq_len(nrow(fmt_eff)), function(i) {
    fmt_levels[which.max(unlist(fmt_eff[i, fmt_levels]))]
  }, character(1))
  consistent <- length(unique(best_by_model)) == 1
  tadd("Best format per model: %s. **%s** — format ranking is %s consistent across models.",
       paste(sprintf("%s → %s", fmt_eff$model, best_by_model), collapse = "; "),
       if (consistent) "Consistent" else "Inconsistent",
       if (consistent) "" else "not")
  tadd("")
}

# 2. Per-paper variability ---------------------------------------------------
tadd("## 2. Reliability — per-paper distribution")
tadd("")
tadd("![per-paper macro-F1](plots/thesis_per_paper_macro_f1_box.png)")
tadd("")
tadd("![per-paper micro-F1](plots/thesis_per_paper_micro_f1_box.png)")
tadd("")
tadd("![per-paper κ](plots/thesis_per_paper_kappa_box.png)")
tadd("")

if ("macro_f1" %in% names(per_paper)) {
  tadd("| config | n papers | median macro-F1 | IQR | min | median micro-F1 | median κ |")
  tadd("|---|---|---|---|---|---|---|")
  for (cfg in configs[order(-headline$macro_f1_pa[match(configs, headline$config)])]) {
    d <- per_paper[per_paper$config == cfg, ]
    if (nrow(d) == 0) next
    med   <- median(d$macro_f1, na.rm = TRUE)
    iqr   <- IQR(d$macro_f1,    na.rm = TRUE)
    mn    <- min(d$macro_f1,    na.rm = TRUE)
    medu  <- median(d$micro_f1, na.rm = TRUE)
    medk  <- median(d$kappa,    na.rm = TRUE)
    tadd("| %s | %d | %s | %s | %s | %s | %s |",
         cfg, nrow(d), fmt1(med), fmt1(iqr), fmt1(mn), fmt1(medu), fmt3(medk))
  }
  tadd("")
}

# 3. Per-class F1 heatmap (pa) -----------------------------------------------
tadd("## 3. Per-class F1 — paper-averaged")
tadd("")
tadd("![per-class F1 pa](plots/per_class_type_f1_pa.png)")
tadd("")
tadd("Hard classes drag the macro mean. Inspect which class limits each config.")
tadd("")
tadd("### 3.1 Per-paper per-class distributions (F1, recall, precision)")
tadd("")
tadd("Each box = distribution across papers; one box per (class × config). Shows whether good means come from consistent performance or from a few easy papers.")
tadd("")
tadd("![per-class F1 box](plots/thesis_per_class_f1_box.png)")
tadd("")
tadd("![per-class recall box](plots/thesis_per_class_recall_box.png)")
tadd("")
tadd("![per-class precision box](plots/thesis_per_class_precision_box.png)")
tadd("")

# 4. Confusion matrix (winner) ----------------------------------------------
tadd("## 4. Error structure — winner config")
tadd("")
tadd("Row-normalised confusion matrix, paper-averaged, for `%s`.", winner)
tadd("")
tadd("![confusion winner](plots/confusion_type_pa_%s.png)", winner)
tadd("")

# 5. Coverage caveat ---------------------------------------------------------
tadd("## 5. Coverage caveat")
tadd("")
tadd("| config | n papers run | %% of corpus | error rate %% |")
tadd("|---|---|---|---|")
n_max <- max(n_papers_per_cfg)
for (cfg in configs) {
  pct_cov <- round(n_papers_per_cfg[cfg] / n_max * 100, 1)
  sent <- headline$pct_sentinel[headline$config == cfg]
  tadd("| %s | %d | %s%% | %.2f |", cfg, n_papers_per_cfg[cfg],
       fmt1(pct_cov), sent)
}
tadd("")
tadd("Configs with < 100%% coverage ran on a non-random subset; their pa scores are not directly comparable to full-coverage configs.")
tadd("")

# 7. Top-3 deep-dive ---------------------------------------------------------
tadd("## 7. Top-3 configs — per-paper distributions")
tadd("")
tadd("For the three highest-scoring configs by macro-F1 pa: per-paper κ (with Landis–Koch shading), per-paper accuracy, per-paper macro-F1, and paper-size vs accuracy.")
tadd("")
for (cfg in top3) {
  d <- per_paper[per_paper$config == cfg, ]
  if (nrow(d) == 0) next
  safe <- safe_label(cfg)
  tadd("### %s", cfg)
  tadd("")
  tadd("- n papers = %d", nrow(d))
  tadd("- κ: mean %.3f, median %.3f, %% κ ≥ 0.8: %.1f%%",
       mean(d$kappa, na.rm = TRUE), median(d$kappa, na.rm = TRUE),
       mean(d$kappa >= 0.8, na.rm = TRUE) * 100)
  tadd("- accuracy: mean %.1f%%, median %.1f%%, %% papers <50%%: %.1f%%",
       mean(d$acc, na.rm = TRUE), median(d$acc, na.rm = TRUE),
       mean(d$acc < 50, na.rm = TRUE) * 100)
  tadd("- macro-F1: mean %.1f%%, median %.1f%%, IQR %.1f",
       mean(d$macro_f1, na.rm = TRUE), median(d$macro_f1, na.rm = TRUE),
       IQR(d$macro_f1, na.rm = TRUE))
  # size correlation
  ok <- !is.na(d$n) & !is.na(d$acc)
  rho <- if (sum(ok) > 5) cor(log(d$n[ok]), d$acc[ok], method = "spearman") else NA
  tadd("- Spearman ρ(log n_files, accuracy) = %s",
       if (is.na(rho)) "—" else sprintf("%.3f", rho))
  tadd("")
  tadd("![κ %s](plots/thesis_kappa_dist_%s.png)", cfg, safe)
  tadd("")
  tadd("![accuracy %s](plots/thesis_acc_dist_%s.png)", cfg, safe)
  tadd("")
  tadd("![macro-F1 %s](plots/thesis_macro_f1_dist_%s.png)", cfg, safe)
  tadd("")
  tadd("![size vs accuracy %s](plots/thesis_size_vs_acc_%s.png)", cfg, safe)
  tadd("")
}

writeLines(tmd, file.path(OUT_DIR, "thesis_report.md"))

cat(sprintf("\nWrote outputs to: %s\n", OUT_DIR))
for (f in sort(list.files(OUT_DIR))) cat("  ", f, "\n")
