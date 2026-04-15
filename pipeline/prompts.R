# prompts.R
# ─────────────────────────────────────────────────────────────────────────────
# All LLM prompt strings used by the pipeline.
# Sourced by 0_index.R and 2_codebook_label.R.
# ─────────────────────────────────────────────────────────────────────────────

# ── File structure classification (0_index.R → llm_batch()) ──────────────────

# PREVIOUS VERSION (rule-based) — kept for comparison
# DEPRECATED: supplemental references below predate the `output` file type (feature 026).
#             result figures, output graphs, and HTML output files are now classified as
#             `output`, not `supplemental`. Do not restore this block.
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


# AB TEST v0 (rule based, pre-2026-04) 

STRUCTURE_PROMPT_v0 <- 'You are classifying files in a psychology research data repository.
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
  code         : executable source file or notebook whose purpose is to generate
                 analyses or research outputs — scripts, syntax files, notebooks
                 (.Rmd, .qmd, .ipynb), regardless of language.
  software     : program, application, or configuration file whose purpose is to
                 run or configure the experiment — stimulus delivery, task
                 presentation, data collection tools, and their configuration
                 files (experiment parameters, trial config, settings files).
                 Compiled binaries (.exe, .app, .jar, .msi, .dmg) → always software.
  output       : file produced by executing a script — rendered notebooks (.html,
                 .pdf, .docx output from .Rmd/.qmd/.ipynb), script-generated
                 figures and graphs, log files (.log, .out), and other
                 computational byproducts. Classify as output when the filename
                 or folder context clearly indicates a script-generated artefact.
                 Exception: experiment software (E-Prime, PsychoPy, etc.) writes
                 per-participant .log files that are raw data — see hard cases.
                 When provenance is ambiguous, prefer supplemental.
  supplemental : human-authored research material that is not data, code, or a
                 codebook — manuscripts, preregistrations, instruments, consent
                 forms, survey scales, appendices. Script-generated artefacts
                 (figures, rendered notebooks) → output, not supplemental.
                 Fallback for ambiguous provenance.
  readme       : file named or contains README (any capitalisation).
  asset        : stimulus media presented to participants during the study —
                 image, audio, or video files.
  other        : ONLY when the file clearly has no research relevance (e.g., system files,
                temporary files, unrelated documents). If any plausible research use exists,
                DO NOT use "other".
                
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
- Tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat) whose name contains
  "graph", "figure", or "plot" → output, NOT data.
- subject-* or sub-* files (e.g. "subject-2294_run1.txt") → always data.
- Transcript files — filename contains "transcript", "transcription", "interview",
  or "verbal" — are raw qualitative data → data, NOT supplemental, regardless
  of format (.txt, .docx, .pdf, .csv).
- .rds/.rdata/.rda/.sav → data unless filename contains "plot", "figure", or "graph"
  → output (not data, not supplemental).
- .json → data if filename suggests measurements; other if it looks like config
  (package.json, dotfiles, *rc.json, *config.json).
- .spv → output (SPSS Viewer file — computational byproduct of running SPSS;
  .sps is code, .spv is NOT supplemental).
- .log/.out → output (system or script log). Exception: if the filename contains
  a participant/subject ID pattern (e.g. "subject01.log", "p01_session1.log")
  → data (experiment software such as E-Prime and PsychoPy writes per-participant
  .log files that are raw data).
- Images/audio/video (.jpg, .png, .gif, .wav, .mp3, .mp4, .avi, .mov, etc.)
  are NEVER other. Classify as:
  → data if filename contains a participant/subject ID (e.g. "subject-2294_run1.wav")
  → output if filename contains "figure", "fig", "plot", "graph", "results", or
    "output" AND not in a stimuli context
  → asset in all other cases (default for unidentified media in a research repo)
  Stimuli folder names (stimuli/, stim/, materials/, images/, sounds/, audio/,
  video/, pictures/) and filename keywords ("stim", "stimulus", "trial", "item")
  are strong positive signals for asset but are not required.
- .html → output if it appears to be a rendered notebook (shares a basename with
  an .Rmd/.qmd/.ipynb file in the same folder, or is in a folder containing
  scripts); otherwise supplemental.
- .mat → output if the filename contains "result", "output", "model", "fit",
  "figure", or "plot". Otherwise → data. In particular: folder path contains
  "data" or "raw" (e.g. raw_data/, rawdata/, data_files/), numeric suffix
  (e.g. "_13", "_14"), or subject/participant ID in name → data. Default for
  all other ambiguous .mat files is also data (conservative fallback).
