# probe_temperature.R
# Tests whether temperature parameter is honored by Ollama models.
# Uses a creative generation task where high temp should produce diverse outputs
# and temp=0 should be fully deterministic (identical responses across reps).
#
# Usage: Rscript runners/eval/probe_temperature.R

library(httr2)

OUT_CSV  <- "results/eval/probe_temperature.csv"
N_REPS   <- 6
TEMPS    <- c(0, 0.5, 1)

MODELS <- list(
  list(id = "gpt-oss:20b-cloud",   label = "gpt-oss-20b"),
  list(id = "gpt-oss:120b-cloud",  label = "gpt-oss-120b"),
  list(id = "qwen3-vl:235b-cloud", label = "qwen3-vl-235b")
)

SYS <- "You are a creative gift advisor. Give exactly one sentence. No preamble."

CASES <- list(
  list(
    persona = "a 40 year old woman who loves natural wine and plays pickleball",
    budget  = "$100"
  ),
  list(
    persona = "a 25 year old man who rock climbs, goes to raves, and lives in a trendy city neighbourhood",
    budget  = "$50"
  ),
  list(
    persona = "a retired engineer who restores vintage motorbikes and hates clutter",
    budget  = "$75"
  )
)

make_prompt <- function(case) {
  sprintf(
    "Come up with a one-sentence creative gift idea for a person who is %s. It should cost under %s.",
    case$persona, case$budget
  )
}

call_ollama <- function(model_id, temp, prompt, sys) {
  body <- list(
    model    = model_id,
    messages = list(
      list(role = "system", content = sys),
      list(role = "user",   content = prompt)
    ),
    stream  = FALSE,
    options = list(temperature = temp)
  )
  r <- request("http://localhost:11434/api/chat") |>
    req_body_json(body) |>
    req_timeout(300) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(r) >= 400)
    stop(sprintf("HTTP %d: %s", resp_status(r), resp_body_string(r)))
  trimws(resp_body_json(r)$message$content)
}

divider <- paste0(rep("─", 72), collapse = "")

# Write CSV header
write.csv(
  data.frame(model=character(), temp=numeric(), case=integer(), rep=integer(),
             response=character(), stringsAsFactors=FALSE),
  OUT_CSV, row.names=FALSE
)

for (m in MODELS) {
  cat(sprintf("\n%s\n  Model: %s\n%s\n", divider, m$label, divider))

  for (temp in TEMPS) {
    cat(sprintf("\n── temp=%.1f ──\n", temp))

    for (ci in seq_along(CASES)) {
      prompt    <- make_prompt(CASES[[ci]])
      responses <- character(N_REPS)
      cat(sprintf("  case %d: %s\n", ci, substr(CASES[[ci]]$persona, 1, 50)))

      for (i in seq_len(N_REPS)) {
        resp <- tryCatch(
          call_ollama(m$id, temp, prompt, SYS),
          error = function(e) paste("ERROR:", e$message)
        )
        cat(sprintf("    [%d] %s\n", i, substr(resp, 1, 80)))
        responses[i] <- resp

        write.table(
          data.frame(model=m$label, temp=temp, case=ci, rep=i,
                     response=resp, stringsAsFactors=FALSE),
          OUT_CSV, sep=",", append=TRUE, row.names=FALSE,
          col.names=FALSE, qmethod="double"
        )
      }

      n_unique <- length(unique(responses))
      cat(sprintf("    → %d/%d unique\n", n_unique, N_REPS))
    }
  }
}

cat(sprintf("\n%s\n  SUMMARY — unique responses per model × temp (max=%d per case)\n%s\n",
            divider, N_REPS, divider))

df <- read.csv(OUT_CSV, stringsAsFactors=FALSE)
for (m in MODELS) {
  cat(sprintf("\n  %s\n", m$label))
  sub <- df[df$model == m$label, ]
  for (temp in TEMPS) {
    t_sub    <- sub[abs(sub$temp - temp) < 1e-9, ]
    n_unique <- tapply(t_sub$response, t_sub$case, function(x) length(unique(x)))
    cat(sprintf("    temp=%.1f: unique/case = %s  (mean=%.1f)\n",
                temp, paste(n_unique, collapse=" / "), mean(n_unique)))
  }
}

cat(sprintf("\nFull responses: %s\n", OUT_CSV))
cat("\nInterpretation:\n")
cat("  temp=0 → 1/6 unique every case AND temp=1 → more unique = param IS working\n")
cat("  flat unique counts across temps             = param likely IGNORED\n")
