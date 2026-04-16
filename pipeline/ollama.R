# llm_ollama(): sibling to llm() that hits Ollama's native /api/chat endpoint
# directly via httr2, instead of going through ellmer's OpenAI-compatible path.
#
# Why it exists: ellmer currently cannot forward the `think` parameter to
# Ollama (tidyverse/ellmer#940), so gpt-oss reasoning levels are not reachable
# through the standard llm() wrapper. This version accepts `think`.
#
# Signature mirrors llm() where possible. New args:
#   - think: "low" | "medium" | "high" | NULL (default NULL = Ollama's default)
#   - base_url: Ollama host (default http://localhost:11434)
#
# The `params` list maps to Ollama's `options` field. Supported keys:
#   temperature, seed, top_p, top_k, num_predict (= max_tokens),
#   repeat_penalty, etc. — see Ollama Modelfile docs.

library(httr2)

llm_ollama <- function(text, system_prompt,
                       text_col = "text",
                       model = llm_model(),
                       params = list(),
                       think = NULL,
                       base_url = "http://localhost:11434",
                       deduplicate = TRUE) {

  ## error detection ----
  if (!llm_use()) {
    stop("Set llm_use(TRUE) to use LLM functions")
  }

  if (!is.null(think) && !think %in% c("low", "medium", "high")) {
    stop("`think` must be one of 'low', 'medium', 'high', or NULL")
  }

  # make a data frame if text is a vector
  if (!is.data.frame(text)) {
    text <- data.frame(text = text)
    names(text) <- text_col
  }

  # set up answer data frame to return ----
  if (deduplicate) {
    unique_text <- unique(text[[text_col]])
  } else {
    unique_text <- text[[text_col]]
  }
  ncalls <- length(unique_text)
  responses <- replicate(ncalls, list(), simplify = FALSE)

  if (ncalls == 0) stop("No calls to the LLM")
  if (ncalls > llm_max_calls()) {
    stop("This would make ", ncalls, " calls to the LLM, but your maximum number of calls is set to ",
         llm_max_calls(), ". Use `llm_max_calls()` to change this.", call. = FALSE)
  }

  ## build the per-call request function ----
  # Note: Ollama's native /api/chat takes sampling params under `options`.
  # We pass params straight through — caller is responsible for using valid
  # Ollama option names (temperature, seed, top_p, top_k, num_predict, ...).
  call_ollama <- function(user_text) {
    body <- list(
      model = model,
      messages = list(
        list(role = "system", content = system_prompt),
        list(role = "user",   content = user_text)
      ),
      stream = FALSE,
      options = params
    )
    if (!is.null(think)) body$think <- think

    resp <- request(paste0(base_url, "/api/chat")) |>
      req_body_json(body) |>
      req_timeout(600) |>
      req_perform()

    parsed <- resp_body_json(resp)
    # message$content holds the final answer; message$thinking holds the
    # reasoning trace (discarded here — capture it if you want to log it).
    parsed$message$content
  }

  ## make the calls ----
  for (i in seq_along(unique_text)) {
    responses[[i]] <- tryCatch(
      call_ollama(unique_text[i]),
      error = \(e) {
        warning("LLM call ", i, " failed: ", e$message, call. = FALSE)
        NA_character_
      }
    )
  }

  ## attach back to the original data frame ----
  if (deduplicate) {
    lookup <- setNames(responses, unique_text)
    text$response <- unlist(lookup[text[[text_col]]])
  } else {
    text$response <- unlist(responses)
  }

  text
}