- "Supplemental Experiment N" or "Supplemental Study N" folders → group "shared".
- Archive and previous-version folders → type of contents, group "shared".

Echo every path exactly. Output ONLY the JSON array.'


 
# AB TEST v1 (rule-based, 2026-04) — kept for comparison

STRUCTURE_PROMPT_v1 <- 'You are classifying files in a psychology research data repository.
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
  code         : executable source file or notebook whose purpose is to generate
                 analyses or research outputs — scripts, syntax files, notebooks
                 (.Rmd, .qmd, .ipynb), regardless of language.
  software     : program, application, or configuration file whose purpose is to
                 run or configure the experiment — stimulus delivery, task
                 presentation, data collection tools, and their configuration
                 files (experiment parameters, trial config, settings files).
                 Compiled binaries (.exe, .app, .jar, .msi, .dmg) → always software.
  output       : file produced by executing a script — rendered notebooks (.html,
                 .pdf, .docx output from .Rmd/.qmd/.ipynb), script-generated
                 figures and graphs, log files (.log, .out), and other
                 computational byproducts. Classify as output when the filename
                 or folder context clearly indicates a script-generated artefact.
                 Exception: experiment software (E-Prime, PsychoPy, etc.) writes
                 per-participant .log files that are raw data — see hard cases.
                 When provenance is ambiguous, prefer supplemental.
  supplemental : human-authored research material that is not data, code, or a
                 codebook — manuscripts, preregistrations, instruments, consent
                 forms, survey scales, appendices. Script-generated artefacts
                 (figures, rendered notebooks) → output, not supplemental.
                 Fallback for ambiguous provenance.
  readme       : file named or contains README (any capitalisation).
  asset        : stimulus media presented to participants during the study —
                 image, audio, or video files.
  other        : ONLY when the file clearly has no research relevance (e.g., system files,
                temporary files, unrelated documents). If any plausible research use exists,
                DO NOT use "other".

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
- Tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat) whose name contains
  "graph", "figure", or "plot" → output, NOT data.
- Tabular files whose name contains "scores", "processed", or "cleaned" → data,
  NOT output. These are intermediate or derived datasets used as inputs to further
  analyses, not script-generated artefacts. (This overrides any output bias from
  the word "results" — tabular result files are data unless they also contain
  "figure", "graph", or "plot".)
- subject-* or sub-* files (e.g. "subject-2294_run1.txt") → always data.
- Transcript files — filename contains "transcript", "transcription", "interview",
  or "verbal" — are raw qualitative data → data, NOT supplemental, regardless
  of format (.txt, .docx, .pdf, .csv).
- .rds/.rdata/.rda/.sav → data unless filename contains "plot", "figure", or "graph"
  → output (not data, not supplemental).
- .json → data if filename suggests measurements; other if it looks like config
  (package.json, dotfiles, *rc.json, *config.json).
- .spv → output (SPSS Viewer file — computational byproduct of running SPSS;
  .sps is code, .spv is NOT supplemental).
- .log/.out → output (system or script log). Exception: if the filename contains
  a participant/subject ID pattern (e.g. "subject01.log", "p01_session1.log")
  → data (experiment software such as E-Prime and PsychoPy writes per-participant
  .log files that are raw data). Also exception: if the file is inside a folder
  named "data", "raw", "rawdata", "raw_data", or named after a task/paradigm
  (i.e. any non-system folder clearly associated with data collection) → data,
  even without a participant ID in the filename. System log folders ("logs/",
  "log/") at repo root → output regardless.
- Images/audio/video (.jpg, .png, .gif, .wav, .mp3, .mp4, .avi, .mov, etc.)
  are NEVER other. Classify as:
  → data if filename contains a participant/subject ID (e.g. "subject-2294_run1.wav")
  → output if filename contains "figure", "fig", "plot", "graph", "results", or
    "output" AND not in a stimuli context
  → asset in all other cases (default for unidentified media in a research repo)
  Stimuli folder names (stimuli/, stim/, materials/, images/, sounds/, audio/,
  video/, pictures/) and filename keywords ("stim", "stimulus", "trial", "item")
  are strong positive signals for asset but are not required.
- .html → output if it appears to be a rendered notebook (shares a basename with
  an .Rmd/.qmd/.ipynb file in the same folder, or is in a folder containing
  scripts); otherwise supplemental.
