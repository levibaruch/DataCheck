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


REPORT_ONLY <- TRUE
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
LLM_MODEL        <- "ollama/gpt-oss:20b-cloud"
llm_model(LLM_MODEL)
TEST_TITLE       <- sprintf("_%s_MD_THINK_%s_TEMP_%s", "20b", LLM_THINK_LEVEL, LLM_TEMPERATURE) #MD stands for the markdown Prompt
STRUCTURE_PROMPT <- STRUCTURE_PROMPT_MD

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
    n_gt       <- nrow(acc)
    n_gt_paps  <- length(unique(acc$paper_id))
    data_acc   <- acc[!is.na(acc$type_gt) & acc$type_gt == "data", ]
    dg_acc     <- data_acc[!is.na(data_acc$data_granularity_gt), ]

    tc <- sum(!is.na(acc$type_gt) & !is.na(acc$type) & acc$type_gt == acc$type)
    tn <- sum(!is.na(acc$type_gt))
    gc <- sum(!is.na(data_acc$group_gt) & !is.na(data_acc$group) & data_acc$group_gt == data_acc$group)
    gn <- sum(!is.na(data_acc$group_gt))
    dc <- sum(!is.na(dg_acc$data_granularity) & dg_acc$data_granularity_gt == dg_acc$data_granularity)
    dn <- nrow(dg_acc)

    L(sprintf("_Based on **%d annotated files** across **%d papers**_", n_gt, n_gt_paps))
    BR()
    L("| Metric | Correct | Total | Accuracy |")
    L("|---|---|---|---|")
    L(sprintf("| **File type** | %d | %d | **%s** |", tc, tn, pct(tc, tn)))
    L(sprintf("| **Group** (data files only) | %d | %d | **%s** |", gc, gn, pct(gc, gn)))
    L(sprintf("| **data_granularity** (data files only) | %d | %d | **%s** |", dc, dn, pct(dc, dn)))
    BR()

    # Per-paper
    L("### Per-Paper")
    BR()
    per_paper <- do.call(rbind, lapply(unique(acc$paper_id), function(pid) {
      a  <- acc[acc$paper_id == pid, ]
      da <- a[!is.na(a$type_gt) & a$type_gt == "data", ]
      dg <- da[!is.na(da$data_granularity_gt), ]
      n  <- sum(!is.na(a$type_gt))
      data.frame(
        Paper       = pid,
        Label       = short_label(pid),
        `Files GT`  = n,
        `Type acc`  = pct(sum(!is.na(a$type_gt) & !is.na(a$type) & a$type_gt == a$type), n),
        `Group acc` = { gn <- sum(!is.na(da$group_gt)); if (gn > 0) pct(sum(!is.na(da$group) & da$group_gt == da$group), gn) else "—" },
        `DG acc`    = { dn <- nrow(dg); if (dn > 0) pct(sum(!is.na(dg$data_granularity) & dg$data_granularity_gt == dg$data_granularity), dn) else "—" },
        check.names = FALSE, stringsAsFactors = FALSE
      )
    }))
    L(md_table(per_paper))
    BR()

    # Per-type recall
    L("### Per-Type Recall")
    BR()
    L("_How often each true type was correctly identified. \"Confused with\" shows the most common wrong prediction._")
    BR()
    all_types <- sort(unique(acc$type_gt[!is.na(acc$type_gt)]))
    per_type  <- do.call(rbind, lapply(all_types, function(t) {
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

    # type_source accuracy
    if ("type_source" %in% names(acc)) {
      L("### Accuracy by type_source")
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

    # Confusion matrix
    L("### Confusion Matrix")
    BR()
    L("_Rows = ground truth type, columns = predicted type. Correct predictions on diagonal._")
    BR()
    valid <- acc[!is.na(acc$type_gt) & !is.na(acc$type), ]
    if (nrow(valid) > 0) {
      ctypes <- sort(unique(c(valid$type_gt, valid$type)))
      cm_df  <- as.data.frame.matrix(
        table(gt = factor(valid$type_gt, levels = ctypes),
              pred = factor(valid$type, levels = ctypes))
      )
      L(md_table(cbind(data.frame(`type \\ pred` = rownames(cm_df),
                                   check.names = FALSE), cm_df)))
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

  # Per-paper thinking log path — llm_batch writes snippets here when CAPTURE_THINKING=TRUE
  THINKING_LOG_PATH <<- file.path(pid_out_dir, "thinking_traces.csv")

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
