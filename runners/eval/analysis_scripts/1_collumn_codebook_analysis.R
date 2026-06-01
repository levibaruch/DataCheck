#!/usr/bin/env Rscript
# eval_unvalidated.R — unvalidated-module summary for the frozen gpt-oss-120b +
# JSON run (runners/eval/run_full_120b_json.R): variable extraction, col_type
# distribution and codebook label coverage, none of which has ground truth to
# score against. Split out from eval.R (validated classification metrics);
# PsychDS conversion validation lives in its own runner, validate_psychds.R.
#
# Run from the repo root:  Rscript runners/eval/eval_unvalidated.R [run_base]
#
# Reads the per-paper outputs under:
#   results/eval/full_120b_json/outputs/<src>/<id>/{columns,labels,codebook_coverage}.csv
# Writes (under <run_base>/): unvalidated_summary.md + unvalidated_{coltype,
# coverage,sources}.csv + plots/{coltype,coverage,codebook_sources}.png.
#
# Reporting convention (see memory: report repository-averaged `_pa`, not
# file-pooled — each paper_id is one OSF repository):
#   - col_type and coverage are reported BOTH file-pooled and repository-weighted
#     (`_pa`). The repository-weighted figure is the HEADLINE; pooled is kept only
#     for contrast — it is swamped by a few pathological wide files (lots of
#     `empty` columns).
#   - "codebook-corpus" = papers with a PARSED codebook (>=1 codebook_coverage
#     row), NOT papers with any non-`no_codebook` label_status (that wrongly
#     counts `unlabelled` columns as codebook-present).
local({
  args     <- commandArgs(trailingOnly = TRUE)
  RUN_BASE <- if (length(args) >= 1) args[[1]] else "results/eval/full_120b_json"
  OUT_DIR  <- file.path(RUN_BASE, "outputs")
  if (!dir.exists(OUT_DIR)) stop("No outputs dir at ", OUT_DIR)

  MD_PATH       <- file.path(RUN_BASE, "unvalidated_summary.md")
  COLTYPE_PATH  <- file.path(RUN_BASE, "unvalidated_coltype.csv")
  COLTYPE_TEX   <- file.path(RUN_BASE, "unvalidated_coltype.tex")
  COVERAGE_PATH <- file.path(RUN_BASE, "unvalidated_coverage.csv")
  SOURCES_PATH  <- file.path(RUN_BASE, "unvalidated_sources.csv")
  PLOT_DIR      <- file.path(RUN_BASE, "plots")
  dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

  # ── Load every per-paper CSV, keyed by paper id ────────────────────────────
  rd <- function(p) if (file.exists(p) && file.info(p)$size > 0)
    tryCatch(read.csv(p, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")),
             error = function(e) NULL) else NULL

  paper_dirs <- list.dirs(OUT_DIR, recursive = TRUE)
  paper_dirs <- paper_dirs[file.exists(file.path(paper_dirs, "structure.csv")) |
                           file.exists(file.path(paper_dirs, "columns.csv"))]
  cols_l <- list(); labs_l <- list(); cov_l <- list()
  for (d in paper_dirs) {
    pid <- basename(d)
    c1 <- rd(file.path(d, "columns.csv"));           if (!is.null(c1) && nrow(c1)) cols_l[[pid]] <- c1
    l1 <- rd(file.path(d, "labels.csv"));            if (!is.null(l1) && nrow(l1)) labs_l[[pid]] <- l1
    v1 <- rd(file.path(d, "codebook_coverage.csv")); if (!is.null(v1) && nrow(v1)) cov_l[[pid]] <- v1
  }
  if (length(cols_l) == 0) stop("No columns.csv found under ", OUT_DIR)
  cols <- do.call(rbind, cols_l)
  labs <- if (length(labs_l)) do.call(rbind, labs_l) else NULL
  cov  <- if (length(cov_l))  do.call(rbind, cov_l)  else NULL

  # ── 1. Variables extracted ─────────────────────────────────────────────────
  n_papers_dir <- length(paper_dirs)
  n_vars       <- nrow(cols)
  n_files      <- length(unique(paste(cols$paper_id, cols$source_file)))
  percol       <- vapply(cols_l, nrow, integer(1))

  # ── 2. col_type distribution: repository-weighted (_pa) only ───────────────
  # File-pooled proportions are deliberately NOT reported — they are swamped by a
  # few pathological wide files. Every figure here is repository-weighted: the
  # proportion is computed within each repository, then averaged across repos.
  tt    <- sort(table(cols$col_type), decreasing = TRUE)
  types <- names(tt)
  pw    <- sapply(cols_l, function(df) {        # per-repository proportions
    tb <- table(factor(df$col_type, levels = types)); tb / sum(tb)
  })
  pwm <- rowMeans(pw)                            # repository-averaged proportion
  coltype_df <- data.frame(
    col_type = types,
    n        = as.integer(tt),                   # raw column count (total, not an average)
    pct_pa   = round(100 * pwm[types], 1),       # repository-weighted (headline)
    row.names = NULL, stringsAsFactors = FALSE
  )
  coltype_df <- coltype_df[order(-coltype_df$pct_pa), ]

  # ── 3. Codebook label coverage ─────────────────────────────────────────────
  # A column is "labelled" (strict) when label_status == "labelled"; "matched"
  # also counts "conflicting_definition" (found in codebook, defs disagree).
  matched <- function(s) s %in% c("labelled", "conflicting_definition")
  strict  <- function(s) s %in% "labelled"

  cb_papers <- names(cov_l)   # authoritative codebook-corpus: parsed codebook present

  cover_one <- function(L, scope) {
    A <- do.call(rbind, L)
    data.frame(
      scope        = scope,
      n_papers     = length(L),
      n_cols       = nrow(A),
      # repository-weighted only: per-paper rate, then averaged across papers.
      labelled_pa  = round(100 * mean(sapply(L, function(d) mean(strict(d$label_status)))), 1),
      matched_pa   = round(100 * mean(sapply(L, function(d) mean(matched(d$label_status)))), 1),
      stringsAsFactors = FALSE
    )
  }
  coverage_df <- NULL
  if (!is.null(labs)) {
    rows <- list(cover_one(labs_l, "whole corpus"))
    cb_lab <- labs_l[intersect(cb_papers, names(labs_l))]
    if (length(cb_lab)) rows[[2]] <- cover_one(cb_lab, "codebook-corpus")
    coverage_df <- do.call(rbind, rows)
  }

  # ── 4. Codebook provenance: haven-embedded vs README vs other structured ───
  sources_df <- NULL
  if (!is.null(cov)) {
    src <- ifelse(cov$parse_method == "haven", "haven-embedded",
           ifelse(grepl("readme", tolower(cov$codebook_source)), "README",
           "structured file"))
    matched_v <- cov$match_status == "matched"
    cats <- unique(src)
    sources_df <- do.call(rbind, lapply(cats, function(s) {
      sel <- src == s
      data.frame(source = s,
                 parsed_vars = sum(sel),
                 matched     = sum(sel & matched_v),
                 match_rate  = round(100 * mean(matched_v[sel]), 1),
                 papers      = length(unique(cov$paper_id[sel])),
                 stringsAsFactors = FALSE)
    }))
    sources_df <- rbind(sources_df,
      data.frame(source = "ALL", parsed_vars = nrow(cov), matched = sum(matched_v),
                 match_rate = round(100 * mean(matched_v), 1),
                 papers = length(unique(cov$paper_id)), stringsAsFactors = FALSE))
    sources_df <- sources_df[order(sources_df$source == "ALL", -sources_df$parsed_vars), ]
  }

  # ── 5. Haven label quality: is the extracted label > the variable name? ─────
  # haven .sav/.dta variable labels are only useful when they say more than the
  # column name. A label that just echoes the name (e.g. var "age" labelled
  # "age", or "Zlgses" -> "zlgses") is trivial and adds no semantic signal.
  # "informative" = normalised label differs from normalised name and is non-empty.
  HAVEN_QUALITY_PATH <- file.path(RUN_BASE, "unvalidated_haven_quality.csv")
  haven_quality_df <- NULL
  if (!is.null(cov) && any(cov$parse_method == "haven")) {
    hv   <- cov[cov$parse_method == "haven", , drop = FALSE]
    lab  <- ifelse(is.na(hv$label), "", hv$label)
    var  <- ifelse(is.na(hv$codebook_variable), "", hv$codebook_variable)
    norm <- function(x) gsub("[^a-z0-9]", "", tolower(trimws(x)))
    nl   <- norm(lab); nv <- norm(var)
    informative <- nl != "" & nl != nv
    # per-row size signal: raw char lengths, length gain, and char edit distance
    len_lab   <- nchar(lab); len_var <- nchar(var)
    len_delta <- len_lab - len_var                          # extra chars the label adds
    edit_dist <- mapply(function(a, b) adist(a, b)[1, 1], tolower(lab), tolower(var))
    Mode <- function(x) { u <- unique(x); u[which.max(tabulate(match(x, u)))] }  # most frequent value
    # repository-weighted (_pa): compute the statistic within each paper, then
    # average across papers so every repo carries equal weight (memory convention).
    pa <- function(x, f) round(mean(tapply(x, hv$paper_id, f)), 1)
    haven_quality_df <- data.frame(
      n_haven_vars       = nrow(hv),
      n_haven_papers     = length(unique(hv$paper_id)),
      informative_pa     = round(100 * mean(tapply(informative, hv$paper_id, mean)), 1),  # headline (repository-weighted)
      # all mean / median / mode are repository-weighted (_pa): per-paper then averaged
      label_len_mean_pa  = pa(len_lab, mean),  label_len_median_pa = pa(len_lab, median),  label_len_mode_pa = pa(len_lab, Mode),
      name_len_mean_pa   = pa(len_var, mean),   name_len_median_pa  = pa(len_var, median),  name_len_mode_pa  = pa(len_var, Mode),
      len_delta_mean_pa  = pa(len_delta, mean), len_delta_median_pa = pa(len_delta, median), len_delta_mode_pa = pa(len_delta, Mode),
      edit_dist_mean_pa  = pa(edit_dist, mean), edit_dist_median_pa = pa(edit_dist, median), edit_dist_mode_pa = pa(edit_dist, Mode),
      stringsAsFactors   = FALSE)
  }

  # ── Write CSVs ──────────────────────────────────────────────────────────────
  write.csv(coltype_df, COLTYPE_PATH, row.names = FALSE)

  # LaTeX booktabs version of the col_type table (repository-weighted).
  tex <- c(
    "\\begin{table}[t]",
    "  \\centering",
    "  \\caption{Column-type distribution (repository-weighted). $n$ is the raw column count; \\texttt{pct\\_pa} is the per-repository proportion averaged across repositories.}",
    "  \\label{tab:coltype}",
    "  \\begin{tabular}{lrr}",
    "    \\toprule",
    "    col\\_type & $n$ & pct\\_pa (\\%) \\\\",
    "    \\midrule",
    sprintf("    \\texttt{%s} & %s & %.1f \\\\",
            gsub("_", "\\\\_", coltype_df$col_type),
            formatC(coltype_df$n, format = "d", big.mark = ","),
            coltype_df$pct_pa),
    "    \\bottomrule",
    "  \\end{tabular}",
    "\\end{table}")
  writeLines(tex, COLTYPE_TEX)
  if (!is.null(haven_quality_df)) write.csv(haven_quality_df, HAVEN_QUALITY_PATH, row.names = FALSE)
  if (!is.null(coverage_df)) write.csv(coverage_df, COVERAGE_PATH, row.names = FALSE)
  if (!is.null(sources_df))  write.csv(sources_df,  SOURCES_PATH,  row.names = FALSE)

  # ── Visualizations (base R; palette matches runners/reports/report_normal.R) ─
  # Seaborn-style eval palette: _pa = blue, file-pooled = red, green = secondary.
  PA_COL <- "#4C72B0"; FP_COL <- "#C44E52"; GREEN <- "#55A868"; GREY <- "#BDBDBD"

  # 1a. per-repository variable count — log-scaled (heavy right skew: a handful
  # of pathological wide files dwarf the median repository).
  png(file.path(PLOT_DIR, "variables.png"), width = 950, height = 620, res = 110)
  par(mar = c(4.5, 4.5, 3, 1), mgp = c(2.6, 0.6, 0))
  h <- hist(log10(percol), breaks = 24, plot = FALSE)
  plot(h, col = PA_COL, border = "white", xaxt = "n",
       xlab = "variables per repository (log scale)", ylab = "repositories",
       main = "Per-repository variable count")
  ticks <- c(0, 1, 10,  100,  1000, 10000, 100000)
  visible_ticks <- ticks[ticks > 0 & ticks >= min(percol) & ticks <= max(percol)]
  axis(1,
       at = c(par("usr")[1], log10(visible_ticks)),
       labels = format(c(0, visible_ticks), big.mark = ",", scientific = FALSE))
  abline(v = log10(mean(percol)),   col = FP_COL, lwd = 2, lty = 2)
  abline(v = log10(median(percol)), col = GREEN,  lwd = 2, lty = 2)
  legend("topright", bty = "n",
         legend = c(sprintf("mean %.0f", mean(percol)),
                    sprintf("median %.0f", median(percol))),
         col = c(FP_COL, GREEN), lwd = 2, lty = 2)
  dev.off()

  # 4a. col_type — repository-weighted (_pa) only, sorted by _pa.
  ct <- coltype_df[order(coltype_df$pct_pa), ]   # bottom-up for horiz bars
  png(file.path(PLOT_DIR, "coltype.png"), width = 1000, height = 700, res = 100)
  par(mar = c(4.5, 11, 3, 1.5), mgp = c(2.6, 0.6, 0))
  b <- barplot(ct$pct_pa, horiz = TRUE, xlim = c(0, 60),
               names.arg = ct$col_type, las = 1, border = NA,
               col = PA_COL, cex.names = 0.85, xlab = "% of columns (repository-weighted)",
               main = "col_type distribution")
  text(ct$pct_pa + 1.2, b, sprintf("%.1f", ct$pct_pa), cex = 0.7, col = PA_COL, adj = 0)
  dev.off()

  # 4b. label coverage — whole corpus vs codebook-corpus, labelled & matched (_pa).
  if (!is.null(coverage_df)) {
    M <- rbind(labelled = coverage_df$labelled_pa, matched = coverage_df$matched_pa)
    colnames(M) <- sprintf("%s\n(n=%d papers)", coverage_df$scope, coverage_df$n_papers)
    png(file.path(PLOT_DIR, "coverage.png"), width = 850, height = 600, res = 100)
    par(mar = c(4, 4.5, 3, 1), mgp = c(2.6, 0.6, 0))
    b <- barplot(M, beside = TRUE, col = c(PA_COL, GREEN), border = NA, ylim = c(0, 100),
                 ylab = "% of columns (repository-weighted)",
                 main = "Codebook label coverage")
    text(b, M + 3, sprintf("%.1f", M), cex = 0.8, col = c(PA_COL, GREEN))
    legend("topleft", c("labelled", "matched (+conflicting)"),
           fill = c(PA_COL, GREEN), border = NA, bty = "n", cex = 0.9)
    dev.off()
  }
  # 4b2 codebook existence distribution across repositories (same histogram as variables.png, including the whole corpus).
  codebook_existence <- sapply(cov_l, nrow)   # per-repository codebook existence (0 = no parsed codebook)
  png(file.path(PLOT_DIR, "codebook_existence.png"), width = 950, height = 620, res = 110)
  par(mar = c(4.5, 4.5, 3, 1), mgp = c(2.6, 0.6, 0))
  h <- hist(log10(codebook_existence), breaks = 24, plot = FALSE)
  plot(h, col = PA_COL, border = "white", xaxt = "n",
       xlab = "codebook existence (log scale)", ylab = "repositories",
       main = "Codebook existence distribution")
  ticks <- c(0, 1, 10, 30, 100, 300, 1000, 3000, 10000, 30000, 100000)
  visible_ticks <- ticks[ticks > -10 & ticks >= min(codebook_existence) & ticks <= max(codebook_existence)]
  axis(1,
       at = c(par("usr")[1], log10(visible_ticks)),
       labels = format(c(0, visible_ticks), big.mark = ",", scientific = FALSE))
  dev.off()


  # 4c. codebook provenance — matched vs unmatched per source (stacked).
  if (!is.null(sources_df)) {
    sd <- sources_df[sources_df$source != "ALL", ]
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

  # ── Render markdown report ──────────────────────────────────────────────────
  md_tbl <- function(df, align = NULL) {
    nm <- names(df)
    if (is.null(align)) align <- rep("---", length(nm))
    body <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
    c(paste0("| ", paste(nm, collapse = " | "), " |"),
      paste0("| ", paste(align, collapse = " | "), " |"), body)
  }
  L <- c(
    "# Unvalidated-feature summary — frozen gpt-oss-120b + JSON run", "",
    sprintf("- Source: `%s`", OUT_DIR),
    sprintf("- Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    sprintf("- Paper dirs scanned: %d (columns: %d, labels: %d, parsed codebook: %d)",
            n_papers_dir, length(cols_l), length(labs_l), length(cov_l)),
    "- All percentages are **repository-weighted** (`_pa`): per-repository rate, then averaged across repos. File-pooled averages are not reported.", "",
    "## 1. Variables extracted", "",
    sprintf("- Total variables (column rows): **%d** across **%d** data files.", n_vars, n_files),
    sprintf("- Per-repository variables: mean %.1f, median %.0f (min %d, max %d).",
            mean(percol), median(percol), min(percol), max(percol)),
    "- Pooled counts are dominated by a few pathological wide files — repository-weighted figures below.", "",
    "![variables](plots/variables.png)", "",
    "## 2. col_type distribution", "",
    "Repository-weighted (`pct_pa`); file-pooled is not reported (swamped by wide sparse files, e.g. `empty`). `n` is the raw column count.",
    "![col_type](plots/coltype.png)", "",
    md_tbl(coltype_df, c("---", "---:", "---:")), ""
  )
  if (!is.null(coverage_df)) {
    L <- c(L, "## 3. Codebook label coverage", "",
      "`labelled` = clean codebook match; `matched` also counts `conflicting_definition`.",
      "Codebook-corpus = papers with a *parsed* codebook (not `unlabelled` columns).",
      "Coverage is repository-weighted (`_pa`); file-pooled is not reported.",
      "![coverage](plots/coverage.png)", "",
      md_tbl(coverage_df, c("---", "---:", "---:", "---:", "---:")), "")
  }
  if (!is.null(sources_df)) {
    L <- c(L, "## 4. Codebook provenance (parsed variables → data match)", "",
      "Includes haven-embedded variable labels (.sav/.dta) and README/structured-file codebooks.",
      "![sources](plots/codebook_sources.png)", "",
      md_tbl(sources_df, c("---", "---:", "---:", "---:", "---:")), "")
  }
  if (!is.null(haven_quality_df)) {
    L <- c(L, "## 5. Haven label quality (label vs variable name)", "",
      "Among haven-embedded labels (.sav/.dta), `informative` = the label says more",
      "than the column name (differs after lower-casing + stripping non-alphanumerics).",
      "A trivial label just echoes the name and carries no extra signal.",
      sprintf("- **%.1f%%** of haven labels are informative (repository-weighted; %d vars / %d papers).",
              haven_quality_df$informative_pa,
              haven_quality_df$n_haven_vars, haven_quality_df$n_haven_papers),
      "All length/edit stats below are repository-weighted (`_pa`): per-paper then averaged.",
      sprintf("- Label len: mean %.1f / median %.1f / mode %.1f chars; name len mean %.1f / median %.1f / mode %.1f.",
              haven_quality_df$label_len_mean_pa, haven_quality_df$label_len_median_pa, haven_quality_df$label_len_mode_pa,
              haven_quality_df$name_len_mean_pa, haven_quality_df$name_len_median_pa, haven_quality_df$name_len_mode_pa),
      sprintf("- Length delta: mean **+%.1f** / median +%.1f / mode +%.1f chars; edit dist mean %.1f / median %.1f / mode %.1f.",
              haven_quality_df$len_delta_mean_pa, haven_quality_df$len_delta_median_pa, haven_quality_df$len_delta_mode_pa,
              haven_quality_df$edit_dist_mean_pa, haven_quality_df$edit_dist_median_pa, haven_quality_df$edit_dist_mode_pa), "",
      md_tbl(haven_quality_df, rep("---:", ncol(haven_quality_df))), "")
  }
  writeLines(L, MD_PATH)

  cat(sprintf("Wrote:\n  %s\n  %s\n  %s\n", MD_PATH, COLTYPE_PATH, COLTYPE_TEX))
  if (!is.null(coverage_df)) cat(sprintf("  %s\n", COVERAGE_PATH))
  if (!is.null(sources_df))  cat(sprintf("  %s\n", SOURCES_PATH))
  if (!is.null(haven_quality_df)) cat(sprintf("  %s\n", HAVEN_QUALITY_PATH))
  cat(sprintf("  %s/{coltype,coverage,codebook_sources}.png\n", PLOT_DIR))
})
