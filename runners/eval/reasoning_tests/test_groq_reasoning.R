# test_groq_reasoning.R
# Probe llm_groq() reasoning wiring after the groq.R patch.
# Confirms: (a) reasoning_effort propagates via think=, (b) include_reasoning
# returns trace in $thinking, (c) channels stay separate under JSON-only prompts.

library(metacheck)
source("pipeline/groq.R")

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

if (!nzchar(Sys.getenv("GROQ_API_KEY"))) stop("GROQ_API_KEY not set")

MODELS  <- c("groq/openai/gpt-oss-20b", "groq/openai/gpt-oss-120b")
EFFORTS <- c("low", "medium")

SYSTEM_PROMPT <- paste(
  "Classify the given filename. Respond with ONLY a JSON object,",
  "no prose, no markdown. Schema: {\"type\": \"data|code|doc\"}."
)
USER_TEXT <- "File: analysis.R"

divider <- paste0(rep("─", 72), collapse = "")
cat(sprintf("%s\n  llm_groq() reasoning probe\n%s\n", divider, divider))

for (m in MODELS) {
  for (e in EFFORTS) {
    cat(sprintf("\n── %s | think=%s\n", m, e))
    t0 <- proc.time()[["elapsed"]]

    res <- tryCatch(
      llm_groq(
        text             = USER_TEXT,
        system_prompt    = SYSTEM_PROMPT,
        model            = m,
        params           = list(temperature = 0.3),
        think            = e,
        capture_thinking = TRUE
      ),
      error = \(err) { cat(sprintf("  ERROR: %s\n", err$message)); NULL }
    )

    el <- round(proc.time()[["elapsed"]] - t0, 1)
    if (is.null(res)) next

    answer    <- res$answer[[1L]]    %||% ""
    thinking  <- res$thinking[[1L]]  %||% ""
    tok_in    <- res$tokens_in[[1L]]  %||% NA
    tok_out   <- res$tokens_out[[1L]] %||% NA

    cat(sprintf("  OK (%.1fs)  tokens_in=%s tokens_out=%s\n",
                el, tok_in, tok_out))
    cat(sprintf("  thinking chars : %d\n", nchar(thinking)))
    cat(sprintf("  answer chars   : %d\n", nchar(answer)))
    cat(sprintf("  thinking preview: %s\n",
                substr(gsub("\\s+", " ", thinking), 1, 160)))
    cat(sprintf("  answer          : %s\n", answer))
  }
}

cat(sprintf("\n%s\n  Done.\n%s\n", divider, divider))