- .mat → output if the filename contains "result", "output", "model", "fit",
  "figure", or "plot". Otherwise → data. In particular: folder path contains
  "data" or "raw" (e.g. raw_data/, rawdata/, data_files/), numeric suffix
  (e.g. "_13", "_14"), or subject/participant ID in name → data. Default for
  all other ambiguous .mat files is also data (conservative fallback).
- "Supplemental Experiment N" or "Supplemental Study N" folders → group "shared".
- Archive and previous-version folders → type of contents, group "shared".
- Tabular files borrowed from a prior published study (name contains "prior",
  "replication", "comparison_data", or a 4-digit year such as "Smith2019" adjacent
  to a tabular extension) → data, NOT supplemental. The data is used in the current
  analysis pipeline regardless of its original source.
- Placeholder / example files: filename starts with or contains "example_", "dummy",
  or "placeholder" → other. Exception: do not trigger on compound research-construct
  names where these words are part of the construct (e.g. "implicit_association_test"
  should not trigger on "test"; "example_stimuli" in a stimuli folder → asset).
  Also: standalone "test_data.csv" used as documentation example → other; but
  "pretest_data.csv" or "IAT_test_run.csv" → data.
- Config files (.yaml, .yml, .cfg, .ini, .toml):
  → software if the file is inside an experiment-associated folder (task/, paradigm/,
    experiment/, stimuli/, jsPsych/, OpenSesame/, PsychoPy/, or similar) or if the
    filename clearly configures experiment parameters (e.g. "trial_config.yaml",
    "task_settings.ini")
  → code if the filename contains "analysis", "model", or "params" (analysis
    configuration)
- .sql files → data. Exception: filename contains "query", "script", or "procedure"
  → code.
- Folders/files named "pretest" → assign "ex<N>" if a study number is
              present, otherwise "shared". Never assign "pilot<N>" to pretest content.

Echo every path exactly. Output ONLY the JSON array.'
# end AB TEST v1

# AB TEST v2 (principle-based, 2026-04)
STRUCTURE_PROMPT <- 'You are classifying files in a psychology research data repository.
You will receive a file tree. Return a JSON array in the same order.
Each element: {"path": "<exact path>", "type": "<type>", "group": "<group>"}

CORE PRINCIPLE: classify by purpose, inferred from the filename and full folder path.
Extension is a weak signal — a .csv can be data, a codebook, or supplemental.
A .txt can be participant data. Ask: what was this file made for?

── TYPE ──────────────────────────────────────────────────────────────────────
data         : contains research measurements — tabular observations, signals,
               or matrices intended for analysis
codebook     : primary purpose is describing what variables mean. Keywords in
               name: codebook, data_dictionary, variable_list, coding key, key,
               variable_key, var_desc, data_guide, labels, legend, metadata;
               or "variables" at the start/end of the filename.
code         : source file or notebook whose purpose is to generate analyses —
               scripts, syntax files, notebooks (.Rmd, .qmd, .ipynb)
software     : program or config file whose purpose is to run the experiment —
               task runners, stimulus apps, compiled binaries (.exe, .app,
               .jar, .msi, .dmg), experiment parameter/config files.
               Task/experiment runtime files → always software: E-Prime
               (.ebs2, .es2, .wndpos, .edat, .edat2, .emrg), PsychoPy
               (.psyexp), OpenSesame (.opensesame, .osexp).
               Documents (.pdf, .docx, .doc, .txt, .rtf) are NEVER software,
               even when inside experiment or task folders.
output       : artefact produced by executing a script — rendered notebooks,
               figures, graphs, log files, SPSS output (.spv), computational
               byproducts. When provenance is ambiguous → supplemental.
supplemental : human-authored research material not captured above —
               manuscripts, preregistrations, instruments, consent forms.
               Fallback when provenance is ambiguous.
readme       : file named README (any capitalisation or extension)
asset        : stimulus media (image, audio, or video) actively presented to
               participants — .jpg, .png, .gif, .bmp, .tif, .wav, .mp3, .mp4,
               .avi, .mov and similar. Documents (.pdf, .docx, .doc), spreadsheets,
               and scripts are NEVER asset regardless of folder or context.
other        : no research relevance — OS metadata (.DS_Store, Thumbs.db),
               lock files, dotfiles. Not a catch-all: if any research use is
               plausible, use another type.

