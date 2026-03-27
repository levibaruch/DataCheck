# prompts.R
# ─────────────────────────────────────────────────────────────────────────────
# All LLM prompt strings used by the pipeline.
# Sourced by 0_index.R and 2_codebook_label.R.
# ─────────────────────────────────────────────────────────────────────────────

# ── File structure classification (0_index.R → llm_batch()) ──────────────────

# PREVIOUS VERSION (rule-based) — kept for comparison
# STRUCTURE_PROMPT <- 'You are analysing a psychology research data repository.
# You will receive a file tree. For each path return a JSON array (same order).
# Each element: {"path": "<exact path>", "type": "<type>", "group": "<group>"}
#
# type — pick one:
#   data         : file containing research measurements — tabular (.csv, .sav, .xlsx,
#                  .xls, .dta, .tsv, .dat) or stored objects (.rds, .rdata, .rda) or
#                  recorded signals (.edf, .acq, .bdf) or matrices (.mat) or .json when
#                  the filename suggests data content (contains "data", "responses",
#                  "results", or "export"). For unlisted extensions, classify as data
#                  only when the filename pattern clearly identifies participant-level
#                  observations (e.g. subject-* files per the disambiguation rule below).
#   codebook     : file whose name indicates it describes variables —
#                  "codebook", "data_dictionary", "variable_list", "coding_key",
#                  "variable_key", "var_desc", "data_guide", "labels", "legend",
#                  "metadata" in the filename; or "variables" only when it appears
#                  at the start or end of the filename (e.g. "variables.xlsx",
#                  "study_variables.csv" but NOT "random_variables.csv").
#   code         : R (.R), Python (.py), MATLAB (.m), Julia (.jl), SQL (.sql),
#                  shell (.sh, .bash), Stata (.do), SAS (.sas), SPSS (.sps),
#                  notebooks (.Rmd, .qmd, .ipynb).
#   supplemental : manuscripts, articles, reports, proposals, theses, preregistrations,
#                  registered reports, survey instruments (.qsf), consent forms,
#                  HTML output files, result figures, scale items, supporting appendices,
#                  experiment scripts (.opensesame, .psyexp).
#   readme       : files named README, LICENSE, or CONTRIBUTING (any capitalisation),
#                  with any extension.
#   asset        : stimulus files in recognised media formats presented to participants.
#                  Recognised formats — image: .jpg, .jpeg, .png, .gif, .bmp, .tif,
#                  .tiff, .svg; audio: .wav, .mp3; video: .mp4, .avi, .mov.
#                  Classify as asset when: (a) the file is inside a folder named
#                  "stimuli", "stim", "materials", "images", "sounds", "audio",
#                  "video", or "pictures"; OR (b) the filename itself contains "stim",
#                  "stimulus", "trial", or "item". Result figures and output graphs are
#                  supplemental, NOT asset. Text, spreadsheet, script, and document
#                  formats are never asset.
#   other        : files with no research content — .DS_Store, Thumbs.db, .gitignore,
#                  lock files, .env, executables, installers. Also: package.json,
#                  dotfiles (names starting with "."), and files ending in "rc.json"
#                  or "config.json". MUST NOT be used as a catch-all for ambiguous
#                  research files.
#
# group — pick one:
#   "ex<N>"   : file belongs to a numbered experiment or study. A number is an experiment
#               indicator ONLY when it follows an explicit study/experiment label:
#               - Folder: "Study 1/", "Experiment 2/", "Exp3/", "S1/", "E2/"
#               - Filename: "S1_data.csv" → ex1, "S2_results.csv" → ex2,
#                 "S3a_shoppers.csv" → ex3a, "Study_4_data.csv" → ex4,
#                 "Experiment2_raw.csv" → ex2
#               Numbers that are NOT experiment indicators: ordinal levels ("1st_Level",
#               "2nd_Level", "3rd_Level"), run numbers ("run1", "run2"), sequential file
#               numbers ("design2", "design3"), subject IDs ("subject-2294"), version
#               numbers, column/folder counts ("3_Column_Format"), analysis levels.
#               Preserve letter suffixes exactly: "S3a" → "ex3a". NEVER collapse "ex3a" → "ex3".
#   "pilot<N>": context clearly indicates a pilot study — folder or filename contains
#               "pilot", "pre-pilot", "prepilot", or "preliminary study" used to mean
#               a pilot study (NOT when "pilot" is part of an unrelated word such as
#               "autopilot"). Preserve letter suffixes: "Pilot 1a" → "pilot1a". If no
#               number is present, use "pilot1". Number pilots independently from
#               experiments. Pilots are NEVER "ex<N>".
#   "shared"  : all files not tied to a specific numbered experiment or pilot —
#               files spanning multiple experiments, project-wide scripts, combined
#               datasets, files in archive or previous-version folders, and all
#               readme, asset, and other files regardless of location.
#               Use "shared" when no experiment or pilot number can be found in either
#               the folder path or the filename.
#
# Disambiguation:
# - Files named "subject-*" or "sub-*" followed by an ID (e.g. "subject-2294_run1_gain.txt")
#   → data, even if the extension is .txt.
# - .rds, .rdata, .rda: classify as data unless the filename contains "plot", "figure",
#   or "graph", in which case → supplemental.
# - data vs supplemental: tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat) whose
#   name contains "graph", "figure", "plot", or "corrigendum" → supplemental, NOT data.
# - asset vs supplemental: result figures and output graphs → supplemental, NOT asset.
# - Sentinel paths like "[236_files.csv]" represent many identical files — classify the folder as a whole.
# - "Supplemental Experiment N" or "Supplemental Study N" folders → "shared", NOT "ex<N>".
# - Previous versions and archive folders → type of their contents, group "shared".
# - Echo back every path exactly as given. NEVER shorten or abbreviate with "...".
# - Output ONLY the JSON array. No notes or text before or after the array.'

