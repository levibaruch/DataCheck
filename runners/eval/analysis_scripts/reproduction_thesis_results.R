#!/usr/bin/env Rscript
# reproduction_thesis_results.R — thesis-only classification-evaluation pipeline.
# Consolidated from 0_0_classification_analysis.R + 0_1_expanded_analysis.R,
# stripped to the artifacts that actually appear in the thesis. Nothing here
# produces a markdown report or an exploratory plot that the thesis does not use.
#
# Stage 1 (compare): build merged.csv / headline_metrics.csv / per_paper.csv /
#   per_class_type.csv from the raw per-paper structure.csv outputs + ground
#   truth. Every figure/table below reads from these.
# Stage 2 (figures):
#   Fig 8   prompt-failure rate per config        -> plots/llm_error_rate.png
#   Fig 9   macro/micro-F1 ranked per config       -> plots/thesis_headline_ranking.png
#   Fig 10  per-class F1 heatmap (type, repo-avg)   -> plots/per_class_type_f1_pa.png
#   Fig 11  prompt-format effect by model          -> plots/thesis_format_effect.png
#   Fig 12  per-paper macro-F1 histogram (best)     -> plots/thesis_macro_f1_dist_<cfg>.png
#   Fig 13  type confusion heatmap (best)           -> plots/confusion_type_pa_<cfg>.png
#   Fig 14  granularity|format|group triptych       -> plots/confusion_triptych_<cfg>.png
#   Fig 15  repo size vs macro-F1 scatter (best)    -> plots/thesis_size_vs_macro_f1_<cfg>.png
# Stage 3 (LaTeX tables):
#   Table 15  sub-classification per config -> granularity_table.tex,
#             data_format_config.tex, group_config.tex  (+ config_f1_table.tex)
#   Table 16  best-model summary stats      -> best_model_summary.tex
#   Table 17  data recall/precision by subtype -> data_recall_by_subtype.tex
#   Table 18  classification-method usage   -> classification_method.tex
#   Table 19  repo-size quartiles           -> size_quartiles.tex
# Stage 4 (unevaluated-module summaries — no ground truth, repository-weighted):
#   Fig 16   per-repository variable count   -> plots/variables.png
#   Fig 17   codebook provenance             -> plots/codebook_sources.png
#   Table 20 column-type distribution        -> coltype_distribution.tex
#   (+ coverage_summary.csv / haven_label_quality.csv backing the prose numbers)
#   NB: Stage 4 reads a DIFFERENT source than stages 1-3 — the frozen
#   gpt-oss-120b + JSON full run (UNVAL_BASE), which carries the columns.csv /
#   labels.csv / codebook_coverage.csv that the step2 comparison does not.
# Stage 5 (PsychDS conversion + validation — §0.1.3, prose-only in the thesis):
#   psychds_conversion_reasons.csv  conversion-failure reasons (groups/repos)
#   psychds_error_keys.csv          validator error-key counts (invalid datasets)
#   + printed funnel: groups processed -> converted -> valid + repo-level pass rate
#   NB: REPORTS ONLY. Conversion runs in pipeline/3_psychds_convert.R; validation
#   shells out to the npm `psychds-validator` CLI inside the full-run pipeline
#   (run_fullPipeline_120bJson.R, Stage 3.5), which then DELETES each psychDS dir.
#   This stage just reads the surviving conversion_summary.csv + validation_summary.csv.
#
# Run from the repo root:  Rscript runners/eval/analysis_scripts/reproduction_thesis_results.R
#
# Each export stage runs in its own local({}) scope; cross-stage handoff is via
# the comparison CSVs on disk, so the compare stage must run first.

source("runners/eval/eval_helpers.R")   # read_gt(), cm_stats(), safe_label(), %||%

# ── shared constants ─────────────────────────────────────────────────────────
ROOT       <- "results/eval/outputs/step2/osf"
UNVAL_BASE <- "results/eval/full_120b_json/outputs"   # Stage 4 source (frozen 120b+JSON run)
PSYCHDS_BASE <- "results/eval/full_120b_json"          # Stage 5 source (conversion/validation CSVs)
COMP_DIR   <- "results/eval/reproduction_thesis"
PLOT_DIR   <- file.path(COMP_DIR, "plots")
FOCUS_CFG  <- "gpt-oss-120b-low_json"   # best model (highest macro-F1, paper-averaged)
SENTINEL   <- "llm_error"
FMT_LEVELS <- c("md", "plaintext", "json")
FIELD_MAP  <- list(
  type             = "type_gt",
  group            = "group_gt",
  data_granularity = "data_granularity_gt",
  data_format      = "data_format_gt"
)
FIELDS <- names(FIELD_MAP)

dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

# ── shared helpers ───────────────────────────────────────────────────────────
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
esc  <- function(x) gsub("_", "\\\\_", x)                 # escape _ for LaTeX
fmtr <- function(x) ifelse(is.na(x), "--", sprintf("%.1f", x))
fmtn <- function(x) format(x, big.mark = ",")
# percentage: keep a positive value that rounds to 0.0 distinct from a true zero
fmtp <- function(x) if (is.na(x)) "--" else if (x > 0 && x < 0.05) "$<0.1$" else sprintf("%.1f", x)

# repository-average: split a config's rows by paper, apply fn per repo, mean across repos
pa <- function(df, fn) {
  if (nrow(df) == 0) return(NA_real_)
  v <- vapply(split(df, df$paper_id), fn, numeric(1))
  if (all(is.na(v))) NA_real_ else mean(v, na.rm = TRUE)
}
# per-class recall closure: share of true-`cl` rows the model also labelled `cl`
rec_of <- function(pred, gt, cl) function(d) {
  g <- d[d[[gt]] == cl, ]
  if (nrow(g) > 0) 100 * mean(g[[pred]] == cl) else NA_real_
}

# comparison-CSV loaders (consistent column typing)
read_merged    <- function() read.csv(file.path(COMP_DIR, "merged.csv"),
  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE,
  check.names = FALSE, na.strings = c("NA", ""))
read_headline  <- function() read.csv(file.path(COMP_DIR, "headline_metrics.csv"),
  stringsAsFactors = FALSE, check.names = FALSE)
read_per_paper <- function() read.csv(file.path(COMP_DIR, "per_paper.csv"),
  stringsAsFactors = FALSE, check.names = FALSE)

# Standard booktabs table. Bespoke captions/rows are passed in; the surrounding
# float + provenance comment + rule scaffolding is generated here.
latex_table <- function(file, caption, label, cols, header, rows,
                        needs = NULL, pre = NULL, post = NULL,
                        env = "table", placement = "[ht]") {
  need <- paste0("% Needs \\usepackage{booktabs}",
                 if (length(needs)) paste0(", ", paste(needs, collapse = ", ")) else "", ".")
  writeLines(c(
    "% Auto-generated by runners/eval/analysis_scripts/reproduction_thesis_results.R - do not edit by hand.",
    need, pre,
    sprintf("\\begin{%s}%s", env, placement),
    "  \\centering",
    paste0("  \\caption{", caption, "}"),
    sprintf("  \\label{%s}", label),
    sprintf("  \\begin{tabular}{%s}", cols),
    "    \\toprule",
    paste0("    ", header, " \\\\"),
    "    \\midrule",
    rows,
    "    \\bottomrule",
    "  \\end{tabular}",
    sprintf("\\end{%s}", env),
    post), file.path(COMP_DIR, file))
}

# Percentage heatmap with cell labels (used for per-class F1 + type confusion).
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