── GROUP ─────────────────────────────────────────────────────────────────────
"ex<N>"   : tied to a numbered experiment. The label can be in the folder OR
            the filename — you do not need both. Either is sufficient:
              folder label:   "Study 1/file.csv" → ex1, "Exp2/p1.dat" → ex2
              filename label: "s1_data.txt" → ex1, "s2a_results.csv" → ex2a,
                              "S3_raw.csv" → ex3, "Experiment4_data.sav" → ex4
            A label in the filename alone is sufficient — the folder does not
            also need to carry it. Both Study, Experiment, S and such can be used as
            explicit experiment indicators.
            Preserve letter suffixes exactly: s3a → ex3a, Exp2b → ex2b.
            NOT indicators: run numbers ("run1"), subject IDs ("subject-2294"),
            version numbers, ordinal levels ("1st_Level"), sequential file counts
            ("(1)", "(2)", "design2", "3_Column_Format"), analysis levels.
"pilot<N>": context explicitly indicates a pilot study. No number → "pilot1".
            Never ex<N>. Pretest folders → shared, never pilot.
"shared"  : everything not tied to a specific numbered experiment or pilot.

── HARD CASES: examples show the reasoning ───────────────────────────────────
Filename is the primary signal for ambiguous extensions:
  "reaction_times.csv"        → data        (measurement name)
  "variable_codebook.csv"     → codebook    (keyword in name)
  "correlations_figure.csv"   → output      (tabular file named after a figure)
  "interview_transcript.docx" → data        (qualitative raw data)
  "consent_form.docx"         → supplemental

Participant-pattern filenames → always data, regardless of extension:
  "subject-2294_run1.txt", "p01_session1.log", "subject01.wav" → data

.log/.out files — use the strongest available signal, in priority order:
  1. participant/subject ID in filename → data
  2. inside a data-collection folder (not a system logs/ folder at repo root) → data
  3. otherwise → output

.mat files: default → data. Exception: filename contains "result", "output",
  "model", "fit", "figure", or "plot" → output.

.html files: shares a basename with a script in the same folder → output.
  Otherwise → supplemental.

Media (.jpg, .png, .wav, .mp4, etc.) — never other:
  participant/subject ID in filename → data
  "figure", "fig", "plot", "graph" in filename → output
  context indicates stimulus material → asset
  otherwise → supplemental

.json: measurement/response filename → data. Config pattern (package.json,
  *rc.json, *config.json, dotfiles) → other.
.spv: always output (SPSS Viewer file; .sps is code).

Tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat):
  name contains "graph", "figure", or "plot" → output, not data
  name contains "scores", "processed", or "cleaned" → data, not output

code vs software — use purpose, not extension:
  analysis / modelling / cleaning scripts → code
  experiment runners, stimulus apps, compiled binaries → software
  config file serving experiment/task context → software ONLY if it is a
    structured config format (.yaml, .yml, .json, .cfg, .ini, .toml) or a
    binary runtime file. Human-authored text documents are NOT config files.
  config file with "analysis", "model", or "params" in name → code

"Supplemental Experiment N" / "Supplemental Study N" folders → group "shared"
Archive and previous-version folders → type of contents, group "shared"

Echo every path exactly. Output ONLY the JSON array.'


SCHEMA_STRUCTURE_PROMPT <- r"[You are classifying files in a psychology research data repository.
You will receive a file tree. For each path return a JSON array (same order).

File organisation varies widely — use the full path and folder context, not just
the extension, to infer each file's purpose."

