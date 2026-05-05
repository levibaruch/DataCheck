# run_ab_test.R
# ─────────────────────────────────────────────────────────────────────────────
# Three-way test: STRUCTURE_PROMPT_v0 (original rule-based, pre-output type)
#                 vs. STRUCTURE_PROMPT_OLD (v1, 2026-04 rule-based)
#                 vs. STRUCTURE_PROMPT    (v2, 2026-04 principle-based)
# on the test paper repository.
#
# Runs only Stage 1 (run_index) for each paper × condition.
# Accuracy is evaluated against tests/ground_truth/<paper_id>.csv.
#
# Outputs:
#   ab_test/results/v0/<paper_id>/ — structure.csv for condition v0
#   ab_test/results/v1/<paper_id>/ — structure.csv for condition v1
#   ab_test/results/v2/<paper_id>/ — structure.csv for condition v2
#   ab_test/ab_log.csv             — one row per paper × condition
#   ab_test/ab_report_<date>.md    — side-by-side comparison report
#
# Usage:  Rscript ab_test/run_ab_test.R
#         source("ab_test/run_ab_test.R")
#
# To rerun a single condition and overwrite its log rows + results:
#   RERUN_CONDITION <- "v2"   # or "v0", "v1"
#   source("ab_test/run_ab_test.R")
# ─────────────────────────────────────────────────────────────────────────────
FULL_RUN <- TRUE
REPORT_ONLY <- FALSE

#RERUN_CONDITION <- "v2"   # or "v0", "v1"

if (!exists("RERUN_CONDITION")) RERUN_CONDITION <- NULL   # NULL = run both
if (!exists("REPORT_ONLY"))     REPORT_ONLY     <- FALSE  # TRUE = skip pipeline, regenerate report

# ── Paths ──────────────────────────────────────────────────────────────────────

AB_DIR      <- "./ab_test"
RESULTS_DIR <- file.path(AB_DIR, "results")
V0_DIR      <- file.path(RESULTS_DIR, "v0")
V1_DIR      <- file.path(RESULTS_DIR, "v1")
V2_DIR      <- file.path(RESULTS_DIR, "v2")
LOG_PATH    <- file.path(AB_DIR, "ab_log.csv")
TEST_DIR    <- "./tests"
GT_DIR      <- file.path(TEST_DIR, "ground_truth/osf")

