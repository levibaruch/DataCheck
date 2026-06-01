# prompts.R
# ─────────────────────────────────────────────────────────────────────────────
# All LLM prompt strings used by the pipeline.
# Sourced by 0_index.R and 2_codebook_label.R.
# ─────────────────────────────────────────────────────────────────────────────

# ── File classification headers (0_index.R → llm_batch()) ────────────────────
# Each format has a matching header + body. Select via structure_prompt_version.

# -- plaintext headers --------------------------------------------------------

SINGLE_HEADER_PLAIN <- 'You are classifying files in a psychology research data repository.
You will receive a file tree. Return a JSON array in the same order.
Each element: {"path": "<exact path>", "type": "<type>", "group": "<group>"}

Respond with a JSON array (one element per input object):
{"path": "<exact path>", "type": "<type>", "group": "<group>"}

CORE PRINCIPLE: classify by purpose, inferred from the filename and full folder path.
Extension is a weak signal — a .csv can be data, a codebook, or supplemental.
A .txt can be participant data. Ask: what was this file made for?

'

AGGREGATE_HEADER_PLAIN <- 'You are classifying a folder of files. All files share the same extension and parent directory. Your classification applies to the folder as a whole.
v
You will receive one JSON object per folder:

{
  "path":      "<folder/.ext key>",
  "ext":       "<shared extension>",
  "n_files":   <total file count>,
  "filenames": ["<sample filename>", ...]
}

Respond with a JSON array (one element per input object):
{"path": "<exact path>", "type": "<type>", "group": "<group>"}

CORE PRINCIPLE: classify by purpose, inferred from the filename and full folder path.
Extension is a weak signal — a .csv can be data, a codebook, or supplemental.
A .txt can be participant data. Ask: what was this file made for?


'

# -- markdown headers ---------------------------------------------------------

SINGLE_HEADER_MD <- '# Task
You are classifying files in a psychology research data repository.

## Input
A file tree — one path per line.

## Output
Return a JSON array in the **same order** as the input.
Each element: `{"path": "<exact path>", "type": "<type>", "group": "<group>"}`

## Core Principle
Classify by **purpose**, inferred from the filename and full folder path.
- Extension is a weak signal — a `.csv` can be data, a codebook, or supplemental.
- A `.txt` can be participant data.
- Ask: **what was this file made for?**

'

AGGREGATE_HEADER_MD <- '# Task
You are classifying a folder of files. All files share the same extension and parent directory. Your classification applies to the **folder as a whole**.

## Input
One JSON object per folder:

```json
{
  "path":      "<folder/.ext key>",
  "ext":       "<shared extension>",
  "n_files":   <total file count>,
  "filenames": ["<sample filename>", ...]
}
```

## Output
Return a JSON array (one element per input object):
`{"path": "<exact path>", "type": "<type>", "group": "<group>"}`

## Core Principle
Classify by **purpose**, inferred from the filename and full folder path.
- Extension is a weak signal — a `.csv` can be data, a codebook, or supplemental.
- A `.txt` can be participant data.
- Ask: **what was this file made for?**

'

# -- JSON headers -------------------------------------------------------------

SINGLE_HEADER_JSON <- r"[{
  "task": "Classify files in a psychology research data repository.",
  "input_format": "File tree — one path per line.",
  "output_format": {
    "type": "JSON array, same order as input",
    "schema": {"path": "<exact path>", "type": "<type>", "group": "<group>"}
  },
  "core_principle": "Classify by purpose, inferred from the filename and full folder path. Extension is a weak signal — a .csv can be data, a codebook, or supplemental. A .txt can be participant data. Ask: what was this file made for?"
}

]"

AGGREGATE_HEADER_JSON <- r"[{
  "task": "Classify a folder of files. All files share the same extension and parent directory. Your classification applies to the folder as a whole.",
  "input_format": {
    "type": "JSON object per folder",
    "schema": {
      "path": "<folder/.ext key>",
      "ext": "<shared extension>",
      "n_files": "<total file count>",
      "filenames": ["<sample filename>", "..."]
    }
  },
  "output_format": {
    "type": "JSON array, one element per input object",
    "schema": {"path": "<exact path>", "type": "<type>", "group": "<group>"}
  },
  "core_principle": "Classify by purpose, inferred from the filename and full folder path. Extension is a weak signal — a .csv can be data, a codebook, or supplemental. A .txt can be participant data. Ask: what was this file made for?"
}

]"