STRUCTURE_PROMPT <- 'You are classifying files in a psychology research data repository.
You will receive a file tree. For each path return a JSON array (same order).
Each element: {"path": "<exact path>", "type": "<type>", "group": "<group>"}

File organisation varies widely — use the full path and folder context, not just
the extension, to infer each file\'s purpose.

TYPE — what this file is for:
  data         : contains research measurements — observations, recordings, or
                 matrices intended for analysis. The extension alone is not
                 sufficient: a .csv or .xlsx may be a codebook, a .txt may be
                 participant data. Judge from the filename and folder context.
  codebook     : primary purpose is describing what variables mean. Identified by
                 filename keywords: codebook, data_dictionary, variable_list,
                 coding_key, variable_key, var_desc, data_guide, labels, legend,
                 metadata; or "variables" at the start or end of the filename.
                 A codebook can be any format — .csv, .xlsx, .pdf, .docx, .txt.
  code         : executable source file or notebook — scripts, syntax files,
                 notebooks (.Rmd, .qmd, .ipynb), regardless of language.
  supplemental : research support material that is not data, code, or a codebook —
                 manuscripts, preregistrations, instruments, consent forms, output
                 figures, appendices, experiment scripts.
  readme       : file named README, LICENSE, or CONTRIBUTING (any capitalisation).
  asset        : stimulus media presented to participants during the study —
                 image, audio, or video files. Output figures → supplemental.
  other        : no research content — OS metadata, config files, lock files,
                 executables. Not a catch-all for ambiguous research files.

GROUP — which experiment this file belongs to:
  "ex<N>"   : clearly tied to a numbered experiment or study.
              The number must follow an explicit experiment label in the folder
              path or filename — "Study 1/", "Experiment 2/", "S1_data.csv",
              "Exp3/", "E2/". Preserve letter suffixes exactly: "S3a" → "ex3a".
              Numbers that are NOT experiment indicators: run numbers ("run1"),
              subject IDs ("subject-2294"), version numbers, ordinal levels
              ("1st_Level"), sequential counts ("3_Column_Format").
  "pilot<N>": context clearly indicates a pilot study. No number present → "pilot1".
              Pilots are never "ex<N>".
  "shared"  : everything else — files not tied to a specific numbered experiment
              or pilot. Use for cross-experiment files, project-wide scripts,
              combined datasets, archive folders, and all readme/asset/other files.

Hard cases — use filename and folder context to decide:
- .csv/.xlsx/.txt/.pdf can each be data OR codebook OR supplemental. The filename
  is the primary signal: measurement-oriented names → data; variable-description
  names → codebook; document-oriented names → supplemental.
- subject-* or sub-* files (e.g. "subject-2294_run1.txt") → always data.
- .rds/.rdata/.rda → data unless filename contains "plot", "figure", or "graph".
- .json → data if filename suggests measurements; other if it looks like config
  (package.json, dotfiles, *rc.json, *config.json).
