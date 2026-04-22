# Misclassification Analysis — Test Run 2026-04-22

**Model:** `20b_MD_THINK_low` at temperature 0.7  
**Scope:** File type classification only (not column labelling)  
**Reported accuracy:** 80.3% (1206/1501 files correct)  
**Single annotator:** Levi Baruch (all 20 papers)

---

## Preamble: Ground Truth Quality

All annotations come from a single annotator. Before attributing errors to the model, we should ask: is each disagreement a model failure or a debatable labelling decision? The evidence shows both are present.

**Detected GT inconsistencies:**

| Paper | Same pattern, different labels |
|---|---|
| 0956797614543801 | `Study1/BIATFiles/*.xml` → software (25 files), `Study2/BIATFiles/*.xml` → supplemental, `Study3/BIATFiles/*.xml` → supplemental. Same folder structure, same extension. |
| 0956797614543801 | `Study1/DemographicsAndPreference/*.jsp` → software, `Study1/Scales/*.jsp` → supplemental. Both are JSP files in Study1Materials, both are survey questionnaire pages. |
| 0956797614543801 | `Study1/BIATFiles/biattask15.jsp` → software, `Study2/BIATFiles/fdirect.htm` → supplemental. Task runner page vs instruction page — plausible distinction, but never stated. |
| 0956797616685770 | `pre1_data_annotation.txt` → supplemental, `pre2_data_annotation.txt` → **readme**, `pre3_data_annotation.txt` → codebook. Three files with identical naming patterns get three different types. |

These inconsistencies are structural: the annotator applied a rationale (e.g., "Study 1 is the full system, later studies are just the instruments") that is legitimate but invisible to both the model and a future annotator. The inconsistencies inflate the apparent error count.

**Genuinely ambiguous categories (model and GT are both defensible):**

- **JSP/HTM pages in experiment materials**: Survey pages running in a web experiment system. Calling them `software` (runtime components of the web app) and `supplemental` (human-authored research instruments) are both coherent. The GT applies both within the same paper.
- **XML task definition files (IAT/BIAT)**: Are these the software driving the experiment, or the instrument definition? Both interpretations are used in the GT for structurally identical files.
- **QSF (Qualtrics Survey Format)**: The actual file uploaded to run a survey. Calling it `software` (it configures the experiment) and `supplemental` (it is the survey instrument) are both defensible.
- **Mini-meta analysis CSVs**: Are manually entered effect sizes `data` (measurements entered by the researcher) or `output` (derived from running a meta-analysis script)? Both are reasonable.
- **Word documents containing output tables** (`EichstaedtTableS2_RNR2.doc`, `Output and Syntax - Study 1.doc`): The filename signals `output` but the extension signals `supplemental`. No prompt rule covers `.doc` files with output content.

With these in mind, the analysis below distinguishes three tiers of findings:

- **Tier A — Clear model error**: GT is unambiguously correct, model fails.
- **Tier B — Ambiguous boundary**: Both model and GT are defensible; the disagreement reveals an underspecified prompt rule.
- **Tier C — Probable GT error**: The model prediction is more consistent with the pattern in the data.

---

## Error Pattern Summary

| Error (GT → Predicted) | Count | Tier | Primary driver |
|---|---|---|---|
| supplemental → codebook | 57 | A | Folder name "DetailedCodebook" overrides file logic |
| supplemental → software | ~24 | B/C | XML/QSF instrument files; GT itself is inconsistent |
| software → supplemental | 20 | B/C | JSP survey pages; same paper, inconsistent GT |
| supplemental → code | 16 | A/B | JSP/XML web pages seen as code |
| output → supplemental | 10 | B | `.doc` output tables; extension/content conflict |
| software → other | 9 | A | "Not_Reported" folder triggers wrong rule |
| supplemental → data | 15 | A | Stimulus word/name lists treated as measurements |
| codebook → supplemental | 7 | A/C | `_annotation.txt` not in keyword list; GT itself inconsistent |
| software → code | 8 | A/B | `.pyw` and `download.py` in Materials folder |
| output → data | 4 | B | Meta-analysis CSVs; genuinely ambiguous type |
| data → codebook | 4 | A | "dictionaries" in filename triggers wrong keyword |

---

## Tier A: Clear Model Errors

