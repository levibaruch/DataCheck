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
OUT_DIR  <- "results/eval/outputs/step2/comparison-new"
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
              "data_granularity", "granularity_source", "data_format",
              "prompt_nr")
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
cat(sprintf("Loaded %d rows · %d repositories · %d configs:\n  %s\n\n",
            nrow(merged), length(unique(merged$paper_id)),
            length(configs), paste(configs, collapse = ", ")))

# ── core metric helpers ──────────────────────────────────────────────────────

scorable <- function(sub, field, gt_field) {
  pred <- sub[[field]]; gt <- sub[[gt_field]]
  # Keep the llm_error sentinel: a failed classification is a wrong answer
  # (a miss for its true class), not an excluded row. Only genuinely missing
  # predictions (NA — file never classified) are dropped.
  ok <- !is.na(pred) & !is.na(gt)
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
  # llm_error is a prediction sink, not a real class — keep it in the matrix
  # (so it lowers real classes' recall) but never report it as its own row.
  cls <- setdiff(rownames(cm), SENTINEL)
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
  # llm_error is not a real class: an error row is a miss (FN for its true
  # class) but never a false positive, so exclude the sentinel from C.
  classes <- setdiff(sort(unique(c(sd$gt, sd$pred))), SENTINEL)
  tp <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred == cl)))
  fp <- sum(sapply(classes, function(cl) sum(sd$gt != cl & sd$pred == cl)))
  fn <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred != cl)))
  # Pooled-F1 form 2·ΣTP/(2·ΣTP+ΣFP+ΣFN) (identical to 2pr/(p+r)). It correctly
  # returns 0 — not NA — for a total-failure repo (ΣTP=0, ΣFP+ΣFN>0).
  denom <- 2 * tp + fp + fn
  if (denom > 0) 2 * tp / denom * 100 else NA_real_
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
  # paper-averaged — grouping mask must match scorable() so it aligns with sd
  pa <- do.call(rbind, lapply(split(sd, sub$paper_id[
      !is.na(sub$type) & !is.na(sub$type_gt)
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

  # prompt-failure rate: a prompt (= one (paper, prompt_nr) batch sent to the
  # LLM) failed if any file in it came back as the llm_error sentinel.
  pf  <- sub[!is.na(sub$prompt_nr), ]
  key <- paste(pf$paper_id, pf$prompt_nr, sep = "\r")
  prompt_fail <- if (length(key))
    mean(tapply(pf$type == SENTINEL, key, any, na.rm = TRUE)) * 100 else NA_real_
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
    pct_prompt_fail = prompt_fail,
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
  scor_mask <- !is.na(sub[[f]]) & !is.na(sub[[gt_field]])
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
    micro_f1 = round(micro_f1_from_sd(sd), 2),
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
  # Returns rows: (paper_id, class, precision, recall, f1) per paper.
  # Sentinel rows kept — they lower recall of the true class (a miss).
  sd <- sub[!is.na(sub[[field]]) & !is.na(sub[[gt_field]]), , drop = FALSE]
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
  # keep llm_error rows — they count as errors (type != type_gt)
  sd  <- sub[!is.na(sub$type) & !is.na(sub$type_gt), ]
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
cross_df <- if (length(cross) > 0) do.call(rbind, cross) else
            data.frame(field = character(), config_a = character(), config_b = character(),
                       n = integer(), pct_agree = numeric(), stringsAsFactors = FALSE)
write.csv(cross_df, file.path(OUT_DIR, "cross_config.csv"), row.names = FALSE)

# ── plots ────────────────────────────────────────────────────────────────────

PLOT_DIR <- file.path(OUT_DIR, "plots")
dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

# Winner = best macro-F1 pa among configs with ≥80% paper coverage (so a config
# can't win by sample bias). Defined here so plot blocks below can reference it.
n_papers_per_cfg <- vapply(configs, function(c)
  length(unique(merged$paper_id[merged$config == c])), integer(1))
eligible   <- configs[n_papers_per_cfg >= 0.8 * max(n_papers_per_cfg)]
winner_idx <- which.max(headline$macro_f1_pa[headline$config %in% eligible])
winner     <- headline$config[headline$config %in% eligible][winner_idx]

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
  image(seq_len(nc), seq_len(nr), t(norm)[, nr:1, drop = FALSE],
        col = cols, axes = FALSE, xlab = "", ylab = "", main = title)
  axis(1, at = seq_len(nc), labels = FALSE)
  text(seq_len(nc), par("usr")[3] - (nr * 0.02 + 0.3),
       labels = colnames(mat), srt = 45, adj = 1, xpd = TRUE, cex = 0.85)
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
  labels  <- c("acc (file-pooled)", "acc (repository-avg)",
               "macro-F1 (fp)", "macro-F1 (pa)")
  M <- as.matrix(headline[, metrics]); rownames(M) <- headline$config
  par(mar = c(10, 5, 4, 2))
  bp <- barplot(t(M), beside = TRUE, names.arg = rep("", nrow(M)),
                col = hcl.colors(length(metrics), "Set 2"),
                ylim = c(0, 105),
                ylab = "%", main = "Headline metrics by configuration (type classification)")
  text(colMeans(bp), par("usr")[3] - 3, labels = rownames(M),
       srt = 45, adj = 1, xpd = TRUE, cex = 0.85)
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

# 3b. Per-field micro-F1 heatmap — subclassification only (no `type`)
{
  sub_fields <- intersect(c("group", "data_granularity", "data_format"), FIELDS)
  M <- matrix(NA_real_, nrow = length(configs), ncol = length(sub_fields),
              dimnames = list(configs, sub_fields))
  for (cfg in configs) for (f in sub_fields) {
    v <- field_summary$micro_f1[field_summary$config == cfg & field_summary$field == f]
    if (length(v)) M[cfg, f] <- v
  }
  heatmap_pct(M, file.path(PLOT_DIR, "per_field_micro_f1_sub.png"),
              "Micro-F1 (%) — subclassification (config × field)",
              palette = c("white", "#238b45"))  # green, distinct from the blue macro-F1 maps
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
            "Per-class F1 (%) — type — repository-averaged")
heatmap_pct(build_class_mat("recall_pa"),
            file.path(PLOT_DIR, "per_class_type_recall_pa.png"),
            "Per-class recall (%) — type — repository-averaged")
heatmap_pct(build_class_mat("precision_pa"),
            file.path(PLOT_DIR, "per_class_type_precision_pa.png"),
            "Per-class precision (%) — type — repository-averaged")

# 5. Confusion matrix heatmap per config — file-pooled AND paper-averaged
# Paper-averaged: each paper's CM is row-normalised; then rows averaged across
# only the papers that contain that gt class (so large repos don't dominate).
for (cfg in configs) {
  sub <- merged[merged$config == cfg, , drop = FALSE]
  sd  <- scorable(sub, "type", "type_gt")
  cm  <- confusion(sd); if (is.null(cm)) next
  rn  <- rowSums(cm)
  norm <- cm / ifelse(rn == 0, 1, rn) * 100
  norm <- norm[setdiff(rownames(norm), SENTINEL), , drop = FALSE]  # drop empty gt row
  heatmap_pct(norm,
              file.path(PLOT_DIR, sprintf("confusion_type_fp_%s.png", cfg)),
              sprintf("Type confusion (row-norm %%, file-pooled) — %s", cfg),
              palette = c("white", "#08519c"))

  # paper-averaged — keep llm_error (an extra pred column = where misses go)
  scor <- sub[!is.na(sub$type) & !is.na(sub$type_gt), , drop = FALSE]
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
  pa_norm <- pa_norm[setdiff(rownames(pa_norm), SENTINEL), , drop = FALSE]
  heatmap_pct(pa_norm,
              file.path(PLOT_DIR, sprintf("confusion_type_pa_%s.png", cfg)),
              sprintf("Type confusion (row-norm %%, repository-avg) — %s", cfg),
              palette = c("white", "#08519c"))
}

# 6. LLM error rate on type (bar)
{
  png(file.path(PLOT_DIR, "llm_error_rate.png"),
      width = 1400, height = 800, res = 150)
  v <- headline$pct_prompt_fail; names(v) <- headline$config
  par(mar = c(10, 5, 4, 2))
  bp <- barplot(v, names.arg = rep("", length(v)), col = cfg_cols[names(v)],
                ylab = "% of prompts failed",
                main = "Prompt failure rate per configuration",
                ylim = c(0, max(v) * 1.15 + 1))
  text(bp, par("usr")[3] - max(v) * 0.04 - 0.2, labels = names(v),
       srt = 45, adj = 1, xpd = TRUE, cex = 0.85)
  text(bp, v, labels = sprintf("%.1f", v), pos = 3, cex = 0.8)
  dev.off()
}

# 7. Per-paper accuracy boxplot per config
if (nrow(per_paper) > 0) {
  png(file.path(PLOT_DIR, "per_paper_accuracy_box.png"),
      width = 1600, height = 900, res = 150)
  par(mar = c(10, 5, 4, 2))
  cfg_lv <- sort(unique(per_paper$config))
  boxplot(acc ~ config, data = per_paper, xaxt = "n", xlab = "",
          col = cfg_cols[cfg_lv],
          ylab = "Per-repository type accuracy (%)",
          main = "Per-repository accuracy distribution by configuration",
          ylim = c(0, 100))
  text(seq_along(cfg_lv), par("usr")[3] - 4, labels = cfg_lv,
       srt = 45, adj = 1, xpd = TRUE, cex = 0.85)
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

# 10. Cross-config agreement heatmaps per field (skip if <2 configs)
for (f in FIELDS) {
  if (length(configs) < 2) next
  s <- cross_df[cross_df$field == f, ]
  if (is.null(s) || NROW(s) == 0) next
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

# 11. Accuracy by classification method (type_source) ------------------------
# The deterministic rules are config-independent (drawn as reference lines);
# only the LLM-driven methods vary by model. Bar = type accuracy, label = % of
# the corpus that method handled (usage rate). Heavy reliance on the lower-
# accuracy `llm` path is the weak link prompt/model changes can move.
if ("type_source" %in% names(merged)) {
  src_acc <- function(df) {
    d <- df[!is.na(df$type_gt) & !is.na(df$type), ]
    if (nrow(d) == 0) return(c(acc = NA_real_, cov = 0, n = 0))
    c(acc = 100 * mean(d$type == d$type_gt), cov = nrow(d), n = nrow(d))
  }
  llm_methods  <- c("llm", "aggregate_llm")
  rule_methods <- c("fixed_filename_rule", "rmd_pair_rule", "fixed_ext_rule")
  meth_cols    <- c(llm = "#C44E52", aggregate_llm = "#4C72B0")

  # per-config accuracy + coverage for the two LLM methods
  Acc <- matrix(NA_real_, 2, length(configs), dimnames = list(llm_methods, configs))
  Cov <- Acc
  for (cfg in configs) {
    sub_cfg <- merged[merged$config == cfg, , drop = FALSE]
    tot <- sum(!is.na(sub_cfg$type_gt) & !is.na(sub_cfg$type))
    for (mth in llm_methods) {
      v <- src_acc(sub_cfg[!is.na(sub_cfg$type_source) &
                           sub_cfg$type_source == mth, ])
      Acc[mth, cfg] <- v["acc"]
      Cov[mth, cfg] <- if (tot > 0) 100 * v["cov"] / tot else NA_real_
    }
  }
  # pooled deterministic-rule accuracy (config-independent) for reference lines
  rule_acc <- vapply(rule_methods, function(mth) {
    unname(src_acc(merged[!is.na(merged$type_source) &
                          merged$type_source == mth, ])["acc"])
  }, numeric(1))

  png(file.path(PLOT_DIR, "thesis_method_accuracy.png"),
      width = 2050, height = 950, res = 150)
  par(mar = c(10, 5, 4, 15))
  bp <- barplot(Acc, beside = TRUE, names.arg = rep("", length(configs)),
                col = meth_cols[rownames(Acc)], ylim = c(0, 105),
                ylab = "Type accuracy (%)",
                main = "Type accuracy by classification method, per configuration")
  # usage-rate labels above each bar
  text(as.vector(bp), as.vector(Acc) + 1.5,
       labels = sprintf("%.0f%%", as.vector(Cov)),
       cex = 0.6, col = "grey30", xpd = TRUE)
  # angled config labels under each group
  text(colMeans(bp), -4, labels = configs, srt = 45, adj = 1,
       xpd = TRUE, cex = 0.8)
  # deterministic-rule reference lines
  rule_lty <- c(2, 3, 4)
  for (i in seq_along(rule_acc))
    abline(h = rule_acc[i], col = "grey40", lwd = 1.5, lty = rule_lty[i])
  legend(x = par("usr")[2] + 0.5, y = par("usr")[4],
         xpd = NA, bty = "n", cex = 0.78, ncol = 1,
         legend = sprintf("%s rule = %.1f%%", names(rule_acc), rule_acc),
         col = rep("grey40", length(rule_acc)),
         lty = rule_lty,
         lwd = rep(1.5, length(rule_acc)))
  mtext("number above bar = % of corpus handled by that method (usage rate)",
        side = 1, line = 8, cex = 0.7, col = "grey30")
  dev.off()
}

# 12. Data-granularity classification ----------------------------------------
# Binary + imbalanced, so accuracy alone hides minority-class performance — plot
# overall accuracy plus per-class recall, then a winner confusion matrix.
# data_format is omitted: it is rule-determined, not model-driven.
{
  gl <- "data_granularity"; glgt <- "data_granularity_gt"
  glcls <- c("individual", "combined")

  # per-config accuracy + per-class recall
  Mr <- matrix(NA_real_, 3, length(configs),
               dimnames = list(c("accuracy", paste0("recall: ", glcls)), configs))
  for (cfg in configs) {
    d <- merged[merged$config == cfg & !is.na(merged[[gl]]) &
                !is.na(merged[[glgt]]), ]
    if (nrow(d) == 0) next
    Mr["accuracy", cfg] <- 100 * mean(d[[gl]] == d[[glgt]])
    for (cl in glcls) {
      gtc <- d[d[[glgt]] == cl, ]
      Mr[paste0("recall: ", cl), cfg] <-
        if (nrow(gtc) > 0) 100 * mean(gtc[[gl]] == cl) else NA_real_
    }
  }
  bar_pal <- c("#4C72B0", "#DD8452", "#55A868")  # accuracy, recall individual, recall combined
  png(file.path(PLOT_DIR, "thesis_data_subfield_accuracy.png"),
      width = 1400, height = 950, res = 150)
  par(mar = c(10, 4.5, 4, 2))
  bp <- barplot(Mr, beside = TRUE, names.arg = rep("", length(configs)),
                col = bar_pal, ylim = c(0, 105), ylab = "%",
                main = "Data-granularity accuracy and per-class recall, per configuration")
  text(colMeans(bp), -5, labels = configs, srt = 45, adj = 1,
       xpd = TRUE, cex = 0.78)
  legend("bottomright", legend = rownames(Mr), fill = bar_pal,
         bty = "n", cex = 0.78)
  dev.off()

  # winner confusion matrix (row-normalised, file-pooled)
  d  <- merged[merged$config == winner & !is.na(merged[[gl]]) &
               !is.na(merged[[glgt]]), ]
  if (nrow(d) > 0) {
    lev <- sort(unique(c(d[[glgt]], d[[gl]])))
    cm  <- as.matrix(table(gt = factor(d[[glgt]], levels = lev),
                           pred = factor(d[[gl]], levels = lev)))
    rn  <- rowSums(cm)
    norm <- cm / ifelse(rn == 0, 1, rn) * 100
    heatmap_pct(norm,
                file.path(PLOT_DIR, sprintf("confusion_%s_%s.png", gl, winner)),
                sprintf("data_granularity confusion (row-norm %%) — %s", winner),
                palette = c("white", "#08519c"), width = 900, height = 800)
  }
}

# ── markdown report ──────────────────────────────────────────────────────────

md <- c(); add <- function(...) md <<- c(md, sprintf(...))

add("# Step 2 — in-depth comparison of configurations against GT")
add("")
add("Source `%s`  ·  GT `tests/ground_truth/osf/`  ·  Generated %s",
    ROOT, format(Sys.time(), "%Y-%m-%d %H:%M"))
add("Repositories **%d**  ·  Configurations **%d**  ·  Merged rows **%d**",
    length(unique(merged$paper_id)), length(configs), nrow(merged))
add("")
add("Configurations: %s", paste(configs, collapse = ", "))
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
add("Both **file-pooled (fp)** — all files counted once — and **repository-averaged (pa)** — metric per repository then averaged.")
add("")
add("`llm_error` files count as wrong (a miss for the true class), not excluded — so high-failure configurations are not rewarded for failing. Prompt-failure rate is the separate reliability metric.")
add("")
add("| configuration | n files | κ fp | κ pa | macro-F1 fp | macro-F1 pa | micro-F1 fp | micro-F1 pa | MCC fp | MCC pa | acc fp | acc pa | %% prompts failed |")
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
      r$pct_prompt_fail)
}
add("")

add("### 1.1 Macro/micro-F1 excluding `other`")
add("")
add("`other` is the LLM fallback bucket — its F1 is near-zero and disproportionately drags macro-F1 down. Rows in which **either** GT or pred is `other` are excluded.")
add("")
add("| configuration | macro-F1 fp | macro-F1 pa | micro-F1 fp | micro-F1 pa |")
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
add("![micro-F1 subclassification heatmap](plots/per_field_micro_f1_sub.png)")
add("")
pivot <- function(metric, dp = 1, label = metric) {
  add("### %s", label)
  add("")
  add("| configuration | %s |", paste(FIELDS, collapse = " | "))
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
add("File-pooled (fp): all files counted once. Repository-averaged (pa): metric per repository, then mean across repositories — large repos do not dominate.")
add("")
pivot("accuracy")
pivot("accuracy_pa")
pivot("macro_f1")
pivot("macro_f1_pa")
pivot("kappa", dp = 3)
pivot("kappa_pa", dp = 3)
pivot("pct_sentinel", dp = 2, label = "% files llm_error (per field)")
pivot("n_scored", dp = 0)
pivot("n_papers", dp = 0, label = "n_repositories")

# 3. Per-class metrics (type) -----------------------------------------------
add("## 3. Per-class metrics — `type`")
add("")
add("![per-class F1 file-pooled](plots/per_class_type_f1_fp.png)")
add("")
add("![per-class recall file-pooled](plots/per_class_type_recall_fp.png)")
add("")
add("![per-class precision file-pooled](plots/per_class_type_precision_fp.png)")
add("")
add("![per-class F1 repository-averaged](plots/per_class_type_f1_pa.png)")
add("")
add("![per-class recall repository-averaged](plots/per_class_type_recall_pa.png)")
add("")
add("![per-class precision repository-averaged](plots/per_class_type_precision_pa.png)")
add("")
classes <- sort(unique(per_class_type$class))
add("### 3.1 Per-class F1 (%%) by configuration")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
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

add("### 3.2 Per-class recall (%%) by configuration — how many true-class files were caught")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$recall[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.3 Per-class precision (%%) by configuration")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
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
add("### 3.4 Per-class F1 (%%) by configuration — repository-averaged")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$f1_pa[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.5 Per-class recall (%%) by configuration — repository-averaged")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
add("|%s|", paste(rep("---", length(classes) + 1), collapse = "|"))
for (cfg in configs) {
  vals <- vapply(classes, function(c) {
    v <- per_class_type$recall_pa[per_class_type$config == cfg & per_class_type$class == c]
    if (length(v) == 0) NA_real_ else v
  }, numeric(1))
  add("| %s | %s |", cfg, paste(vapply(vals, fmt1, ""), collapse = " | "))
}
add("")

add("### 3.6 Per-class precision (%%) by configuration — repository-averaged")
add("")
add("| configuration | %s |", paste(classes, collapse = " | "))
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
add("Row-normalised type confusion matrices (one per configuration) — file-pooled and repository-averaged.")
add("")
for (cfg in configs) {
  add("**%s — file-pooled**", cfg)
  add("")
  add("![confusion fp %s](plots/confusion_type_fp_%s.png)", cfg, cfg)
  add("")
  add("**%s — repository-averaged**", cfg)
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
add("Showing the 12 extensions with highest worst-case error across configurations.")
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

# 5.5 Accuracy by classification method (type_source) -----------------------
add("## 5.5 Accuracy by classification method (`type_source`)")
add("")
add("How files were classified (LLM vs deterministic rules) and the per-method accuracy. **Coverage** = share of all annotated files handled by that method within a configuration. Rules with 100%% accuracy and meaningful coverage are pure wins; LLM accuracy is the part that prompt/model changes can still move.")
add("")

if ("type_source" %in% names(merged)) {
  src_levels <- sort(unique(merged$type_source[
    !is.na(merged$type_source) &
      !merged$type_source %in% c("extension_rule", "sentinel_llm")
  ]))

  for (cfg in configs) {
    sub_cfg <- merged[merged$config == cfg, , drop = FALSE]
    total_n <- sum(!is.na(sub_cfg$type_gt) & !is.na(sub_cfg$type))
    if (total_n == 0) next

    add("**%s**", cfg)
    add("")
    add("| method | n files | coverage | type acc | group acc |")
    add("|---|---|---|---|---|")

    rows_out <- list()
    for (src in src_levels) {
      r  <- sub_cfg[!is.na(sub_cfg$type_source) & sub_cfg$type_source == src, ]
      nt <- sum(!is.na(r$type_gt) & !is.na(r$type))
      if (nt == 0) next
      tacc <- 100 * sum(r$type_gt == r$type, na.rm = TRUE) / nt
      gr   <- r[!is.na(r$group_gt) & !is.na(r$group), ]
      gacc <- if (nrow(gr) > 0) 100 * sum(gr$group_gt == gr$group) / nrow(gr) else NA_real_
      cov  <- 100 * nt / total_n
      rows_out[[src]] <- c(n = nt, cov = cov, tacc = tacc, gacc = gacc)
    }
    if (length(rows_out) == 0) { add(""); next }

    ord <- order(-vapply(rows_out, function(x) x["n"], numeric(1)))
    for (k in ord) {
      src <- names(rows_out)[k]; v <- rows_out[[k]]
      add("| %s | %d | %s%% | %s%% | %s%% |",
          src, as.integer(v["n"]),
          fmt1(v["cov"]), fmt1(v["tacc"]), fmt1(v["gacc"]))
    }
    # Total row
    all_t  <- sub_cfg[!is.na(sub_cfg$type_gt) & !is.na(sub_cfg$type), ]
    fp_t   <- 100 * sum(all_t$type_gt == all_t$type) / nrow(all_t)
    all_g  <- sub_cfg[!is.na(sub_cfg$group_gt) & !is.na(sub_cfg$group), ]
    fp_g   <- if (nrow(all_g) > 0) 100 * sum(all_g$group_gt == all_g$group) / nrow(all_g) else NA_real_
    add("| **TOTAL** | **%d** | **100.0%%** | **%s%%** | **%s%%** |",
        nrow(all_t), fmt1(fp_t), fmt1(fp_g))
    add("")
  }
} else {
  add("_`type_source` column not available._")
  add("")
}

# 6. Per-paper variability ---------------------------------------------------
add("## 6. Per-repository variability (`type` accuracy)")
add("")
add("![per-paper accuracy](plots/per_paper_accuracy_box.png)")
add("")
add("| configuration | n repositories | mean acc | SD acc | min acc | %% repositories <50%% | mean κ |")
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
add("### 6.1 Worst 5 repositories per configuration (`type` accuracy)")
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

# 7. Prompt failure rate ---------------------------------------------------
add("## 7. Prompt failure rate")
add("")
add("![prompt failure rate](plots/llm_error_rate.png)")
add("")
add("Prompt failure rate per configuration = %% of prompts (one `(repository, prompt_nr)` batch sent to the LLM) where at least one file came back as `llm_error` (parse failure / retry exhausted).")
add("")
add("| configuration | %% prompts failed |")
add("|---|---|")
for (i in seq_len(nrow(headline)))
  add("| %s | %.2f |", headline$config[i], headline$pct_prompt_fail[i])
add("")

# 8. Cross-configuration agreement -------------------------------------------------
add("## 8. Cross-configuration agreement (ignoring GT)")
add("")
for (f in FIELDS) {
  if (length(configs) < 2) next
  s <- cross_df[cross_df$field == f, ]
  if (is.null(s) || NROW(s) == 0) next
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
main_effects_block("accuracy_pa", "Repository-averaged")

writeLines(md, file.path(OUT_DIR, "report.md"))

# ── thesis report — 5 artifacts only ─────────────────────────────────────────
# Lean, claim-per-figure version for the thesis. No accuracy, no fp metrics in
# the headline; "other" excluded from F1.

# Winner = highest pa macro-F1 (≥80% paper coverage so a half-finished config
# can't win by sample bias) — computed at the top of the plots section

# Per-paper macro-F1 / micro-F1 / κ are drawn as a combined reliability panel
# in the thesis figures section below (see figure C).

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
            las = 2, xlab = "", ylab = sprintf("Per-repository %s %%", metric),
            main = sprintf("Per-repository per-class %s — class × configuration", metric),
            col = rep(hcl.colors(length(cls_order), "Set 2"),
                      each = length(configs)),
            ylim = c(0, 100), cex.axis = 0.55)
    dev.off()
  }
}

# Top-3 deep-dive plots — κ / accuracy / macro-F1 histograms + size scatter
# (macro-F1 and micro-F1 vs repository size).
top3 <- headline$config[order(-headline$macro_f1_pa)][1:3]

plot_macro_f1_hist <- function(vals, file, title_suffix) {
  vals <- vals[!is.na(vals)]
  if (length(vals) == 0) return()
  png(file, width = 1200, height = 700, res = 150)
  on.exit(dev.off())
  par(mar = c(5, 4, 3, 1))
  h <- hist(vals, breaks = seq(0, 100, by = 5), plot = FALSE)
  ymax <- max(h$counts) + 1
  plot(NULL, xlim = c(0, 100), ylim = c(0, ymax),
       xlab = "Macro F1 (per paper)", ylab = "Number of papers",
       main = sprintf("%s  (mean=%.1f  median=%.1f)",
                      title_suffix, mean(vals), median(vals)), las = 1)
  rect(h$breaks[-length(h$breaks)], 0, h$breaks[-1], h$counts,
       col = "#4C72B0", border = "white")
  abline(v = mean(vals),   col = "#C44E52", lwd = 2, lty = 2)
  abline(v = median(vals), col = "#55A868", lwd = 2, lty = 2)
  legend("topleft",
         legend = c(sprintf("Mean   %.1f", mean(vals)),
                    sprintf("Median %.1f", median(vals))),
         col = c("#C44E52", "#55A868"), lwd = 2, lty = 2, bty = "n")
}

plot_size_vs_metric <- function(n_files, y, file, title_suffix, ylab) {
  ok <- !is.na(n_files) & !is.na(y)
  if (sum(ok) == 0) return()
  n_files <- n_files[ok]; y <- y[ok]
  png(file, width = 1200, height = 700, res = 150)
  on.exit(dev.off())
  par(mar = c(5, 4.5, 3.5, 1))
  plot(n_files, y, log = "x", pch = 19, col = "#4C72B080", cex = 1.1,
       xlab = "Repository size (n files, log)", ylab = ylab,
       main = title_suffix, las = 1, ylim = c(0, 100))
  abline(h = mean(y), col = "#C44E52", lwd = 2, lty = 2)
  if (length(unique(n_files)) > 2) {
    lo <- tryCatch(loess(y ~ log10(n_files)), error = function(e) NULL)
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
  plot_macro_f1_hist(d$macro_f1,
                  file.path(PLOT_DIR, sprintf("thesis_macro_f1_dist_%s.png", safe)),
                  sprintf("Per-paper Macro F1 — %s", cfg))
  plot_size_vs_metric(d$n, d$macro_f1,
                   file.path(PLOT_DIR, sprintf("thesis_size_vs_macro_f1_%s.png", safe)),
                   sprintf("Repository size vs macro-F1 — %s", cfg), "Macro-F1 (%)")
  plot_size_vs_metric(d$n, d$micro_f1,
                   file.path(PLOT_DIR, sprintf("thesis_size_vs_micro_f1_%s.png", safe)),
                   sprintf("Repository size vs micro-F1 — %s", cfg), "Micro-F1 (%)")
}

# ── repackaged thesis figures ────────────────────────────────────────────────
# One story per figure: a ranked headline, the format effect, a reliability
# panel, and a top-3 distribution grid — replacing the wall of single plots.

fmt_levels  <- c("md", "plaintext", "json")
model_of    <- function(cfg) sub("_[^_]+$", "", cfg)
model_lvls  <- unique(model_of(configs))
model_cols  <- setNames(hcl.colors(length(model_lvls), "Dark 3"), model_lvls)

# A. Headline ranking — configs sorted by macro-F1 pa, paired macro/micro-F1
#    bars (equal- vs frequency-weighted), κ (primary) + prompt-fail annotated
{
  hr <- headline[order(headline$macro_f1_pa), ]   # ascending → best on top (horiz)
  M  <- rbind(`macro-F1` = hr$macro_f1_pa,
              `micro-F1` = hr$micro_f1_pa,
              `κ×100`    = hr$kappa_pa * 100)
  bar_cols <- c("macro-F1" = "#4C72B0", "micro-F1" = "#DD8452", "κ×100" = "#55A868")
  png(file.path(PLOT_DIR, "thesis_headline_ranking.png"),
      width = 1700, height = 1100, res = 150)
  par(mar = c(7, 11, 4, 3))
  bp <- barplot(M, beside = TRUE, horiz = TRUE, names.arg = hr$config, las = 1,
                col = bar_cols, xlim = c(0, 100), cex.names = 0.85,
                xlab = "macro-F1 / micro-F1 (%)   ·   Cohen's κ (×100)",
                main = "Configurations ranked by macro-F1 (repository-averaged)")
  text(M[1, ], bp[1, ], sprintf("%.1f", M[1, ]), pos = 4, cex = 0.65, xpd = TRUE)
  text(M[2, ], bp[2, ], sprintf("%.1f", M[2, ]), pos = 4, cex = 0.65, xpd = TRUE)
  text(M[3, ], bp[3, ], sprintf("κ=%.2f", hr$kappa_pa), pos = 4, cex = 0.65, xpd = TRUE)
  legend(x = 50, y = par("usr")[3] - diff(par("usr")[3:4]) * 0.13,
         legend = names(bar_cols), fill = bar_cols, horiz = TRUE, xjust = 0.5,
         bty = "n", cex = 0.85, xpd = NA)
  dev.off()
}

# B. Format effect — macro-F1 and micro-F1 pa across md → plaintext → json,
#    one line per model; two panels (equal- vs frequency-weighted)
{
  effect_mat <- function(metric) sapply(model_lvls, function(m)
    vapply(fmt_levels, function(f) {
      v <- headline[[metric]][headline$config == paste(m, f, sep = "_")]
      if (length(v)) v else NA_real_
    }, numeric(1)))
  Mmac <- effect_mat("macro_f1_pa")
  Mmic <- effect_mat("micro_f1_pa")
  # shared y-axis across both panels so the size of the format effect is
  # directly comparable between macro- and micro-F1
  yl <- range(c(Mmac, Mmic), na.rm = TRUE); yl <- yl + c(-1, 1) * diff(yl) * 0.08
  png(file.path(PLOT_DIR, "thesis_format_effect.png"),
      width = 1700, height = 850, res = 150)
  par(mfrow = c(1, 2), mar = c(4, 5, 3, 1), oma = c(4, 0, 2, 0))
  for (pn in list(list(M = Mmac, lab = "macro-F1 (repository-averaged) %"),
                  list(M = Mmic, lab = "micro-F1 (repository-averaged) %"))) {
    plot(NULL, xlim = c(0.9, 3.1), ylim = yl, xaxt = "n",
         xlab = "", ylab = pn$lab, las = 1)
    axis(1, at = 1:3, labels = fmt_levels)
    for (m in model_lvls)
      lines(1:3, pn$M[, m], col = model_cols[m], lwd = 2, type = "b", pch = 19)
  }
  mtext("Prompt-format effect by model", side = 3, outer = TRUE,
        cex = 1.1, font = 2)
  par(fig = c(0, 1, 0, 1), oma = c(0, 0, 0, 0), mar = c(0, 0, 0, 0), new = TRUE)
  plot(0, 0, type = "n", axes = FALSE, xlab = "", ylab = "")
  legend("bottom", legend = model_lvls, col = model_cols, lwd = 2, pch = 19,
         horiz = TRUE, bty = "n", cex = 0.85, inset = c(0, 0.01))
  dev.off()
}

# C. Reliability panel — per-paper macro-F1 / micro-F1 / κ in one 1×3 figure
if (nrow(per_paper) > 0 && "macro_f1" %in% names(per_paper)) {
  cfg_lv <- sort(unique(per_paper$config))
  panels <- list(
    list(col = "macro_f1", lab = "Per-repository macro-F1 %", yl = c(0, 100)),
    list(col = "micro_f1", lab = "Per-repository micro-F1 %", yl = c(0, 100)),
    list(col = "kappa",    lab = "Per-repository κ",          yl = c(-0.1, 1)))
  png(file.path(PLOT_DIR, "thesis_reliability_panel.png"),
      width = 2400, height = 950, res = 150)
  par(mfrow = c(1, 3), mar = c(10, 4.5, 4, 1), oma = c(0, 0, 2, 0))
  for (p in panels) {
    d <- per_paper[!is.na(per_paper[[p$col]]), ]
    boxplot(d[[p$col]] ~ d$config, xaxt = "n", xlab = "",
            col = cfg_cols[cfg_lv], ylab = p$lab, ylim = p$yl)
    text(seq_along(cfg_lv), par("usr")[3] - diff(p$yl) * 0.04,
         labels = cfg_lv, srt = 45, adj = 1, xpd = TRUE, cex = 0.8)
  }
  mtext("Per-repository reliability by configuration", outer = TRUE, cex = 1.1, font = 2)
  dev.off()
}

# D. Top-3 grid — rows = top-3 configs, cols = κ / accuracy / macro-F1 hists
{
  panel_hist <- function(vals, breaks, xlim, xlab) {
    vals <- vals[!is.na(vals)]
    h <- hist(vals, breaks = breaks, plot = FALSE)
    ymax <- max(h$counts, 1) + 1
    plot(NULL, xlim = xlim, ylim = c(0, ymax), xlab = xlab,
         ylab = "n repositories", las = 1)
    rect(h$breaks[-length(h$breaks)], 0, h$breaks[-1], h$counts,
         col = "#4C72B0", border = "white")
    abline(v = mean(vals),   col = "#C44E52", lwd = 2, lty = 2)
    abline(v = median(vals), col = "#55A868", lwd = 2, lty = 2)
    legend("topleft", bty = "n", cex = 0.75,
           legend = sprintf(c("mean %.2f", "median %.2f"),
                            c(mean(vals), median(vals))),
           col = c("#C44E52", "#55A868"), lwd = 2, lty = 2)
  }
  png(file.path(PLOT_DIR, "thesis_top3_grid.png"),
      width = 2100, height = 1850, res = 150)
  par(mfrow = c(3, 3), mar = c(4, 4, 3, 1), oma = c(0, 3, 3, 0))
  for (cfg in top3) {
    d <- per_paper[per_paper$config == cfg, ]
    if (nrow(d) == 0) { plot.new(); plot.new(); plot.new(); next }
    klo <- min(-0.1, floor(min(d$kappa, na.rm = TRUE) / 0.05) * 0.05)
    panel_hist(d$kappa, seq(klo, 1, 0.05), c(klo, 1), "Cohen's κ")
    mtext(cfg, side = 2, line = 4, cex = 0.8, font = 2)
    panel_hist(d$acc,      seq(0, 100, 5), c(0, 100), "accuracy %")
    panel_hist(d$macro_f1, seq(0, 100, 5), c(0, 100), "macro-F1 %")
  }
  mtext(c("Cohen's κ", "Accuracy", "macro-F1"), side = 3, outer = TRUE,
        at = c(1/6, 3/6, 5/6), cex = 0.95, font = 2)
  mtext("Top-3 configurations — per-repository distributions", side = 3, outer = TRUE,
        line = 1.4, cex = 1.1, font = 2)
  dev.off()
}

tmd <- c(); tadd <- function(...) tmd <<- c(tmd, sprintf(...))

tadd("# Thesis report — type classification")
tadd("")
tadd("Generated %s. Repository-averaged (pa) metrics primary. All classes included (incl. `other`, which is the pool for non-research items, not just an LLM fallback).",
     format(Sys.time(), "%Y-%m-%d %H:%M"))
tadd("")
tadd("**`llm_error` files count as wrong** (a failed classification is a miss for its true class, lowering recall — not an excluded row). Earlier exclusion inflated high-failure configurations; counting them is the honest comparison. Per-prompt reliability is reported separately as the prompt-failure rate.")
tadd("")

# 1. Headline ----------------------------------------------------------------
tadd("## 1. Headline — repository-averaged")
tadd("")
tadd("Decision unit = repository. Each repository contributes one score; large repositories do not dominate. Prompt failure rate = %% of prompts (one `(repository, prompt_nr)` LLM batch) with at least one `llm_error` file (parse failure / retry exhausted).")
tadd("")
tadd("| model | prompt | n repositories | macro-F1 pa | micro-F1 pa | κ pa | prompts failed %% |")
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
         fmt3(r$kappa_pa), r$pct_prompt_fail)
  }
}
tadd("")
tadd("![headline ranking](plots/thesis_headline_ranking.png)")
tadd("")
tadd("**Best (≥80%% repository coverage): `%s`**", winner)
tadd("")

# 1.1 Prompt-format effect --------------------------------------------------
tadd("### 1.1 Prompt-format effect")
tadd("")
tadd("For every model, the three prompt formats are compared on the same 250-repository corpus. **Δ** = best-format minus worst-format within the model — measures how much format choice moves the score, holding the model fixed. Reported for both **macro-F1** (every class weighted equally) and **micro-F1** (weighted by class frequency).")
tadd("")
tadd("![format effect](plots/thesis_format_effect.png)")
tadd("")

# Per-metric format-effect tables (per-model spread + aggregated deviation)
fmt_effect_tables <- function(metric, metric_lab) {
  tadd("#### %s", metric_lab)
  tadd("")
  tadd("| model | md | plaintext | json | best | worst | Δ |")
  tadd("|---|---|---|---|---|---|---|")
  fe <- data.frame()
  for (mdl in model_order) {
    vals <- vapply(fmt_levels, function(f) {
      v <- headline[[metric]][headline$config == paste(mdl, f, sep = "_")]
      if (length(v) == 0) NA_real_ else v
    }, numeric(1))
    if (sum(!is.na(vals)) < 2) next
    best_f  <- fmt_levels[which.max(vals)]
    worst_f <- fmt_levels[which.min(vals)]
    delta   <- max(vals, na.rm = TRUE) - min(vals, na.rm = TRUE)
    tadd("| %s | %s | %s | %s | %s | %s | %s |",
         mdl, fmt1(vals[1]), fmt1(vals[2]), fmt1(vals[3]),
         best_f, worst_f, fmt1(delta))
    fe <- rbind(fe, data.frame(model = mdl, md = vals[1],
                               plaintext = vals[2], json = vals[3],
                               stringsAsFactors = FALSE))
  }
  tadd("")
  if (nrow(fe) >= 2) {
    # Average each format's deviation from the within-model mean — removes the
    # model-level baseline so only the format contribution remains.
    fe$within_mean <- rowMeans(fe[, fmt_levels], na.rm = TRUE)
    dev <- sapply(fmt_levels, function(f) fe[[f]] - fe$within_mean)
    mean_dev <- colMeans(dev, na.rm = TRUE)
    sd_dev   <- apply(dev, 2, sd, na.rm = TRUE)
    tadd("**Aggregated %s effect across models** (deviation from each model's own mean):", metric_lab)
    tadd("")
    tadd("| format | mean Δ vs model-mean | SD |")
    tadd("|---|---|---|")
    for (f in fmt_levels) tadd("| %s | %+.2f | %.2f |", f, mean_dev[f], sd_dev[f])
    tadd("")
    best_by_model <- vapply(seq_len(nrow(fe)), function(i)
      fmt_levels[which.max(unlist(fe[i, fmt_levels]))], character(1))
    consistent <- length(unique(best_by_model)) == 1
    tadd("Best format per model: %s. **%s** — format ranking is %s consistent across models.",
         paste(sprintf("%s → %s", fe$model, best_by_model), collapse = "; "),
         if (consistent) "Consistent" else "Inconsistent",
         if (consistent) "" else "not")
    tadd("")
  }
}
fmt_effect_tables("macro_f1_pa", "macro-F1")
fmt_effect_tables("micro_f1_pa", "micro-F1")

# 2. Per-paper variability ---------------------------------------------------
tadd("## 2. Reliability — per-repository distribution")
tadd("")
tadd("![reliability panel](plots/thesis_reliability_panel.png)")
tadd("")

if ("macro_f1" %in% names(per_paper)) {
  tadd("| configuration | n repositories | median macro-F1 | IQR | min | median micro-F1 | median κ |")
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
tadd("## 3. Per-class F1 — repository-averaged")
tadd("")
tadd("![per-class F1 pa](plots/per_class_type_f1_pa.png)")
tadd("")
tadd("Hard classes drag the macro mean. Inspect which class limits each configuration.")
tadd("")
tadd("### 3.1 Per-repository per-class distributions (F1, recall, precision)")
tadd("")
tadd("Each box = distribution across repositories; one box per (class × configuration). Shows whether good means come from consistent performance or from a few easy repositories.")
tadd("")
tadd("![per-class F1 box](plots/thesis_per_class_f1_box.png)")
tadd("")
tadd("![per-class recall box](plots/thesis_per_class_recall_box.png)")
tadd("")
tadd("![per-class precision box](plots/thesis_per_class_precision_box.png)")
tadd("")

# 4. Confusion matrix (winner) ----------------------------------------------
tadd("## 4. Error structure — winner configuration")
tadd("")
tadd("Row-normalised confusion matrix, repository-averaged, for `%s`.", winner)
tadd("")
tadd("![confusion winner](plots/confusion_type_pa_%s.png)", winner)
tadd("")

# 4.1 Data-granularity classification ----------------------------------------
if (file.exists(file.path(PLOT_DIR, "thesis_data_subfield_accuracy.png"))) {
  tadd("### 4.1 Data-granularity classification")
  tadd("")
  tadd("`data_granularity` (individual vs combined) is scored only on files whose true type is `data`. It is binary and imbalanced, so overall accuracy is shown alongside per-class recall — a high accuracy with low minority-class recall means the model defaults to the majority label. (`data_format` is rule-determined, not model-driven, so it is not analysed here.)")
  tadd("")
  tadd("![data-granularity accuracy](plots/thesis_data_subfield_accuracy.png)")
  tadd("")
  fp <- sprintf("plots/confusion_data_granularity_%s.png", winner)
  if (file.exists(file.path(OUT_DIR, fp)))
    tadd("![data_granularity confusion](%s)", fp)
  tadd("")
}

# 5. Coverage caveat ---------------------------------------------------------
tadd("## 5. Coverage caveat")
tadd("")
tadd("| configuration | n repositories run | %% of corpus | prompts failed %% |")
tadd("|---|---|---|---|")
n_max <- max(n_papers_per_cfg)
for (cfg in configs) {
  pct_cov <- round(n_papers_per_cfg[cfg] / n_max * 100, 1)
  pfail <- headline$pct_prompt_fail[headline$config == cfg]
  tadd("| %s | %d | %s%% | %.2f |", cfg, n_papers_per_cfg[cfg],
       fmt1(pct_cov), pfail)
}
tadd("")
tadd("Configurations with < 100%% coverage ran on a non-random subset; their pa scores are not directly comparable to full-coverage configurations.")
tadd("")

# 6. Accuracy by classification method --------------------------------------
if (file.exists(file.path(PLOT_DIR, "thesis_method_accuracy.png"))) {
  tadd("## 6. Accuracy by classification method")
  tadd("")
  tadd("DataCheck assigns each file a type via one of several methods (`type_source`). The deterministic rules (`fixed_filename_rule`, `rmd_pair_rule`, `fixed_ext_rule`) are configuration-independent and near-perfect, shown as reference lines. Only the LLM-driven methods vary by model: `aggregate_llm` (folder-level) and the direct per-file `llm` path. The number above each bar is the share of the corpus that method handled.")
  tadd("")
  tadd("![method accuracy](plots/thesis_method_accuracy.png)")
  tadd("")
  tadd("The per-file `llm` path is the weakest method by a wide margin — when a file falls through to it rather than being resolved by a rule or the folder-level aggregate, accuracy drops sharply. This is the part of the pipeline that prompt and model changes can still move.")
  tadd("")
}

# 7. Top-3 deep-dive ---------------------------------------------------------
tadd("## 7. Top-3 configurations — per-repository distributions")
tadd("")
tadd("For the three highest-scoring configurations by macro-F1 pa: per-repository κ, accuracy, and macro-F1 distributions in one grid, then repository-size vs macro-/micro-F1 per configuration.")
tadd("")
tadd("![top-3 distribution grid](plots/thesis_top3_grid.png)")
tadd("")

# Repository-size vs per-repository metric. The naive unweighted Spearman over
# all repos is dominated by tiny repos (a ≤3-file repo can only score 0 or 100
# and clusters at the ceiling), so it shows a spurious negative ρ. We report the
# robust picture instead: Spearman on repos with ≥ MIN_FILES_STABLE files (where
# the metric is meaningful), the file-count-weighted Pearson on log size, and the
# naive ρ flagged as an artifact for transparency.
MIN_FILES_STABLE <- 20
size_corr_lines <- function(n, y, ylab, min_files = MIN_FILES_STABLE) {
  ok <- !is.na(n) & !is.na(y); n <- n[ok]; y <- y[ok]
  if (length(n) < 6) return(sprintf("Size vs %s: n < 6, not tested.", ylab))
  out <- character(0)
  keep <- n >= min_files
  if (sum(keep) >= 6) {
    ct <- suppressWarnings(cor.test(log(n[keep]), y[keep], method = "spearman"))
    pstr <- if (is.na(ct$p.value)) "p = n/a" else if (ct$p.value < 0.001) "p < 0.001"
            else sprintf("p = %.3f", ct$p.value)
    verdict <- if (!is.na(ct$p.value) && ct$p.value < 0.05) "significant"
               else "not significant — no size effect"
    out <- c(out, sprintf("Spearman ρ(size, %s), repos with ≥%d files: ρ = %.3f, %s, n = %d — %s",
                          ylab, min_files, unname(ct$estimate), pstr, sum(keep), verdict))
  }
  w <- n; lx <- log(n); wm <- function(v) sum(v * w) / sum(w)
  den <- sqrt(wm((lx - wm(lx))^2) * wm((y - wm(y))^2))
  rw  <- if (den > 0) wm((lx - wm(lx)) * (y - wm(y))) / den else NA_real_
  out <- c(out, sprintf("File-weighted Pearson(log size, %s) = %.3f (weights = n files)", ylab, rw))
  ctall <- suppressWarnings(cor.test(log(n), y, method = "spearman"))
  out <- c(out, sprintf(paste0("Unweighted all-repo ρ = %.3f (n = %d) — small-n artifact, ",
                               "not a real effect: ≤3-file repos take only 0 or 100 and cluster ",
                               "at the ceiling; restricting to ≥%d files removes it."),
                        unname(ctall$estimate), length(n), min_files))
  out
}

for (cfg in top3) {
  d <- per_paper[per_paper$config == cfg, ]
  if (nrow(d) == 0) next
  safe <- safe_label(cfg)
  tadd("### %s", cfg)
  tadd("")
  tadd("- n repositories = %d", nrow(d))
  tadd("- κ: mean %.3f, median %.3f, %% κ ≥ 0.8: %.1f%%",
       mean(d$kappa, na.rm = TRUE), median(d$kappa, na.rm = TRUE),
       mean(d$kappa >= 0.8, na.rm = TRUE) * 100)
  tadd("- accuracy: mean %.1f%%, median %.1f%%, %% repositories <50%%: %.1f%%",
       mean(d$acc, na.rm = TRUE), median(d$acc, na.rm = TRUE),
       mean(d$acc < 50, na.rm = TRUE) * 100)
  tadd("- macro-F1: mean %.1f%%, median %.1f%%, IQR %.1f",
       mean(d$macro_f1, na.rm = TRUE), median(d$macro_f1, na.rm = TRUE),
       IQR(d$macro_f1, na.rm = TRUE))
  # size correlation — robust to small-repo ceiling artifact (see helper)
  for (ln in size_corr_lines(d$n, d$macro_f1, "macro-F1")) tadd("- %s", ln)
  for (ln in size_corr_lines(d$n, d$micro_f1, "micro-F1")) tadd("- %s", ln)
  tadd("")
  tadd("![per-paper κ %s](plots/thesis_kappa_dist_%s.png)", cfg, safe)
  tadd("")
  tadd("![size vs macro-F1 %s](plots/thesis_size_vs_macro_f1_%s.png)", cfg, safe)
  tadd("")
  tadd("![size vs micro-F1 %s](plots/thesis_size_vs_micro_f1_%s.png)", cfg, safe)
  tadd("")
}

writeLines(tmd, file.path(OUT_DIR, "thesis_report.md"))

# ── LaTeX table: macro / micro-F1 per config (all configs) ───────────────────
# Δ = macro − micro (equal-class-weight minus frequency-weight). Grouped by
# model (best model first), prompt formats md → plaintext → json within each.
# Requires \usepackage{booktabs} in the thesis preamble. \input{} this file.
{
  tex <- c(
    "% Auto-generated by runners/eval/compare_step2_outputs.R — do not edit by hand.",
    "% Needs \\usepackage{booktabs}.",
    "\\begin{table}[ht]",
    "  \\centering",
    "  \\caption{Type-classification performance per configuration (repository-averaged). Macro-F1 weights every class equally; micro-F1 weights by class frequency; $\\Delta$ is their difference. \\texttt{llm\\_error} files count as misclassifications.}",
    "  \\label{tab:config-f1}",
    "  \\begin{tabular}{llrrr}",
    "    \\toprule",
    "    Model & Prompt & Macro-F1 & Micro-F1 & $\\Delta$ \\\\",
    "    \\midrule")
  tex_esc <- function(x) gsub("_", "\\\\_", x)
  for (mi in seq_along(model_order)) {
    mdl <- model_order[mi]
    for (f in fmt_levels) {
      r <- headline[headline$config == paste(mdl, f, sep = "_"), ]
      if (nrow(r) == 0) next
      d <- r$macro_f1_pa - r$micro_f1_pa
      tex <- c(tex, sprintf("    %s & %s & %.1f & %.1f & %+.1f \\\\",
                            tex_esc(mdl), f, r$macro_f1_pa, r$micro_f1_pa, d))
    }
    if (mi < length(model_order)) tex <- c(tex, "    \\addlinespace")
  }
  tex <- c(tex,
           "    \\bottomrule",
           "  \\end{tabular}",
           "\\end{table}", "")
  writeLines(tex, file.path(OUT_DIR, "config_f1_table.tex"))
}

# ── LaTeX table: data_granularity per config ─────────────────────────────────
# Binary + imbalanced (individual ≫ combined), so report accuracy plus per-class
# recall. Repository-averaged: each metric is computed per repository, then
# averaged across repos (every repo weighted equally), matching the _pa
# convention. data_format is omitted: it is rule-determined, not model-driven.
# Requires \usepackage{booktabs}. \input{} this file.
{
  gl <- "data_granularity"; glgt <- "data_granularity_gt"
  glcls <- c("individual", "combined")
  pa <- function(df, fn) {                       # per-repo metric, averaged over repos
    if (nrow(df) == 0) return(NA_real_)
    v <- vapply(split(df, df$paper_id), fn, numeric(1))
    if (all(is.na(v))) NA_real_ else mean(v, na.rm = TRUE)
  }
  tex <- c(
    "% Auto-generated by runners/eval/compare_step2_outputs.R — do not edit by hand.",
    "% Needs \\usepackage{booktabs}.",
    "\\begin{table}[ht]",
    "  \\centering",
    "  \\caption{Data-granularity classification per configuration (files with true type \\texttt{data}), repository-averaged. Binary and imbalanced (\\emph{individual} dominates), so accuracy is reported with per-class recall; a high accuracy with low \\emph{combined} recall means the model defaults to \\emph{individual}. \\emph{Rec.\\ data} is the share of true-data files classified as data at all (the denominator behind the granularity recalls): a high \\emph{individual} recall is only meaningful when \\emph{Rec.\\ data} is high.}",
    "  \\label{tab:granularity}",
    "  \\begin{tabular}{llrrrr}",
    "    \\toprule",
    "    Model & Prompt & \\emph{data} recall (\\%) & Accuracy (\\%) & \\emph{individual} recall (\\%) & \\emph{combined} recall (\\%) \\\\",
    "    \\midrule")
  tex_esc <- function(x) gsub("_", "\\\\_", x)
  for (mi in seq_along(model_order)) {
    mdl <- model_order[mi]
    for (f in fmt_levels) {
      cfg_id <- paste(mdl, f, sep = "_")
      d <- merged[merged$config == cfg_id &
                  !is.na(merged[[gl]]) & !is.na(merged[[glgt]]), ]
      if (nrow(d) == 0) next
      acc  <- pa(d, function(x) 100 * mean(x[[gl]] == x[[glgt]]))
      recs <- vapply(glcls, function(cl) pa(d, function(x) {
        g <- x[x[[glgt]] == cl, ]
        if (nrow(g) > 0) 100 * mean(g[[gl]] == cl) else NA_real_
      }), numeric(1))
      # type-level recall of `data`, over ALL true-data files (incl. misclassified)
      td <- merged[merged$config == cfg_id &
                   !is.na(merged$type_gt) & merged$type_gt == "data", ]
      drec <- pa(td, function(x) 100 * mean(x$type == "data", na.rm = TRUE))
      fmtr <- function(x) if (is.na(x)) "--" else sprintf("%.1f", x)
      tex <- c(tex, sprintf("    %s & %s & %s & %s & %s & %s \\\\",
                            tex_esc(mdl), f, fmtr(drec), fmtr(acc),
                            fmtr(recs[1]), fmtr(recs[2])))
    }
    if (mi < length(model_order)) tex <- c(tex, "    \\addlinespace")
  }
  tex <- c(tex, "    \\bottomrule", "  \\end{tabular}", "\\end{table}", "")
  writeLines(tex, file.path(OUT_DIR, "granularity_table.tex"))
}

cat(sprintf("\nWrote outputs to: %s\n", OUT_DIR))
for (f in sort(list.files(OUT_DIR))) cat("  ", f, "\n")
