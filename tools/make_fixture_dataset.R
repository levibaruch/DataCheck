# make_fixture_dataset.R
# ─────────────────────────────────────────────────────────────────────────────
# Generates a fictitious OSF repository under data/osf/0000000000000000 that
# exercises every DataCheck feature:
#   - multiple studies (experiment1 → ex1, experiment2 → ex2, pilot → pilot1)
#   - file-type rules:  .R/.py/.ipynb → code, .psyexp → software, README → readme,
#                       .sav → data, .png → asset (deterministic)
#   - LLM file types:   ambiguous data / output / supplemental / codebook
#   - software folders:  node_modules (Tier A) + build/ with ≥100 files (Tier B)
#   - data aggregates:   participants/ (60 files, sub-XX → individual/filename),
#                        per_subject/ (25 numeric subdirs → individual/folder),
#                        raw_recordings/ (60 .edf → data/raw aggregate)
#   - column types:      id, continuous, binary, categorical, ordinal, date,
#                        text, constant, empty, continuous_comma_decimal
#   - codebooks:         codebook.csv (structured), codebook_study2.xlsx
#                        (structured), data_dictionary.docx (LLM parse)
#   - Haven labels:      study2_data.sav with embedded variable + value labels
#
# Run:  Rscript tools/make_fixture_dataset.R
# ─────────────────────────────────────────────────────────────────────────────

set.seed(42)
suppressMessages({ library(haven); library(writexl); library(officer) })

ROOT <- "data/osf/0000000000000000"
unlink(file.path(ROOT, c("data", "scripts", "experiment")), recursive = TRUE)  # drop empty placeholders
dir.create(ROOT, recursive = TRUE, showWarnings = FALSE)

mk  <- function(...) { p <- file.path(ROOT, ...); dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE); p }
txt <- function(path, lines) writeLines(lines, mk(path))
bin <- function(path, n = 64) writeBin(as.raw(sample(0:255, n, TRUE)), mk(path))

# ── Top-level readme / license / misc ────────────────────────────────────────
txt("README.md", c("# Fictitious DataCheck fixture",
                   "Synthetic multi-study repository for exercising the pipeline."))
txt("LICENSE", "MIT License — synthetic data, no rights reserved.")
txt("misc/notes.txt", c("Lab notebook scratch notes.", "Nothing structured here."))
bin("misc/.DS_Store", 32)
txt("misc/desktop.ini", "[.ShellClassInfo]")

# ── Analysis scripts (code via fixed_ext_rule) ───────────────────────────────
txt("analysis/analysis.R",   c("library(tidyverse)", "d <- read.csv('../experiment1/data/combined_data.csv')", "summary(d)"))
txt("analysis/clean_data.py", c("import pandas as pd", "df = pd.read_csv('combined.csv')", "df.dropna(inplace=True)"))
txt("analysis/explore.ipynb", '{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}')

# ── Software: experiment program + Tier A + Tier B software folders ───────────
txt("software/experiment.psyexp", "<PsychoPy2experiment version='2023.1'></PsychoPy2experiment>")
bin("software/task_installer.exe", 128)
# Tier A: node_modules (unambiguous) — a few files suffice
for (pkg in c("lodash", "react", "d3")) {
  txt(file.path("software/node_modules", pkg, "package.json"), '{"name":"x","version":"1.0.0"}')
  txt(file.path("software/node_modules", pkg, "index.js"), "module.exports = {};")
}
# Tier B: build/ with >= 100 non-tabular files
for (i in seq_len(105)) bin(sprintf("software/build/obj_%03d.o", i), 24)

# ── Codebooks (multi-format) ─────────────────────────────────────────────────
# Structured CSV codebook for experiment1 (some vars deliberately not in data)
cb1 <- data.frame(
  variable = c("participant_id","age","gender","condition","difficulty",
               "reaction_time","correct","rating","test_date","comments",
               "handedness","income_bracket"),
  description = c("Unique participant identifier","Age in years",
    "Self-reported gender (M/F)","Experimental condition assigned",
    "Task difficulty level (low/medium/high)","Response time in seconds",
    "Whether the response was correct (0/1)","Confidence rating 1-7",
    "Date of testing session","Free-text debrief comment",
    "Handedness (not collected in this dataset)",
    "Household income bracket (not collected in this dataset)"),
  stringsAsFactors = FALSE)
write.csv(cb1, mk("codebook.csv"), row.names = FALSE)

# Structured XLSX codebook for experiment2
cb2 <- data.frame(
  variable = c("pid","q1","q2","q3","grp"),
  label    = c("Participant ID","Question 1: I feel confident",
               "Question 2: I feel anxious","Question 3: I feel prepared",
               "Treatment group"),
  stringsAsFactors = FALSE)
write_xlsx(cb2, mk("codebook_study2.xlsx"))