# ============================================================================
# === STAGE 1 — build comparison data (merged + headline + per_paper + per_class)
# ============================================================================
# Inputs : results/eval/outputs/step2/osf/<paper>/<config>/structure.csv
#          tests/ground_truth/osf/<paper>.csv
# Outputs: comparison/{merged,headline_metrics,per_paper,per_class_type}.csv
local({
  fmt1 <- function(x) if (is.na(x)) "—" else sprintf("%.1f", x)

  # ── load ──────────────────────────────────────────────────────────────────
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
  write.csv(merged, file.path(COMP_DIR, "merged.csv"), row.names = FALSE, na = "")

  configs <- sort(unique(merged$config))
  cat(sprintf("Loaded %d rows · %d repositories · %d configs:\n  %s\n\n",
              nrow(merged), length(unique(merged$paper_id)),
              length(configs), paste(configs, collapse = ", ")))

  # ── core metric helpers ─────────────────────────────────────────────────────
  # Keep the llm_error sentinel: a failed classification is a wrong answer (a miss
  # for its true class), not an excluded row. Only genuinely-missing predictions
  # (NA — file never classified) are dropped.
  scorable <- function(sub, field, gt_field) {
    pred <- sub[[field]]; gt <- sub[[gt_field]]
    ok <- !is.na(pred) & !is.na(gt)
    data.frame(pred = pred[ok], gt = gt[ok], stringsAsFactors = FALSE)
  }
  confusion <- function(sd) {
    if (nrow(sd) == 0) return(NULL)
    lev <- sort(unique(c(sd$gt, sd$pred)))
    as.matrix(table(gt   = factor(sd$gt,   levels = lev),
                    pred = factor(sd$pred, levels = lev)))
  }
  # micro-F1 with the sentinel excluded from the class set: an error row is a miss
  # (FN for its true class) but never a false positive.
  micro_f1_from_sd <- function(sd) {
    if (nrow(sd) == 0) return(NA_real_)
    classes <- setdiff(sort(unique(c(sd$gt, sd$pred))), SENTINEL)
    tp <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred == cl)))
    fp <- sum(sapply(classes, function(cl) sum(sd$gt != cl & sd$pred == cl)))
    fn <- sum(sapply(classes, function(cl) sum(sd$gt == cl & sd$pred != cl)))
    denom <- 2 * tp + fp + fn
    if (denom > 0) 2 * tp / denom * 100 else NA_real_
  }
  # llm_error is a prediction sink, not a real class — keep it in the matrix (so it
  # lowers real classes' recall) but never report it as its own row.
  per_class_from_cm <- function(cm) {
    cls <- setdiff(rownames(cm), SENTINEL)
    do.call(rbind, lapply(cls, function(c) {
      tp <- cm[c, c]; fp <- sum(cm[, c]) - tp; fn <- sum(cm[c, ]) - tp
      p  <- if ((tp + fp) > 0) tp / (tp + fp) * 100 else NA_real_
      r  <- if ((tp + fn) > 0) tp / (tp + fn) * 100 else NA_real_
      f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
      data.frame(class = c, precision = p, recall = r, f1 = f1,
                 stringsAsFactors = FALSE)
    }))
  }
  # Per-paper P/R/F1 per class (only papers where the class appears in GT
  # contribute), then mean across papers — equal weight per paper.
  per_class_paper <- function(sub, field, gt_field) {
    sd <- sub[!is.na(sub[[field]]) & !is.na(sub[[gt_field]]), , drop = FALSE]
    if (nrow(sd) == 0) return(NULL)
    out <- list()
    for (pid in unique(sd$paper_id)) {
      d <- sd[sd$paper_id == pid, , drop = FALSE]
      lev <- sort(unique(c(d[[field]], d[[gt_field]])))
      if (length(lev) == 0) next
      cm <- as.matrix(table(gt   = factor(d[[gt_field]], levels = lev),
                            pred = factor(d[[field]],    levels = lev)))
      for (cl in lev[rowSums(cm) > 0]) {
        tp <- cm[cl, cl]; fp <- sum(cm[, cl]) - tp; fn <- sum(cm[cl, ]) - tp
        p <- if ((tp + fp) > 0) tp / (tp + fp) * 100 else NA_real_
        r <- if ((tp + fn) > 0) tp / (tp + fn) * 100 else NA_real_
        f1 <- if (!is.na(p) && !is.na(r) && (p + r) > 0) 2*p*r/(p+r) else NA_real_
        out[[length(out) + 1L]] <- data.frame(
          paper_id = pid, class = cl, precision = p, recall = r, f1 = f1,
          stringsAsFactors = FALSE)
      }
    }
    if (length(out) == 0) return(NULL)
    do.call(rbind, out)
  }
  paper_avg_class <- function(pp) {
    do.call(rbind, lapply(split(pp, pp$class), function(d) {
      data.frame(class = d$class[1], n_papers = nrow(d),
                 precision_pa = mean(d$precision, na.rm = TRUE),
                 recall_pa    = mean(d$recall,    na.rm = TRUE),
                 f1_pa        = mean(d$f1,        na.rm = TRUE),
                 stringsAsFactors = FALSE)
    }))
  }

  # ── headline metrics + per-paper (type — primary task) ──────────────────────
  headline <- list(); per_paper_all <- list()
  for (cfg in configs) {
    sub <- merged[merged$config == cfg, , drop = FALSE]
    sd  <- scorable(sub, "type", "type_gt")
    cm  <- confusion(sd)
    s   <- if (!is.null(cm)) cm_stats(cm) else list(macro_f1 = NA)
    micro_f1_fp <- micro_f1_from_sd(sd)
    N   <- nrow(sd)
    acc <- if (N > 0) mean(sd$pred == sd$gt) * 100 else NA_real_

    # per-paper — grouping mask must match scorable() so it aligns with sd
    pp <- do.call(rbind, lapply(split(sd, sub$paper_id[
        !is.na(sub$type) & !is.na(sub$type_gt)
      ]), function(d) {
        if (nrow(d) == 0) return(NULL)
        lev <- sort(unique(c(d$gt, d$pred)))
        cmp <- as.matrix(table(gt   = factor(d$gt,   levels = lev),
                              pred = factor(d$pred, levels = lev)))
        sp <- cm_stats(cmp)
        data.frame(n = nrow(d), acc = mean(d$gt == d$pred) * 100,
                   macro_f1 = sp$macro_f1, micro_f1 = micro_f1_from_sd(d))
      }))
    if (!is.null(pp) && nrow(pp) > 0) {
      pp$config <- cfg
      per_paper_all[[length(per_paper_all) + 1L]] <-
        cbind(paper_id = rownames(pp), pp, stringsAsFactors = FALSE)
    }

    # prompt-failure rate: a prompt (one (paper, prompt_nr) batch) failed if any
    # file in it came back as the llm_error sentinel.
    pf  <- sub[!is.na(sub$prompt_nr), ]
    key <- paste(pf$paper_id, pf$prompt_nr, sep = "\r")
    prompt_fail <- if (length(key))
      mean(tapply(pf$type == SENTINEL, key, any, na.rm = TRUE)) * 100 else NA_real_

    headline[[length(headline) + 1L]] <- data.frame(
      config = cfg, n_files = N,
      accuracy_fp = acc, macro_f1_fp = s$macro_f1, micro_f1_fp = micro_f1_fp,
      macro_f1_pa = if (!is.null(pp)) mean(pp$macro_f1, na.rm = TRUE) else NA,
      micro_f1_pa = if (!is.null(pp)) mean(pp$micro_f1, na.rm = TRUE) else NA,
      accuracy_pa = if (!is.null(pp)) mean(pp$acc, na.rm = TRUE) else NA,
      pct_prompt_fail = prompt_fail,
      stringsAsFactors = FALSE)
  }
  headline  <- do.call(rbind, headline)
  per_paper <- if (length(per_paper_all)) do.call(rbind, per_paper_all) else data.frame()
  write.csv(headline,  file.path(COMP_DIR, "headline_metrics.csv"), row.names = FALSE, na = "")
  write.csv(per_paper, file.path(COMP_DIR, "per_paper.csv"),        row.names = FALSE, na = "")

  # ── per-class metrics (file-pooled + paper-averaged), type ──────────────────
  per_class_type <- list()
  for (cfg in configs) {
    sub <- merged[merged$config == cfg, , drop = FALSE]
    sd  <- scorable(sub, "type", "type_gt")
    cm  <- confusion(sd); if (is.null(cm)) next
    pc  <- per_class_from_cm(cm)                       # file-pooled
    pp  <- per_class_paper(sub, "type", "type_gt")     # per paper
    pa_cls <- if (!is.null(pp)) paper_avg_class(pp)
              else data.frame(class = character(), n_papers = integer(),
                              precision_pa = double(), recall_pa = double(),
                              f1_pa = double())
    mr <- merge(pc, pa_cls, by = "class", all.x = TRUE)
    mr$config <- cfg
    per_class_type[[length(per_class_type) + 1L]] <- mr
  }
  per_class_type <- do.call(rbind, per_class_type)
  write.csv(per_class_type, file.path(COMP_DIR, "per_class_type.csv"),
            row.names = FALSE, na = "")

  # ── figures ─────────────────────────────────────────────────────────────────
  cfg_cols <- setNames(hcl.colors(length(configs), palette = "Dark 3"), configs)

  # Fig 10 — per-class F1 heatmap (type), repository-averaged
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
  heatmap_pct(build_class_mat("f1_pa"),
              file.path(PLOT_DIR, "per_class_type_f1_pa.png"),
              "Per-class F1 (%) — type — repository-averaged")

  # Fig 13 — type confusion heatmap per config, repository-averaged. Each paper's
  # CM is row-normalised, then rows averaged across only the papers that contain
  # that gt class (so large repos don't dominate). Thesis uses the best config.
  for (cfg in configs) {
    sub  <- merged[merged$config == cfg, , drop = FALSE]
    scor <- sub[!is.na(sub$type) & !is.na(sub$type_gt), , drop = FALSE]
    if (nrow(scor) == 0) next
    lev <- sort(unique(c(scor$type, scor$type_gt)))
    pa_sum <- matrix(0, length(lev), length(lev), dimnames = list(lev, lev))
    pa_n   <- setNames(integer(length(lev)), lev)
    for (pid in unique(scor$paper_id)) {
      d <- scor[scor$paper_id == pid, , drop = FALSE]
      cmp <- as.matrix(table(gt   = factor(d$type_gt, levels = lev),
                            pred = factor(d$type,    levels = lev)))
      rs <- rowSums(cmp); ch <- which(rs > 0)
      if (length(ch) == 0) next
      cmn <- cmp; cmn[ch, ] <- cmp[ch, , drop = FALSE] / rs[ch]
      pa_sum[ch, ] <- pa_sum[ch, , drop = FALSE] + cmn[ch, , drop = FALSE]
      pa_n[ch] <- pa_n[ch] + 1L
    }
    pa_norm <- pa_sum / ifelse(pa_n == 0, 1, pa_n) * 100
    pa_norm <- pa_norm[setdiff(rownames(pa_norm), SENTINEL), , drop = FALSE]
    heatmap_pct(pa_norm,
                file.path(PLOT_DIR, sprintf("confusion_type_pa_%s.png", cfg)),
                sprintf("Type confusion (row-norm %%, repository-avg) — %s", cfg),
                palette = c("white", "#08519c"))
  }

  # Fig 8 — prompt-failure rate per config (bar)
  {
    png(file.path(PLOT_DIR, "llm_error_rate.png"), width = 1400, height = 800, res = 150)
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

  # Fig 9 — headline ranking: configs sorted by macro-F1 pa, paired macro/micro bars
  {
    hr <- headline[order(headline$macro_f1_pa), ]   # ascending → best on top (horiz)
    M  <- rbind(`macro-F1` = hr$macro_f1_pa, `micro-F1` = hr$micro_f1_pa)
    bar_cols <- c("macro-F1" = "#4C72B0", "micro-F1" = "#DD8452")
    png(file.path(PLOT_DIR, "thesis_headline_ranking.png"),
        width = 1700, height = 1100, res = 150)
    par(mar = c(7, 11, 4, 3))
    bp <- barplot(M, beside = TRUE, horiz = TRUE, names.arg = hr$config, las = 1,
                  col = bar_cols, xlim = c(0, 100), cex.names = 0.85,
                  xlab = "macro-F1 / micro-F1 (%)",
                  main = "Configurations ranked by macro-F1 (repository-averaged)")
    text(M[1, ], bp[1, ], sprintf("%.1f", M[1, ]), pos = 4, cex = 0.65, xpd = TRUE)
    text(M[2, ], bp[2, ], sprintf("%.1f", M[2, ]), pos = 4, cex = 0.65, xpd = TRUE)
    legend(x = 50, y = par("usr")[3] - diff(par("usr")[3:4]) * 0.13,
           legend = names(bar_cols), fill = bar_cols, horiz = TRUE, xjust = 0.5,
           bty = "n", cex = 0.85, xpd = NA)
    dev.off()
  }

  # Fig 11 — prompt-format effect by model (macro + micro panels, shared y-axis)
  {
    model_of   <- function(cfg) sub("_[^_]+$", "", cfg)
    model_lvls <- unique(model_of(configs))
    model_cols <- setNames(hcl.colors(length(model_lvls), "Dark 3"), model_lvls)
    effect_mat <- function(metric) sapply(model_lvls, function(m)
      vapply(FMT_LEVELS, function(f) {
        v <- headline[[metric]][headline$config == paste(m, f, sep = "_")]
        if (length(v)) v else NA_real_
      }, numeric(1)))
    Mmac <- effect_mat("macro_f1_pa"); Mmic <- effect_mat("micro_f1_pa")
    yl <- range(c(Mmac, Mmic), na.rm = TRUE); yl <- yl + c(-1, 1) * diff(yl) * 0.08
    png(file.path(PLOT_DIR, "thesis_format_effect.png"),
        width = 1700, height = 850, res = 150)
    par(mfrow = c(1, 2), mar = c(4, 5, 3, 1), oma = c(4, 0, 2, 0))
    for (pn in list(list(M = Mmac, lab = "macro-F1 (repository-averaged) %"),
                    list(M = Mmic, lab = "micro-F1 (repository-averaged) %"))) {
      plot(NULL, xlim = c(0.9, 3.1), ylim = yl, xaxt = "n", xlab = "", ylab = pn$lab, las = 1)
      axis(1, at = 1:3, labels = FMT_LEVELS)
      for (m in model_lvls)
        lines(1:3, pn$M[, m], col = model_cols[m], lwd = 2, type = "b", pch = 19)
    }
    mtext("Prompt-format effect by model", side = 3, outer = TRUE, cex = 1.1, font = 2)
    par(fig = c(0, 1, 0, 1), oma = c(0, 0, 0, 0), mar = c(0, 0, 0, 0), new = TRUE)
    plot(0, 0, type = "n", axes = FALSE, xlab = "", ylab = "")
    legend("bottom", legend = model_lvls, col = model_cols, lwd = 2, pch = 19,
           horiz = TRUE, bty = "n", cex = 0.85, inset = c(0, 0.01))
    dev.off()
  }

  # Fig 12 + Fig 15 — per-paper macro-F1 histogram + repo-size-vs-macro-F1 scatter,
  # for the top-3 configs by macro-F1 pa (thesis uses the best of these).
  top3 <- headline$config[order(-headline$macro_f1_pa)][1:3]
  plot_macro_f1_hist <- function(vals, file, title_suffix) {
    vals <- vals[!is.na(vals)]; if (length(vals) == 0) return()
    png(file, width = 1200, height = 700, res = 150); on.exit(dev.off())
    par(mar = c(5, 4, 3, 1))
    h <- hist(vals, breaks = seq(0, 100, by = 5), plot = FALSE)
    plot(NULL, xlim = c(0, 100), ylim = c(0, max(h$counts) + 1),
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
    ok <- !is.na(n_files) & !is.na(y); if (sum(ok) == 0) return()
    n_files <- n_files[ok]; y <- y[ok]
    png(file, width = 1200, height = 700, res = 150); on.exit(dev.off())
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
  }

  # ── LaTeX: macro/micro-F1 per config (supports Fig 9) ───────────────────────
  # Δ = macro − micro (equal-class-weight minus frequency-weight). Grouped by
  # model (best model first), prompts md → plaintext → json within each.
  model_order <- names(sort(tapply(headline$macro_f1_pa,
                    sub("_[^_]+$", "", headline$config), mean, na.rm = TRUE),
                    decreasing = TRUE))
  {
    tex <- c(
      "% Auto-generated by runners/eval/analysis_scripts/reproduction_thesis_results.R — do not edit by hand.",
      "% Needs \\usepackage{booktabs}.",
      "\\begin{table}[ht]", "  \\centering",
      "  \\caption{Type-classification performance per configuration (repository-averaged). Macro-F1 weights every class equally; micro-F1 weights by class frequency; $\\Delta$ is their difference. \\texttt{llm\\_error} files count as misclassifications.}",
      "  \\label{tab:config-f1}", "  \\begin{tabular}{llrrr}", "    \\toprule",
      "    Model & Prompt & Macro-F1 & Micro-F1 & $\\Delta$ \\\\", "    \\midrule")
    for (mi in seq_along(model_order)) {
      mdl <- model_order[mi]
      for (f in FMT_LEVELS) {
        r <- headline[headline$config == paste(mdl, f, sep = "_"), ]
        if (nrow(r) == 0) next
        tex <- c(tex, sprintf("    %s & %s & %.1f & %.1f & %+.1f \\\\",
                 esc(mdl), f, r$macro_f1_pa, r$micro_f1_pa, r$macro_f1_pa - r$micro_f1_pa))
      }
      if (mi < length(model_order)) tex <- c(tex, "    \\addlinespace")
    }
    tex <- c(tex, "    \\bottomrule", "  \\end{tabular}", "\\end{table}", "")
    writeLines(tex, file.path(COMP_DIR, "config_f1_table.tex"))
  }

  # ── LaTeX: data_granularity per config (Table 15, granularity block) ────────
  # Binary + imbalanced (individual ≫ combined): report accuracy + per-class recall.
  {
    gl <- "data_granularity"; glgt <- "data_granularity_gt"; glcls <- c("individual", "combined")
    tex <- c(
      "% Auto-generated by runners/eval/analysis_scripts/reproduction_thesis_results.R — do not edit by hand.",
      "% Needs \\usepackage{booktabs}.",
      "\\begin{table}[ht]", "  \\centering",
      "  \\caption{Data-granularity classification per configuration (files with true type \\texttt{data}), repository-averaged. Binary and imbalanced (\\emph{individual} dominates), so accuracy is reported with per-class recall; a high accuracy with low \\emph{combined} recall means the model defaults to \\emph{individual}. \\emph{Rec.\\ data} is the share of true-data files classified as data at all (the denominator behind the granularity recalls): a high \\emph{individual} recall is only meaningful when \\emph{Rec.\\ data} is high.}",
      "  \\label{tab:granularity}", "  \\begin{tabular}{llrrrr}", "    \\toprule",
      "    Model & Prompt & \\emph{data} recall (\\%) & Accuracy (\\%) & \\emph{individual} recall (\\%) & \\emph{combined} recall (\\%) \\\\",
      "    \\midrule")
    for (mi in seq_along(model_order)) {
      mdl <- model_order[mi]
      for (f in FMT_LEVELS) {
        cfg_id <- paste(mdl, f, sep = "_")
        d <- merged[merged$config == cfg_id & !is.na(merged[[gl]]) & !is.na(merged[[glgt]]), ]
        if (nrow(d) == 0) next
        acc  <- pa(d, function(x) 100 * mean(x[[gl]] == x[[glgt]]))
        recs <- vapply(glcls, function(cl) pa(d, rec_of(gl, glgt, cl)), numeric(1))
        td   <- merged[merged$config == cfg_id & !is.na(merged$type_gt) & merged$type_gt == "data", ]
        drec <- pa(td, function(x) 100 * mean(x$type == "data", na.rm = TRUE))
        tex  <- c(tex, sprintf("    %s & %s & %s & %s & %s & %s \\\\",
                  esc(mdl), f, fmtr(drec), fmtr(acc), fmtr(recs[1]), fmtr(recs[2])))
      }
      if (mi < length(model_order)) tex <- c(tex, "    \\addlinespace")
    }
    tex <- c(tex, "    \\bottomrule", "  \\end{tabular}", "\\end{table}", "")
    writeLines(tex, file.path(COMP_DIR, "granularity_table.tex"))
  }

  cat(sprintf("\nStage 1 wrote merged/headline/per_paper/per_class_type + figures to: %s\n", COMP_DIR))
})