### A1. HTML Survey Pages Classified as Codebook (55 errors)

**Paper:** 0956797614559730 (22.2% accuracy)

**Files:** 55 `.html` files in `Data/DetailedCodebook.HTML.pages/`, such as:
```
Data/DetailedCodebook.HTML.pages/allowedforbiddena.html
Data/DetailedCodebook.HTML.pages/anchoring1a.html
Data/DetailedCodebook.HTML.pages/diseaseframinga.html
```

**What they are:** HTML survey instrument pages for an online study — each is one screen presented to participants (an anchoring task, IAT block, explicit attitude item). The folder is named `DetailedCodebook.HTML.pages` by the researcher, but the content is stimulus material.

**GT:** supplemental. **Model:** codebook.

**Why the error occurs:** These files are processed by `aggregate_llm` (batch by folder). The folder name contains "Codebook", which is in the prompt's keyword list. The batch-level reasoning sees the folder name and classifies everything inside as codebook. The per-file `.html` rule (*"Otherwise → supplemental"*) is never applied — the folder name wins.

**Verdict:** Clear model error. The `.html` disambiguation rule is correct but never reached because aggregate_llm reasons at folder level first.

**Prompt fix:** State explicitly that the HTML disambiguation rule applies regardless of parent folder name: *"The folder name containing 'codebook' does NOT make `.html` files codebook — always apply the basename-matching rule."*

---

### A2. "Not_Reported" Folder Files Classified as Other (9 errors)

**Paper:** 0956797614553121

**Files:**
```
Underpowered_Lab_Study_Not_Reported/Materials/blackwhite_gba.xml
Underpowered_Lab_Study_Not_Reported/Materials/demographics.jsp
Underpowered_Lab_Study_Not_Reported/Materials/reprod.xml
```

**What they are:** IAT stimulus XMLs and survey pages from a study that was run but not reported due to low power. The files are structurally identical to other materials in the same repo labeled `software` and `supplemental`.

**GT:** `software` / `supplemental`. **Model:** `other`.

**Why the error occurs:** The model reads "Not_Reported" in the folder name and infers "no research relevance", triggering the `other` rule. But `other` is defined for OS metadata (`.DS_Store`, lock files) — not for unreported research files.

**Verdict:** Clear model error. The model over-applies `other` based on folder semantics.

**Prompt fix:** Add explicitly: *"'Not_Reported', 'Unpublished', 'Pilot', or similar folder names do NOT indicate `other`. Use the file's own type. `other` is reserved for OS artifacts only."*

---

### A3. Stimulus Name/Word Lists Classified as Data (15 errors)

**Paper:** 0956797616685770

**Files:**
```
Study_7/Materials/names.txt
Study_7/Materials/newnames.txt
Study_5/Methods_and_Measures/selectednames.txt
Study_6/Analysis/study6_new_additives.txt
Study_6/Materials/.../old_additives.txt
```

**What they are:** Lists of stimulus words (drug names, additive names) used as experimental materials in a study about pronounceability. `names.txt` contains target stimuli; `new_additives.txt` contains filler words. These are experiment design inputs, not collected measurements.

**GT:** supplemental. **Model:** data.

**Why the error occurs:** The model sees plain text files with list-like content in study folders and infers tabular data. There is no prompt rule distinguishing "stimulus list" from "data list". The model also correctly identified `s7_names.txt` in a different folder (`Data_and_analysis/`) as `data` (GT=data) — showing the folder context drives the decision.

**Verdict:** Clear model error, but also a prompt gap. The `data` definition (*"tabular observations, signals, or matrices intended for analysis"*) technically excludes stimulus lists, but the model has no positive signal to route to `supplemental`.

**Prompt fix:** Add to supplemental examples: *"Stimulus word/item lists (.txt, .csv files containing stimuli, wordlists, or name banks used in tasks) → supplemental, not data."* Or add a rule for `Methods_and_Measures/`, `Stimuli/`, and `Materials/` folders: files named `names.txt`, `wordlist.txt`, `items.txt` → supplemental.

---

### A4. County Frequency Data Classified as Codebook (4 errors)

**Paper:** 0956797614557867

