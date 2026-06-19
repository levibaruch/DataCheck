# batch_size_calls.R
# ─────────────────────────────────────────────────────────────────────────────
# Describe how many structure-classification LLM calls the ground-truth corpus
# would need at each candidate batch size B.
#
# run_index() classifies in TWO separate phases, each chunked independently:
#   Phase 1: individual (non-aggregate) paths   -> ceil(n_individual / B) calls
#   Phase 2: aggregate folder GROUPS (collapsed) -> ceil(n_groups     / B) calls
# So a paper's calls = ceil(n_individual / B) + ceil(n_groups / B). Aggregate
# folders are collapsed to ONE sentinel each, so their member files cost nothing
# beyond the single group entry.
#
# Counts come from each paper's structure.csv (the real pipeline output, which
# carries the aggregate grouping that ground-truth CSVs lack). Corpus = papers
# that have a ground-truth file.
#
#   Rscript runners/analysis/batch_size_calls.R [B1 B2 ...]
# ─────────────────────────────────────────────────────────────────────────────

GT_DIR     <- "tests/ground_truth/osf"
STRUCT_DIR <- "outputs/osf"

args        <- commandArgs(trailingOnly = TRUE)
batch_sizes <- if (length(args) > 0) as.integer(args) else c(10L, 15L, 20L, 30L, 50L, 100L)
batch_sizes <- sort(unique(batch_sizes[is.finite(batch_sizes) & batch_sizes > 0]))

gt_ids <- sub("\\.csv$", "", list.files(GT_DIR, pattern = "\\.csv$"))
if (length(gt_ids) == 0) stop("No ground-truth CSVs under ", GT_DIR)

# Per paper: individual-path count and aggregate-group count from structure.csv.
counts <- lapply(gt_ids, function(id) {
  f <- file.path(STRUCT_DIR, id, "structure.csv")
  if (!file.exists(f)) return(NULL)
  d <- tryCatch(read.csv(f, stringsAsFactors = FALSE, check.names = FALSE),
                error = function(e) NULL)
  if (is.null(d) || !"aggregate_folder" %in% names(d)) return(NULL)
  agg    <- trimws(as.character(d$aggregate_folder))
  is_agg <- !is.na(agg) & nzchar(agg) & agg != "NA"
  data.frame(id = id,
             n_individual = sum(!is_agg),
             n_groups     = length(unique(agg[is_agg])),
             n_rows       = nrow(d),
             stringsAsFactors = FALSE)
})
counts <- do.call(rbind, counts)
n_paper <- nrow(counts)

cat(sprintf("Corpus: %d ground-truth papers (%d with structure.csv)\n",
            length(gt_ids), n_paper))
cat(sprintf("Individual paths/paper: median %d · mean %.1f · max %d · total %d\n",
            as.integer(median(counts$n_individual)), mean(counts$n_individual),
            max(counts$n_individual), sum(counts$n_individual)))
cat(sprintf("Aggregate groups/paper:  median %d · mean %.1f · max %d · total %d\n",
            as.integer(median(counts$n_groups)), mean(counts$n_groups),
            max(counts$n_groups), sum(counts$n_groups)))
cat(sprintf("(expanded rows incl. agg members: total %d — what naive row-count would overcount)\n\n",
            sum(counts$n_rows)))

pct <- function(x) sprintf("%.1f%%", 100 * x)

rows <- lapply(batch_sizes, function(B) {
  calls <- ceiling(counts$n_individual / B) + ceiling(counts$n_groups / B)
  data.frame(
    B            = B,
    total_calls  = sum(calls),
    mean_calls   = round(mean(calls), 2),
    median_calls = as.integer(median(calls)),
    max_calls    = max(calls),
    pct_1_call   = pct(mean(calls == 1)),
    pct_le_2     = pct(mean(calls <= 2)),
    pct_le_5     = pct(mean(calls <= 5)),
    stringsAsFactors = FALSE)
})
tab <- do.call(rbind, rows)

cat("Calls needed by batch size B  (calls = ceil(individual/B) + ceil(groups/B)):\n\n")
print(tab, row.names = FALSE)
cat("\n  pct_1_call = share of papers fully classified in a single LLM call\n")