# ============================================================================
# === Table 16 — per-repository summary stats (min/max/median/mean/sd), best cfg
# ============================================================================
local({
  d <- read_per_paper(); d <- d[d$config == FOCUS_CFG, ]
  if (nrow(d) == 0) stop("No per_paper rows for config: ", FOCUS_CFG)
  metrics <- list(c(col = "macro_f1", label = "Macro-F1", dp = "1"),
                  c(col = "micro_f1", label = "Micro-F1", dp = "1"))
  summ <- do.call(rbind, lapply(metrics, function(m) {
    v <- d[[m["col"]]]; v <- v[!is.na(v)]
    data.frame(metric = m["label"], dp = m["dp"], min = min(v), max = max(v),
               median = median(v), mean = mean(v), sd = sd(v), stringsAsFactors = FALSE)
  }))
  write.csv(summ[, c("metric", "min", "max", "median", "mean", "sd")],
            file.path(COMP_DIR, "best_model_summary.csv"), row.names = FALSE)
  f <- function(x, dp) sprintf(paste0("%.", dp, "f"), x)
  rows <- vapply(seq_len(nrow(summ)), function(i) { r <- summ[i, ]
    sprintf("    %s & %s & %s & %s & %s & %s \\\\", r$metric, f(r$min, r$dp),
            f(r$max, r$dp), f(r$median, r$dp), f(r$mean, r$dp), f(r$sd, r$dp))
  }, character(1))
  latex_table("best_model_summary.tex",
    sprintf(paste0("Per-repository summary statistics for the best model ",
      "(\\texttt{%s}), across %d repositories. Each statistic is computed over ",
      "the per-repository metric distribution."), esc(FOCUS_CFG), nrow(d)),
    "tab:best-model-summary", "lrrrrr", "Metric & Min & Max & Median & Mean & SD", rows)
  cat("Wrote best_model_summary.{csv,tex}\n")
})

