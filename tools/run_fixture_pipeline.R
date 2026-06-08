# run_fixture_pipeline.R — run the full pipeline on the fictitious fixture.
# Local data, no download, all four stages incl. report.
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")
source("pipeline/3_psychds_convert.R")
source("pipeline/4_report.R")

FULL_RUN         <- TRUE
DATA_DIR         <- "./data"
OUTPUT_DIR       <- "./outputs"
PSYCHDS_OUT_DIR  <- "./psychds"
GROUND_TRUTH_DIR <- "./tests/ground_truth"
LLM_TEMPERATURE  <- 0.7
LLM_THINK_LEVEL  <- "low"
CAPTURE_THINKING <- TRUE

llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

pid <- "0000000000000000"; src <- "osf"

cat("\n===== STAGE 1: index =====\n")
t <- proc.time()[["elapsed"]]
s1 <- tryCatch(run_index(paper_id = pid, download = FALSE),
               error = function(e) list(success = FALSE, error = conditionMessage(e)))
cat(sprintf("index: success=%s files=%s data=%s cols=%s (%.1fs)\n",
            s1$success %||% NA, s1$n_files %||% NA, s1$n_data_files %||% NA,
            s1$n_columns %||% NA, proc.time()[["elapsed"]] - t))
if (isFALSE(s1$success)) { cat("FAILED:", s1$error, "\n"); quit(save = "no") }

cat("\n===== STAGE 2: codebook label =====\n")
t <- proc.time()[["elapsed"]]
s2 <- tryCatch(run_codebook_label(paper_id = pid),
               error = function(e) list(success = FALSE, error = conditionMessage(e)))
cat(sprintf("codebook: status=%s labelled=%s unlabelled=%s vars=%s (%.1fs)\n",
            s2$label_status %||% NA, s2$n_labelled %||% NA, s2$n_unlabelled %||% NA,
            s2$n_codebook_vars %||% NA, proc.time()[["elapsed"]] - t))

cat("\n===== STAGE 3: psychds =====\n")
t <- proc.time()[["elapsed"]]
PSYCHDS_CSV <- file.path(PSYCHDS_OUT_DIR, "conversion_summary.csv")
s3 <- tryCatch(convert_psychds(pid),
               error = function(e) list(list(success = FALSE, error = conditionMessage(e))))
tryCatch(append_conversion_summary(s3, PSYCHDS_CSV), error = function(e) NULL)
cat(sprintf("psychds: ok=%s (%.1fs)\n",
            all(vapply(s3, function(r) isTRUE(r$success), logical(1))),
            proc.time()[["elapsed"]] - t))

cat("\n===== STAGE 4: report =====\n")
r <- tryCatch(run_report(pid, src),
              error = function(e) list(success = FALSE, error = conditionMessage(e)))
cat(sprintf("report: success=%s -> %s\n", r$success %||% NA, r$html_path %||% NA))
cat("\nDONE.\n")
