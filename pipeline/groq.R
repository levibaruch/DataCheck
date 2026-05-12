# groq.R — llm_groq(): hits Groq's OpenAI-compatible API.
# Interface mirrors llm_ollama() so llm_batch() can dispatch transparently.
# Set GROQ_API_KEY in environment before use.
# Llama on Groq does not support thinking — think param is silently ignored.

library(httr2)

`%||%` <- function(x, y) if (is.null(x)) y else x

llm_groq <- function(text, system_prompt,
                     text_col        = "text",
                     model           = "llama-3.1-8b-instant",
                     params          = list(),
                     think           = NULL,      # ignored — Groq/Llama has no thinking
                     capture_thinking = FALSE) {

  api_key <- Sys.getenv("GROQ_API_KEY")
  if (!nzchar(api_key)) stop("GROQ_API_KEY environment variable not set")

  # strip provider prefix if present (e.g. "groq/llama-3.1-8b-instant")
  groq_model <- sub("^groq/", "", model)

  if (!is.data.frame(text)) {
    text <- data.frame(text = text)
    names(text) <- text_col
  }

  unique_text <- unique(text[[text_col]])
  ncalls      <- length(unique_text)
  if (ncalls == 0) stop("No calls to the LLM")

  call_groq <- function(user_text) {
    body <- list(
      model    = groq_model,
      messages = list(
        list(role = "system", content = system_prompt),
        list(role = "user",   content = user_text)
      ),
      stream      = FALSE,
      temperature = params$temperature %||% 0
    )
    if (!is.null(params$max_tokens))  body$max_tokens  <- params$max_tokens
    if (!is.null(params$top_p))       body$top_p       <- params$top_p

    resp <- request("https://api.groq.com/openai/v1/chat/completions") |>
      req_headers(Authorization = paste("Bearer", api_key),
                  `Content-Type` = "application/json") |>
      req_body_json(body) |>
      req_timeout(120) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()

    if (resp_status(resp) >= 400) {
      err_body <- tryCatch(resp_body_string(resp), error = \(e) "<unreadable>")
      stop(sprintf("Groq HTTP %d: %s", resp_status(resp), err_body))
    }

    parsed <- resp_body_json(resp)
    list(
      content  = parsed$choices[[1]]$message$content,
      thinking = NULL   # Groq/Llama produces no thinking trace
    )
  }

  responses <- vector("list", ncalls)
  pb <- pb(ncalls, "Querying Groq [:bar] :current/:total :elapsedfull")
  for (i in seq_along(unique_text)) {
    responses[[i]] <- tryCatch(
      {
        raw    <- call_groq(unique_text[i])
        result <- list(answer = trimws(raw$content))
        if (capture_thinking) result$thinking <- ""
        result
      },
      error = \(e) {
        warning("Groq call ", i, " failed: ", e$message, call. = FALSE)
        list(answer = NA_character_, error = TRUE, error_msg = e$message)
      }
    )
    pb$tick()
  }

  response_df <- do.call(dplyr::bind_rows, responses)
  response_df[[text_col]] <- unique_text
  answer_df <- dplyr::left_join(text, response_df, by = text_col)

  class(answer_df) <- c("metacheck_llm", "data.frame")
  attr(answer_df, "llm") <- c(list(system_prompt = system_prompt, model = model), params)

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