for (d in c(V0_DIR, V1_DIR, V2_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# ── Test papers ────────────────────────────────────────────────────────────────

test_papers_df <- read.csv(
  file.path(TEST_DIR, "test_papers.csv"),
  colClasses       = c(id = "character"),
  stringsAsFactors = FALSE
)

# ── Helpers ────────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

pct <- function(n, d) if (d == 0L) "n/a" else sprintf("%.1f%%", 100 * n / d)

na_dash <- function(x) ifelse(is.na(x) | x == "NA", "—", as.character(x))

md_table <- function(df) {
  df[] <- lapply(df, na_dash)
  hdr  <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep  <- paste0("| ", paste(rep("---", ncol(df)), collapse = " | "), " |")
  rows <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
  paste(c(hdr, sep, rows), collapse = "\n")
}

# ── Sources (skipped in report-only mode) ─────────────────────────────────────

if (!REPORT_ONLY) source("pipeline/0_index.R")  # loads STRUCTURE_PROMPT + SCHEMA_STRUCTURE_PROMPT

# ── Log ────────────────────────────────────────────────────────────────────────

LOG_COLS <- c(
  "run_id", "condition", "paper_id", "label",
  "success", "error",
  "n_files", "n_data_files", "elapsed_sec",
  "type_correct", "type_total", "type_acc",
  "group_correct", "group_total", "group_acc"
)

write_log_row <- function(row) {
  for (col in LOG_COLS) if (is.null(row[[col]])) row[[col]] <- NA_character_
  df <- as.data.frame(row, stringsAsFactors = FALSE)[, LOG_COLS]
  write.table(df,
    file      = LOG_PATH,
    sep       = ",",
    col.names = !file.exists(LOG_PATH),
    row.names = FALSE,
    append    = TRUE,
    qmethod   = "double"
  )
}

# Compute accuracy vs ground truth for a structure.csv + gt file pair
compute_accuracy <- function(str_path, gt_path) {
  out <- list(type_correct = NA, type_total = NA, type_acc = NA,
              group_correct = NA, group_total = NA, group_acc = NA)
  if (!file.exists(gt_path) || !file.exists(str_path)) return(out)
  gt  <- read.csv(gt_path,  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
  str <- read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
  if (nrow(gt) == 0) return(out)
  m <- merge(gt[, c("rel_path", "type_gt", "group_gt")],
             str[, intersect(c("rel_path", "type", "group"), names(str))],
             by = "rel_path", all.x = TRUE)
  data_m <- m[!is.na(m$type_gt) & m$type_gt == "data", ]
  out$type_total   <- sum(!is.na(m$type_gt))
  out$type_correct <- sum(!is.na(m$type_gt) & !is.na(m$type) & m$type_gt == m$type)
  out$type_acc     <- pct(out$type_correct, out$type_total)
  out$group_total  <- sum(!is.na(data_m$group_gt))
  out$group_correct <- sum(!is.na(data_m$group_gt) & !is.na(data_m$group) &
                             data_m$group_gt == data_m$group)
  out$group_acc    <- pct(out$group_correct, out$group_total)
  out
}

# ── Report generator ──────────────────────────────────────────────────────────

generate_report <- function(run_id = NULL) {
  if (!file.exists(LOG_PATH)) {
    cat("  [report] ab_log.csv not found — run the pipeline first\n")
    return(invisible(NULL))
  }

  log_df <- read.csv(LOG_PATH, colClasses = c(paper_id = "character"),
                     stringsAsFactors = FALSE)

  # For each condition × paper: prefer the fresh row from run_id if it exists,
  # otherwise fall back to the latest prior row. This handles partial re-runs
  # where only some papers were re-run for a condition.
  pick_rows <- function(cond_name) {
    all_rows <- log_df[log_df$condition == cond_name, ]
    if (nrow(all_rows) == 0) return(all_rows)
    do.call(rbind, lapply(unique(all_rows$paper_id), function(pid) {
      rows <- all_rows[all_rows$paper_id == pid, ]
      if (!is.null(run_id)) {
        fresh <- rows[rows$run_id == run_id, ]
        if (nrow(fresh) > 0) return(fresh[nrow(fresh), , drop = FALSE])
      }
      rows[tail(order(rows$run_id), 1L), , drop = FALSE]
    }))
  }

  v0_rows     <- pick_rows("v0")
  nlp_rows    <- pick_rows("v1")
  schema_rows <- pick_rows("v2")

  latest_run <- if (!is.null(run_id)) run_id else {
    tail(sort(unique(log_df$run_id)), 1L)
  }

  lines <- character(0)
  L  <- function(...) { lines <<- c(lines, paste0(...)) }
  BR <- function()    { lines <<- c(lines, "") }

  short_label <- function(lbl) substr(lbl %||% "—", 1L, 50L)

  summarise_acc <- function(rows) {
    tc <- sum(as.integer(rows$type_correct),  na.rm = TRUE)
    tn <- sum(as.integer(rows$type_total),    na.rm = TRUE)
    gc <- sum(as.integer(rows$group_correct), na.rm = TRUE)
    gn <- sum(as.integer(rows$group_total),   na.rm = TRUE)
    list(type_correct = tc, type_total = tn, type_acc = pct(tc, tn),
         group_correct = gc, group_total = gn, group_acc = pct(gc, gn))
  }

  compute_per_type <- function(out_dir) {
    acc_list <- lapply(test_papers_df$id, function(pid) {
      gt_path  <- file.path(GT_DIR, paste0(pid, ".csv"))
      str_path <- file.path(out_dir, pid, "structure.csv")
      if (!file.exists(gt_path) || !file.exists(str_path)) return(NULL)
      gt  <- read.csv(gt_path,  colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
      str <- read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
      if (nrow(gt) == 0) return(NULL)
      merge(gt[, c("rel_path", "type_gt")],
            str[, intersect(c("rel_path", "type"), names(str))],
            by = "rel_path", all.x = TRUE)
    })
    acc <- do.call(rbind, acc_list[!sapply(acc_list, is.null)])
    if (is.null(acc) || nrow(acc) == 0) return(NULL)
    all_types <- sort(unique(acc$type_gt[!is.na(acc$type_gt)]))
    do.call(rbind, lapply(all_types, function(t) {
      rows <- acc[!is.na(acc$type_gt) & acc$type_gt == t, ]
      n    <- nrow(rows)
      corr <- sum(!is.na(rows$type) & rows$type == t)
      data.frame(Type = t, N = n, Correct = corr, Recall = pct(corr, n),
                 stringsAsFactors = FALSE)
    }))
  }

  date_str <- format(Sys.Date(), "%Y-%m-%d")
  L("# AB Test Report — v0 (original) vs v1 (rule-based) vs v2 (principle-based) Prompt — ", date_str)
  BR()
  L("**Run:** `", latest_run, "`  |  **Papers:** ", nrow(test_papers_df),
    "  |  **Conditions:** v0, v1, v2")
  BR()
  L("> Compares `STRUCTURE_PROMPT_v0` (original) against")
  L("> `STRUCTURE_PROMPT_OLD` (v1, 2026-04 exhaustive rule list) against")
  L("> `STRUCTURE_PROMPT` (v2, 2026-04 principle-based with annotated examples).")
  BR()
  L("---")
  BR()

  # 1. Overall Accuracy
  v0_sum     <- summarise_acc(v0_rows)
  nlp_sum    <- summarise_acc(nlp_rows)
  schema_sum <- summarise_acc(schema_rows)
  L("## 1. Overall Accuracy")
  BR()
  L("| Metric | v0 (original) | v1 (rule-based) | v2 (principle-based) |")
  L("|---|---|---|---|")
  L(sprintf("| **File type** | %s (%d/%d) | %s (%d/%d) | %s (%d/%d) |",
    v0_sum$type_acc,     v0_sum$type_correct,     v0_sum$type_total,
    nlp_sum$type_acc,    nlp_sum$type_correct,    nlp_sum$type_total,
    schema_sum$type_acc, schema_sum$type_correct, schema_sum$type_total))
  L(sprintf("| **Group** (data files) | %s (%d/%d) | %s (%d/%d) | %s (%d/%d) |",
    v0_sum$group_acc,     v0_sum$group_correct,     v0_sum$group_total,
    nlp_sum$group_acc,    nlp_sum$group_correct,    nlp_sum$group_total,
    schema_sum$group_acc, schema_sum$group_correct, schema_sum$group_total))
  BR()
  L("---")
  BR()

  # 2. Per-Paper
  L("## 2. Per-Paper Accuracy")
  BR()
  per_paper_rows <- do.call(rbind, lapply(test_papers_df$id, function(pid) {
    z0 <- v0_rows[v0_rows$paper_id         == pid, ]
    nr <- nlp_rows[nlp_rows$paper_id       == pid, ]
    sr <- schema_rows[schema_rows$paper_id == pid, ]
    data.frame(
      Paper         = pid,
      Label         = short_label(test_papers_df$label[test_papers_df$id == pid]),
      `v0 type`  = if (nrow(z0) > 0) z0$type_acc  %||% "—" else "—",
      `v1 type`  = if (nrow(nr) > 0) nr$type_acc  %||% "—" else "—",
      `v2 type`  = if (nrow(sr) > 0) sr$type_acc  %||% "—" else "—",
      `v0 group` = if (nrow(z0) > 0) z0$group_acc %||% "—" else "—",
      `v1 group` = if (nrow(nr) > 0) nr$group_acc %||% "—" else "—",
      `v2 group` = if (nrow(sr) > 0) sr$group_acc %||% "—" else "—",
      `v0 s`     = if (nrow(z0) > 0) sprintf("%.1f", as.numeric(z0$elapsed_sec) %||% NA) else "—",
      `v1 s`     = if (nrow(nr) > 0) sprintf("%.1f", as.numeric(nr$elapsed_sec) %||% NA) else "—",
      `v2 s`     = if (nrow(sr) > 0) sprintf("%.1f", as.numeric(sr$elapsed_sec) %||% NA) else "—",
      check.names   = FALSE, stringsAsFactors = FALSE
    )
  }))
  L(md_table(per_paper_rows))
  BR()
  L("---")
  BR()

  # 3. Per-Type Recall
  v0_pt     <- compute_per_type(V0_DIR)
  nlp_pt    <- compute_per_type(V1_DIR)
  schema_pt <- compute_per_type(V2_DIR)
  L("## 3. Per-Type Recall")
  BR()
  if (!is.null(nlp_pt) && !is.null(schema_pt)) {
    merged_pt <- merge(nlp_pt, schema_pt, by = "Type", all = TRUE,
                       suffixes = c("_v1", "_v2"))
    if (!is.null(v0_pt)) {
      merged_pt <- merge(v0_pt[, c("Type", "N", "Recall")], merged_pt, by = "Type", all = TRUE)
      names(merged_pt)[names(merged_pt) == "N"]      <- "N_v0"
      names(merged_pt)[names(merged_pt) == "Recall"] <- "Recall_v0"
    }
    pt_out <- data.frame(
      Type        = merged_pt$Type,
      `N (v0)`    = if (!is.null(v0_pt)) merged_pt$N_v0      %||% "—" else "—",
      `Recall v0` = if (!is.null(v0_pt)) merged_pt$Recall_v0 %||% "—" else "—",
      `Recall v1` = merged_pt$Recall_v1 %||% "—",
      `Recall v2` = merged_pt$Recall_v2 %||% "—",
      check.names = FALSE, stringsAsFactors = FALSE
    )
    L(md_table(pt_out))
  } else {
    L("_No ground truth available — skipping per-type recall._")
  }
  BR()
  L("---")
  BR()

  # 4. Timing
  L("## 4. Timing")
  BR()
  summarise_time <- function(rows) {
    secs <- suppressWarnings(as.numeric(rows$elapsed_sec))
    secs <- secs[!is.na(secs)]
    if (length(secs) == 0) return(list(n = 0L, total = "—", mean = "—", median = "—"))
    list(
      n      = length(secs),
      total  = sprintf("%.1fs", sum(secs)),
      mean   = sprintf("%.1fs", mean(secs)),
      median = sprintf("%.1fs", median(secs))
    )
  }
  t0 <- summarise_time(v0_rows)
  t1 <- summarise_time(nlp_rows)
  t2 <- summarise_time(schema_rows)
  L("| Metric | v0 (original) | v1 (rule-based) | v2 (principle-based) |")
  L("|---|---|---|---|")
  L(sprintf("| **Total** | %s | %s | %s |",   t0$total,  t1$total,  t2$total))
  L(sprintf("| **Mean / paper** | %s | %s | %s |",  t0$mean,   t1$mean,   t2$mean))
  L(sprintf("| **Median / paper** | %s | %s | %s |", t0$median, t1$median, t2$median))
  L(sprintf("| **N papers** | %d | %d | %d |",       t0$n,      t1$n,      t2$n))
  BR()
  L("---")
  BR()

  # 5. Notes
  L("## 5. Notes")
  BR()
  L("- **v0**: `STRUCTURE_PROMPT_v0` — original prompt.")
  L("- **v1**: `STRUCTURE_PROMPT_OLD` — 2026-04 exhaustive rule list with per-extension lookup tables.")
  L("- **v2**: `STRUCTURE_PROMPT` — 2026-04 principle-based with annotated examples; ~40% shorter.")
  L("- Only Stage 1 (structure index) was run; codebook and PsychDS stages were skipped.")
  L("- Outputs: `ab_test/results/v0/`, `ab_test/results/v1/`, and `ab_test/results/v2/`")
  BR()
  L("---")
  BR()

  # 6. Prompts
  L("## 6. Prompts")
  BR()
  prompt_vars <- list(
    v0 = "STRUCTURE_PROMPT_v0",
    v1 = "STRUCTURE_PROMPT_OLD",
    v2 = "STRUCTURE_PROMPT"
  )
  # Load prompts from file if not already in environment
  prompts_env <- new.env(parent = emptyenv())
  if (!all(sapply(unlist(prompt_vars), exists, envir = globalenv(), USE.NAMES = FALSE))) {
    source("pipeline/prompts.R", local = prompts_env)
  }
  get_prompt <- function(var_name) {
    if (exists(var_name, envir = globalenv())) get(var_name, envir = globalenv())
    else if (exists(var_name, envir = prompts_env)) get(var_name, envir = prompts_env)
    else NULL
  }

  for (cond_name in names(prompt_vars)) {
    var_name <- prompt_vars[[cond_name]]
    L("### ", cond_name, " — `", var_name, "`")
    BR()
    p <- get_prompt(var_name)
    if (!is.null(p)) {
      L("```")
      L(p)
      L("```")
    } else {
      L("_Prompt `", var_name, "` not found._")
    }
    BR()
  }

  report_path <- file.path(AB_DIR, sprintf("ab_report_%s.md", latest_run))
  writeLines(lines, report_path)
  cat(sprintf("  [report] written: %s\n", report_path))
  invisible(report_path)
}

# ── Entry point ───────────────────────────────────────────────────────────────

if (REPORT_ONLY) {
  generate_report()
  invisible(NULL)
} else {

# ── Main loop ──────────────────────────────────────────────────────────────────

RUN_ID   <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider  <- paste0(rep("─", 72), collapse = "")
divider_h <- paste0(rep("═", 72), collapse = "")

ALL_CONDITIONS <- list(
  list(name = "v0", prompt = STRUCTURE_PROMPT_v0,  out_dir = V0_DIR),
  list(name = "v1", prompt = STRUCTURE_PROMPT_OLD, out_dir = V1_DIR),
  list(name = "v2", prompt = STRUCTURE_PROMPT,     out_dir = V2_DIR)
)

CONDITIONS <- if (!is.null(RERUN_CONDITION)) {
  matches <- Filter(function(c) c$name == RERUN_CONDITION, ALL_CONDITIONS)
  if (length(matches) == 0) stop("Unknown RERUN_CONDITION: ", RERUN_CONDITION)
  # Drop all prior log rows for this condition so the report reflects the fresh run
  if (file.exists(LOG_PATH)) {
    old <- read.csv(LOG_PATH, colClasses = c(paper_id = "character"),
                    stringsAsFactors = FALSE)
    old <- old[old$condition != RERUN_CONDITION, ]
    write.csv(old, LOG_PATH, row.names = FALSE, quote = TRUE)
  }
  cat(sprintf("  Rerunning condition: %s (prior rows removed from log)\n", RERUN_CONDITION))
  matches
} else {
  ALL_CONDITIONS
}

n_cond <- length(CONDITIONS)
cat(sprintf("\n%s\n  AB TEST %s — %d papers × %d condition(s): %s  [v0=original, v1=rule-based, v2=principle-based]\n%s\n",
  divider_h, RUN_ID, nrow(test_papers_df), n_cond,
  paste(sapply(CONDITIONS, `[[`, "name"), collapse = ", "), divider_h))

# Load existing log once so we can skip already-completed paper × condition pairs
existing_log <- if (file.exists(LOG_PATH)) {
  read.csv(LOG_PATH, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
} else {
  data.frame(condition = character(), paper_id = character(), stringsAsFactors = FALSE)
}

for (i in seq_len(nrow(test_papers_df))) {
  pid   <- test_papers_df$id[i]
  label <- test_papers_df$label[i]
  cat(sprintf("\n%s\n  %s\n  %s\n%s\n", divider, pid, label, divider))

  for (cond in CONDITIONS) {
    # Skip if a log entry already exists for this paper × condition
    already_done <- any(existing_log$condition == cond$name & existing_log$paper_id == pid)
    if (already_done) {
      cat(sprintf("  [%s] skipping (already in log)\n", cond$name))
      next
    }
    cat(sprintf("  [%s] running...\n", cond$name))

    # Swap the prompt for this condition
    STRUCTURE_PROMPT <<- cond$prompt

    pid_out_dir <- file.path(cond$out_dir, pid)
    dir.create(pid_out_dir, recursive = TRUE, showWarnings = FALSE)

    row <- list(run_id = RUN_ID, condition = cond$name, paper_id = pid, label = label)

    t_start <- proc.time()[["elapsed"]]
    s1 <- tryCatch(
      run_index(paper_id = pid, download = FALSE, output_dir = pid_out_dir),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    row$elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)

    if (!isTRUE(s1$success)) {
      cat(sprintf("  [%s] ERROR: %s\n", cond$name, s1$error))
      row$success <- FALSE
      row$error   <- s1$error
    } else {
      row$success      <- TRUE
      row$n_files      <- s1$n_files
      row$n_data_files <- s1$n_data_files

      acc <- compute_accuracy(
        file.path(pid_out_dir, "structure.csv"),
        file.path(GT_DIR, paste0(pid, ".csv"))
      )
      row <- c(row, acc)

      cat(sprintf("  [%s] files=%d  data=%d  elapsed=%.1fs  type=%s  group=%s\n",
        cond$name, s1$n_files, s1$n_data_files, row$elapsed_sec,
        acc$type_acc %||% "n/a", acc$group_acc %||% "n/a"))
    }

    write_log_row(row)
  }
}

generate_report(run_id = RUN_ID)

cat(sprintf("\n%s\n  AB test complete [%s]\n  log:    %s\n%s\n\n",
  divider_h, RUN_ID, LOG_PATH, divider_h))

} # end !REPORT_ONLY