# ============================================================================
# === Table 18 — file-type accuracy by classification method (type_source), best
# ============================================================================
# Observational, not controlled: the methods act on different file populations
# (aggregate_llm on big homogeneous data folders, llm on varied standalone files,
# rules on narrow patterns), so accuracy gaps conflate method with difficulty.
local({
  CFG <- FOCUS_CFG
  LABELS <- c(
    aggregate_llm       = "\\texttt{aggregate\\_llm}",
    llm                 = "\\texttt{llm}",
    rule_folder         = "\\texttt{rule\\_folder}",
    rmd_pair_rule       = "\\texttt{rmd\\_pair\\_rule}",
    fixed_ext_rule      = "\\texttt{fixed\\_ext\\_rule}",
    fixed_filename_rule = "\\texttt{fixed\\_filename\\_rule}")
  m <- read_merged()
  d <- m[m$config == CFG & !is.na(m$type) & !is.na(m$type_gt) & !is.na(m$type_source), ]
  if (nrow(d) == 0) stop("No scorable type rows for config: ", CFG)
  d$correct <- d$type == d$type_gt
  ALWAYS_SHOW <- "rule_folder"   # absence is itself a finding
  tot_files <- nrow(d); tot_repos <- length(unique(d$paper_id))
  res <- do.call(rbind, lapply(names(LABELS), function(src) {
    s <- d[d$type_source == src, ]
    if (nrow(s) == 0) {
      if (!src %in% ALWAYS_SHOW) return(NULL)
      return(data.frame(source = src, method = LABELS[[src]],
                        n_files = 0L, pct_files = 0, n_papers = 0L, pct_repos = 0,
                        acc_pa = NA_real_, acc_pooled = NA_real_, stringsAsFactors = FALSE))
    }
    acc_pa <- mean(vapply(split(s, s$paper_id), function(x) 100 * mean(x$correct), numeric(1)))
    data.frame(source = src, method = LABELS[[src]],
               n_files = nrow(s), pct_files = 100 * nrow(s) / tot_files,
               n_papers = length(unique(s$paper_id)),
               pct_repos = 100 * length(unique(s$paper_id)) / tot_repos,
               acc_pa = acc_pa, acc_pooled = 100 * mean(s$correct), stringsAsFactors = FALSE)
  }))
  write.csv(res, file.path(COMP_DIR, "classification_method.csv"), row.names = FALSE)
  rows <- vapply(seq_len(nrow(res)), function(i) { r <- res[i, ]
    sprintf("    %s & %s & %s & %s & %s & %s & %s \\\\", r$method, fmtn(r$n_files),
            fmtp(r$pct_files), fmtn(r$n_papers), fmtp(r$pct_repos),
            fmtr(r$acc_pa), fmtr(r$acc_pooled)) }, character(1))
  note <- paste0(
    " \\texttt{rule\\_folder} (the software-folder bypass) claims zero files here: ",
    "it targets dependency/build directories (\\texttt{node\\_modules}, \\texttt{renv}, ",
    "\\texttt{\\_\\_pycache\\_\\_}, large \\texttt{lib}/\\texttt{src}), which these OSF deposits ",
    "do not contain, so all software is classified by the LLM instead.")
  latex_table("classification_method.tex",
    paste0("File-type classification accuracy by the method that produced the ",
      "label (\\texttt{type\\_source}) for \\textit{", esc(CFG), "}, repository-averaged ",
      "and file-pooled. \\textbf{Observational, not controlled:} the methods act on ",
      "different file populations -- aggregated LLM on large homogeneous data folders, ",
      "per-file LLM on varied standalone files, rules on narrow pattern matches -- so the ",
      "accuracy gaps conflate method with file difficulty. Rule rows fire on few files and ",
      "are degenerate repository-averaged (one wrong file forces a repo to $0\\%$); read ",
      "their file-pooled column instead. \\% files is the share of all classified files; ",
      "\\% repos the share of repositories in which the method fires at least once ",
      "(repos use several methods, so this column does not sum to 100).", note),
    "tab:classification-method", "lrrrrrr",
    paste0("Method & \\makecell[r]{$n$\\\\files} & \\makecell[r]{\\%\\\\files} & ",
      "\\makecell[r]{$n$\\\\repos} & \\makecell[r]{\\%\\\\repos} & ",
      "\\makecell[r]{Accuracy,\\\\repo-avg.\\ (\\%)} & \\makecell[r]{Accuracy,\\\\pooled (\\%)}"),
    rows, needs = "\\usepackage{makecell}")
  cat("Wrote classification_method.{csv,tex}\n")
})

