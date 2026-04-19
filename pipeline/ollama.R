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

`%||%` <- function(x, y) if (is.null(x)) y else x

llm_ollama <- function(text, system_prompt,
                       text_col = "text",
                       model = llm_model(),
                       params = list(),
                       think = NULL,
                       base_url = "http://localhost:11434",
                       deduplicate = TRUE,
                       capture_thinking = FALSE) {

  ## extract think from params if passed there (callers may bundle it in) ----
  if ("think" %in% names(params)) {
    if (is.null(think)) think <- params$think
    params <- params[names(params) != "think"]
  }

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

  ## strip ellmer provider prefix (e.g. "ollama/gpt-oss:tag" → "gpt-oss:tag") ----
  ollama_model <- sub("^ollama/", "", model)

  ## build the per-call request function ----
  # Note: Ollama's native /api/chat takes sampling params under `options`.
  # We pass params straight through — caller is responsible for using valid
  # Ollama option names (temperature, seed, top_p, top_k, num_predict, ...).
  call_ollama <- function(user_text) {
    body <- list(
      model = ollama_model,
      messages = list(
        list(role = "system", content = system_prompt),
        list(role = "user",   content = user_text)
      ),
      stream = FALSE
    )
    if (length(params) > 0) body$options <- params
    if (!is.null(think)) body$think <- think

    resp <- request(paste0(base_url, "/api/chat")) |>
      req_body_json(body) |>
      req_timeout(600) |>
      req_error(is_error = \(r) FALSE) |>  # suppress httr2 error so we can read body
      req_perform()

    if (resp_status(resp) >= 400) {
      err_body <- tryCatch(resp_body_string(resp), error = \(e) "<unreadable>")
      stop(sprintf("HTTP %d: %s", resp_status(resp), err_body))
    }

    parsed <- resp_body_json(resp)
    # message$content = final answer; message$thinking = reasoning trace.
    # Return a list so the caller can access both when capture_thinking=TRUE.
    list(
      content  = parsed$message$content,
      thinking = parsed$message$thinking   # NULL when model didn't think
    )
  }

  ## make the calls ----
  pb <- pb(ncalls, "Querying LLM [:bar] :current/:total :elapsedfull")
  for (i in seq_along(unique_text)) {
    responses[[i]] <- tryCatch(
      {
        raw    <- call_ollama(unique_text[i])
        result <- list(answer = trimws(raw$content))
        if (capture_thinking) result$thinking <- raw$thinking %||% ""
        result
      },
      error = \(e) {
        warning("LLM call ", i, " failed: ", e$message, call. = FALSE)
        list(answer = NA_character_, error = TRUE, error_msg = e$message)
      }
    )
    pb$tick()
  }

  ## attach back to the original data frame ----
  response_df <- do.call(dplyr::bind_rows, responses)
  response_df[[text_col]] <- unique_text
  answer_df <- dplyr::left_join(text, response_df, by = text_col)

  ## match llm() class + attribute ----
  class(answer_df) <- c("metacheck_llm", "data.frame")
  attr(answer_df, "llm") <- c(
    list(system_prompt = system_prompt, model = model, think = think),
    params
  )

  ## warn about errors (mirrors llm()) ----
  error_indices <- answer_df$error %in% TRUE
  if (any(error_indices)) {
    warn <- paste(which(error_indices), collapse = ", ") |>
      paste("There were errors in the following rows:", x = _)
    answer_df$error_msg[error_indices] |>
      unique() |>
      paste("\n  * ", x = _) |>
      paste(warn, x = _) |>
      warning()
  }

  answer_df
}