# Free-text DOCX codebook (forces the LLM parse path)
doc <- read_docx()
doc <- body_add_par(doc, "Data Dictionary — Pilot Study", style = "heading 1")
doc <- body_add_par(doc, "trial: the trial number within the block.")
doc <- body_add_par(doc, "stim_type: the category of stimulus shown to the participant.")
doc <- body_add_par(doc, "response_key: which key the participant pressed.")
doc <- body_add_par(doc, "rt_ms: reaction time in milliseconds.")
print(doc, target = mk("data_dictionary.docx"))

# ── Experiment 1 (→ ex1) ─────────────────────────────────────────────────────
n <- 40
ex1 <- data.frame(
  participant_id = sprintf("P%03d", 1:n),                              # id (name rule)
  age            = round(rnorm(n, 30, 8), 1),                          # continuous
  gender         = sample(c("M","F"), n, TRUE),                        # binary
  condition      = sample(c("control","treatment","placebo"), n, TRUE),# categorical (LLM)
  difficulty     = sample(c("low","medium","high"), n, TRUE),          # ordinal (LLM)
  reaction_time  = round(rexp(n, 1.5) + 0.2, 3),                       # continuous
  correct        = sample(0:1, n, TRUE),                               # binary
  rating         = sample(1:7, n, TRUE),                               # continuous (few-unique int)
  test_date      = as.character(as.Date("2023-01-01") + sample(0:120, n, TRUE)), # date
  comments       = sample(c("Participant was engaged throughout the session.",
                            "Reported mild fatigue near the end of the task.",
                            "No issues noted during the experiment block."), n, TRUE), # text
  site           = "LabA",                                             # constant
  notes          = NA,                                                 # empty
  score_eu       = sub("\\.", ",", sprintf("%.2f", runif(n, 1, 9))),   # comma-decimal
  stringsAsFactors = FALSE)
write.csv(ex1, mk("experiment1/data/combined_data.csv"), row.names = FALSE)

# Aggregate folder #1: per-participant files (filename heuristic, >50 → aggregate)
for (i in 1:60) {
  d <- data.frame(trial = 1:10,
                  rt = round(runif(10, .3, 1.8), 3),
                  response = sample(c("yes","no"), 10, TRUE))
  write.csv(d, mk(sprintf("experiment1/data/participants/sub-%02d.csv", i)), row.names = FALSE)
}
# Aggregate folder #2: numeric subdirs (folder heuristic, >20 subdirs → individual)
for (i in 1:25) {
  d <- data.frame(block = 1:5, accuracy = round(runif(5), 2))
  write.csv(d, mk(sprintf("experiment1/data/per_subject/%02d/data.csv", i)), row.names = FALSE)
}
# Materials (assets) + output
for (i in 1:3) bin(sprintf("experiment1/materials/stimulus_%d.png", i), 96)
txt("experiment1/results/report.html", c("<html><body><h1>Results</h1><p>Generated output.</p></body></html>"))
txt("experiment1/manuscript_draft.docx", "placeholder")  # overwritten below as real docx
doc2 <- read_docx()
doc2 <- body_add_par(doc2, "Manuscript Draft", style = "heading 1")
doc2 <- body_add_par(doc2, "This is a synthetic manuscript used as supplemental material.")
print(doc2, target = mk("experiment1/manuscript_draft.docx"))

# ── Experiment 2 (→ ex2): SAV with Haven labels ──────────────────────────────
m <- 30
ex2 <- data.frame(
  pid = 1:m,
  q1  = sample(1:5, m, TRUE),
  q2  = sample(1:5, m, TRUE),
  q3  = sample(1:5, m, TRUE),
  gender = sample(0:1, m, TRUE),
  grp = sample(1:3, m, TRUE))
attr(ex2$pid, "label") <- "Participant ID"
attr(ex2$q1,  "label") <- "Question 1: I feel confident"
attr(ex2$q2,  "label") <- "Question 2: I feel anxious"
attr(ex2$q3,  "label") <- "Question 3: I feel prepared"
ex2$gender <- haven::labelled(ex2$gender, c(male = 0, female = 1), label = "Participant gender")
ex2$grp    <- haven::labelled(ex2$grp, c(control = 1, treatment = 2, waitlist = 3), label = "Treatment group")
haven::write_sav(ex2, mk("experiment2/data/study2_data.sav"))

# Aggregate folder #3: raw recordings (.edf → data/raw, >50 → aggregate)
for (i in 1:60) bin(sprintf("experiment2/data/raw_recordings/sub-%02d_eeg.edf", i), 128)
txt("experiment2/results/analysis_output.log", c("Run started", "Model converged", "Done."))

# ── Pilot (→ pilot1) ─────────────────────────────────────────────────────────
p <- 15
pilot <- data.frame(
  trial = rep(1:5, p),
  stim_type = sample(c("face","house","tool"), 5 * p, TRUE),
  response_key = sample(c("f","j"), 5 * p, TRUE),
  rt_ms = sample(250:1200, 5 * p, TRUE))
write.csv(pilot, mk("pilot/pilot_data.csv"), row.names = FALSE)

cat(sprintf("Done. %d files written under %s\n",
            length(list.files(ROOT, recursive = TRUE)), ROOT))