{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.org/schema/file-classification.json",
  "title": "File Classification",
  "description": "Classification output for a psychology research repository file tree.",
  "type": "array",
  "items": { "$ref": "#/$defs/file_entry" },

  "$defs": {
    "file_entry": {
      "type": "object",
      "required": ["path", "type", "group"],
      "additionalProperties": false,
      "properties": {
        "path": {
          "type": "string",
          "description": "Echo the input path exactly as given."
        },
        "type": {
          "type": "string",
          "enum": ["data", "codebook", "code", "software", "output", "supplemental", "readme", "asset", "other"],
          "description": "What this file is for. Use the full path and folder context — not just the extension — to infer purpose. Rules per value: 'data': contains research measurements — observations, recordings, or matrices intended for analysis. The extension alone is not sufficient: a .csv or .xlsx may be a codebook, a .txt may be participant data. Judge from filename and folder context. 'codebook': primary purpose is describing what variables mean. Identified by filename keywords: codebook, data_dictionary, variable_list, coding_key, variable_key, var_desc, data_guide, labels, legend, metadata; or 'variables' at the start or end of the filename. A codebook can be any format — .csv, .xlsx, .pdf, .docx, .txt. 'code': executable source file or notebook whose purpose is to generate analyses or research outputs — scripts, syntax files, notebooks (.Rmd, .qmd, .ipynb), regardless of language. 'software': program, application, or configuration file whose purpose is to run or configure the experiment — stimulus delivery, task presentation, data collection tools, configuration files, and any other file that is part of the experiment software package. Compiled binaries (.exe, .app, .jar, .msi, .dmg) → always software. Any file belonging to the experiment software package → software. 'output': file produced by executing a script — rendered notebooks (.html, .pdf, .docx output from .Rmd/.qmd/.ipynb), script-generated figures and graphs, log files (.log, .out), and other computational byproducts. Classify as output when the filename or folder context clearly indicates a script-generated artefact. When provenance is ambiguous, prefer supplemental. 'supplemental': human-authored research material that is not data, code, or a codebook — manuscripts, preregistrations, instruments, consent forms, survey scales, appendices. Script-generated artefacts (figures, rendered notebooks) → output, not supplemental. Fallback for ambiguous provenance. 'readme': file named or contains README (any capitalisation). 'asset': stimulus media presented to participants during the study — image, audio, or video files. 'other': no research content — OS metadata, config files, lock files. Not a catch-all for ambiguous research files. (Compiled experiment programs → software, not other.) Hard cases: .csv/.xlsx/.txt/.pdf can each be data OR codebook OR supplemental — the filename is the primary signal: measurement-oriented names → data; variable-description names → codebook; document-oriented names → supplemental. subject-* or sub-* files → always data. Transcript files (filename contains 'transcript', 'transcription', 'interview', or 'verbal') → data, NOT supplemental, regardless of format. .rds/.rdata/.rda → data unless filename contains 'plot', 'figure', or 'graph' → output. .json → data if filename suggests measurements; other if it looks like config (package.json, dotfiles, *rc.json, *config.json). .spv → output (SPSS Viewer file — computational byproduct; .sps is code, .spv is NOT supplemental). .log/.out → output unless filename contains a participant/subject ID → data. Tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat) whose name contains 'graph', 'figure', or 'plot' → output, NOT data. Images/audio/video (.jpg, .png, .wav, .mp4, etc.) are NEVER other — classify as: data if filename contains a participant/subject ID; output if filename contains 'figure', 'fig', 'plot', 'graph', 'results', or 'output' AND not in stimuli context; asset in all other cases (default for unidentified media). Stimuli folder names and filename keywords ('stim', 'stimulus', 'trial', 'item') are strong positive signals for asset but not required. .html → output if it shares a basename with an .Rmd/.qmd/.ipynb in the same folder or is in a folder containing scripts; otherwise supplemental. .mat → output if filename contains 'result', 'output', 'model', 'fit', 'figure', or 'plot'; → data otherwise (including folder path contains 'data' or 'raw', numeric suffix, or subject/participant ID in name). Default for ambiguous .mat is data. code vs software: use purpose and full path as the signal. Analysis/modelling/cleaning scripts → code. Experiment task runners, stimulus apps, compiled programs → software. Path contains experiment/, task/, paradigm/, or stimulus/ folder AND file runs something → prefer software. Analysis/, results/, scripts/ folder context → code."
        },
        "group": {
          "type": "string",
          "pattern": "^(ex[0-9]+[a-zA-Z]?|pilot[0-9]*|shared)$",
          "description": "Which experiment this file belongs to. 'ex<N>': clearly tied to a numbered experiment or study — the number must follow an explicit experiment label in the folder path or filename: 'Study 1/', 'Experiment 2/', 'S1_data.csv', 'Exp3/', 'E2/'. Preserve letter suffixes exactly: S3a → ex3a. Numbers that are NOT experiment indicators: run numbers ('run1'), subject IDs ('subject-2294'), version numbers, ordinal levels ('1st_Level'), sequential counts ('3_Column_Format'). 'pilot<N>': context clearly indicates a pilot study. No number present → 'pilot1'. Pilots are never ex<N>. 'shared': everything else — files not tied to a specific numbered experiment or pilot. Use for cross-experiment files, project-wide scripts, combined datasets, archive folders, and all readme/asset/other files. 'Supplemental Experiment N' or 'Supplemental Study N' folders → group 'shared'. Archive and previous-version folders → group 'shared'."
        }
      }
    }
  }
}

Echo every path exactly. Output ONLY the JSON array.]"