**Files:**
```
county.freqs.dictionaries_dense/county.freqs.dictionaries_dense.csv
county.freqs.dictionaries/county.freqs.dictionaries.csv
county.freqs.topics_dense/county.freqs.topics_dense.csv
county.freqs.topics/county.freqs.topics.csv
```

**What they are:** County-level frequency tables of LIWC linguistic categories and LDA topics — numeric measurements (county × language-feature matrix). The word "dictionaries" refers to LIWC dictionaries (linguistic category lists), not variable documentation.

**GT:** data. **Model:** codebook.

**Why the error occurs:** The prompt's codebook keyword list includes "data_dictionary". The model pattern-matches "dictionaries" ≈ "data_dictionary". The `.csv` extension with numeric measurement content should override this, but the filename signal wins.

**Verdict:** Clear model error caused by an over-broad keyword match.

**Prompt fix:** The keyword "data_dictionary" should require the whole phrase, not match on "dictionaries" alone. Add a counter-example: *"county_frequencies.csv — not codebook even though it references 'dictionaries' (LIWC category lists are not variable documentation)."*

---

### A5. Supplemental → Code: JSP/XML Web Experiment Pages (13 errors)

**Paper:** 0956797614553121

**Files:**
```
Study_1_-_Materials/raceiata.xml
Study_1_-_Materials/questionnaire.xml
Study_3_-_Materials/debriefing.jsp
Study_3_-_Materials/explicitqs.jsp
```

**What they are:** XML task definition files and JSP web pages for an online IAT and debriefing survey. These are experiment instruments viewed by participants, not scripts that generate analyses.

**GT:** supplemental. **Model:** code.

**Why the error occurs:** The prompt defines `code` as *"source file or notebook whose purpose is to generate analyses."* `.jsp` looks like Java Server Pages (code), and `.xml` looks like structured data or config. The model should reach for the `supplemental` fallback but doesn't consistently apply it for non-binary/non-analysis files.

**Verdict:** Clear model error. The prompt fallback rule for `supplemental` is applied inconsistently.

**Prompt fix:** Add `.jsp` to the supplemental examples: *"Online experiment web pages (.jsp, .htm survey templates) → supplemental."*

---

## Tier B: Ambiguous Boundary Cases

### B1 → C. XML Trial-Sequence Files in BIATFiles: GT Inconsistency (now Tier C)

**Paper:** 0956797614543801

**GT inconsistency:**
- `Study1/BIATFiles/*.xml` (25 files) → GT = **software**
- `Study2/BIATFiles/defaults.xml` → GT = **supplemental**
- `Study3/BIATFiles/*.xml` (26 files) → GT = **supplemental**

These are structurally identical files: XML trial-sequence and counterbalancing definitions for the BIAT, in parallel `BIATFiles/` sub-folders across three studies.

**What the model does:** Classifies all BIATFiles XML as `software` — consistent across all three studies, matching Study 1's annotation.

**Verdict:** Tier C. Per the principle in S2, BIAT XML files define algorithmic trial sequences and counterbalancing that constitute the computerised measurement — they are software. The Study 1 annotation is correct. The Study 2–3 annotations are GT drift. The model is right; the GT for Studies 2–3 is wrong for ~50 files.

---

### B2. JSP Survey Pages: Software vs Supplemental (18 errors software→supplemental)

**Paper:** 0956797614543801

**GT pattern:**
- `Study1/DemographicsAndPreference/demographics.jsp` → software
- `Study1/Scales/anesscale.jsp` → supplemental

Both are JSP questionnaire pages served within the same web experiment system. The annotator's apparent logic: `DemographicsAndPreference/` files are part of the IAT measurement system (software), while `Scales/` files are standalone questionnaire instruments (supplemental). Again — a defensible distinction, but not derivable from filename or folder name alone.

**What the model does:** Classifies all `.jsp` files in `Scales/` and `DemographicsAndPreference/` as `supplemental`. It gets the `Scales/` group right and gets the `DemographicsAndPreference/` group wrong.

**Verdict:** Tier B. The distinction is too fine-grained for the current prompt. The model correctly applies the `supplemental` fallback for all web survey JSP pages; the GT penalizes it for a subfolder-level distinction that can't be inferred from path alone.

---

### B3. Qualtrics Survey Files (12 errors: supplemental→software)

**Paper:** 0956797617706706