# ============================================================================
# === Fig 14 — confusion triptych (data_granularity | data_format | group), best
# ============================================================================
# One PNG, three row-normalised confusion matrices (repository-weighted: each
# paper's row distribution first, then averaged across papers). Sentinel gt rows
# dropped. Output: plots/confusion_triptych_<cfg>.png
local({
  CFG <- FOCUS_CFG
  merged <- read_merged()
  sub <- merged[merged$config == CFG, , drop = FALSE]
  if (nrow(sub) == 0) stop("no rows for config ", CFG)

  build_cm <- function(pred, gt, pid) {
    ok  <- !is.na(pred) & !is.na(gt) & nzchar(pred) & nzchar(gt)
    pred <- pred[ok]; gt <- gt[ok]; pid <- pid[ok]
    lev  <- sort(unique(c(gt, pred))); nr <- length(lev)
    rate_sum   <- matrix(0, nr, nr, dimnames = list(lev, lev))
    row_papers <- setNames(integer(nr), lev)
    for (p in unique(pid)) {
      sel <- pid == p
      cm  <- table(gt = factor(gt[sel], levels = lev), pred = factor(pred[sel], levels = lev))
      cm  <- matrix(as.numeric(cm), nr, nr, dimnames = list(lev, lev))
      rs  <- rowSums(cm)
      for (g in which(rs > 0)) {
        rate_sum[g, ] <- rate_sum[g, ] + cm[g, ] / rs[g]
        row_papers[g] <- row_papers[g] + 1L
      }
    }
    norm <- rate_sum / ifelse(row_papers == 0, 1, row_papers) * 100
    keep <- rownames(norm) != SENTINEL
    list(mat = norm[keep, , drop = FALSE], cnt = row_papers[keep], n = length(unique(pid)))
  }
  nice <- function(x) { x <- gsub("_", " ", x)
    paste0(toupper(substring(x, 1, 1)), substring(x, 2)) }
  panel <- function(cm, title, palette = c("white", "#08519c")) {
    mat <- cm$mat; cnt <- cm$cnt
    cols <- colorRampPalette(palette)(100)
    nr <- nrow(mat); nc <- ncol(mat); norm <- mat / 100
    par(mar = c(10, 11, 6, 1))
    image(seq_len(nc), seq_len(nr), t(norm)[, nr:1, drop = FALSE],
          col = cols, zlim = c(0, 1), axes = FALSE, xlab = "", ylab = "",
          main = sprintf("%s\n(N = %s repositories)", title, format(cm$n, big.mark = ",")),
          cex.main = 2.1, asp = 1)
    text(seq_len(nc), par("usr")[3] - (nr * 0.02 + 0.12),
         labels = nice(colnames(mat)), srt = 45, adj = 1, xpd = TRUE, cex = 1.9)
    axis(2, at = seq_len(nr), labels = nice(rev(rownames(mat))), las = 1,
         cex.axis = 1.9, mgp = c(3, 0.4, 0), tcl = -0.3)
    for (i in seq_len(nr)) for (j in seq_len(nc)) {
      v <- mat[nr + 1 - i, j]; k <- cnt[nr + 1 - i]
      if (is.na(v)) next
      txt_col <- if (norm[nr + 1 - i, j] > 0.55) "white" else "black"
      text(j, i + 0.10, sprintf("%.2f%%", v), col = txt_col, cex = 1.9)
      text(j, i - 0.15, sprintf("n = %s", format(k, big.mark = ",")), col = txt_col, cex = 1.6)
    }
  }
  # group has free-form study labels — collapse to a binary FILE-level scope:
  # a "shared*" label spans multiple study groups; any ex<N>/pilot<N> belongs to one.
  collapse_grp <- function(x) ifelse(is.na(x) | !nzchar(x), x,
    ifelse(grepl("shared", x, ignore.case = TRUE), "shared", "experiment-specific"))

  cm_dg  <- build_cm(sub$data_granularity, sub$data_granularity_gt, sub$paper_id)
  cm_fmt <- build_cm(sub$data_format,      sub$data_format_gt,      sub$paper_id)
  cm_grp <- build_cm(collapse_grp(sub$group), collapse_grp(sub$group_gt), sub$paper_id)

  out <- file.path(PLOT_DIR, sprintf("confusion_triptych_%s.png", CFG))
  png(out, width = 2700, height = 1150, res = 150)
  par(mfrow = c(1, 3))
  panel(cm_dg,  "data_granularity")
  panel(cm_fmt, "data_format (raw vs tabular)")
  panel(cm_grp, "group scope\n(shared vs experiment-specific labels)")
  dev.off()
  cat("wrote", out, "\n")
})

