# eval_helpers.R — shared functions for all eval runners

EVAL_RESULTS_DIR <- "./results/eval"
EVAL_LOGS_DIR    <- "./results/eval/logs"
GT_DIR           <- "./tests/ground_truth"
SENTINEL_VAL     <- "llm_error"

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

EVAL_MODELS <- list(
  list(model = "groq/llama-3.1-8b-instant",  think = FALSE,      label = "llama3.1-8b"),
  list(model = "ollama/gpt-oss:20b-cloud",   think = "low",      label = "gpt-oss-20b-low"),
  list(model = "ollama/gpt-oss:20b-cloud",   think = "medium",   label = "gpt-oss-20b-medium"),
  list(model = "ollama/gpt-oss:120b-cloud",  think = "low",      label = "gpt-oss-120b-low"),
  list(model = "ollama/gpt-oss:120b-cloud",  think = "medium",   label = "gpt-oss-120b-medium"),
  list(model = "ollama/qwen3-vl:235b-cloud", think = TRUE,        label = "qwen3-vl-235b-on")
)

EVAL_TEMPS <- c(0, 0.3, 0.7)

EVAL_PROMPTS <- list(
  list(version = "md",        label = "md"),
  list(version = "plaintext", label = "plaintext"),
  list(version = "json",      label = "json")
)

safe_label <- function(x) gsub("[^A-Za-z0-9._-]", "_", as.character(x))

read_gt <- function(pid, src = "osf") {
  path <- file.path(GT_DIR, src, paste0(pid, ".csv"))
  if (!file.exists(path)) return(NULL)
  read.csv(path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE)
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

# Compare structure.csv output to GT; return metrics row
eval_paper <- function(pid, output_dir, src = "osf") {
  gt <- read_gt(pid, src)
  str_path <- file.path(output_dir, "structure.csv")
  if (is.null(gt) || !file.exists(str_path)) return(NULL)
  str <- tryCatch(
    read.csv(str_path, colClasses = c(paper_id = "character"), stringsAsFactors = FALSE),
    error = function(e) NULL
  )
  if (is.null(str) || nrow(str) == 0) return(NULL)

  m <- merge(
    gt[, c("rel_path", "type_gt")],
    str[, intersect(c("rel_path", "type", "type_source"), names(str))],
    by = "rel_path", all.x = TRUE
  )
  valid  <- m[!is.na(m$type_gt) & !is.na(m$type), ]
  if (nrow(valid) < 1) return(NULL)

  all_t  <- sort(unique(c(valid$type_gt, valid$type)))
  cm_mat <- as.matrix(table(
    gt   = factor(valid$type_gt, levels = all_t),
    pred = factor(valid$type,    levels = all_t)
  ))
  s <- cm_stats(cm_mat)

  # micro F1 from per-class TP/FP/FN
  class_tp <- sapply(all_t, function(cls) sum(valid$type_gt == cls & valid$type == cls))
  class_fp <- sapply(all_t, function(cls) sum(valid$type_gt != cls & valid$type == cls))
  class_fn <- sapply(all_t, function(cls) sum(valid$type_gt == cls & valid$type != cls))
  mtp <- sum(class_tp); mfp <- sum(class_fp); mfn <- sum(class_fn)
  mp  <- if ((mtp + mfp) > 0) mtp / (mtp + mfp) else NA_real_
  mr  <- if ((mtp + mfn) > 0) mtp / (mtp + mfn) else NA_real_
  micro_f1 <- if (!is.na(mp) && !is.na(mr) && (mp + mr) > 0)
    2 * mp * mr / (mp + mr) * 100 else NA_real_

  retry_rate <- if ("type" %in% names(str))
    mean(str$type == SENTINEL_VAL, na.rm = TRUE) * 100 else NA_real_

  result <- list(
    paper_id   = pid,
    n_files    = nrow(valid),
    macro_f1   = s$macro_f1,
    micro_f1   = micro_f1,
    kappa      = s$kappa,
    mcc        = s$mcc,
    accuracy   = s$accuracy,
    retry_rate = retry_rate
  )
  # Attach named per-class F1s so callers can optionally save them
  if (!is.null(s$f1s)) attr(result, "f1s") <- s$f1s
  result
}

# Aggregate per-paper metrics into a summary row.
# If any paper_results carry an "f1s" attribute (named per-class F1 vector),
# the mean per class is appended as per_class_f1_<type> columns.
aggregate_metrics <- function(paper_results, model, think, temp,
                               prompt_format = NA, run_id = NA) {
  rows <- Filter(Negate(is.null), paper_results)
  if (length(rows) == 0) return(NULL)
  df <- do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
  out <- data.frame(
    run_id        = run_id,
    model         = model,
    think         = as.character(think),
    temp          = temp,
    prompt_format = prompt_format,
    n_papers      = nrow(df),
    macro_f1      = mean(df$macro_f1,   na.rm = TRUE),
    micro_f1      = mean(df$micro_f1,   na.rm = TRUE),
    kappa         = mean(df$kappa,      na.rm = TRUE),
    mcc           = mean(df$mcc,        na.rm = TRUE),
    accuracy      = mean(df$accuracy,   na.rm = TRUE),
    retry_rate    = mean(df$retry_rate, na.rm = TRUE),
    stringsAsFactors = FALSE
  )

  # Collect per-class F1s from attrs and average across papers
  all_f1s <- lapply(rows, function(r) attr(r, "f1s"))
  all_f1s <- Filter(Negate(is.null), all_f1s)
  if (length(all_f1s) > 0) {
    all_types <- unique(unlist(lapply(all_f1s, names)))
    for (tp in sort(all_types)) {
      vals <- sapply(all_f1s, function(v) {
        if (tp %in% names(v)) v[[tp]] else NA_real_
      })
      out[[paste0("per_class_f1_", tp)]] <- mean(vals, na.rm = TRUE)
    }
  }

  out
}

# Return TRUE if this (model, think, temp, prompt_format) cell already has a
# summary row in `results_path`. Used by step runners to skip completed cells.
cell_done <- function(results_path, model, think, temp, prompt_format = NA) {
  if (!file.exists(results_path)) return(FALSE)
  existing <- tryCatch(
    read.csv(results_path, stringsAsFactors = FALSE),
    error = function(e) NULL
  )
  if (is.null(existing) || nrow(existing) == 0) return(FALSE)
  match <- existing$model == model &
           existing$think == as.character(think) &
           existing$temp  == temp
  if (!is.na(prompt_format) && "prompt_format" %in% names(existing))
    match <- match & existing$prompt_format == prompt_format
  any(match, na.rm = TRUE)
}

# Return TRUE if structure.csv already exists for this paper output dir.
paper_done <- function(out_dir) file.exists(file.path(out_dir, "structure.csv"))

append_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  suppressWarnings(
    write.table(df, file = path, sep = ",",
                col.names = !file.exists(path),
                row.names = FALSE, append = TRUE, qmethod = "double")
  )
}