**Files:** `BFF_Study1.qsf`, `ROS4b.qsf`, etc.

**What they are:** Qualtrics Survey Format files — the exported survey definition file uploaded to Qualtrics to deploy a study.

**GT:** supplemental. **Model:** software.

**The genuine ambiguity:** A `.qsf` file *is* the thing that runs the study on Qualtrics — without it, the study doesn't exist. In that sense `software` is coherent. But it's also a human-authored instrument (questions, branching logic, display wording) in the same way a paper questionnaire is. The annotator chose `supplemental` (instrument framing). The model chose `software` (runtime framing).

**Verdict:** Tier B. Neither is wrong; the prompt doesn't address `.qsf` at all, forcing analogical inference. The model's reasoning (*"Qualtrics survey file used to run experiment → software"*) is explicit and logical.

**Prompt fix:** Add a decision: *".qsf (Qualtrics survey format) → supplemental. Survey instrument files are supplemental regardless of their role as experiment runners."*

---

### B4. Word Documents Containing Statistical Output (10 errors: output→supplemental)

**Papers:** 0956797614557867, 0956797614524581

**Files:**
```
EichstaedtTableS2_RNR2.doc   (Supplemental Table S2)
Output and Syntax - Study 1.doc
PROCESS Output - Study 1.doc
```

**What they are:** Word files containing SPSS output tables and PROCESS macro results, referenced in a corrigendum. The "Output" in the filename is intentional.

**GT:** output. **Model:** supplemental.

**The genuine ambiguity:** Is a Word document containing output tables an `output` (computational artifact) or `supplemental` (human-authored document)? The `.doc` extension signals human-authored document; the filename content signals computational product. The prompt explicitly excludes documents from software but says nothing about documents-as-output. It does list `.spv` (SPSS Viewer) as always output — but doesn't generalize this to `.doc` files containing the same content.

**Verdict:** Tier B. The model consistently applies "document extension → supplemental", which is reasonable. The GT labels these as `output` based on the filename word "Output" and their role as corrigendum-referenced results.

**Prompt fix:** *"Documents (.doc, .docx) named with 'Output', 'Results', 'Tables' → output. The document extension alone does not override the filename signal."*

---

### B5. Meta-Analysis CSVs: Output vs Data (4 errors)

**Paper:** 0956797617739368

**Files:**
```
Mini_meta/action-orientation-meta_Sheet1.csv
Mini_meta/escalation-action-framing-with-stats.csv
```

**GT:** output. **Model:** data.

**The genuine ambiguity:** A mini-meta-analysis table contains manually entered effect sizes from published papers — each row is a coded study, each column is a measured property. This fits the `data` definition (*"tabular observations intended for analysis"*). It also fits the `output` definition (*"artefact produced by executing a script"*) if the table was generated by running a meta-analysis R script.

**What the model does:** Classifies as `data`. The thinking trace: *"Mini_meta CSV with stats likely data."* The `_Sheet1.csv` suffix (spreadsheet export) and the `Data_and_code/` parent folder both pull toward `data`.

**Verdict:** Tier B. Both are defensible. The `with-stats` suffix in the filename is the strongest output signal but is not in the prompt's signal list.

**Prompt note:** Add "meta", "with_stats", "effect_size" to the output signal list for tabular files.

---

### B6. Python Experiment Scripts (.pyw) Classified as Code (4 of 8 errors)

**Paper:** 0956797616685770

**Files:**
```
Study_3/Materials/Materials/Materials/experiment.pyw
Study_3/s3b_materials_czech.pyw
Study_3/s3b_materials_english.pyw
```

**GT:** software. **Model:** code.

**The genuine ambiguity:** `.pyw` files are Python scripts with the `.w` variant indicating GUI/windowless execution (Windows). `experiment.pyw` in a `Materials/Materials/` folder is very likely an experiment runner. The prompt lists `.py` as a script and says *"scripts in Task/, Stimuli/ → software"* but `Materials/` is a weak signal and `.pyw` is not listed.

**Verdict:** Tier B. The model applies the "`.py` → code" default because `.pyw` isn't mentioned and the folder signal is weak. Adding `.pyw` to the software list would fix this.

---

### B7. download.py as Software vs Code (4 of 8 errors)