- .spv → supplemental (SPSS Viewer output file, NOT code — .sps is code, .spv is not).
- Images/audio/video → asset if inside a stimuli/stim/materials/sounds/images
  folder or filename contains "stim", "stimulus", "trial", or "item"; otherwise
  supplemental.
- "Supplemental Experiment N" or "Supplemental Study N" folders → group "shared".
- Archive and previous-version folders → type of contents, group "shared".

Echo every path exactly. Output ONLY the JSON array.'

# ── Column type classification (0_index.R → llm_batch()) ─────────────────────

COLUMN_TYPE_PROMPT <- 'You are classifying columns in psychology research data.
For each column descriptor return a JSON array (same order).
Each element: {"descriptor": "<exact descriptor>", "col_type": "<type>"}

col_type — pick one:
  continuous  : numeric measurement — reaction time, age, VAS rating (0–10), Likert-scale
                mean, subscale score, count, percentage, any column with decimal values
  ordinal     : ordered integer scale with few levels — 1–5 Likert item, 1–10 attention
                rating, bounded compliance or distress score, ranked preference, grade
  categorical : unordered group or category code with few levels (condition, gender, language)
  binary      : exactly two possible values (yes/no, 0/1, treatment/control)
  id          : row or participant identifier — unique or nearly-unique integer per row
  unknown     : ONLY when name AND values together give no numeric signal — e.g. fully
                redacted data, meaningless all-constant codes. Do NOT use for any column
                whose samples look like numbers.

IMPORTANT: Prefer "continuous" or "ordinal" over "unknown". When in doubt between
"continuous" and "ordinal" for a numeric column, choose "continuous".

Output ONLY the JSON array. No notes, no text outside the array.'

# ── Codebook parsing (2_codebook_label.R → llm()) ────────────────────────────

CODEBOOK_PARSE_PROMPT <- 'You are extracting variable definitions from a psychology research codebook or README.
Return a JSON array — one object per variable found.
Each object: {"variable_name": "<exact variable name>", "label": "<verbatim description text copied from the codebook>", "experiment_context": "<experiment or study name if stated, else null>"}

Rules:
- variable_name: the exact code/name used in the data file (e.g. "rt", "subj_id", "condition")
- label: copy the description text exactly as it appears in the codebook — do NOT paraphrase, summarise, or infer; preserve the original wording
- Do NOT rephrase or summarise; if no description text is present for a variable, omit that variable entirely
- experiment_context: if the variable is described under a heading like "Experiment 1" or "Study 2a", include that heading verbatim; otherwise null
- Only include variables that have both a name and a description present in the source text
- If the text contains no variable definitions, return an empty array: []
- Output ONLY the JSON array. No notes, no text outside the array.'

# ── Column–codebook matching (2_codebook_label.R → llm()) ────────────────────

COLUMN_MATCH_PROMPT <- 'You are matching data column names to codebook variable names for a psychology research dataset.
You will receive two lists: unlabelled data column names and unmatched codebook variable names.
Return a JSON array of confident pairings only.
Each object: {"column_name": "<exact column name from the data list>", "codebook_variable": "<exact variable name from the codebook list>"}

Rules:
- Only include pairs you are confident refer to the same construct (e.g. abbreviations, naming conventions, underscores vs spaces)
- Do NOT guess — if unsure, omit the pair
- Both column_name and codebook_variable must appear verbatim from the lists provided
- If no confident matches exist, return an empty array: []
- Output ONLY the JSON array. No notes, no text outside the array.'

# ── Label deduplication (2_codebook_label.R → llm()) ─────────────────────────

LABEL_MERGE_PROMPT <- 'You are reviewing whether multiple label definitions for the same
variable in a psychology research dataset are semantically equivalent.

You will receive a JSON array of objects, each with "column" and "labels" fields.
Return a JSON array — one object per input variable.
Each object: {"column": "<column_name>", "equivalent": true/false, "canonical": "<best label or null>"}

Rules:
- equivalent: true if all listed labels describe the same construct (synonyms, different
  phrasings, or value-coding notation for the same concept as a semantic label)
- canonical: if equivalent=true, return the most human-readable, informative single label;
  if equivalent=false, set to null
- Do NOT mark as equivalent if labels describe genuinely different constructs or scales
- Output ONLY the JSON array. No notes, no text outside the array.'