# ============================================================================
# === Table 15 (format block) — data_format (raw vs tabular) per config ─────
# ============================================================================
# Scored only on files with true type `data` that the model also called data.
# Binary + imbalanced (tabular dominates), so accuracy is shown with per-class recall.
local({
  fl <- "data_format"; flgt <- "data_format_gt"
  mall <- read_merged()
  m <- mall[!is.na(mall[[fl]]) & !is.na(mall[[flgt]]), ]
  if (nrow(m) == 0) stop("No scorable data_format rows in merged.csv")
  percfg <- do.call(rbind, lapply(sort(unique(m$config)), function(cfg) {
    d  <- m[m$config == cfg, ]
    td <- mall[mall$config == cfg & !is.na(mall$type_gt) & mall$type_gt == "data", ]
    data.frame(config = cfg, model = d$model[1], format = d$format[1],
      rec_data    = pa(td, function(x) 100 * mean(x$type == "data", na.rm = TRUE)),
      accuracy    = pa(d,  function(x) 100 * mean(x[[fl]] == x[[flgt]])),
      rec_raw     = pa(d,  rec_of(fl, flgt, "raw")),
      rec_tabular = pa(d,  rec_of(fl, flgt, "tabular")), stringsAsFactors = FALSE)
  }))
  model_order <- names(sort(vapply(split(percfg$accuracy, percfg$model), mean, numeric(1)),
                            decreasing = TRUE))
  percfg <- percfg[order(match(percfg$model, model_order), match(percfg$format, FMT_LEVELS)), ]
  write.csv(percfg, file.path(COMP_DIR, "data_format_config.csv"), row.names = FALSE)
  rows <- character()
  for (mi in seq_along(model_order)) {
    for (f in FMT_LEVELS) {
      r <- percfg[percfg$model == model_order[mi] & percfg$format == f, ]
      if (nrow(r) == 0) next
      rows <- c(rows, sprintf("    %s & %s & %s & %s & %s & %s \\\\", esc(model_order[mi]),
        f, fmtr(r$rec_data), fmtr(r$accuracy), fmtr(r$rec_raw), fmtr(r$rec_tabular)))
    }
    if (mi < length(model_order)) rows <- c(rows, "    \\addlinespace")
  }
  latex_table("data_format_config.tex",
    paste0("Data-type (\\texttt{raw} vs.\\ \\texttt{tabular}) classification per ",
      "configuration (model $\\times$ prompt) on files with true type \\texttt{data}, ",
      "repository-averaged. Binary and imbalanced (\\emph{tabular} dominates), so accuracy ",
      "is reported with per-class recall. \\emph{Rec.\\ data} is the share of true-data ",
      "files the model classified as data at all (the denominator behind the format ",
      "recalls): a high raw/tabular recall is only meaningful when \\emph{Rec.\\ data} is high."),
    "tab:data-format-config", "llrrrr",
    paste0("Model & Prompt & \\emph{data} recall (\\%) & Accuracy (\\%) & ",
           "\\emph{raw} recall (\\%) & \\emph{tabular} recall (\\%)"),
    rows)
  cat("Wrote data_format_config.{csv,tex}\n")
})

# ============================================================================
# === Table 17 — data-class recall/precision split by file subtype, best cfg ─
# ============================================================================
# Recall is binned by TRUE subtype, precision by PREDICTED subtype (false
# positives have no true subtype), so n is the recall denominator.
local({
  CFG <- FOCUS_CFG
  m  <- read_merged()
  dd <- m[m$config == CFG, ]
  td <- dd[!is.na(dd$type_gt) & dd$type_gt == "data", ]   # true-data (recall denom)
  pd <- dd[!is.na(dd$type)    & dd$type    == "data", ]   # predicted-data (precision denom)
  if (nrow(td) == 0) stop("No true-data rows for config: ", CFG)
  is_pred_data <- function(d) 100 * mean(d$type == "data", na.rm = TRUE)
  is_true_data <- function(d) 100 * mean(d$type_gt == "data", na.rm = TRUE)
  split_metrics <- function(col, predcol, group) {
    do.call(rbind, lapply(sort(unique(na.omit(td[[col]]))), function(lv) {
      s <- td[!is.na(td[[col]])     & td[[col]]     == lv, ]
      p <- pd[!is.na(pd[[predcol]]) & pd[[predcol]] == lv, ]
      data.frame(group = group, subtype = lv, n_files = nrow(s),
                 rec_data_pa = pa(s, is_pred_data), prec_data_pa = pa(p, is_true_data),
                 stringsAsFactors = FALSE)
    }))
  }
  res <- rbind(
    data.frame(group = "Overall", subtype = "all data files", n_files = nrow(td),
               rec_data_pa = pa(td, is_pred_data), prec_data_pa = pa(pd, is_true_data),
               stringsAsFactors = FALSE),
    split_metrics("data_format_gt",      "data_format",      "Format"),
    split_metrics("data_granularity_gt", "data_granularity", "Granularity"))
  write.csv(res, file.path(COMP_DIR, "data_recall_by_subtype.csv"), row.names = FALSE)
  groups <- unique(res$group); rows <- character()
  for (gi in seq_along(groups)) {
    g <- res[res$group == groups[gi], ]
    for (i in seq_len(nrow(g))) { r <- g[i, ]
      lab <- if (i != 1) "" else if (nrow(g) == 1) groups[gi] else
        sprintf("\\multirow{%d}{*}{%s}", nrow(g), groups[gi])
      rows <- c(rows, sprintf("    %s & \\emph{%s} & %s & %s & %s \\\\", lab,
        esc(r$subtype), fmtn(r$n_files), fmtr(r$rec_data_pa), fmtr(r$prec_data_pa)))
    }
    if (gi < length(groups)) rows <- c(rows, "    \\addlinespace")
  }
  latex_table("data_recall_by_subtype.tex",
    paste0("Type-level recall and precision of the \\texttt{data} class for ",
      "\\textit{", esc(CFG), "}, repository-averaged (per repo, then mean over repos). ",
      "Recall (share of true-data files classified as data) is binned by the file's ",
      "\\emph{true} subtype; precision (share of predicted-data files that are truly data) ",
      "by the model's \\emph{predicted} subtype, since false positives have no true subtype. ",
      "$n$ counts true-data files (the recall denominator). Recall and precision are flat ",
      "across subtypes ($\\sim$2 percentage points); the low repository-averaged precision ",
      "for predicted-\\emph{raw} files is a small-sample artifact.\\protect\\footnotemark"),
    "tab:data-recall-by-subtype", "llrrr",
    "& Subtype & $n$ files & Data recall (\\%) & Data precision (\\%)", rows,
    needs = "\\usepackage{multirow}",
    post = paste0("\\footnotetext{Predicted-\\emph{raw} files are sparse per repository (20 repos, ",
      "several with a single such file), so one false positive forces that repo to $0\\%$ ",
      "and drags the repo-average. File-pooled precision is $98.6\\%$, in line with the ",
      "other subtypes; the repository-average is unstable here for the same degenerate ",
      "small-$n$ reason that destabilises per-repository metrics on tiny repositories.}"))
  cat("Wrote data_recall_by_subtype.{csv,tex}\n")
})

# ============================================================================
# === Table 15 (group block) — group-classification accuracy per config ─────
# ============================================================================
# `group` is a WITHIN-paper assignment, so accuracy is computed per repository
# then averaged. Single-group repos are trivial and split out; multi-group repos
# are the discriminating test.
local({
  m <- read_merged()
  m <- m[!is.na(m$group) & !is.na(m$group_gt), ]
  if (nrow(m) == 0) stop("No scorable group rows in merged.csv")
  percfg <- do.call(rbind, lapply(sort(unique(m$config)), function(cfg) {
    d  <- m[m$config == cfg, ]
    sp <- split(seq_len(nrow(d)), d$paper_id)
    acc <- vapply(sp, function(i) 100 * mean(d$group[i] == d$group_gt[i]), numeric(1))
    ng  <- vapply(sp, function(i) length(unique(d$group_gt[i])), integer(1))
    data.frame(config = cfg, model = d$model[1], format = d$format[1],
               acc_all = mean(acc), acc_multi = mean(acc[ng >= 2]),
               acc_single = mean(acc[ng == 1]),
               n_multi = sum(ng >= 2), n_single = sum(ng == 1), stringsAsFactors = FALSE)
  }))
  res <- do.call(rbind, lapply(split(percfg, percfg$model), function(d)
    data.frame(model = d$model[1], acc_multi = mean(d$acc_multi), stringsAsFactors = FALSE)))
  res <- res[order(-res$acc_multi), ]
  n_multi <- percfg$n_multi[1]; n_single <- percfg$n_single[1]   # GT-defined, constant
  n_total <- n_multi + n_single
  model_order <- unique(res$model)
  percfg <- percfg[order(match(percfg$model, model_order), match(percfg$format, FMT_LEVELS)), ]
  write.csv(percfg[, c("config", "model", "format", "acc_all", "acc_multi", "acc_single")],
            file.path(COMP_DIR, "group_config.csv"), row.names = FALSE)
  crows <- character()
  for (mi in seq_along(model_order)) {
    for (f in FMT_LEVELS) {
      r <- percfg[percfg$model == model_order[mi] & percfg$format == f, ]
      if (nrow(r) == 0) next
      crows <- c(crows, sprintf("    %s & %s & %.1f & %.1f & %.1f \\\\",
        esc(model_order[mi]), f, r$acc_all, r$acc_multi, r$acc_single))
    }
    if (mi < length(model_order)) crows <- c(crows, "    \\addlinespace")
  }
  latex_table("group_config.tex",
    sprintf(paste0("Group-classification accuracy per configuration ",
      "(model $\\times$ prompt), repository-averaged. \\texttt{group} is a ",
      "within-paper assignment, so accuracy is computed per repository. ",
      "Single-group repositories (%d) are trivial and reported separately; ",
      "multi-group repositories (%d) are the discriminating test."), n_single, n_multi),
    "tab:group-config", "llrrr",
    sprintf("Model & Prompt & All (%d) & Multi-group (%d) & Single-group (%d)",
            n_total, n_multi, n_single),
    crows)
  cat("Wrote group_config.{csv,tex}\n")
})