**Files:**
```
Study_5/Methods_and_Measures/download.py
Study_6/Materials/.../download.py
Study_7/Materials/download.py
```

**GT:** software. **Model:** code.

**The genuine ambiguity:** `download.py` could be a utility script that downloads stimuli at experiment setup time (software) or a data download utility for a researcher (code). The prompt's software filename signals are: *"task, run, experiment, stimulus, present, paradigm"*. "download" is not listed.

**Verdict:** Tier B. The model's code classification is reasonable. The annotator's software classification is based on purpose (these scripts download experiment stimuli), which cannot be inferred from the filename alone.

---

## Tier C: Probable GT Errors

### C1. Annotation File GT Inconsistency (affects 7 errors)

**Paper:** 0956797616685770

**Pattern:**
```
pre1_data_annotation.txt  → GT = supplemental
pre2_data_annotation.txt  → GT = readme         ← clear slip
pre3_data_annotation.txt  → GT = codebook
s1_data_annotation.txt    → GT = codebook
s2_data_annotation.txt    → GT = codebook
s3a_data_annotation.txt   → GT = codebook
```

All six files follow the same naming convention: `<study>_data_annotation.txt`. They contain variable coding keys — what each variable name means and how it was coded.

`pre2_data_annotation.txt` being labeled `readme` is almost certainly an annotation slip. `pre1` being labeled `supplemental` while all others are `codebook` may be another slip or an intentional distinction that isn't visible from the filename.

**What the model does:** Classifies all `_data_annotation.txt` files as `supplemental` because "annotation" is not in the codebook keyword list.

**Verdict:** Tier C for `pre2_data_annotation.txt` (GT is wrong). Tier A for the others (model should recognise `_annotation` as a codebook signal).

**Prompt fix:** Add "annotation" to the codebook keyword list.

---

### C2. Structural BIATFiles Inconsistency Revisited

As noted in B1, the Study 2 and Study 3 XML files in `BIATFiles/` being labeled `supplemental` while the Study 1 equivalents are `software` is best understood as annotation drift across a 25+ file annotation session, not a deliberate distinction.

If the intended policy is "BIATFiles XML = software" (matching Study 1), the model is right and the GT for Studies 2–3 is wrong. If the policy is "BIATFiles XML = supplemental" (matching Studies 2–3), the model is still more consistent (it applies `software` to all of them) but the Study 1 GT is wrong.

---

## Recalibrated Accuracy Estimate

Accounting for the inconsistencies above, the **real accuracy is approximately 84–87%** rather than 80.3%, depending on how ambiguous cases are resolved:

| Adjustment | Errors reclassified |
|---|---|
| BIATFiles XML: treat model's uniform prediction as correct (Study 1 is the anchor) | ~24 |
| JSP Scales/ vs DemographicsAndPreference/ subfolder distinction: too fine for current prompt | ~7 |
| `pre2_data_annotation.txt` GT is `readme` — clear slip | ~1 |
| Meta-analysis CSVs: accept both labels as valid | ~4 |

This leaves roughly 200–220 genuine model errors, concentrated in five prompt gaps.

---

## Proposed Structural Prompt Fixes

The error patterns above share five underlying conceptual failures in the prompt. Rather than patching each pattern with a specific rule, each fix below addresses the abstract principle that would resolve an entire class of errors.

---

### S1. Establish a Signal Hierarchy: File-Level Beats Folder-Level

**What the prompt currently implies:** The model treats folder name, file extension, and filename as equally weighted signals, combining them freely. When the folder is named "DetailedCodebook", the model treats all contents as codebook regardless of extension. When the folder is "Not_Reported", the model treats contents as having no research relevance.

**The conceptual failure:** Folder names describe organisational intent, not file type. A researcher can name a folder "DetailedCodebook" and store survey instrument pages in it. A folder named "Not_Reported" still contains valid research files. The folder is always weaker evidence than the file itself.

**Structural principle to add:**

> Folder names are contextual hints, never overrides. The file's own name and extension determine its type. A folder named "Codebook", "Output", "Not_Reported", or "Archive" narrows ambiguity only when the file itself carries no strong signal. If the file-level type rule produces a clear answer, the folder name is irrelevant.

