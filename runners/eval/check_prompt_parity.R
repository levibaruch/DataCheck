# check_prompt_parity.R
# Verifies that STRUCTURE_PROMPT_MD, STRUCTURE_PROMPT_PLAIN, and
# STRUCTURE_PROMPT_JSON all contain the same key rules and phrases.
# Prints PASS / FAIL per check; exits with error if any fail.

source("pipeline/prompts.R")

prompts <- list(
  md        = paste0(SINGLE_HEADER, STRUCTURE_PROMPT_MD),
  plaintext = paste0(SINGLE_HEADER, STRUCTURE_PROMPT_PLAIN),
  json      = paste0(SINGLE_HEADER, STRUCTURE_PROMPT_JSON)
)

# Strip markdown/JSON formatting so phrase matching works across formats
strip <- function(x) tolower(gsub("\\s+", " ", gsub("[`*#\"']|\\[|\\]|\\{|\\}|→", "", x)))
stripped <- lapply(prompts, strip)

checks <- list(
  # ── Core principle ──────────────────────────────────────────────────────────
  list("core: classify by purpose",                   "classify by purpose"),
  list("core: extension is a weak signal",            "extension is a weak signal"),

  # ── Type definitions ────────────────────────────────────────────────────────
  list("type data: tabular observations",             "tabular observations, signals, or matrices"),
  list("type codebook: keyword list",                 "data_dictionary, variable_list, coding, variable_key"),
  list("type codebook: _key suffix",                  "study1_key.csv"),
  list("type codebook: sullivanEtAl2014_key.csv",     "sullivanetAl2014_key.csv"),
  list("type codebook: _dict _dd _cb",                "_dict"),
  list("type code: .Rmd .qmd .ipynb",                 ".rmd, .qmd, .ipynb"),
  list("type software: E-Prime .ebs2",                ".ebs2"),
  list("type software: PsychoPy .psyexp",             ".psyexp"),
  list("type software: OpenSesame .opensesame",       ".opensesame"),
  list("type software: never documents",              "never software"),
  list("type output: fallback supplemental",          "when provenance is ambiguous"),
  list("type readme: any capitalisation or extension","file named readme (any capitalisation or extension)"),
  list("type asset: never documents/spreadsheets",    "never asset"),
  list("type other: split-archive .z01",              ".z01"),
  list("type other: not a catch-all",                 "not a catch-all"),

  # ── Group definitions ───────────────────────────────────────────────────────
  list("group ex<N>: label in folder OR filename",    "either alone is sufficient"),
  list("group ex<N>: Study 1/file.csv → ex1",         "study 1"),
  list("group ex<N>: s2a_results.csv → ex2a",         "s2a_results.csv"),
  list("group ex<N>: letter suffixes s3a → ex3a",     "s3a"),
  list("group ex<N>: NOT run numbers",                "run numbers"),
  list("group ex<N>: NOT subject IDs",                "subject-2294"),
  list("group ex<N>: NOT 3_Column_Format",            "3_column_format"),
  list("group pilot<N>: no number → pilot1",          "no number"),
  list("group pilot<N>: pretest → shared not pilot",  "pretest"),
  list("group shared: everything not tied",           "everything not tied"),

  # ── Priority overrides ──────────────────────────────────────────────────────
  list("priority: .spv always output",                ".spv"),
  list("priority: .sps is code",                      ".sps is code"),
  list("priority: supplemental experiment n → shared","supplemental experiment"),
  list("priority: archive folders → shared",          "archive and previous-version"),

  # ── Decision procedures ─────────────────────────────────────────────────────
  list("decision: participant ID → data",             "subject-2294_run1.txt"),
  list("decision: participant config → software",     "p01_config.json"),
  list("decision: .log participant ID → data",        "p01_session1.log"),
  list("decision: .log data-collection folder",       "data-collection folder"),
  list("decision: media participant ID → data",       "subject01.wav"),
  list("decision: media figure → output",             "fig, plot, or graph in filename"),
  list("decision: media stimulus → asset",            "context indicates stimulus"),
  list("decision: media otherwise → supplemental",    "otherwise supplemental"),

  # ── Disambiguation ──────────────────────────────────────────────────────────
  list("disambig: reaction_times.csv → data",         "reaction_times.csv"),
  list("disambig: variable_codebook.csv → codebook",  "variable_codebook.csv"),
  list("disambig: correlations_figure.csv → output",  "correlations_figure.csv"),
  list("disambig: interview_transcript.docx → data",  "interview_transcript.docx"),
  list("disambig: consent_form.docx → supplemental",  "consent_form.docx"),
  list("disambig: tabular graph/figure/plot → output","graph, figure, or plot"),
  list("disambig: tabular statistical terms",         "correlations, regression, t-test"),
  list("disambig: tabular scores/processed → data",   "scores, processed, or cleaned"),
  list("disambig: .mat default data",                 "default"),
  list("disambig: .mat result/output/model → output", "result, output, model, fit"),
  list("disambig: .html basename script → output",    "shares a basename"),
  list("disambig: .json config → software",           "package.json"),

  # ── Code vs software ────────────────────────────────────────────────────────
  list("c/s: Task/ Tasks/ Stimuli/ Paradigm/ → software", "task/, tasks/, stimuli/"),
  list("c/s: rarely overloaded",                      "rarely overloaded"),
  list("c/s: Materials/ weak signal",                 "materials/"),
  list("c/s: task-specific subfolder example",        "fas-sif"),
  list("c/s: config structured format only",          "plain .txt and .xml"),
  list("c/s: .rtf/.doc never config",                 "never config"),
  list("c/s: analysis/model/params → code",           "analysis, model, or params"),
  list("c/s: filename signal task/run/experiment",    "task, run, experiment, stimulus"),
  list("c/s: task-1.py example",                      "task-1.py"),
  list("c/s: testing-fas-sif-1.py example",           "testing-fas-sif-1.py"),
  list("c/s: code signals analysis/regression",       "analysis, regression, stats"),
  list("c/s: plot_* signal",                          "plot_"),
  list("c/s: .R always code never software",          ".r files are always"),
  list("c/s: .js jsPsych → software",                 "jspsych"),
  list("c/s: analysis-named .js → code",              "regression_analysis.js")
)

# ── Run checks ─────────────────────────────────────────────────────────────────
all_pass <- TRUE
fails    <- 0

for (chk in checks) {
  label   <- chk[[1]]
  phrase  <- strip(chk[[2]])
  results <- vapply(names(stripped), function(nm) grepl(phrase, stripped[[nm]], fixed = TRUE), logical(1))
  passed  <- all(results)
  if (!passed) {
    missing_in <- names(results)[!results]
    cat(sprintf("FAIL  %-55s  missing in: %s\n", label, paste(missing_in, collapse = ", ")))
    all_pass <- FALSE
    fails    <- fails + 1
  }
}

total <- length(checks)
if (all_pass) {
  cat(sprintf("\nPASS  All %d checks matched across md / plaintext / json.\n", total))
} else {
  cat(sprintf("\n%d / %d checks FAILED.\n", fails, total))
  stop("Prompt parity check failed — see FAIL lines above.")
}