# ── PROMPT: md ────────────────────────────────────────────────────────────────
# Markdown format with headers, bold, and bullet lists.

STRUCTURE_PROMPT_MD <- '
# File Classification

---

## TYPE

### data
Contains research measurements — tabular observations, signals, or matrices intended for analysis.

### codebook
Primary purpose is describing what variables mean.

Any of these keywords anywhere in the filename indicates codebook: codebook, data_dictionary, variable_list, coding, variable_key, var_desc, data_guide, labels, legend, metadata.

Positional patterns that also indicate codebook:
- `variables` at the start or end of the filename
- `_key` or `-key` as a suffix (e.g. `study1_key.csv`, `sullivanEtAl2014_key.csv`)
- Filename ending in `_dict`, `_dd`, or `_cb`

### code
Source file or notebook whose purpose is to generate analyses.
- **Examples:** scripts (`.R`, `.py`), syntax files, notebooks (`.Rmd`, `.qmd`, `.ipynb`)

### software
Program or config file whose purpose is to run the experiment.
- **Examples:** task runners, stimulus apps, compiled binaries (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`), experiment parameter/config files
- **Task/experiment runtime files → always software:**
  - E-Prime: `.ebs2`, `.es2`, `.wndpos`, `.edat`, `.edat2`, `.emrg`
  - PsychoPy: `.psyexp`
  - OpenSesame: `.opensesame`, `.osexp`
- **Never software:** documents (`.pdf`, `.docx`, `.doc`, `.rtf`), even when inside experiment or task folders

### output
Artefact produced by executing a script.
- **Examples:** rendered notebooks, figures, graphs, log files, SPSS output (`.spv`), computational byproducts
- **Fallback:** when provenance is ambiguous → supplemental (not output)

### supplemental
Human-authored research material not captured above.
- **Examples:** manuscripts, preregistrations, instruments, consent forms
- **Role:** fallback when provenance is ambiguous

### readme
File named README (any capitalisation or extension).

### asset
Stimulus media actively presented to participants.
- **Extensions:** `.jpg`, `.png`, `.gif`, `.bmp`, `.tif`, `.wav`, `.mp3`, `.mp4`, `.avi`, `.mov` and similar
- **Never asset:** documents (`.pdf`, `.docx`, `.doc`), spreadsheets, scripts — regardless of folder or context

### other
No research relevance.
- **Examples:** OS metadata (`.DS_Store`, `Thumbs.db`), lock files, dotfiles
- **Split-archive parts:** `.z01`, `.z02`, `.z03`, `.7z.001`, `.7z.002`, `.r01`, `.r02`, etc. → always `other`, regardless of the base filename
- **Not a catch-all:** if any research use is plausible, use another type

---

## GROUP

### `ex<N>` — numbered experiment
Tied to a numbered experiment. The label can appear in **any ancestor folder along the path** or in the filename — either alone is sufficient. Scan the full path, not just the immediate parent.

**Folder label examples:**
- `Study 1/file.csv` → `ex1`
- `Exp2/p1.dat` → `ex2`
- `Project/Experiments/Study_1/data/p01.csv` → `ex1` (marker is two levels up)

**Filename label examples (folder does NOT also need to carry it):**
- `s1_data.txt` → `ex1`
- `s2a_results.csv` → `ex2a`
- `S3_raw.csv` → `ex3`
- `Experiment4_data.sav` → `ex4`

**Valid indicators:** `Study`, `Experiment`, `S`, `Exp`, and similar.

**Preserve letter suffixes exactly:** `s3a` → `ex3a`, `Exp2b` → `ex2b`.

**NOT experiment indicators:**
- Run numbers (`run1`)
- Subject IDs (`subject-2294`)
- Version numbers
- Ordinal levels (`1st_Level`)
- Sequential file counts (`(1)`, `(2)`, `design2`, `3_Column_Format`)
- Analysis levels

### `pilot<N>` — pilot study
Context explicitly indicates a pilot study.
- No number → `pilot1`
- Never use `ex<N>` for pilots
- Pretest folders → `shared`, never `pilot`

### `shared` — everything else
Everything not tied to a specific numbered experiment or pilot.

---

## PRIORITY RULES (unconditional overrides)

These override any default extension-based classification.

- **Split-archive parts** (`.z01`, `.z02`, `.7z.001`, `.r01`, etc.) → always `other`
- **"Supplemental Experiment N" / "Supplemental Study N" folders → group `shared`**
- **Archive and previous-version folders → type of contents, group `shared`**

---

## DECISION PROCEDURES (ordered — try in sequence)

### Participant-pattern signals (filename OR folder name)
A participant signal in either the filename (`subject-2294`, `pXX`) or a parent folder (`Participants/`, `Recordings/`, `Subjects/`) — either alone is sufficient. Pure-numeric stems (`1.mp4`, `42.csv`) inside such folders also count. Check in order:
1. Filename contains `config`, `params`, or `settings`, **or** has a structured config extension (`.yaml`, `.yml`, `.json`, `.cfg`, `.ini`, `.toml`) → apply normal `code`/`software` logic (usually `software`)
2. Otherwise → `data`
   - Examples routing to `data`: `subject-2294_run1.txt`, `p01_session1.log`, `subject01.wav`
   - Example routing to `software`: `p01_config.json`, `subject03_params.yaml`

### `.log` / `.out` files
Use the strongest available signal, in priority order:
1. Participant/subject ID in filename → `data`
2. Inside a data-collection folder (not a system `logs/` folder at repo root) → `data`
3. Otherwise → `output`

### Media files (`.jpg`, `.png`, `.wav`, `.mp4`, etc.)
Never `other`. Check in order:
1. Participant signal in filename OR folder (see above) → `data`
2. `figure`, `fig`, `plot`, or `graph` in filename → `output`
3. Stimulus signal in filename or folder (`Stimuli/`, `Photo_arrays/`, `Images/`, `Sounds/`, etc.) → `asset`
4. Otherwise → `supplemental`

---

## DISAMBIGUATION (pattern-based)

### Filename is the primary signal for ambiguous extensions
- `reaction_times.csv` → `data` (measurement name)
- `variable_codebook.csv` → `codebook` (keyword in name)
- `sullivanEtAl2014_key.csv` → `codebook` (`_key` suffix)
- `correlations_figure.csv` → `output` (tabular file named after a figure)
- `interview_transcript.docx` → `data` (qualitative raw data)
- `consent_form.docx` → `supplemental`

### Tabular files (`.csv`, `.xlsx`, `.sav`, `.dta`, `.tsv`, `.dat`)
- Name contains `graph`, `figure`, or `plot` → `output`, not `data`
- Name contains statistical tests or inferences (correlations, regression, t-test, anova, p-values) → `output`, not `data`
- Name contains `scores`, `processed`, or `cleaned` → `data`, not `output`

### `.mat` files
- **Default:** `data`
- **Exception:** filename contains `result`, `output`, `model`, `fit`, `figure`, or `plot` → `output`
- `.spv` → default `output` (SPSS Viewer)
- `.fig` → default `output` (MATLAB figure)
- `.jasp` → default `data` (JASP project)

### `.html`, `.htm`, `.xml`, `.jsp` (web-experiment runtime)
- **Default:** `software` (jsPsych, JATOS, Qualtrics exports)
- Shares basename with a same-folder script → `output`

### `.json` files
- Measurement/response filename → `data`
- Config pattern (`package.json`, `*rc.json`, `*config.json`, dotfiles) → `software`

### `code` vs `software` — use purpose, not extension
- **Strong folder signals (alone sufficient):** scripts (`.py`, `.js`, `.m`, etc.) living in `Task/`, `Tasks/`, `Stimuli/`, `Paradigm/` → `software`. These folder names are rarely overloaded.
- **Weak folder signals (require filename corroboration):** folders like `Materials/`, `Experiment/`, `online_materials/`, `testing/` are common generic names. A script in these folders is `software` **only if** the filename also suggests runtime (see filename signals below) or the path includes a task-specific subfolder (e.g. `Materials/testing/fas-sif/` where `fas-sif` is a task identifier).
- Analysis, modelling, or cleaning scripts → `code`
- Experiment runners, stimulus apps, compiled binaries → `software`
- Config file serving experiment/task context → `software` **only if** it is a structured config format (`.yaml`, `.yml`, `.json`, `.cfg`, `.ini`, `.toml`) or a binary runtime file. Plain `.txt` and `.xml` files are NOT automatically config — treat by content, not extension. Human-authored text documents (`.rtf`, `.doc`) are NEVER config.
- Config file with `analysis`, `model`, or `params` in name → `code`
- **Filename signals for `software`:** `task`, `run`, `experiment`, `stimulus`, `present`, `paradigm`, numbered sequences suggesting task versions (`task-1.py`, `testing-fas-sif-1.py`)
- **Filename signals for `code` (override folder context):** `analysis`, `regression`, `stats`, `model_fit`, `clean`, `preprocess`, `plot_*`
- `.R` files are always analysis → `code`, never `software`
- `.js` is almost always `software` (jsPsych); analysis-named `.js` (e.g. `regression_analysis.js`) → `code`
- `.m` (MATLAB) — same logic as `.js`: runtime folder/filename → `software`; analysis name → `code`; default `code`

---

## Output
Echo every path exactly. Output ONLY the JSON array.
'


# ── PROMPT: plaintext ─────────────────────────────────────────────────────────
# Same taxonomy and rules as md, expressed as dense prose with no markup.

STRUCTURE_PROMPT_PLAIN <- '

TYPE. data: contains research measurements — tabular observations, signals, or matrices intended for analysis. codebook: primary purpose is describing what variables mean. Any of these keywords anywhere in the filename indicates codebook: codebook, data_dictionary, variable_list, coding, variable_key, var_desc, data_guide, labels, legend, metadata. Positional patterns that also indicate codebook: variables at the start or end of the filename; _key or -key as a suffix (e.g. study1_key.csv, sullivanEtAl2014_key.csv); filename ending in _dict, _dd, or _cb. code: source file or notebook whose purpose is to generate analyses. Examples: scripts (.R, .py), syntax files, notebooks (.Rmd, .qmd, .ipynb). software: program or config file whose purpose is to run the experiment. Examples: task runners, stimulus apps, compiled binaries (.exe, .app, .jar, .msi, .dmg), experiment parameter/config files. Task/experiment runtime files always software: E-Prime (.ebs2, .es2, .wndpos, .edat, .edat2, .emrg), PsychoPy (.psyexp), OpenSesame (.opensesame, .osexp). Never software: documents (.pdf, .docx, .doc, .rtf), even when inside experiment or task folders. output: artefact produced by executing a script. Examples: rendered notebooks, figures, graphs, log files, SPSS output (.spv), computational byproducts. Fallback: when provenance is ambiguous use supplemental, not output. supplemental: human-authored research material not captured above. Examples: manuscripts, preregistrations, instruments, consent forms. Fallback when provenance is ambiguous. readme: file named README (any capitalisation or extension). asset: stimulus media actively presented to participants. Extensions: .jpg, .png, .gif, .bmp, .tif, .wav, .mp3, .mp4, .avi, .mov and similar. Never asset: documents (.pdf, .docx, .doc), spreadsheets, scripts — regardless of folder or context. other: no research relevance. Examples: OS metadata (.DS_Store, Thumbs.db), lock files, dotfiles. Split-archive parts: .z01, .z02, .z03, .7z.001, .7z.002, .r01, .r02, etc. — always other, regardless of the base filename. Not a catch-all: if any research use is plausible, use another type.

GROUP. ex<N>: tied to a numbered experiment. The label can appear in any ancestor folder along the path or in the filename — either alone is sufficient. Scan the full path, not just the immediate parent. Folder label examples: Study 1/file.csv gives ex1, Exp2/p1.dat gives ex2, Project/Experiments/Study_1/data/p01.csv gives ex1 (marker is two levels up). Filename label examples (folder does NOT also need to carry it): s1_data.txt gives ex1, s2a_results.csv gives ex2a, S3_raw.csv gives ex3, Experiment4_data.sav gives ex4. Valid indicators: Study, Experiment, S, Exp, and similar. Preserve letter suffixes exactly: s3a gives ex3a, Exp2b gives ex2b. NOT experiment indicators: run numbers (run1), subject IDs (subject-2294), version numbers, ordinal levels (1st_Level), sequential file counts ((1), (2), design2, 3_Column_Format), analysis levels. pilot<N>: context explicitly indicates a pilot study. No number gives pilot1. Never use ex<N> for pilots. Pretest folders give shared, never pilot. shared: everything not tied to a specific numbered experiment or pilot.

Priority rules (unconditional overrides). Split-archive parts (.z01, .z02, .7z.001, .r01, etc.) always other. Supplemental Experiment N / Supplemental Study N folders give group shared. Archive and previous-version folders give type of contents, group shared.

Decision procedures. Participant-pattern signals (filename OR folder name): subject ID in filename (subject-2294, pXX) OR parent folder name (Participants/, Recordings/, Subjects/) — either alone is sufficient. Pure-numeric stems (1.mp4, 42.csv) inside such folders also count. Check in order: (1) filename contains config, params, or settings, or has a structured config extension (.yaml, .yml, .json, .cfg, .ini, .toml) — apply normal code/software logic (usually software); (2) otherwise data. Examples routing to data: subject-2294_run1.txt, p01_session1.log, subject01.wav. Example routing to software: p01_config.json, subject03_params.yaml. .log / .out files: use the strongest available signal, in priority order: (1) participant/subject ID in filename gives data; (2) inside a data-collection folder (not a system logs/ folder at repo root) gives data; (3) otherwise output. Media files (.jpg, .png, .wav, .mp4, etc.): never other. Check in order: (1) participant signal in filename or folder gives data; (2) figure, fig, plot, or graph in filename gives output; (3) stimulus signal in filename or folder (Stimuli/, Photo_arrays/, Images/, Sounds/, etc.) gives asset; (4) otherwise supplemental.

Disambiguation. Filename is the primary signal for ambiguous extensions: reaction_times.csv gives data (measurement name); variable_codebook.csv gives codebook (keyword in name); sullivanEtAl2014_key.csv gives codebook (_key suffix); correlations_figure.csv gives output (tabular file named after a figure); interview_transcript.docx gives data (qualitative raw data); consent_form.docx gives supplemental. Tabular files (.csv, .xlsx, .sav, .dta, .tsv, .dat): name contains graph, figure, or plot gives output, not data; name contains statistical tests or inferences (correlations, regression, t-test, anova, p-values) gives output, not data; name contains scores, processed, or cleaned gives data, not output. .mat files: default is data. Exception: filename contains result, output, model, fit, figure, or plot gives output. .spv default output (SPSS Viewer). .fig default output (MATLAB figure). .jasp default data (JASP project). .html/.htm/.xml/.jsp (web-experiment runtime): default software (jsPsych, JATOS, Qualtrics exports). Shares basename with a same-folder script gives output. .json files: measurement/response filename gives data; config pattern (package.json, *rc.json, *config.json, dotfiles) gives software. code vs software — use purpose, not extension: strong folder signals (alone sufficient) — scripts (.py, .js, .m, etc.) living in Task/, Tasks/, Stimuli/, Paradigm/ give software; these folder names are rarely overloaded. Weak folder signals (require filename corroboration) — folders like Materials/, Experiment/, online_materials/, testing/ are common generic names; a script in these folders is software only if the filename also suggests runtime or the path includes a task-specific subfolder (e.g. Materials/testing/fas-sif/ where fas-sif is a task identifier). Analysis, modelling, or cleaning scripts give code. Experiment runners, stimulus apps, compiled binaries give software. Config file serving experiment/task context gives software only if it is a structured config format (.yaml, .yml, .json, .cfg, .ini, .toml) or a binary runtime file. Plain .txt and .xml files are NOT automatically config — treat by content, not extension. Human-authored text documents (.rtf, .doc) are NEVER config. Config file with analysis, model, or params in name gives code. Filename signals for software: task, run, experiment, stimulus, present, paradigm, numbered sequences suggesting task versions (task-1.py, testing-fas-sif-1.py). Filename signals for code (override folder context): analysis, regression, stats, model_fit, clean, preprocess, plot_*. .R files are always analysis gives code, never software. .js is almost always software (jsPsych); analysis-named .js (e.g. regression_analysis.js) gives code. .m (MATLAB) follows same logic as .js: runtime folder/filename gives software; analysis name gives code; default code.

Echo every path exactly. Output ONLY the JSON array.
'


# ── PROMPT: json ──────────────────────────────────────────────────────────────
# JSON Schema format — rules encoded in $defs sections, one per type/rule set.
# Structurally different from prose formats; same complete ruleset.

STRUCTURE_PROMPT_JSON <- r"[
The $defs sections define all classification rules — read them before classifying.

{
  "$schema": "https://json-schema.org/draft/2020-12/schema",

  "$defs": {

    "core_principle": "Classify by purpose, inferred from the filename and full folder path. Extension is a weak signal — a .csv can be data, a codebook, or supplemental. A .txt can be participant data or a codebook. Ask: what was this file made for?",

    "type_definitions": {
      "data":        "Contains research measurements — tabular observations, signals, or matrices intended for analysis.",
      "codebook":    "Primary purpose is describing what variables mean. Any of these keywords anywhere in the filename indicates codebook: codebook, data_dictionary, variable_list, coding, variable_key, var_desc, data_guide, labels, legend, metadata. Positional patterns that also indicate codebook: variables at the start or end of the filename; _key or -key as a suffix (e.g. study1_key.csv, sullivanEtAl2014_key.csv); filename ending in _dict, _dd, or _cb.",
      "code":        "Source file or notebook whose purpose is to generate analyses. Examples: scripts (.R, .py), syntax files, notebooks (.Rmd, .qmd, .ipynb).",
      "software":    "Program or config file whose purpose is to run the experiment. Examples: task runners, stimulus apps, compiled binaries (.exe, .app, .jar, .msi, .dmg), experiment parameter/config files. Task/experiment runtime files always software: E-Prime (.ebs2, .es2, .wndpos, .edat, .edat2, .emrg), PsychoPy (.psyexp), OpenSesame (.opensesame, .osexp). Never software: documents (.pdf, .docx, .doc, .rtf), even when inside experiment or task folders.",
      "output":      "Artefact produced by executing a script. Examples: rendered notebooks, figures, graphs, log files, SPSS output (.spv), computational byproducts. Fallback: when provenance is ambiguous use supplemental, not output.",
      "supplemental":"Human-authored research material not captured above. Examples: manuscripts, preregistrations, instruments, consent forms. Fallback when provenance is ambiguous.",
      "readme":      "File named README (any capitalisation or extension).",
      "asset":       "Stimulus media actively presented to participants. Extensions: .jpg, .png, .gif, .bmp, .tif, .wav, .mp3, .mp4, .avi, .mov and similar. Never asset: documents (.pdf, .docx, .doc), spreadsheets, scripts — regardless of folder or context.",
      "other":       "No research relevance. Examples: OS metadata (.DS_Store, Thumbs.db), lock files, dotfiles. Split-archive parts: .z01, .z02, .z03, .7z.001, .7z.002, .r01, .r02, etc. — always other, regardless of the base filename. Not a catch-all: if any research use is plausible, use another type."
    },

    "group_definitions": {
      "ex_N":    "Tied to a numbered experiment. The label can appear in any ancestor folder along the path or in the filename — either alone is sufficient. Scan the full path, not just the immediate parent. Folder label examples: Study 1/file.csv gives ex1, Exp2/p1.dat gives ex2, Project/Experiments/Study_1/data/p01.csv gives ex1 (marker is two levels up). Filename label examples (folder does NOT also need to carry it): s1_data.txt gives ex1, s2a_results.csv gives ex2a, S3_raw.csv gives ex3, Experiment4_data.sav gives ex4. Valid indicators: Study, Experiment, S, Exp, and similar. Preserve letter suffixes exactly: s3a gives ex3a, Exp2b gives ex2b. NOT experiment indicators: run numbers (run1), subject IDs (subject-2294), version numbers, ordinal levels (1st_Level), sequential file counts ((1), (2), design2, 3_Column_Format), analysis levels.",
      "pilot_N": "Context explicitly indicates a pilot study. No number gives pilot1. Never use ex<N> for pilots. Pretest folders give shared, never pilot.",
      "shared":  "Everything not tied to a specific numbered experiment or pilot."
    },

    "priority_overrides": [
      "Split-archive parts (.z01, .z02, .7z.001, .r01, etc.) always other",
      "Supplemental Experiment N / Supplemental Study N folders give group shared",
      "Archive and previous-version folders give type of contents, group shared"
    ],

    "decision_procedures": {
      "participant_pattern_signals": "Filename OR folder name — either alone is sufficient. Filename: subject IDs (subject-2294, pXX). Folder: Participants/, Recordings/, Subjects/, etc. Pure-numeric stems (1.mp4, 42.csv) inside such folders also count. Check in order: (1) filename contains config, params, or settings, or has a structured config extension (.yaml, .yml, .json, .cfg, .ini, .toml) — apply normal code/software logic (usually software); (2) otherwise data. Examples routing to data: subject-2294_run1.txt, p01_session1.log, subject01.wav. Example routing to software: p01_config.json, subject03_params.yaml.",
      "log_out_files": "Use the strongest available signal, in priority order: (1) participant/subject ID in filename gives data; (2) inside a data-collection folder (not a system logs/ folder at repo root) gives data; (3) otherwise output.",
      "media_files": "Never other. Check in order: (1) participant signal in filename or folder gives data; (2) figure, fig, plot, or graph in filename gives output; (3) stimulus signal in filename or folder (Stimuli/, Photo_arrays/, Images/, Sounds/, etc.) gives asset; (4) otherwise supplemental."
    },

    "disambiguation": {
      "examples": [
        "reaction_times.csv gives data (measurement name)",
        "variable_codebook.csv gives codebook (keyword in name)",
        "sullivanEtAl2014_key.csv gives codebook (_key suffix)",
        "correlations_figure.csv gives output (tabular file named after a figure)",
        "interview_transcript.docx gives data (qualitative raw data)",
        "consent_form.docx gives supplemental"
      ],
      "tabular_files": [
        "name contains graph, figure, or plot gives output, not data",
        "name contains statistical tests or inferences (correlations, regression, t-test, anova, p-values) gives output, not data",
        "name contains scores, processed, or cleaned gives data, not output"
      ],
      "mat_files":  "Default is data. Exception: filename contains result, output, model, fit, figure, or plot gives output.",
      "spv_files":  "Default output (SPSS Viewer).",
      "fig_files":  "Default output (MATLAB figure).",
      "jasp_files": "Default data (JASP project).",
      "web_runtime_files": "(.html, .htm, .xml, .jsp) Default software (jsPsych, JATOS, Qualtrics exports). Shares basename with a same-folder script gives output.",
      "json_files": "Measurement/response filename gives data. Config pattern (package.json, *rc.json, *config.json, dotfiles) gives software.",
      "code_vs_software": {
        "strong_folder_signals": "Scripts (.py, .js, .m, etc.) living in Task/, Tasks/, Stimuli/, Paradigm/ give software. These folder names are rarely overloaded.",
        "weak_folder_signals": "Folders like Materials/, Experiment/, online_materials/, testing/ are common generic names. A script in these folders is software only if the filename also suggests runtime or the path includes a task-specific subfolder (e.g. Materials/testing/fas-sif/ where fas-sif is a task identifier).",
        "analysis_scripts": "Analysis, modelling, or cleaning scripts give code.",
        "compiled_binaries": "Experiment runners, stimulus apps, compiled binaries give software.",
        "config_files": "Config file serving experiment/task context gives software only if it is a structured config format (.yaml, .yml, .json, .cfg, .ini, .toml) or a binary runtime file. Plain .txt and .xml files are NOT automatically config — treat by content, not extension. Human-authored text documents (.rtf, .doc) are NEVER config. Config file with analysis, model, or params in name gives code.",
        "filename_signals_software": "task, run, experiment, stimulus, present, paradigm, numbered sequences suggesting task versions (task-1.py, testing-fas-sif-1.py)",
        "filename_signals_code": "analysis, regression, stats, model_fit, clean, preprocess, plot_* — these override folder context",
        "r_files": ".R files are always analysis gives code, never software.",
        "js_files": ".js is almost always software (jsPsych); analysis-named .js (e.g. regression_analysis.js) gives code.",
        "m_files":  ".m (MATLAB) follows same logic as .js: runtime folder/filename gives software; analysis name gives code; default code."
      }
    }
  },

  "type": "array",
  "items": {
    "type": "object",
    "required": ["path", "type", "group"],
    "additionalProperties": false,
    "properties": {
      "path":  { "type": "string",  "description": "Echo the input path exactly as given." },
      "type":  { "type": "string",  "enum": ["data", "codebook", "code", "software", "output", "supplemental", "readme", "asset", "other"] },
      "group": { "type": "string",  "pattern": "^(ex[0-9]+[a-zA-Z]?|pilot[0-9]*|shared)$" }
    }
  }
}

Echo every path exactly. Output ONLY the JSON array — no schema, no notes.]"


# ── Character column type classification (0_index.R → llm_batch(), Batch 2) ──

CHAR_COLUMN_TYPE_PROMPT <- 'You are classifying columns in psychology research data.
For each column return a JSON array (same order).
Each element: {"col_name": "<exact col_name>", "col_type": "<type>"}

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

# ── Data granularity detection (0_index.R US3 → aggregate folders with unclear signals) ──

GRANULARITY_PROMPT <- "You are classifying whether a set of psychology research data files store
data at individual or combined granularity based on their filename structure:
- \"individual\": each participant has their own SEPARATE data file (e.g., sub_1.txt, sub_2.txt, sub_3.txt)
- \"combined\": all participants' data in ONE file (e.g., data.csv, all_data.xlsx, experiment1_results.sav, study_4_data.dat)

Each numbered item below has:
- folder_name (the identifier)
- pattern=regex (extracted repeating structure)
- examples=sample filenames

Return: JSON array where each object has:
- \"folder_path\": the folder name from the input (exact match)
- \"granularity\": \"individual\" or \"combined\"

Classification rules:
- \"individual\": Pattern contains participant identifier (sub_\\d+, s\\d+, P\\d+, pp\\d+, ID\\d+, participant_\\d+, etc.)
- \"individual\": Pure numeric filename stem (^\\d+, e.g., 1.mat, 2.mat, 123.dat) → strong indicator of participant ID
- \"individual\": Multiple numeric-indexed files (_1, _2, _3, etc.) indicating separate data per participant
- \"individual\": ANY consistent prefix+number pattern where only the number varies across many files —
  even non-standard prefixes (e.g., IFFControl2C.xls, IFFControl11C.xls, Subject3.csv, Cond7.dat)
  are per-participant when the number is the only varying part across a large set of files
- \"individual\": pattern=(multiple patterns) with examples showing participant-like structure → infer from examples
- \"combined\": Single file or name contains no varying numeric component (data.csv, all_data.xlsx, results_final.sav)
- \"combined\": Pattern lacks participant identifier (data, results, raw, etc.) indicating all participants in one file
- When many files (10+) share the same extension and only a number varies → default to \"individual\"

EXAMPLES:
Input: exp/data/Exp2: pattern=Exp\\\\d+_\\\\d+\\\\.dat examples=Exp2_1.dat, Exp2_10.dat, Exp2_11.dat
Output: [{\"folder_path\": \"exp/data/Exp2\", \"granularity\": \"individual\"}]
(Reason: numeric suffix pattern _\\\\d+ suggests per-participant files)

Input: data/RawResponses: pattern=^\\\\d+\\\\.mat examples=1.mat, 50.mat, 149.mat
Output: [{\"folder_path\": \"data/RawResponses\", \"granularity\": \"individual\"}]
(Reason: pure numeric filename stems without parent labels are participant ID indicators)

Input: Control/RA_IATData: pattern=(multiple patterns) examples=IFFControl2C.xls, IFFControl11C.xls, IFFControl17C.xls
Output: [{\"folder_path\": \"Control/RA_IATData\", \"granularity\": \"individual\"}]
(Reason: IFFControl2C, IFFControl11C — consistent prefix+varying number = one file per participant)

Return ONLY the JSON array. No notes. Echo folder_path exactly as it appears in the input."