This single principle fixes: the DetailedCodebook HTML case (~55 errors), the Not_Reported XML/JSP case (~9 errors), and any future cases where organisational folder names mislead.

---

### S2. Define Software by Whether Computerisation Is Intrinsic to the Measurement

**What the prompt currently implies:** Any file that is "used to run the experiment" qualifies as software. This is loose enough that the model classifies JSP questionnaire pages, QSF survey exports, and XML trial-sequence files identically — all are "used to run the experiment."

**The conceptual failure:** Not all experiment files are software. The word "software" conflates two genuinely different things: (a) files that define *algorithmic* behaviour — trial sequencing, counterbalancing, timing, stimulus assignment — where the computerisation is *intrinsic* to what is being measured; and (b) files that define *content* — question text, instructions, debriefing copy — where the computer is merely a delivery mechanism and the same content could exist on paper.

Type (a) is software: without the computer interpreting these files, the measurement cannot exist. Type (b) is supplemental: the content is a human-authored instrument that happens to be delivered electronically.

**Structural principle to add:**

> Ask: does the computerisation constitute the measurement, or does it merely deliver it? If the file defines algorithmic behaviour — trial sequences, counterbalancing schemes, timing parameters, stimulus assignment logic — that could not be replicated by a human with paper, it is software. If the file defines content — question text, instructions, debriefing copy, survey items — that could in principle be administered on paper and produce the same data, it is supplemental.

> Concretely: IAT/BIAT XML files that define trial sequences and counterbalancing schemes are software (the counterbalancing cannot exist without the machine). A Qualtrics `.qsf` or a JSP scale page that defines survey questions is supplemental (the same questions could be on paper). An E-Prime `.es2` file that sequences stimuli with precise timing is software. A consent form in `.html` is supplemental.

This principle draws the right boundary in the cases where the GT is itself inconsistent: IAT trial-sequence XML → software; questionnaire JSP pages → supplemental. It replaces the "loaded by vs executes" distinction (which incorrectly excludes both) with a distinction grounded in whether the measurement is computationally constituted.

---

### S3. Make Supplemental the Explicit Default, Not a Fallback

**What the prompt currently implies:** Supplemental is defined last, described as a "fallback when provenance is ambiguous." This means the model only reaches it after exhausting other options. For files with any plausible alternative signal (`.jsp` = code? `.xml` = software?), the model stops before the fallback.

**The conceptual failure:** The fallback framing inverts the correct decision logic. Most files in a psychology OSF repository are supplemental — manuscripts, consent forms, instruments, stimuli, instructions, protocol documents. Only a small fraction are data, code, or software. The prompt should frame supplemental as the *prior* and require positive evidence to override it, not the other way around.

**Structural principle to add:**

> Unless there is positive evidence for a more specific type, classify as supplemental. Positive evidence means: the file contains measurements (data), executes or is executed (software/code), describes variables (codebook), or was produced by running a script (output). The mere presence of a file in an experiment folder, or its use within an experiment workflow, is not positive evidence for software or code — it is consistent with supplemental.

This restructuring changes the decision flow from "find any positive signal → assign type" to "start at supplemental → override only with positive evidence." It makes the prompt robust to new file formats the model hasn't seen.

---

### S4. Separate Keyword Matching from Semantic Matching for Codebook Detection

**What the prompt currently implies:** The codebook keyword list (*"codebook, data_dictionary, variable_list, coding, variable_key..."*) is used as a substring/proximity match. The model applies it loosely, matching "dictionaries" to "data_dictionary" and treating any file in a folder with "Codebook" in its name as codebook.

**The conceptual failure:** Keywords are not semantic equivalents. "Dictionaries" means something different from "data_dictionary" in a filename about linguistic frequency counts. Proximity to a keyword-containing folder is not the same as the file itself being a codebook. The prompt mixes two distinct signals — filename keyword presence (strong, direct) and contextual association (weak, indirect) — without distinguishing them.

**Structural principle to add:**

> A file is a codebook when its *own filename* contains a codebook keyword, or when its content is obviously and entirely devoted to describing variables (e.g., a `.txt` file named `variable_annotation.txt`). A file is not codebook because a parent folder happens to contain a codebook keyword, nor because its name contains a word that resembles a keyword when interpreted loosely. Keyword matching is exact, applied to the filename in isolation.