# ── Column type classification (0_index.R → llm_batch()) ─────────────────────

COLUMN_TYPE_PROMPT <- 'You are classifying columns in psychology research data.
For each column descriptor return a JSON array (same order).
Each element: {"descriptor": "<exact descriptor>", "col_type": "<type>"}

col_type — pick one:
  continuous  : numeric measurement — reaction time, age, VAS rating, Likert mean,
                subscale score, count, percentage, any column with decimal values
  ordinal     : ordered integer scale with few levels — 1–5 Likert item, 1–10 rating,
                bounded score, ranked preference
  categorical : unordered group or category code with few levels (condition, gender,
                language, group assignment)
  binary      : exactly two possible values (yes/no, 0/1, treatment/control)
  id          : participant or row identifier — the PRIMARY signal is the column NAME
                (participant, subject, ResponseId, pid, etc.); values may be numeric or
                alphanumeric codes; unique or near-unique per row

  unknown     : ONLY when the name AND all sample values together give absolutely no
                classifiable signal — virtually never the right answer. When in doubt
                between "unknown" and any other type, always choose the other type.
                Never use "unknown" for a column whose samples look like numbers.

IMPORTANT: Prefer "continuous" or "ordinal" over "unknown" for numeric columns.
When in doubt between "continuous" and "ordinal", choose "continuous".

Output ONLY the JSON array. No notes, no text outside the array.'

# ── Character column type classification (0_index.R → llm_batch(), Batch 2) ──

CHAR_COLUMN_TYPE_PROMPT <- 'You are classifying columns in psychology research data.
For each column descriptor return a JSON array (same order).
Each element: {"descriptor": "<exact descriptor>", "col_type": "<type>"}

col_type — pick one:
  categorical : unordered group or category label — condition names, gender codes,
                language labels, response options like "yes"/"no"/"maybe"
  ordinal     : ordered scale stored as strings — "low"/"medium"/"high", letter
                grades, Likert labels ("strongly agree" etc.)
  binary      : exactly two distinct values (yes/no, true/false, present/absent)
  text        : free-form written response — sentences, phrases, open-ended answers
  id          : participant or row identifier — the PRIMARY signal is the column NAME;
                keep for edge cases (e.g. alphanumeric codes not caught by name rules)
  unknown     : ONLY when name AND all sample values give absolutely no classifiable
                signal — virtually never correct; always prefer another type

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

# ── Aggregate sentinel classification (0_index.R → llm_batch(), Phase 2) ─────

SENTINEL_PROMPT <- 'You are classifying aggregate folder series in a psychology research data repository.
Each entry describes a series of files collapsed to a single descriptor.
For each descriptor return a JSON array (same order).
Each element: {"path": "<exact descriptor string>", "type": "<type>", "group": "<group>"}

Descriptor format: folder/[prefix: "PREFIX", N files, .EXT, samples: FILE1, FILE2, ...]
  or: folder/[mixed, N files, .EXT, samples: ...] for an unsorted collection

TYPE — use the same definitions as file classification:
  data         : series of research measurements (participant-level recordings, responses)
  asset        : stimulus media presented to participants
  code         : executable scripts or notebooks whose purpose is to generate analyses
  software     : series of experiment programs, compiled binaries, task tools,
                 or experiment configuration files
  output       : script-generated artefacts — rendered notebooks, figures, graphs,
                 log files, computational byproducts
  supplemental : human-authored research material — manuscripts, instruments, consent
                 forms. Ambiguous provenance → supplemental.
  other        : no research content

GROUP — use the same rules as file classification:
  "ex<N>"   : clearly tied to a numbered experiment or study
  "pilot<N>": clearly a pilot study
  "shared"  : everything else

Key signals for aggregate series:
- Participant-named series (participant IDs, subject codes) with tabular extensions → data
- Participant-named media series (subject IDs in filenames, .wav/.mp4 etc.) → data
- Task-condition prefixes (e.g. "FlowerInsectCong-", "RaceEvalCong-") within an IAT folder → data,
  use the prior-batch experiment context to assign the correct group
- Numbered or stimulus-keyword media files (.jpg, .png, .wav) → asset (NEVER other)
- Figure/graph/plot series named files (.jpg, .png, .svg) outside stimuli folder → output
- Script collections → code
- Use the Known experiment structure context (if provided) to assign group labels consistent
  with how merged data files from the same experiment were already classified

Echo every descriptor string exactly. Output ONLY the JSON array.'

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