# ============================================================================
# === Table 19 — repository-size quartiles, best cfg ────────────────────────
# ============================================================================
# Mean metric by repository-size quartile — repo sizes are right-skewed, so
# quartile bins show where the size effect on accuracy lives.
local({
  d <- read_per_paper(); d <- d[d$config == FOCUS_CFG, ]
  if (nrow(d) == 0) stop("No per_paper rows for config: ", FOCUS_CFG)
  qb <- quantile(d$n, probs = seq(0, 1, 0.25), na.rm = TRUE)
  d$q <- cut(d$n, breaks = qb, include.lowest = TRUE, labels = c("Q1", "Q2", "Q3", "Q4"))
  qsumm <- do.call(rbind, lapply(levels(d$q), function(lv) {
    s <- d[!is.na(d$q) & d$q == lv, ]
    data.frame(quartile = lv, n_repos = nrow(s), size_lo = min(s$n), size_hi = max(s$n),
               size_med = median(s$n),
               macro_f1 = mean(s$macro_f1, na.rm = TRUE),
               micro_f1 = mean(s$micro_f1, na.rm = TRUE), stringsAsFactors = FALSE)
  }))
  write.csv(qsumm, file.path(COMP_DIR, "size_quartiles.csv"), row.names = FALSE)
  rng <- function(lo, hi) if (lo == hi) as.character(lo) else
    sprintf("%s--%s", format(lo, big.mark = ","), format(hi, big.mark = ","))
  rows2 <- vapply(seq_len(nrow(qsumm)), function(i) { r <- qsumm[i, ]
    sprintf("    %s & %s & %d & %d & %.1f & %.1f \\\\", r$quartile,
      rng(r$size_lo, r$size_hi), r$size_med, r$n_repos, r$macro_f1, r$micro_f1)
  }, character(1))
  latex_table("size_quartiles.tex",
    sprintf(paste0("Mean evaluation metric by repository-size quartile for the best ",
      "model (\\texttt{%s}). Accuracy is highest in the mid-size repos and declines ",
      "toward the largest (clearest for Macro-F1), while the smallest repos dip ",
      "slightly as their few files make the metric coarse. The relationship is thus ",
      "negative overall but not strictly monotonic."), esc(FOCUS_CFG)),
    "tab:size-quartiles", "lrrrrr",
    "Quartile & Size (files) & Median & Repos & Macro-F1 & Micro-F1", rows2)
  cat("Wrote size_quartiles.{csv,tex}\n")
})