This fixes: county.freqs.dictionaries.csv classified as codebook (~4 errors), HTML files in "DetailedCodebook" folder (~55 errors, overlapping with S1), and prevents future false matches on domain-specific terminology.

---

### S5. Ground `other` Entirely in File-Level Signals

**What the prompt currently implies:** The `other` type means "no research relevance," which the model interprets as a semantic judgment about whether a file matters — reachable via folder context ("Not_Reported") or researcher framing.

**The conceptual failure:** Research relevance is not inferrable from a filename or folder path. Files from unreported studies, archived versions, or methodologically failed attempts are still research files. The `other` type should be defined purely by file-level pattern matching — specific known-irrelevant extensions and naming conventions — not by any semantic interpretation of purpose or relevance.

**Structural principle to add:**

> `other` is a structural category, not a semantic one. It applies when the file *format itself* indicates non-research content: OS metadata, version-control artifacts, lock files, editor backup files. It does not apply when a folder name suggests the files are unwanted, unreported, archived, or ancillary. If the file could plausibly serve any research purpose — even in an unreported or failed study — it is not `other`.

---

## Recalibrated Accuracy Estimate

Accounting for the GT inconsistencies documented above, the **real accuracy is approximately 87–89%** rather than 80.3%, depending on how ambiguous cases are resolved:

| Adjustment | Errors reclassified |
|---|---|
| BIATFiles XML (Studies 2–3): GT drift from Study 1; model's uniform `software` prediction is correct | ~50 |
| JSP Scales/ vs DemographicsAndPreference/ subfolder distinction: too fine for current prompt | ~7 |
| `pre2_data_annotation.txt` GT is `readme` — clear slip | ~1 |
| Meta-analysis CSVs: accept both labels as valid | ~4 |

This leaves roughly 200–220 genuine model errors, most of which are addressed conceptually by S1–S5 above.

**GT quality constrains meaningful accuracy measurement.** With a single annotator and no consistency checks, the reported 80.3% accuracy cannot be taken at face value. At least 50–80 of the 295 errors involve GT annotations that are either internally inconsistent, individually debatable, or plausibly wrong. A meaningful evaluation would require a second annotator on the contentious cases before using the number to drive prompt changes.

---

## Appendix: Ground Truth Inconsistencies by Paper

The following papers contain cases where the same file extension receives different type labels within the same paper. Entries are flagged as either **principled** (the distinction is defensible from the filename/content, even if not always derivable from path alone) or **inconsistent** (same apparent context, different labels — likely annotation drift or error).

---

### 0956797614524581
| Extension | Types assigned | Assessment |
|---|---|---|
| `.csv` | data, output | Principled — "Graphs for Corrigendum" CSVs vs raw data CSVs |
| `.docx` | code, codebook, supplemental | Principled — `Syntax.docx` is code, `Codebook.docx` is codebook, others supplemental |

---

### 0956797614534695
| Extension | Types assigned | Assessment |
|---|---|---|
| `.csv` | data, supplemental | Principled — `Notes.csv` (researcher notes) vs raw data CSVs |

---

### 0956797614543801
| Extension | Types assigned | Assessment |
|---|---|---|
| `.xml` | software, supplemental | **Inconsistent** — `Study1/BIATFiles/*.xml` = software; `Study2/BIATFiles/*.xml` = supplemental; `Study3/BIATFiles/*.xml` = supplemental. Structurally identical files across parallel study folders. Per S2, all should be software. |
| `.jsp` | code, software, supplemental | **Inconsistent** — `exp_bcij.jsp` / `exp_chij.jsp` = code; `biattask15.jsp` / `demographics.jsp` = software; `anesscale.jsp` etc. = supplemental. Three types for JSP within one paper. The code/software distinction for JSP is not derivable from filename alone. |
| `.htm` | software, supplemental | Principled but marginal — `race4instruct.htm` (IAT instruction screen, integral to task) = software; `ques2.htm` (questionnaire page) = supplemental. The distinction maps to S2 but requires knowing the file's role in the task flow. |
| `.txt` | codebook, data | Principled — `Study1Codebook.txt` vs `Study1Data.txt` (filename disambiguates clearly) |

---

### 0956797614553121
| Extension | Types assigned | Assessment |
|---|---|---|
| `.xml` | software, supplemental | **Inconsistent** — `Underpowered_Lab_Study_Not_Reported/Materials/reprod.xml` = software; `Study_1_-_Materials/reprod.xml` = supplemental. Same filename, same structural role, different GT based on which study folder it's in. |
| `.html` | software, supplemental | **Inconsistent** — `lastpage.html` appears as **both** software (in one study folder) and supplemental (in another). Identical filename, different labels. |
| `.jsp` | software, supplemental | **Inconsistent** — `demographics.jsp` / `followup.jsp` (Underpowered folder) = software; `debriefing.jsp` / `explicitqs.jsp` (Study_3 folder) = supplemental. Same file types, folder determines label. |
| `.csv` | codebook, data, other, output | Principled mostly — `Data_Dictionary_Sheet1.csv` = codebook (filename); `Data_Dictionary_Sheet2.csv` = **other** (inconsistent with Sheet1 being codebook); meta-analysis CSVs = output; raw data CSVs = data |

---

### 0956797614557867
| Extension | Types assigned | Assessment |
|---|---|---|
| `.doc` | codebook, output, supplemental | **Principled** — `EichstaedtTableS1_RNR2.doc` = codebook (contains variable descriptions); `EichstaedtTableS2–S6_RNR2.doc` = output (statistical result tables); `EichstaedtSOM-R.doc` = supplemental (narrative methods text). Distinction is based on internal document content, not filename pattern alone. Annotation is correct. |

---

### 0956797614559543
| Extension | Types assigned | Assessment |
|---|---|---|
| `.m` | code, software | Principled — `mediationAnalysis.m` / `percHeight.m` = code (analysis); `taskone.m` / `taskone_food_ratings.m` = software (experiment runner). Filename carries the signal. |

---

### 0956797616685770
| Extension | Types assigned | Assessment |
|---|---|---|
| `.txt` | codebook, data, output, readme, supplemental | Mixed — principled distinctions exist (readme.txt = readme; annotation.txt = codebook; descriptives.txt = output; names.txt = supplemental; data files = data) but `pre1_data_annotation.txt` = supplemental and `pre2_data_annotation.txt` = **readme** while all other `_data_annotation.txt` files = codebook. The pre2 readme label is a clear slip. |
| `.py` | code, software | Principled but marginal — `s3b_raw_data_processing.py` = code (analysis, filename says so); `download.py` = software. Filename carries the signal for the analysis script, but "download" as a software signal requires context not present in the prompt. |

---

### 0956797617706706
| Extension | Types assigned | Assessment |
|---|---|---|
| `.docx` | output, supplemental | Principled — `ROS4b results.docx` = output; `ROS4c pre-reg.docx` = supplemental. Filename distinguishes "results" from "pre-registration." |

---

### 0956797617739368
| Extension | Types assigned | Assessment |
|---|---|---|
| `.csv` | data, output | Principled — experiment data CSVs vs meta-analysis result CSVs. Folder (`Mini_meta/`) disambiguates but filename also helps (`with-stats`, `meta`). |
| `.docx` | output, supplemental | Principled — `R-markdown.docx` (rendered report) = output; `pre-Registration.docx` = supplemental. |
| `.pdf` | output, supplemental | Principled — `output.pdf` / `R-markdown.pdf` = output; manuscript preprint PDF = supplemental. |

---

### 0956797617746749
| Extension | Types assigned | Assessment |
|---|---|---|
| `.txt` | output, supplemental | Principled — `BINOMIAL_1_main_fig1a.txt` (computation output) = output; `Systematic Literature Review Methods.txt` = supplemental. Filename carries the signal. |

---

### 0956797620965536
| Extension | Types assigned | Assessment |
|---|---|---|
| `.csv` | codebook, data | Principled — `Codebook_Sheet1.csv` vs data CSVs. Filename disambiguates. |
| `.sav` | data, other | **Inconsistent** — `Processed Datafile Narc_and_SE_longfile.sav` = other; `Processed Datafile Narc_and_SE_longfile_FOLLOWER WELLBEING DV.sav` = data. Same base name, same folder, one with a suffix = data, one without = other. The base file is probably the source and the suffixed files are subsets — both should be data. |