# ============================================================================
# === STAGE 4 — unevaluated modules (variable count, col_type, codebook) ─────
# ============================================================================
# No ground truth — descriptive summaries only. Reads the frozen gpt-oss-120b +
# JSON full run (UNVAL_BASE), which carries columns.csv / labels.csv /
# codebook_coverage.csv per paper. Everything is repository-weighted (_pa): the
# statistic is computed within each repository, then averaged across repos, so a
# few pathological wide files cannot dominate (memory: report _pa, not pooled).
local({
  if (!dir.exists(UNVAL_BASE)) {
    cat(sprintf("Stage 4 skipped — no unevaluated-module source at %s\n", UNVAL_BASE))
    return(invisible(NULL))
  }
  rd <- function(p) if (file.exists(p) && file.info(p)$size > 0)
    tryCatch(read.csv(p, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")),
             error = function(e) NULL) else NULL

  paper_dirs <- list.dirs(UNVAL_BASE, recursive = TRUE)
  paper_dirs <- paper_dirs[file.exists(file.path(paper_dirs, "structure.csv")) |
                           file.exists(file.path(paper_dirs, "columns.csv"))]
  cols_l <- list(); labs_l <- list(); cov_l <- list()
  for (d in paper_dirs) {
    pid <- basename(d)
    c1 <- rd(file.path(d, "columns.csv"));           if (!is.null(c1) && nrow(c1)) cols_l[[pid]] <- c1
    l1 <- rd(file.path(d, "labels.csv"));            if (!is.null(l1) && nrow(l1)) labs_l[[pid]] <- l1
    v1 <- rd(file.path(d, "codebook_coverage.csv")); if (!is.null(v1) && nrow(v1)) cov_l[[pid]] <- v1
  }
  if (length(cols_l) == 0) stop("No columns.csv found under ", UNVAL_BASE)
  cols   <- do.call(rbind, cols_l)
  percol <- vapply(cols_l, nrow, integer(1))   # variables per repository

  PA_COL <- "#4C72B0"; FP_COL <- "#C44E52"; GREEN <- "#55A868"; GREY <- "#BDBDBD"

  # ── Fig 16 — per-repository variable count (log-scaled, heavy right skew) ────
  png(file.path(PLOT_DIR, "variables.png"), width = 950, height = 620, res = 110)
  par(mar = c(4.5, 4.5, 3, 1), mgp = c(2.6, 0.6, 0))
  h <- hist(log10(percol), breaks = 24, plot = FALSE)
  plot(h, col = PA_COL, border = "white", xaxt = "n",
       xlab = "variables per repository (log scale)", ylab = "repositories",
       main = "Per-repository variable count")
  ticks <- c(0, 1, 10, 100, 1000, 10000, 100000)
  vt <- ticks[ticks > 0 & ticks >= min(percol) & ticks <= max(percol)]
  axis(1, at = c(par("usr")[1], log10(vt)),
       labels = format(c(0, vt), big.mark = ",", scientific = FALSE))
  abline(v = log10(mean(percol)),   col = FP_COL, lwd = 2, lty = 2)
  abline(v = log10(median(percol)), col = GREEN,  lwd = 2, lty = 2)
  legend("topright", bty = "n",
         legend = c(sprintf("mean %.0f", mean(percol)),
                    sprintf("median %.0f", median(percol))),
         col = c(FP_COL, GREEN), lwd = 2, lty = 2)
  dev.off()

  # ── Table 20 — col_type distribution (repository-weighted) ──────────────────
  tt    <- sort(table(cols$col_type), decreasing = TRUE)
  types <- names(tt)
  pw    <- sapply(cols_l, function(df) {
    tb <- table(factor(df$col_type, levels = types)); tb / sum(tb)
  })
  pwm <- rowMeans(pw)
  coltype_df <- data.frame(col_type = types, n = as.integer(tt),
                           pct_pa = round(100 * pwm[types], 1),
                           row.names = NULL, stringsAsFactors = FALSE)
  coltype_df <- coltype_df[order(-coltype_df$pct_pa), ]
  write.csv(coltype_df, file.path(COMP_DIR, "coltype_distribution.csv"), row.names = FALSE)
  ct_rows <- sprintf("    \\texttt{%s} & %s & %.1f \\\\",
                     esc(coltype_df$col_type), fmtn(coltype_df$n), coltype_df$pct_pa)
  latex_table("coltype_distribution.tex",
    paste0("Column-type distribution (repository-weighted). $n$ is the raw column ",
      "count across the corpus; the proportion is computed per repository and then ",
      "averaged across repositories, so a few wide sparse files (many \\texttt{empty} ",
      "columns) do not dominate."),
    "tab:coltype", "lrr",
    "col\\_type & $n$ & Repository avg.\\ proportion (\\%)", ct_rows)

  # ── Fig 17 — codebook provenance (matched vs unmatched per source) ──────────
  if (length(cov_l)) {
    cov <- do.call(rbind, cov_l)
    src <- ifelse(cov$parse_method == "haven", "haven-embedded",
           ifelse(grepl("readme", tolower(cov$codebook_source)), "README", "structured file"))
    matched_v <- cov$match_status == "matched"
    sd <- do.call(rbind, lapply(unique(src), function(s) {
      sel <- src == s
      data.frame(source = s, parsed_vars = sum(sel), matched = sum(sel & matched_v),
                 match_rate = round(100 * mean(matched_v[sel]), 1), stringsAsFactors = FALSE)
    }))
    sd <- sd[order(sd$parsed_vars), ]
    png(file.path(PLOT_DIR, "codebook_sources.png"), width = 900, height = 550, res = 100)
    par(mar = c(4.5, 9, 3, 1.5), mgp = c(2.6, 0.6, 0))
    b <- barplot(rbind(sd$matched, sd$parsed_vars - sd$matched), horiz = TRUE,
                 names.arg = sd$source, las = 1, border = NA, col = c(PA_COL, GREY),
                 xlab = "parsed codebook variables", xlim = c(0, max(sd$parsed_vars) * 1.28),
                 main = "Codebook provenance")
    text(sd$parsed_vars + max(sd$parsed_vars) * 0.01, b,
         sprintf("%d/%d  (%.0f%%)", sd$matched, sd$parsed_vars, sd$match_rate),
         cex = 0.8, col = PA_COL, adj = 0)
    legend("bottomright", c("matched to data", "unmatched"),
           fill = c(PA_COL, GREY), border = NA, bty = "n", cex = 0.9)
    dev.off()
  }

  # ── Coverage + haven-label-quality summaries (back the thesis prose numbers) ─
  # Thesis cites: ~21% of columns labelled (whole corpus), ~66% within codebook
  # repos, ~91% of haven labels informative, mean haven label 45.8 vs name 10.4
  # chars. No standalone figure/table — written to CSV for traceability.
  if (length(labs_l)) {
    matched_lab <- function(s) s %in% c("labelled", "conflicting_definition")
    strict      <- function(s) s %in% "labelled"
    cover_one <- function(L, scope) data.frame(scope = scope, n_papers = length(L),
      n_cols = sum(vapply(L, nrow, integer(1))),
      labelled_pa = round(100 * mean(sapply(L, function(d) mean(strict(d$label_status)))), 1),
      matched_pa  = round(100 * mean(sapply(L, function(d) mean(matched_lab(d$label_status)))), 1),
      stringsAsFactors = FALSE)
    rows <- list(cover_one(labs_l, "whole corpus"))
    cb_lab <- labs_l[intersect(names(cov_l), names(labs_l))]   # repos with a parsed codebook
    if (length(cb_lab)) rows[[2]] <- cover_one(cb_lab, "codebook-corpus")
    coverage_df <- do.call(rbind, rows)
    write.csv(coverage_df, file.path(COMP_DIR, "coverage_summary.csv"), row.names = FALSE)
  }
  if (length(cov_l)) {
    cov <- do.call(rbind, cov_l)
    if (any(cov$parse_method == "haven")) {
      hv  <- cov[cov$parse_method == "haven", , drop = FALSE]
      lab <- ifelse(is.na(hv$label), "", hv$label)
      var <- ifelse(is.na(hv$codebook_variable), "", hv$codebook_variable)
      norm <- function(x) gsub("[^a-z0-9]", "", tolower(trimws(x)))
      informative <- norm(lab) != "" & norm(lab) != norm(var)
      pa_stat <- function(x, f) round(mean(tapply(x, hv$paper_id, f)), 1)
      haven_quality_df <- data.frame(
        n_haven_vars   = nrow(hv), n_haven_papers = length(unique(hv$paper_id)),
        informative_pa = round(100 * mean(tapply(informative, hv$paper_id, mean)), 1),
        label_len_mean_pa = pa_stat(nchar(lab), mean),
        name_len_mean_pa  = pa_stat(nchar(var), mean), stringsAsFactors = FALSE)
      write.csv(haven_quality_df, file.path(COMP_DIR, "haven_label_quality.csv"), row.names = FALSE)
    }
  }
  cat(sprintf("Stage 4 wrote variables.png, codebook_sources.png, coltype_distribution.{csv,tex} + coverage/haven summaries (%d repos)\n",
              length(cols_l)))
})

# ============================================================================
# === STAGE 5 — PsychDS conversion + validation (§0.1.3, reports only) ───────
# ============================================================================
# Reads the two summary CSVs from the frozen run; computes nothing about the
# datasets themselves. Conversion = pipeline/3_psychds_convert.R (unit = one
# study group; success=FALSE here is a DataCheck-side parse/convert failure,
# before spec validation). Validation = npm `psychds-validator` CLI run inside
# the full-run pipeline, which deletes each psychDS dir afterwards — so only the
# validity rows survive. A repository passes iff all its study groups validate.
local({
  conv_path <- file.path(PSYCHDS_BASE, "conversion_summary.csv")
  val_path  <- file.path(PSYCHDS_BASE, "validation_summary.csv")
  if (!file.exists(conv_path)) {
    cat(sprintf("Stage 5 skipped — no conversion_summary.csv at %s\n", conv_path))
    return(invisible(NULL))
  }
  istrue <- function(x) x %in% c(TRUE, "TRUE")
  conv <- read.csv(conv_path, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
  val  <- if (file.exists(val_path))
            read.csv(val_path, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
          else NULL

  # ── conversion funnel + failure reasons ─────────────────────────────────────
  n_groups <- nrow(conv); n_repos <- length(unique(conv$paper_id))
  conv_ok  <- istrue(conv$success); n_conv <- sum(conv_ok)
  fail     <- conv[!conv_ok, ]; n_fail <- nrow(fail)
  reason <- function(e) {
    e <- ifelse(is.na(e) | !nzchar(e), "unspecified", e)
    e <- sub("\\n.*$", "", e)                                  # first line only
    e <- ifelse(grepl("UTF-8|locale|invalid in this", e), "encoding (non-UTF-8 input)", e)
    ifelse(grepl("no_data_files", e), "no data files in group", e)
  }
  fr <- sort(table(reason(fail$error)), decreasing = TRUE)
  conv_df <- data.frame(reason = names(fr), n_groups = as.integer(fr),
    n_repos = vapply(names(fr), function(r)
      length(unique(fail$paper_id[reason(fail$error) == r])), integer(1)),
    row.names = NULL, stringsAsFactors = FALSE)
  write.csv(conv_df, file.path(COMP_DIR, "psychds_conversion_reasons.csv"), row.names = FALSE)

  cat(sprintf("\nPsychDS conversion: %d study groups from %d repositories — %d converted (%.1f%%), %d failed (%.1f%%).\n",
              n_groups, n_repos, n_conv, 100 * n_conv / n_groups, n_fail, 100 * n_fail / n_groups))

  # ── validation outcomes + error keys ────────────────────────────────────────
  if (!is.null(val) && nrow(val) > 0) {
    parsed <- istrue(val$parsed); is_valid <- istrue(val$valid)
    n_val <- nrow(val); n_valid <- sum(is_valid, na.rm = TRUE)
    paper_ok <- tapply(is_valid, val$paper_id, all)            # repo valid iff all groups pass
    ek <- unlist(strsplit(val$error_keys[nzchar(val$error_keys)], ";"))
    ek_tab <- sort(table(ek), decreasing = TRUE)
    errkey_df <- data.frame(error_key = names(ek_tab), n_datasets = as.integer(ek_tab),
                            row.names = NULL, stringsAsFactors = FALSE)
    write.csv(errkey_df, file.path(COMP_DIR, "psychds_error_keys.csv"), row.names = FALSE)
    cat(sprintf("PsychDS validation: %d datasets validated — %d valid (%.1f%%); repositories fully valid: %d / %d.\n",
                n_val, n_valid, 100 * n_valid / n_val, sum(paper_ok, na.rm = TRUE), length(paper_ok)))
    if (nrow(errkey_df)) cat(sprintf("Top validator error key: %s (%d datasets).\n",
                                     errkey_df$error_key[1], errkey_df$n_datasets[1]))
  } else {
    cat("PsychDS validation: validation_summary.csv absent — conversion funnel only.\n")
  }
})

cat(sprintf("\nDone. All thesis figures + tables written under: %s\n", COMP_DIR))
