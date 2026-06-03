# 4_report.R — Per-paper user-facing report (feature: 4_report stage)
# ─────────────────────────────────────────────────────────────────────────────
# Reads the four per-paper CSV outputs (structure / columns / labels /
# codebook_coverage) and renders a styled, self-contained HTML report
# (report.html) into the paper's output directory.
#
# READ-ONLY over existing outputs: never re-runs the LLM, never changes any
# classification. Its job is to explain — to an end user — how the run went for
# their repository, define the jargon, list their variables, give actionable
# codebook feedback, and make transparent what was decided by an LLM versus by
# deterministic rules.
#
# Entry point: run_report(paper_id, source = "osf", out_dir = NULL)
# Returns: list(success, error, paper_id, html_path,
#               n_files, n_columns, n_labelled, n_codebook_vars)
# ─────────────────────────────────────────────────────────────────────────────

# ── Static copy (kept consistent with docs/output-schemas.md) ─────────────────

REPORT_INTRO <- paste(
  "This report summarises what DataCheck did with your repository. It scanned the repository, classified every file,",
  "extracted all columns of each tabular dataset, determined the variable type of each of those columns,",
  "and matched the columns to variables in any codebooks you added. Below you can follow the process step by step,",
  "see where an LLM was used, and get feedback on a few best practices for sharing repositories."
)

# Each step: c(title, summary, detail, tag ∈ {Rules, LLM, Rules + LLM}).
# `summary` is the one-line gist shown when collapsed; `detail` is the deeper
# step-specific explanation revealed when the step is expanded.
REPORT_PROCESS <- list(
  c("1 · Download & unpack",
    "All files are downloaded and any archives are extracted.",
    "If not downloaded yet, DataCheck fetches all files from the OSF link you supplied. It then recursively extracts archives within the repository (.zip, .tar, .rar) and ignores duplicate files (files with the same name and exact size).",
    "Rules"),
  c("2 · Classify each file",
    "Every file gets a type and an experiment group; data files also get a granularity.",
    "All files within the repository are classified into one of nine types: data, code, codebook, software, output, supplemental, readme, asset, or other. Files are classified based on their purpose; each category is defined under \"What each type means\" in the Files found section. Besides the type, the experimental group (in multi-study repositories) is classified by an LLM. Finally, for every data file the granularity (whether the file holds measurements of one or of multiple participants) is determined here. Classification combines deterministic rules with LLM inference; the LLM sees only the file name and path.",
    "Rules + LLM"),
  c("3 · Detect data granularity",
    "Each data file is marked individual (per-participant) or combined.",
    "Folder structure (numbered participant subfolders) and filename patterns (sub-01, participant_003) decide most cases; when the structure is unclear, the LLM infers granularity. Granularity is settled here, right after classification, because it gates the next step: only combined files have their columns extracted. Per-participant 'individual' files are skipped, since one representative file covers the whole series. It also drives how the data is organised in the PsychDS export.",
    "Rules + LLM"),
  c("4 · Extract columns",
    "Column names and a sample of values are read from each combined tabular data file.",
    "From all detected data files that are tabular (.csv, .xlsx, etc.) and contain measurements of multiple participants (i.e. 'combined'), the variables are extracted. Each column is assumed to be a variable. Only the header and a sample of rows are read; no file contents are sent to the LLM.",
    "Rules"),
  c("5 · Infer column types",
    "Each column is labelled continuous, binary, categorical, id, date, text, ...",
    "Each column is given a category of its own (continuous, binary, categorical, id, date, text, etc.). This is done using deterministic rules; ambiguous columns are handed to the LLM, which picks categorical, ordinal, or text. Summary statistics (mean, sd, quartiles, etc.) are then calculated for the numeric columns.",
    "Rules + LLM"),
  c("6 · Match to the codebook",
    "Data columns are matched to the variable definitions in the codebooks.",
    "DataCheck first parses any codebook or readme files into variable definitions: directly for spreadsheets and SPSS/Stata files, and via the LLM for free-text PDFs and Word documents. Each data column is then matched to a codebook variable by normalised name. When the same name carries different definitions across codebooks, the LLM is asked only whether they mean the same thing. Matched descriptions become the column labels you see in the variables table.",
    "Rules + LLM"),
  c("7 · Convert to PsychDS",
    "Outputs are reorganised into the standard PsychDS dataset layout.",
    "The outputs are reshaped into the PsychDS standard: a dataset_description.json carrying variable metadata, data files with JSON sidecars, and separate code/materials/documentation folders. Oversized files are copied raw without conversion. Ground-truth overrides and extracted paper metadata (from GROBID) are applied at this stage.",
    "Rules")
)

# The file types DataCheck assigns, with short plain-language meanings.
# Order roughly by how often a researcher cares about them.
REPORT_FILE_TYPES <- list(
  c("data",         "Files holding the research measurements to be analysed: spreadsheets (CSV, SAV, XLSX, etc.) and raw recordings (EEG, MATLAB, video)."),
  c("codebook",     "A document describing what each variable means: a data dictionary or coding key."),
  c("code",         "Analysis scripts (R, Python, MATLAB, etc.) that produce the analyses or results, also known as 'analysis' files. Not the experiment program."),
  c("software",     "The experiment program itself: stimulus/task software, installers, build files, compiled binaries."),
  c("output",       "Files produced by running a script: rendered notebooks, generated figures, log files."),
  c("supplemental", "Human-authored material that is not data, code, or a codebook: both the manuscript (papers, reports, preregistrations) and study materials (survey instruments, consent forms)."),
  c("readme",       "README, LICENSE, or CONTRIBUTING files."),
  c("asset",        "Stimuli shown to participants: images, audio, or video used in the study."),
  c("other",        "No research content: OS metadata, lock files, environment config, and the like."),
  c("llm_error",    "A file the classification step could not label after retries. Review it manually.")
)

REPORT_LLM_VALUES <- c("llm", "aggregate_llm")  # type_source values meaning "decided by LLM"
REPORT_MAX_VARS   <- 400L                        # cap rows in the variables list

# Plain-language explanation of each label_status (codebook match outcome).
LABEL_STATUS_EXPLAIN <- c(
  labelled               = "Matched a codebook variable.",
  llm                    = "Matched via a language-model check after no exact name match.",
  unlabelled             = "No matching codebook variable was found.",
  conflicting_definition = "Matched a name that is defined differently across several codebooks.",
  ambiguous_experiment   = "The name appears only in a different experiment's codebook.",
  no_codebook            = "This repository has no codebook, so nothing could be matched."
)

# Plain-language explanation of each label_method (how a label was assigned).
LABEL_METHOD_EXPLAIN <- c(
  rules        = "exact name match (rule-based)",
  merged_rules = "several codebook entries with equivalent wording, merged by rule",
  merged_llm   = "several codebook entries confirmed equivalent by a language model",
  llm          = "matched by a language-model check"
)

# Plain-language explanation of each granularity_source (how individual vs
# combined was inferred for a data file).
GRAN_SOURCE_EXPLAIN <- c(
  folder_heuristic      = "the file sits in a folder of numbered per-participant subfolders",
  folder_name_heuristic = "the folder name signals per-participant data",
  filename_heuristic    = "the filename matches a per-participant pattern (e.g. sub-01)",
  llm                   = "a language model inferred it from the column names",
  llm_pattern_inference = "a language model inferred it from column-name patterns",
  default_combined      = "no per-participant signal was found, so it defaults to combined"
)

# Plain-language explanation of each type_source (how a file's type was decided).
TYPE_SOURCE_EXPLAIN <- c(
  rule_folder         = "a folder-based rule (e.g. a software or build folder)",
  fixed_ext_rule      = "the file extension",
  fixed_filename_rule = "the filename (e.g. README, LICENSE)",
  rmd_pair_rule       = "an R Markdown source/output pairing rule",
  llm                 = "a language model, classified directly",
  aggregate_llm       = "a language model, from one sample propagated across an aggregate folder"
)

# How a col_type was decided: returns c(method, why). method ∈ {Rule, LLM, —}.
.coltype_method <- function(t) {
  if (is.na(t) || t == "") return(c("—", "not determined"))
  if (grepl("^continuous", t)) return(c("Rule", "numeric values (decimals, or a wide range of integers)"))
  switch(t,
    empty       = c("Rule", "every value was missing"),
    constant    = c("Rule", "only one distinct value"),
    binary      = c("Rule", "exactly two distinct values"),
    id          = c("Rule", "the column name looks like an identifier"),
    date        = c("Rule", "the values parse as dates"),
    text        = c("Rule", "long free-text values"),
    categorical = c("LLM",  "a language model judged these to be unordered categories"),
    ordinal     = c("LLM",  "a language model judged these to be an ordered scale"),
    unknown     = c("LLM",  "could not be determined from the name and values"),
    llm_error   = c("LLM",  "the language-model classification step failed"),
    c("Rule", "classified by rule"))
}

# ── CSV loading (tolerant; paper_id forced to character) ──────────────────────

.report_load_csv <- function(path) {
  if (is.null(path) || !file.exists(path)) return(NULL)
  tryCatch(
    read.csv(path, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")),
    error = function(e) NULL
  )
}

# ── Small helpers ──────────────────────────────────────────────────────────────

.html_escape <- function(x) {
  x <- as.character(x)
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x
}

.pct <- function(n, d) if (is.na(d) || d == 0) "0%" else sprintf("%d%%", round(100 * n / d))

.count_tbl <- function(x) {
  x <- x[!is.na(x) & x != ""]
  if (length(x) == 0) return(data.frame(value = character(0), n = integer(0)))
  t <- sort(table(x), decreasing = TRUE)
  data.frame(value = names(t), n = as.integer(t), stringsAsFactors = FALSE)
}

.cap_list <- function(x, cap = 30L) {
  x <- unique(x[!is.na(x) & x != ""])
  if (length(x) <= cap) return(x)
  c(x[seq_len(cap)], sprintf("... and %d more", length(x) - cap))
}

.fmt_num <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x)) return("")
  if (is.numeric(x) && is.finite(x) && x == round(x) && abs(x) < 1e7) return(as.character(x))
  formatC(x, digits = 4, format = "g")
}

# Colour-class for a column type / file type (classes defined in .HTML_STYLE)
.ct_class <- function(t) {
  if (is.na(t)) return("b-gray")
  if (grepl("^continuous", t)) return("b-blue")
  switch(t,
    binary = "b-purple", categorical = "b-teal", ordinal = "b-indigo",
    id = "b-gray", date = "b-orange", text = "b-slate",
    constant = "b-gray", empty = "b-gray",
    unknown = "b-red", llm_error = "b-red", "b-gray")
}
# Friendly display label for a col_type: collapse continuous variants (e.g.
# continuous_comma_decimal) to plain "continuous" for end users.
.ct_label <- function(t) if (!is.na(t) && grepl("^continuous", t)) "continuous" else t
.ft_class <- function(t) {
  if (is.na(t)) return("b-gray")
  switch(t,
    data = "b-blue", code = "b-green", codebook = "b-purple", software = "b-slate",
    output = "b-orange", supplemental = "b-teal", readme = "b-gray",
    asset = "b-pink", other = "b-gray", llm_error = "b-red", "b-gray")
}

# ── HTML fragment builders (return character vectors of HTML) ─────────────────

.fp     <- function(text) sprintf("<p>%s</p>", .html_escape(text))
.fbadge <- function(text, cls) sprintf("<span class=\"badge %s\">%s</span>", cls, .html_escape(text))

.ful <- function(items)
  c("<ul>", vapply(items, function(x) sprintf("<li>%s</li>", .html_escape(x)), character(1)), "</ul>")

# spec grid: pairs is a list of c(key, value_html). Values are emitted raw, so the
# caller is responsible for escaping plain text (badges pass through as HTML).
.fspec <- function(pairs)
  c("<div class=\"spec\">",
    unlist(lapply(pairs, function(p)
      c(sprintf("<div class=\"spec-k\">%s</div>", .html_escape(p[1])),
        sprintf("<div class=\"spec-v\">%s</div>", p[2])))),
    "</div>")

# rows: list of character vectors (already-HTML cells allowed when raw=TRUE per column)
.ftable <- function(headers, rows, raw_cols = integer(0)) {
  cell <- function(v, j) if (j %in% raw_cols) v else .html_escape(v)
  c("<table>", "<thead><tr>",
    vapply(headers, function(h) sprintf("<th>%s</th>", .html_escape(h)), character(1)),
    "</tr></thead>", "<tbody>",
    unlist(lapply(rows, function(r)
      c("<tr>", vapply(seq_along(r), function(j) sprintf("<td>%s</td>", cell(r[[j]], j)), character(1)), "</tr>"))),
    "</tbody>", "</table>")
}

# tiles: list of c(value, label)
.ftiles <- function(tiles)
  c("<div class=\"tiles\">",
    unlist(lapply(tiles, function(t)
      sprintf("<div class=\"tile\"><div class=\"tile-val\">%s</div><div class=\"tile-lab\">%s</div></div>",
              .html_escape(t[1]), .html_escape(t[2])))),
    "</div>")

# callout: kind ∈ good | warn | info
.fcallout <- function(kind, text) {
  icon <- switch(kind, good = "&#10003;", warn = "&#9888;", info = "&#9432;", "&#9432;")
  sprintf("<div class=\"callout %s\"><span class=\"ci\">%s</span><span>%s</span></div>",
          kind, icon, .html_escape(text))
}

# quality check row: kind ∈ good | warn | info; label + a one-line detail/advice
.fcheck <- function(kind, label, detail) {
  icon <- switch(kind, good = "&#10003;", warn = "&#9888;", info = "&#9432;", "&#9432;")
  sprintf(paste0("<div class=\"check %s\"><span class=\"ci\">%s</span>",
                 "<div class=\"check-t\"><b>%s</b><div class=\"check-d\">%s</div></div></div>"),
          kind, icon, .html_escape(label), .html_escape(detail))
}

# steps: list of c(title, summary, detail, tag). Rendered as expandable
# <details> accordions — collapsed shows title + tag; expanded reveals detail.
.fsteps <- function(steps) {
  tag_cls <- function(tag) switch(tag, "Rules" = "b-green", "LLM" = "b-orange", "b-indigo")
  unlist(lapply(steps, function(s)
    c("<details class=\"step\">",
      "<summary>",
      sprintf("<span class=\"step-title\">%s</span>", .html_escape(s[1])),
      sprintf("<span class=\"step-gist\">%s</span>", .html_escape(s[2])),
      .fbadge(s[4], tag_cls(s[4])),
      "<span class=\"chev\" aria-hidden=\"true\">&#9656;</span>",
      "</summary>",
      sprintf("<div class=\"step-body\">%s</div>", .fp(s[3])),
      "</details>")))
}

# distribution of colour-coded badges with counts
.fdist <- function(values, counts, classfn) {
  c("<div class=\"dist\">",
    vapply(seq_along(values), function(i)
      sprintf("<span class=\"badge %s\">%s <b>%d</b></span>",
              classfn(values[i]), .html_escape(values[i]), counts[i]),
      character(1)),
    "</div>")
}

# ── Section builders — each returns list(title, step, html) ───────────────────
# `step` is the pipeline-stage number this card reports on (NA = not a stage).

.card <- function(title, step, html) list(title = title, step = step, html = html)

.pdetail <- function(i) REPORT_PROCESS[[i]][3]   # the deep "how" text for step i

# Generic expandable disclosure.
.fdetails <- function(label, html, cls = "how")
  c(sprintf("<details class=\"%s\"><summary>%s</summary><div class=\"how-body\">", cls, .html_escape(label)),
    html, "</div></details>")

# "How this works" accordion built from one or more plain-text paragraphs.
.fhow <- function(paras)
  .fdetails("How this step works", unlist(lapply(paras, .fp)))

.sec_overview <- function(st, n_columns) {
  n_data <- sum(st$type == "data", na.rm = TRUE)
  fmt    <- if ("data_format" %in% names(st)) st$data_format[st$type == "data"] else character(0)
  n_tab  <- sum(fmt == "tabular", na.rm = TRUE)
  groups <- unique(st$group[!is.na(st$group) & st$group != ""])
  exp_grp <- groups[grepl("^(ex|pilot)", groups)]

  tiles <- list(
    c(format(nrow(st), big.mark = ","), "files"),
    c(as.character(n_data),             sprintf("data files (%d tabular)", n_tab)),
    c(format(n_columns, big.mark = ","),"columns"),
    c(as.character(length(exp_grp)),    "experiment groups")
  )
  roadmap <- c(
    "<p>DataCheck processed your repository in these stages. The numbered sections below follow that order:</p>",
    "<ol class=\"roadmap\">",
    "<li><a href=\"#files-found\"><b>Files found</b> — every file sorted into a type</a></li>",
    "<li><a href=\"#experimental-groups\"><b>Experimental groups</b> — which study each file belongs to</a></li>",
    "<li><a href=\"#data-granularity\"><b>Data granularity</b> — per-participant or combined? (decides which files are read)</a></li>",
    "<li><a href=\"#columns-their-types\"><b>Columns &amp; their types</b> — the variables inside your data</a></li>",
    "<li><a href=\"#codebook-matching\"><b>Codebook matching</b> — are your variables documented?</a></li>",
    "<li><a href=\"#psychds-conversion\"><b>PsychDS conversion</b> — how your repository was re-packaged</a></li>",
    "</ol>",
    "<p class=\"mut\">See <a href=\"#repository-quality\">Repository quality</a> for documentation feedback. Each step shows whether it was decided by rules or by a language model, with the model's reasoning available inline.</p>"
  )
  .card("Overview", NA, c(.ftiles(tiles),
    if (length(exp_grp) > 0) .fp(sprintf("Experiment groups detected: %s.", paste(sort(exp_grp), collapse = ", "))) else character(0),
    roadmap))
}

.sec_files <- function(st, traces = NULL) {
  ts      <- st$type_source
  type_counts <- .count_tbl(st$type)
  src     <- .count_tbl(ts)
  src_rows <- lapply(seq_len(nrow(src)), function(i) {
    v   <- src$value[i]
    why <- if (v %in% names(TYPE_SOURCE_EXPLAIN)) TYPE_SOURCE_EXPLAIN[[v]] else "a deterministic rule"
    c(v, as.character(src$n[i]), why)
  })
  legend  <- lapply(REPORT_FILE_TYPES, function(ft) c(.fbadge(ft[1], .ft_class(ft[1])), ft[2]))

  .card("Files found", 1L, c(
    .fp("DataCheck downloaded your repository, unpacked archives, and sorted every file into a type."),
    .fp("Files by type:"),
    .fdist(type_counts$value, type_counts$n, .ft_class),
    .fdetails("What each type means", .ftable(c("Type", "What it means"), legend, raw_cols = c(1L))),
    .fp("How each file's type was decided:"),
    .ftable(c("Method", "Files", "What it means"), src_rows),
    .fhow(c(.pdetail(1), .pdetail(2))),
    .trace_html(traces, "^file-type", title = "Show the model's reasoning for these classifications")))
}

GROUP_HOW <- paste(
  "DataCheck assigns each file to the study it belongs to: a numbered experiment",
  "(ex1, ex2, ...), a pilot (pilot1, ...), or 'shared' for project-wide files such as",
  "combined datasets, analysis scripts, and readmes. Experiment and pilot tags are",
  "inferred from folder and file context, often with help from a language model.",
  "readme, asset, and other files are always 'shared'. A group is the study,",
  "not a grouping of participants.")

.group_order <- function(groups) {
  exg <- sort(groups[grepl("^ex", groups)])
  pil <- sort(groups[grepl("^pilot", groups)])
  shd <- groups[groups == "shared"]
  oth <- sort(setdiff(groups, c(exg, pil, shd)))
  c(exg, pil, shd, oth)
}

.sec_groups <- function(st) {
  groups <- unique(st$group[!is.na(st$group) & st$group != ""])
  if (length(groups) == 0)
    return(.card("Experimental groups", 2L,
                 c(.fp("No study groups were assigned."), .fhow(GROUP_HOW))))

  ordered <- .group_order(groups)

  # Count matrix: one expandable row per group, one column per file type, cells
  # holding counts (blank when a type is absent) so groups are directly
  # comparable at a glance. Clicking a row lists the files in that group.
  cat_types <- vapply(REPORT_FILE_TYPES, function(x) x[1], character(1))
  present   <- unique(st$type[!is.na(st$type) & st$type != ""])
  types     <- c(intersect(cat_types, present), setdiff(present, cat_types))
  tmpl <- sprintf("minmax(48px,82px) 38px repeat(%d,minmax(0,1fr)) 14px", length(types))

  type_hdr <- paste(vapply(types, function(t)
    sprintf("<span class=\"gth\">%s</span>", .fbadge(t, .ft_class(t))), character(1)), collapse = "")
  head_row <- sprintf(
    "<div class=\"gtbl-head\" style=\"grid-template-columns:%s\"><span>Group</span><span>Files</span>%s<span></span></div>",
    tmpl, type_hdr)

  rows <- unlist(lapply(ordered, function(g) {
    sub <- st[st$group == g & !is.na(st$group), ]
    fls <- if ("rel_path" %in% names(sub)) sub$rel_path else sub$filename
    cnt <- table(factor(sub$type, levels = types))
    cells <- paste(vapply(types, function(t) {
      n <- as.integer(cnt[[t]])
      if (is.na(n) || n == 0) "<span class=\"gz\">&middot;</span>"
      else sprintf("<span class=\"gn\">%d</span>", n)
    }, character(1)), collapse = "")
    c(sprintf("<details class=\"grow\"><summary class=\"grow-sum\" style=\"grid-template-columns:%s\">", tmpl),
      sprintf("<span class=\"gname\">%s</span>", .html_escape(g)),
      sprintf("<span class=\"gcount\">%d</span>", nrow(sub)),
      cells,
      "<span class=\"chev\" aria-hidden=\"true\">&#9656;</span>",
      "</summary>",
      sprintf("<div class=\"grow-body\">%s</div>", paste(.ful(.cap_list(fls, 50L)), collapse = "")),
      "</details>")
  }))

  .card("Experimental groups", 2L,
        c(.fp("Files in your repository are split across these study groups. Each column is a file type; click a group to list its files."),
          "<div class=\"gtbl-wrap\"><div class=\"gtbl\">", head_row, rows, "</div></div>",
          .fhow(GROUP_HOW)))
}

# Build a small directory tree (<= 2 levels deep) with per-folder file counts.
.psy_tree <- function(root) {
  dirs <- tryCatch(list.dirs(root, recursive = TRUE, full.names = TRUE), error = function(e) character(0))
  if (length(dirs) == 0) return(character(0))
  rel  <- sub(paste0("^", root, "/?"), "", dirs)
  keep <- rel != "" & lengths(gregexpr("/", rel)) <= 2 | rel == ""
  sel  <- which(rel == "" | (rel != "" & vapply(strsplit(rel, "/"), length, integer(1)) <= 2))
  lines <- vapply(sel, function(k) {
    d <- dirs[k]; r <- rel[k]
    depth <- if (r == "") 0L else length(strsplit(r, "/")[[1]])
    files <- tryCatch({
      ff <- list.files(d, full.names = TRUE)
      sum(!file.info(ff)$isdir, na.rm = TRUE)
    }, error = function(e) 0L)
    name <- if (r == "") basename(root) else basename(r)
    sprintf("%s%s/%s", strrep("    ", depth), name,
            if (files > 0) sprintf("   (%d file%s)", files, if (files == 1) "" else "s") else "")
  }, character(1))
  lines <- head(lines, 60L)
  c("<pre class=\"tree\">", .html_escape(paste(lines, collapse = "\n")), "</pre>")
}

.sec_psychds <- function(paper_id, out_dir) {
  psy_paper   <- sub("/outputs/", "/psychds/", out_dir)
  summary_csv <- file.path(dirname(dirname(psy_paper)), "conversion_summary.csv")
  what <- .fp("PsychDS is a community standard layout for sharing a dataset so both humans and machines can read it.")

  rows <- NULL
  if (file.exists(summary_csv)) {
    df <- .report_load_csv(summary_csv)
    if (!is.null(df) && "paper_id" %in% names(df)) rows <- df[df$paper_id == paper_id, , drop = FALSE]
  }
  # Defensive: an older append-only summary may hold duplicate rows per study
  # group from repeated runs — keep only the most recent row for each group.
  if (!is.null(rows) && nrow(rows) > 0 && "study_group" %in% names(rows))
    rows <- rows[!rev(duplicated(rev(rows$study_group))), , drop = FALSE]

  # The conversion summary row is the source of truth for whether the conversion
  # actually ran in the latest pipeline run. Without it, do NOT narrate a
  # conversion or show a (possibly stale) psychds/ folder as if freshly produced.
  if (is.null(rows) || nrow(rows) == 0)
    return(.card("PsychDS conversion", 6L,
                 c(what,
                   .fcallout("info", "PsychDS conversion was not run for this repository in the latest pipeline run, so there is no converted output to report."),
                   .fhow(.pdetail(7)))))

  # Prefer the actual output location recorded by the converter (its layout may
  # differ from outputs/, e.g. psychds/<id>/study-<group> with no source subdir).
  if ("output_path" %in% names(rows)) {
    op <- rows$output_path[!is.na(rows$output_path)]
    if (length(op) > 0) psy_paper <- if (any(grepl("/study-", op))) dirname(op[1]) else op[1]
  }

  parts <- c(what,
    .fp("DataCheck re-packaged your repository into this layout: tabular data files are exported as CSV with a JSON metadata sidecar each, code and materials and documentation go into their own folders, and a dataset_description.json carries the variable metadata. Every original file is also copied across into a raw/ folder, and oversized or binary files (EEG, video, MATLAB) are copied untouched without conversion."),
    .fcallout("good", "Your original data files are never edited. DataCheck only restructures copies and adds metadata alongside them. The values inside your data are left exactly as they were."))

  g <- function(col) if (col %in% names(rows)) rows[[col]] else rep(NA, nrow(rows))
  sg <- g("study_group"); ndf <- g("n_data_files"); nrf <- g("n_raw_files")
  nv <- g("n_variables"); nl <- g("n_labelled"); ok <- g("success")
  trows <- lapply(seq_len(nrow(rows)), function(i)
    c(as.character(sg[i]), .fmt_num(ndf[i]), .fmt_num(nrf[i]), .fmt_num(nv[i]), .fmt_num(nl[i]),
      if (isTRUE(as.logical(ok[i]))) "&#10003;" else "&#10007;"))
  parts <- c(parts,
    .fp("Each study group became its own PsychDS dataset:"),
    .ftable(c("Study group", "Data files", "Raw-copied", "Variables", "Labelled", "OK"),
            trows, raw_cols = c(6L)))
  if (any(as.logical(g("has_paper_metadata")), na.rm = TRUE))
    parts <- c(parts, .fcallout("info", "Paper metadata (extracted from the manuscript with GROBID) was attached to the dataset description."))
  if (any(as.logical(g("has_ground_truth")), na.rm = TRUE))
    parts <- c(parts, .fcallout("info", "Hand-curated ground-truth overrides were applied during conversion for this repository."))

  tree <- .psy_tree(psy_paper)
  if (length(tree) > 0)
    parts <- c(parts, .fdetails("Folder structure produced", tree))
  .card("PsychDS conversion", 6L, c(parts, .fhow(.pdetail(7))))
}

.sec_granularity <- function(st, traces = NULL) {
  is_data <- st$type == "data" & !is.na(st$type)
  gran    <- if ("data_granularity" %in% names(st)) st$data_granularity[is_data] else character(0)
  gsrc    <- if ("granularity_source" %in% names(st)) st$granularity_source[is_data] else character(0)
  n_ind <- sum(gran == "individual", na.rm = TRUE)
  n_com <- sum(gran == "combined", na.rm = TRUE)

  if (length(gran[!is.na(gran)]) == 0)
    return(.card("Data granularity", 3L,
                 c(.fp("No data files were found, so there is nothing to report on granularity."),
                   .fhow(.pdetail(3)))))

  intro <- "<p>DataCheck marks each dataset as <b>individual</b> (one file per participant) or <b>combined</b> (all participants in one file). Below is what it found and how it decided.</p>"
  tiles <- .ftiles(list(
    c(as.character(n_ind), "individual (per-participant)"),
    c(as.character(n_com), "combined (all participants)")
  ))

  # per-source breakdown with explanations (cells escaped by .ftable)
  sc   <- .count_tbl(gsrc)
  rows <- lapply(seq_len(nrow(sc)), function(i) {
    s   <- sc$value[i]
    why <- if (s %in% names(GRAN_SOURCE_EXPLAIN)) GRAN_SOURCE_EXPLAIN[[s]] else "—"
    c(s, as.character(sc$n[i]), why)
  })
  tbl <- if (nrow(sc) > 0)
    c(.fp("How it was inferred (granularity_source):"),
      .ftable(c("Source", "Files", "What it means"), rows)) else character(0)

  caveat <- if (any(gsrc == "default_combined", na.rm = TRUE))
    .fcallout("info", "\"default_combined\" means no per-participant signal was detected. If your data is actually per-participant but the files or folders aren't named in a recognised pattern, those files may be marked combined here.") else character(0)

  .card("Data granularity", 3L, c(intro, tiles, tbl, caveat, .fhow(.pdetail(3)),
        .trace_html(traces, "^granularity", title = "Show the model's reasoning for granularity")))
}

.sec_columns <- function(co, lb, st = NULL, traces = NULL) {
  if (is.null(co) || nrow(co) == 0)
    return(.card("Columns & their types", 4L,
                 c(.fp("No tabular columns were extracted from this repository (the data files are non-tabular, e.g. recordings or matrices)."),
                   .fhow(c(.pdetail(4), .pdetail(5))))))
  ct <- .count_tbl(vapply(co$col_type, .ct_label, character(1)))
  head_html <- c(
    .fp(sprintf("DataCheck read %d columns from your tabular data files and inferred a type for each. Only tabular files (CSV, XLSX, SAV) have columns to read; raw recordings (EEG, MATLAB, video) do not. Types are decided by rules first; a language model only helps with the ambiguous text columns.", nrow(co))),
    .fdist(ct$value, ct$n, .ct_class))
  vars_html <- .vars_html(co, lb, st)
  .card("Columns & their types", 4L, c(head_html, vars_html, .fhow(c(.pdetail(4), .pdetail(5))),
        .trace_html(traces, "^col-type", title = "Show the model's reasoning for column types")))
}

.vars_html <- function(co, lb, st = NULL) {

  # Index labels by source_file + column_name (parallel to columns.csv rows)
  lb_key <- if (!is.null(lb) && nrow(lb) > 0) paste(lb$source_file, lb$column_name, sep = "\r") else character(0)
  lget   <- function(col) if (!is.null(lb) && col %in% names(lb)) lb[[col]] else NULL

  # Granularity lookup: columns.csv source_file == structure.csv rel_path
  gran_g <- character(0); gran_s <- character(0)
  if (!is.null(st) && "rel_path" %in% names(st) && "data_granularity" %in% names(st)) {
    gran_g <- setNames(st$data_granularity, st$rel_path)
    if ("granularity_source" %in% names(st))
      gran_s <- setNames(st$granularity_source, st$rel_path)
  }

  multi_file <- length(unique(co$source_file)) > 1
  n_show     <- min(nrow(co), REPORT_MAX_VARS)
  get <- function(col) if (col %in% names(co)) co[[col]] else rep(NA, nrow(co))
  src <- get("source_file"); nm <- get("column_name"); ctype <- get("col_type")
  samp <- get("sample_values")
  n_ <- get("n"); nmiss <- get("n_missing"); nuniq <- get("n_unique")
  mn <- get("mean"); sd_ <- get("sd"); md <- get("median")
  min_ <- get("min"); max_ <- get("max"); p25 <- get("p25"); p75 <- get("p75")

  is_num_type <- function(t) !is.na(t) && grepl("^continuous", t)

  one_var <- function(i) {
    j <- if (length(lb_key) > 0) match(paste(src[i], nm[i], sep = "\r"), lb_key) else NA_integer_
    l_label  <- if (!is.na(j)) lget("label")[j]             else NA
    l_status <- if (!is.na(j)) lget("label_status")[j]      else NA
    l_method <- if (!is.na(j)) lget("label_method")[j]      else NA
    l_source <- if (!is.na(j)) lget("label_source")[j]      else NA
    l_cbvar  <- if (!is.na(j)) lget("codebook_variable")[j] else NA

    labelled <- !is.na(l_status) && l_status %in% c("labelled", "llm") && !is.na(l_label)
    label_txt <- if (labelled) l_label else "not labelled"

    # ── summary line (collapsed) ──
    summ <- c("<summary>",
      sprintf("<span class=\"var-name\">%s</span>", .html_escape(nm[i])),
      sprintf("<span class=\"var-label%s\">%s</span>",
              if (labelled) "" else " none", .html_escape(label_txt)),
      .fbadge(ifelse(is.na(ctype[i]), "?", .ct_label(ctype[i])), .ct_class(ctype[i])),
      "<span class=\"chev\" aria-hidden=\"true\">&#9656;</span>",
      "</summary>")

    # ── type provenance ──
    cm  <- .coltype_method(ctype[i])
    type_v <- sprintf("%s &mdash; %s <span class=\"mut\">(%s: %s)</span>",
                      .fbadge(ifelse(is.na(ctype[i]), "?", .ct_label(ctype[i])), .ct_class(ctype[i])),
                      .html_escape(ifelse(is.na(ctype[i]), "?", .ct_label(ctype[i]))),
                      .fbadge(cm[1], if (cm[1] == "LLM") "b-orange" else "b-green"),
                      .html_escape(cm[2]))

    # ── codebook label provenance ──
    if (labelled) {
      status_x <- LABEL_STATUS_EXPLAIN[[l_status]]
      method_x <- if (!is.na(l_method) && l_method %in% names(LABEL_METHOD_EXPLAIN))
        LABEL_METHOD_EXPLAIN[[l_method]] else NA
      label_v <- .html_escape(l_label)
    } else {
      status_x <- if (!is.na(l_status) && l_status %in% names(LABEL_STATUS_EXPLAIN))
        LABEL_STATUS_EXPLAIN[[l_status]] else "No matching codebook variable was found."
      method_x <- NA
      label_v  <- "<span class=\"mut\">not labelled</span>"
    }

    pairs <- list(
      c("Type", type_v),
      c("Codebook label", label_v),
      c("Label status", sprintf("<span class=\"badge %s\">%s</span> %s",
          if (labelled) "b-green" else "b-gray",
          .html_escape(ifelse(is.na(l_status), "unlabelled", l_status)),
          .html_escape(status_x)))
    )
    if (!is.na(method_x))
      pairs <- c(pairs, list(c("Matched how", .html_escape(method_x))))
    if (labelled && !is.na(l_cbvar) && nzchar(l_cbvar))
      pairs <- c(pairs, list(c("Codebook variable", .html_escape(l_cbvar))))
    if (labelled && !is.na(l_source) && nzchar(l_source))
      pairs <- c(pairs, list(c("Codebook source", .html_escape(l_source))))
    if (multi_file)
      pairs <- c(pairs, list(c("Data file", .html_escape(basename(src[i])))))
    g_val <- if (length(gran_g) > 0) gran_g[[src[i]]] else NULL
    if (!is.null(g_val) && !is.na(g_val) && nzchar(g_val)) {
      g_src <- if (length(gran_s) > 0) gran_s[[src[i]]] else NA
      why   <- if (!is.na(g_src) && g_src %in% names(GRAN_SOURCE_EXPLAIN)) GRAN_SOURCE_EXPLAIN[[g_src]] else NA
      gtxt  <- sprintf("<span class=\"badge %s\">%s</span>",
                       if (g_val == "individual") "b-teal" else "b-gray", .html_escape(g_val))
      if (!is.na(why)) gtxt <- paste0(gtxt, sprintf(" <span class=\"mut\">(%s)</span>", .html_escape(why)))
      pairs <- c(pairs, list(c("Granularity", gtxt)))
    }
    if (!is.na(samp[i]) && nzchar(samp[i]))
      pairs <- c(pairs, list(c("Sample values", .html_escape(gsub("|", " · ", samp[i], fixed = TRUE)))))

    # ── statistics ──
    stat <- sprintf("n %s &middot; missing %s &middot; unique %s",
                    .fmt_num(n_[i]), .fmt_num(nmiss[i]), .fmt_num(nuniq[i]))
    if (is_num_type(ctype[i])) {
      stat <- paste0(stat, sprintf(
        "<br>mean %s &middot; sd %s &middot; median %s &middot; min %s &middot; max %s &middot; p25 %s &middot; p75 %s",
        .fmt_num(mn[i]), .fmt_num(sd_[i]), .fmt_num(md[i]),
        .fmt_num(min_[i]), .fmt_num(max_[i]), .fmt_num(p25[i]), .fmt_num(p75[i])))
    }
    pairs <- c(pairs, list(c("Statistics", stat)))

    c("<details class=\"var\">", summ,
      sprintf("<div class=\"var-body\">%s</div>", paste(.fspec(pairs), collapse = "")),
      "</details>")
  }

  body <- unlist(lapply(seq_len(n_show), one_var))
  note <- if (nrow(co) > n_show)
    .fp(sprintf("Showing the first %d of %d columns.", n_show, nrow(co))) else character(0)
  c("<h3 class=\"sub\">Every variable</h3>",
    .fp("Click a variable to see its inferred type (and how that was decided), its codebook label and how it was matched, granularity, sample values, and statistics."),
    body, note)
}

.sec_codebook <- function(st, lb, cov, traces = NULL) {
  n_codebook_files <- sum(st$type == "codebook", na.rm = TRUE)
  status <- if (!is.null(lb)) lb$label_status else character(0)
  n_labelled   <- sum(status %in% c("labelled", "llm"), na.rm = TRUE)
  n_total_cols <- length(status)
  n_cov_vars <- if (!is.null(cov)) nrow(cov) else 0L
  n_matched  <- if (!is.null(cov)) sum(cov$match_status == "matched", na.rm = TRUE) else 0L
  n_unmatch  <- if (!is.null(cov)) sum(cov$match_status == "unmatched_in_data", na.rm = TRUE) else 0L

  has_no_codebook       <- n_codebook_files == 0 && n_cov_vars == 0
  has_unparsed_codebook <- n_codebook_files > 0  && n_cov_vars == 0

  tiles <- list(
    c(as.character(n_codebook_files), "codebook files"),
    c(as.character(n_cov_vars),       "variables defined"),
    c(sprintf("%s", .pct(n_labelled, n_total_cols)), sprintf("columns labelled (%d/%d)", n_labelled, n_total_cols)),
    c(sprintf("%s", .pct(n_matched, n_cov_vars)),    sprintf("codebook vars matched (%d/%d)", n_matched, n_cov_vars))
  )

  callouts <- character(0)
  if (has_no_codebook) {
    callouts <- c(callouts, .fcallout("warn",
      "No codebook was found. Add a data dictionary (a file with one row per variable giving its name and a short description) so that others, and DataCheck, can understand every column."))
  } else if (has_unparsed_codebook) {
    callouts <- c(callouts, .fcallout("warn", sprintf(
      "%d codebook file(s) were found, but no variable definitions could be extracted. The codebook may be a scanned/image PDF, free-form prose, or an unsupported layout. A machine-readable data dictionary (a CSV/XLSX with a variable-name column and a description column) would let every column be labelled.", n_codebook_files)))
  } else {
    if (n_unmatch > 0)
      callouts <- c(callouts, .fcallout("warn", sprintf(
        "%d codebook variable(s) were defined but not found in any data column. This is usually a naming mismatch between the codebook and the data headers.", n_unmatch)))
    if (n_labelled < n_total_cols && n_total_cols > 0)
      callouts <- c(callouts, .fcallout("info", sprintf(
        "%d data column(s) have no codebook entry. Documenting these would make the dataset fully self-describing.", n_total_cols - n_labelled)))
    if (n_unmatch == 0 && n_labelled == n_total_cols && n_total_cols > 0)
      callouts <- c(callouts, .fcallout("good",
        "Every data column was matched to the codebook and every codebook variable was found in the data. Excellent documentation."))
  }
  if (any(status == "conflicting_definition", na.rm = TRUE))
    callouts <- c(callouts, .fcallout("warn",
      "Some columns matched a variable defined differently across multiple codebooks (conflicting_definition). Consider reconciling those definitions."))
  if (any(status == "ambiguous_experiment", na.rm = TRUE))
    callouts <- c(callouts, .fcallout("warn",
      "Some columns matched a variable that only appears in a different experiment's codebook (ambiguous_experiment). Check the codebook covers the right experiment."))

  lists <- character(0)
  if (!has_no_codebook && !has_unparsed_codebook && n_unmatch > 0) {
    unmatched_names <- cov$codebook_variable[cov$match_status == "unmatched_in_data"]
    lists <- c(lists, .fp("Codebook variables not found in the data:"), .ful(.cap_list(unmatched_names)))
  }
  if (!has_no_codebook && !has_unparsed_codebook && !is.null(lb) && n_total_cols > 0) {
    unl <- lb$column_name[lb$label_status == "unlabelled"]
    if (length(unl[!is.na(unl)]) > 0)
      lists <- c(lists, .fp("Data columns with no codebook entry:"), .ful(.cap_list(unl)))
  }
  .card("Codebook matching", 5L, c(.ftiles(tiles),
        "<p>Two views of the same matching: <b>labelled</b> is per data column (did this column get a description?); <b>coverage</b> is per codebook variable (was this defined variable found in the data?).</p>",
        callouts, lists, .fhow(.pdetail(6)),
        .trace_html(traces, "^(file-type|col-type|granularity)", negate = TRUE,
                    title = "Show the model's reasoning for codebook matching")))
}

.sec_quality <- function(st, co, lb, cov) {
  has_readme   <- any(st$type == "readme",   na.rm = TRUE)
  has_codebook <- any(st$type == "codebook", na.rm = TRUE)
  pm   <- if (!is.null(cov)) cov$parse_method else character(0)
  machine_readable <- any(pm %in% c("structured", "haven"), na.rm = TRUE)
  lmeth   <- if (!is.null(lb)) lb$label_method else character(0)
  has_haven <- any(lmeth == "haven", na.rm = TRUE)
  status <- if (!is.null(lb)) lb$label_status else character(0)
  n_cols <- length(status)
  n_lab  <- sum(status %in% c("labelled", "llm"), na.rm = TRUE)
  n_cov  <- if (!is.null(cov)) nrow(cov) else 0L
  n_match<- if (!is.null(cov)) sum(cov$match_status == "matched", na.rm = TRUE) else 0L

  checks <- list()
  add <- function(...) checks[[length(checks) + 1L]] <<- c(...)

  add(if (has_readme) "good" else "warn",
      if (has_readme) "README present" else "No README",
      if (has_readme) "A README documents the study and how to use the files."
      else "Add a README describing the study, the files, and how to reproduce the results.")

  add(if (has_codebook) "good" else "warn",
      if (has_codebook) "Codebook present" else "No codebook",
      if (has_codebook) "A codebook / data dictionary documents your variables."
      else "Add a data dictionary: one row per variable with its name and a short description.")

  if (has_codebook)
    add(if (machine_readable) "good" else "info",
        if (machine_readable) "Machine-readable codebook" else "Codebook is free-text",
        if (machine_readable) "Variable definitions were read directly from a spreadsheet or embedded labels."
        else "Definitions had to be read by a language model. A CSV/XLSX data dictionary parses more reliably.")

  if (has_haven)
    add("good", "Embedded value labels",
        "SPSS/Stata value labels are embedded in the data files. Excellent self-documentation.")

  if (n_cols > 0)
    add(if (n_lab == n_cols) "good" else "warn",
        if (n_lab == n_cols) sprintf("All %d columns documented", n_cols)
        else sprintf("%s of columns documented", .pct(n_lab, n_cols)),
        if (n_lab == n_cols) "Every data column matched a codebook description."
        else sprintf("%d of %d columns have no codebook entry. Documenting them makes the dataset self-describing.",
                     n_cols - n_lab, n_cols))

  if (n_cov > 0)
    add(if (n_match == n_cov) "good" else "warn",
        if (n_match == n_cov) "All codebook variables found"
        else sprintf("%s of codebook variables found", .pct(n_match, n_cov)),
        if (n_match == n_cov) "Every variable defined in the codebook was located in the data."
        else sprintf("%d defined variable(s) were not found in any data column. This is usually a naming mismatch between codebook and headers.",
                     n_cov - n_match))

  n_good <- sum(vapply(checks, function(c) c[1] == "good", logical(1)))
  head_html <- sprintf(
    "<p>A quick health check of how well your repository documents itself. <b>%d of %d</b> indicators look good.</p>",
    n_good, length(checks))
  body <- vapply(checks, function(c) .fcheck(c[1], c[2], c[3]), character(1))
  .card("Repository quality", NA,
        c(head_html, body,
          .fcallout("info", "These indicators reflect documentation quality for sharing and reuse. They are guidance, not a judgement of your research.")))
}

# Classification keyword -> badge colour class. Used to colour-highlight the
# terms the model uses inside its thinking text, matching the badges elsewhere
# in the report (file types via .ft_class, column types via .ct_class).
# 'id' is deliberately omitted — it matches too much ordinary prose.
.TRACE_KW <- c(
  data = "b-blue", codebook = "b-purple", code = "b-green", software = "b-slate",
  output = "b-orange", supplemental = "b-teal", readme = "b-gray",
  asset = "b-pink", other = "b-gray",
  continuous = "b-blue", binary = "b-purple", categorical = "b-teal",
  ordinal = "b-indigo", date = "b-orange", text = "b-slate",
  constant = "b-gray", empty = "b-gray", unknown = "b-red",
  individual = "b-teal", combined = "b-gray"
)

# Wrap recognised keywords in coloured <span class="kw ...">. Input must already
# be HTML-escaped; longer keys are matched first so 'codebook' beats 'code'.
.trace_highlight <- function(escaped) {
  for (k in names(.TRACE_KW)[order(nchar(names(.TRACE_KW)), decreasing = TRUE)])
    escaped <- gsub(sprintf("\\b(\\Q%s\\E)\\b", k),
                    sprintf("<span class=\"kw %s\">\\1</span>", .TRACE_KW[[k]]),
                    escaped, ignore.case = TRUE, perl = TRUE)
  # Experiment/study groups are bold + underlined (not coloured) to set them
  # apart from the colour-coded type/column keywords above.
  escaped <- gsub("\\b(ex\\d+|pilot\\d+|shared)\\b",
                  "<span class=\"kw-grp\">\\1</span>", escaped, ignore.case = TRUE, perl = TRUE)
  escaped
}

# Collapsible display of the LLM's own reasoning for a stage, with keywords
# colour-coded. `tr` is thinking_traces.csv (NULL when capture was disabled).
# `stage_re` filters rows by stage_name (negate = TRUE keeps the complement).
# The whole block is a closed <details> so it never bloats the default view.
.trace_html <- function(tr, stage_re = NULL, negate = FALSE,
                        title = "Show the model's reasoning (thinking traces)") {
  if (is.null(tr) || nrow(tr) == 0 || !"stage_name" %in% names(tr)) return(character(0))
  tr <- tr[!is.na(tr$thinking) & nzchar(tr$thinking), , drop = FALSE]
  # Defensive: drop duplicate trace rows left by earlier reruns of an
  # append-only log — keep the most recent occurrence of each stage/chunk/paths.
  key_cols <- intersect(c("stage_name", "chunk", "paths"), names(tr))
  if (nrow(tr) > 0 && length(key_cols) > 0) {
    key <- do.call(paste, c(tr[key_cols], sep = "\r"))
    tr  <- tr[!rev(duplicated(rev(key))), , drop = FALSE]
  }
  if (!is.null(stage_re)) {
    hit <- grepl(stage_re, tr$stage_name)
    tr  <- tr[if (negate) !hit else hit, , drop = FALSE]
  }
  if (nrow(tr) == 0) return(character(0))

  g <- function(col, i) if (col %in% names(tr)) as.character(tr[[col]][i]) else ""
  stages <- unique(tr$stage_name)
  inner <- unlist(lapply(stages, function(s) {
    sel <- which(tr$stage_name == s)
    idx <- head(sel, 20L)                       # cap per stage to keep the page sane
    blocks <- unlist(lapply(idx, function(i) {
      meta <- sprintf("chunk %s · %s path(s) · %s words · model %s",
                      g("chunk", i), g("n_paths", i), g("n_thinking_words", i), g("model", i))
      c(sprintf("<div class=\"trace-meta\">%s</div>", .html_escape(meta)),
        sprintf("<pre class=\"trace\">%s</pre>", .trace_highlight(.html_escape(tr$thinking[i]))))
    }))
    label <- sprintf("%s — %d LLM call%s%s", s, length(sel), if (length(sel) == 1) "" else "s",
                     if (length(sel) > 20L) " (first 20 shown)" else "")
    .fdetails(label, blocks)
  }))
  .fdetails(title,
    c(.fp("The language model's own notes while it decided. These are captured only when DataCheck runs with thinking-capture enabled. Classification keywords are colour-coded to match the badges above."),
      inner))
}

# ── Page assembly ──────────────────────────────────────────────────────────────

.HTML_STYLE <- "
:root{--blue:#2f4a63;--green:#38573b;--purple:#4a3d63;--teal:#2f5650;
--orange:#7a5a2c;--indigo:#3d3f63;--slate:#3a4452;--gray:#3a3a3a;
--pink:#6b3a4d;--red:#7a2c2c;--cyan:#2f5650;--brand:#33475b;
--bg:#ffffff;--card:#ffffff;--ink:#1a1a1a;--mut:#555555;--rule:#cfcfcf;--rule2:#e3e3e3}
*{box-sizing:border-box}
body{font-family:Georgia,\"Times New Roman\",Times,serif;
background:var(--bg);color:var(--ink);line-height:1.55;margin:0;padding:2rem 1rem;-webkit-font-smoothing:antialiased}
.wrap{max-width:1440px;width:94%;margin:0 auto}
.layout{display:grid;grid-template-columns:250px 1fr;gap:1.8rem;align-items:start}
.sidebar{position:sticky;top:1.2rem;display:flex;flex-direction:column;gap:1rem}
.main{min-width:0}
h1{font-size:1.4rem;margin:0 0 .15rem;line-height:1.2;font-weight:700}
.meta{color:var(--mut);margin:0;font-size:.85rem;word-break:break-all}
.side-card{background:var(--card);border:1px solid var(--rule);border-radius:2px;padding:.9rem 1rem}
.kpanel{display:flex;flex-direction:column;gap:0}
.kp{display:flex;align-items:baseline;justify-content:space-between;gap:.5rem;
border-bottom:1px solid var(--rule2);padding:.32rem 0}
.kp:last-child{border-bottom:none}
.kp-v{font-size:1.1rem;font-weight:700;color:var(--ink)}
.kp-l{color:var(--mut);font-size:.82rem;text-align:right}
.toc{display:flex;flex-direction:column;gap:.05rem}
.toc-h{color:var(--mut);font-size:.72rem;font-weight:700;text-transform:uppercase;
letter-spacing:.06em;margin:.1rem 0 .4rem}
.toc a{display:flex;align-items:center;gap:.5rem;color:var(--ink);text-decoration:none;
font-size:.88rem;padding:.2rem .25rem}
.toc a:hover{color:var(--brand);text-decoration:underline}
.toc a:hover .num{border-color:var(--brand);color:var(--brand)}
.nav-dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:#b0b0b0;
flex:0 0 auto;margin:0 .2rem}
/* numbered chip: outlined square, document-style (no filled accent) */
.toc .num{display:inline-flex;align-items:center;justify-content:center;width:19px;height:19px;
border:1px solid var(--ink);border-radius:2px;background:transparent;color:var(--ink);font-size:.74rem;font-weight:700;flex:0 0 auto}
.brand{border-left:3px solid var(--brand)}
.lead{background:var(--card);border:1px solid var(--rule);border-radius:2px;padding:1rem 1.25rem;margin-bottom:1.25rem}
@media(max-width:760px){.layout{grid-template-columns:1fr}
.sidebar{position:static}.toc{display:none}
.var>summary{display:flex;flex-wrap:wrap;gap:.4rem}}
.card{background:var(--card);border:1px solid var(--rule);border-radius:2px;padding:1rem 1.3rem 1.3rem;margin-bottom:1.3rem}
.card h2{font-size:1.25rem;margin:.1rem 0 .9rem;color:var(--ink);scroll-margin-top:1.2rem;font-weight:700;
display:flex;align-items:center;gap:.55rem;padding-bottom:.4rem;border-bottom:1px solid var(--rule)}
.card h2 .num{display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;
border:1.5px solid var(--brand);border-radius:2px;background:transparent;color:var(--brand);font-size:.95rem;font-weight:700;flex:0 0 auto}
h3.sub{font-size:1rem;margin:1.1rem 0 .2rem;color:var(--ink);font-weight:700}
.roadmap{margin:.4rem 0 .2rem;padding-left:1.3rem}
.roadmap li{margin:.3rem 0}
.roadmap a{color:var(--ink);text-decoration:none}
.roadmap a:hover{color:var(--brand);text-decoration:underline}
.how{margin:.7rem 0 .2rem;border:1px solid var(--rule);border-radius:2px;background:#faf9f6}
.how>summary{list-style:none;cursor:pointer;padding:.5rem .8rem;font-size:.88rem;font-weight:700;
color:var(--brand);user-select:none}
.how>summary::-webkit-details-marker{display:none}
.how>summary::before{content:\"\\25B8  \";color:var(--mut)}
.how[open]>summary::before{content:\"\\25BE  \"}
.how-body{padding:0 .9rem .7rem;font-size:.92rem}
.how-body p{margin:.5rem 0 0}
.tree{background:#f6f5f1;color:#2a2a2a;border:1px solid var(--rule);border-radius:2px;padding:.7rem .9rem;margin:.4rem 0 0;
font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.82rem;line-height:1.5;
overflow-x:auto;white-space:pre}
p{margin:.5rem 0}
table{border-collapse:collapse;width:100%;margin:.7rem 0;font-size:.92rem}
th,td{border-bottom:1px solid var(--rule2);padding:.4rem .55rem;text-align:left;vertical-align:top}
th{background:transparent;color:var(--ink);font-weight:700;border-bottom:1.5px solid var(--ink)}
tbody tr:hover{background:#f7f7f5}
.badge{display:inline-block;padding:.1rem .42rem;border-radius:3px;font-size:.8rem;
font-weight:600;line-height:1.5;white-space:nowrap;border:1px solid rgba(0,0,0,.1)}
.badge b{font-weight:700;margin-left:.15rem}
.b-blue{background:#e7edf3;color:#2f4a63}.b-green{background:#e9efe8;color:#38573b}
.b-purple{background:#ece9f1;color:#4a3d63}.b-teal{background:#e4eeec;color:#2f5650}
.b-orange{background:#f1ece1;color:#7a5a2c}.b-indigo{background:#e9eaf1;color:#3d3f63}
.b-slate{background:#e9ecef;color:#3a4452}.b-gray{background:#eeeeee;color:#3a3a3a}
.b-pink{background:#f1e7ec;color:#6b3a4d}.b-red{background:#f1e3e3;color:#7a2c2c}
.dist{display:flex;flex-wrap:wrap;gap:.4rem;margin:.5rem 0}
.gtbl-wrap{margin:.6rem 0}
.gtbl{border:1px solid var(--rule);border-radius:2px;overflow:hidden;width:100%}
.gtbl-head,.grow-sum{display:grid;align-items:center;gap:.35rem;padding:.5rem .5rem}
.gtbl-head>span,.grow-sum>span{min-width:0}
.gtbl-head{background:transparent;color:var(--ink);font-size:.72rem;font-weight:700;
text-transform:uppercase;letter-spacing:.03em;border-bottom:1.5px solid var(--ink)}
.gth{display:flex;justify-content:center;text-align:center}
.gtbl-head .gth .badge{font-size:.66rem;white-space:normal;line-height:1.2;letter-spacing:.02em}
.grow{border-top:1px solid var(--rule2)}
.grow:first-of-type{border-top:none}
.grow>summary{list-style:none;cursor:pointer;user-select:none}
.grow>summary::-webkit-details-marker{display:none}
.grow>summary:hover{background:#f7f7f5}
.gname{font-weight:700;font-size:.92rem;justify-self:start}
.gcount,.gn,.gz,.gth{justify-self:center}
.gcount{font-weight:700;color:var(--ink)}
.gn{font-weight:600}
.gz{color:#b8b8b8}
.grow[open]>summary{border-bottom:1px solid var(--rule2);background:#f7f7f5}
.grow[open] .chev{transform:rotate(90deg)}
.grow-body{padding:.4rem .9rem .7rem}
.grow-body ul{margin:.3rem 0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:.6rem;margin:.3rem 0 .7rem}
.tile{background:#fff;border:1px solid var(--rule);border-radius:2px;padding:.6rem .8rem}
.tile-val{font-size:1.4rem;font-weight:700;color:var(--ink)}
.tile-lab{color:var(--mut);font-size:.85rem}
.step{border:1px solid var(--rule);border-radius:2px;margin:.5rem 0;background:#fff;overflow:hidden}
.step[open]{border-color:#bdbdbd}
.step>summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:.6rem;
flex-wrap:wrap;padding:.6rem .8rem;user-select:none}
.step>summary::-webkit-details-marker{display:none}
.step>summary:hover{background:#f7f7f5}
.step-title{font-weight:700;flex:0 0 auto}
.step-gist{color:var(--mut);font-size:.9rem;flex:1 1 200px;min-width:160px}
.chev{color:var(--mut);transition:transform .15s ease;flex:0 0 auto}
.step[open] .chev{transform:rotate(90deg)}
.step-body{padding:0 .9rem .7rem;border-top:1px solid var(--rule2)}
.step-body p{margin:.6rem 0 0;color:var(--ink)}
.var{border:1px solid var(--rule);border-radius:2px;margin:.35rem 0;background:#fff}
.var[open]{border-color:#bdbdbd}
.var>summary{list-style:none;cursor:pointer;display:grid;
grid-template-columns:170px 1fr 130px 16px;align-items:center;gap:.55rem;padding:.45rem .7rem}
.var>summary::-webkit-details-marker{display:none}
.var>summary:hover{background:#f7f7f5}
.var[open]>summary{border-bottom:1px solid var(--rule2)}
.var[open] .chev{transform:rotate(90deg)}
.var-name{font-weight:700;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9rem}
.var-label{color:#333;font-size:.88rem;min-width:0}
.var-label.none{color:var(--mut);font-style:italic}
.var-body{padding:.4rem .8rem .7rem}
.spec{display:grid;grid-template-columns:max-content 1fr;gap:.3rem .9rem;font-size:.9rem}
.spec-k{color:var(--mut);font-weight:700}
.spec-v{color:var(--ink)}
.mut{color:var(--mut)}
.callout{display:flex;gap:.6rem;align-items:flex-start;border:1px solid var(--rule);border-left-width:3px;border-radius:2px;
padding:.55rem .8rem;margin:.55rem 0;font-size:.93rem}
.callout .ci{font-weight:700;flex:0 0 auto}
.callout.good{background:#eef2ec;border-left-color:#38573b;color:#2f4a2f}
.callout.warn{background:#f5efe3;border-left-color:#8a6a2c;color:#5f441f}
.callout.info{background:#eceff3;border-left-color:#33475b;color:#2f4257}
.check{display:flex;gap:.6rem;align-items:flex-start;border:1px solid var(--rule);
border-left-width:3px;border-radius:2px;padding:.55rem .8rem;margin:.4rem 0;background:#fff;font-size:.92rem}
.check .ci{font-weight:700;flex:0 0 auto;font-size:1.05rem;line-height:1.4}
.check-t b{font-weight:700}
.check-d{color:var(--mut);font-size:.88rem;margin-top:.1rem}
.check.good{border-left-color:#38573b}.check.good .ci{color:#38573b}
.check.warn{border-left-color:#8a6a2c}.check.warn .ci{color:#8a6a2c}
.check.info{border-left-color:#33475b}.check.info .ci{color:#33475b}
.trace-meta{color:var(--mut);font-size:.78rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;margin:.5rem 0 .15rem}
.trace{background:#f6f5f1;color:#2a2a2a;border:1px solid var(--rule);border-radius:2px;padding:.6rem .8rem;margin:0 0 .3rem;
font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem;line-height:1.6;
white-space:pre-wrap;word-break:break-word;max-height:340px;overflow-y:auto}
.trace .kw{padding:0 .25rem;border-radius:2px;font-weight:700;border:1px solid rgba(0,0,0,.12)}
.trace .kw-grp{font-weight:700;text-decoration:underline}
ul{margin:.4rem 0 .6rem}
footer{color:var(--mut);font-size:.82rem;text-align:center;margin:1rem 0}
"

.slug <- function(t) gsub("(^-|-$)", "", gsub("[^a-z0-9]+", "-", tolower(t)))

.page <- function(paper_id, source, cards, summary = list()) {
  slugs <- vapply(cards, function(cd) .slug(cd$title), character(1))

  # ── Sidebar ──
  kp <- if (length(summary) > 0)
    c("<div class=\"side-card\"><div class=\"kpanel\">",
      unlist(lapply(summary, function(s)
        sprintf("<div class=\"kp\"><span class=\"kp-v\">%s</span><span class=\"kp-l\">%s</span></div>",
                .html_escape(s[1]), .html_escape(s[2])))),
      "</div></div>") else character(0)

  marker <- function(step) if (is.na(step)) "<span class=\"nav-dot\"></span>"
                           else sprintf("<span class=\"num\">%d</span>", step)
  toc <- c("<div class=\"side-card\"><div class=\"toc\"><div class=\"toc-h\">Contents</div>",
    unlist(lapply(seq_along(cards), function(i)
      sprintf("<a href=\"#%s\">%s%s</a>",
              slugs[i], marker(cards[[i]]$step), .html_escape(cards[[i]]$title)))),
    "</div></div>")

  sidebar <- c("<aside class=\"sidebar\">",
    "<div class=\"side-card brand\">",
    "<h1>DataCheck report</h1>",
    sprintf("<p class=\"meta\">%s<br>source: %s &middot; %s</p>",
            .html_escape(paper_id), .html_escape(source), format(Sys.Date(), "%Y-%m-%d")),
    "</div>", kp, toc, "</aside>")

  # ── Main column ──
  card_html <- unlist(lapply(seq_along(cards), function(i) {
    cd <- cards[[i]]
    chip <- if (is.na(cd$step)) "" else sprintf("<span class=\"num\">%d</span>", cd$step)
    c("<section class=\"card\">",
      sprintf("<h2 id=\"%s\">%s%s</h2>", slugs[i], chip, .html_escape(cd$title)),
      cd$html, "</section>")
  }))
  main <- c("<div class=\"main\">",
    sprintf("<div class=\"lead\">%s</div>", .html_escape(REPORT_INTRO)),
    card_html,
    "<footer>Generated by DataCheck · this report reads existing pipeline outputs only.</footer>",
    "</div>")

  c("<!DOCTYPE html>", "<html lang=\"en\">", "<head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    sprintf("<title>DataCheck report — %s</title>", .html_escape(paper_id)),
    sprintf("<style>%s</style>", .HTML_STYLE),
    "</head>", "<body>", "<div class=\"wrap\"><div class=\"layout\">",
    sidebar, main,
    "</div></div>", "</body>", "</html>")
}

# ── Entry point ────────────────────────────────────────────────────────────────

run_report <- function(paper_id, source = "osf", out_dir = NULL) {
  if (is.null(out_dir)) out_dir <- paper_path("outputs", source, paper_id)

  fail <- function(err) list(
    success = FALSE, error = err, paper_id = paper_id, html_path = NA_character_,
    n_files = NA_integer_, n_columns = NA_integer_,
    n_labelled = NA_integer_, n_codebook_vars = NA_integer_
  )

  st <- .report_load_csv(file.path(out_dir, "structure.csv"))
  if (is.null(st) || nrow(st) == 0) return(fail("no_structure"))
  co  <- .report_load_csv(file.path(out_dir, "columns.csv"))
  lb  <- .report_load_csv(file.path(out_dir, "labels.csv"))
  cov <- .report_load_csv(file.path(out_dir, "codebook_coverage.csv"))
  traces <- .report_load_csv(file.path(out_dir, "thinking_traces.csv"))
  n_columns <- if (!is.null(co)) nrow(co) else 0L

  cards <- list(
    .sec_overview(st, n_columns),
    .sec_files(st, traces),
    .sec_groups(st),
    .sec_granularity(st, traces),
    .sec_columns(co, lb, st, traces),
    .sec_codebook(st, lb, cov, traces),
    .sec_quality(st, co, lb, cov),
    .sec_psychds(paper_id, out_dir)
  )

  # Key numbers for the sidebar panel
  status   <- if (!is.null(lb)) lb$label_status else character(0)
  n_data   <- sum(st$type == "data", na.rm = TRUE)
  n_lab    <- sum(status %in% c("labelled", "llm"), na.rm = TRUE)
  n_ind    <- if ("data_granularity" %in% names(st)) sum(st$data_granularity == "individual", na.rm = TRUE) else 0L
  summary <- list(
    c(format(nrow(st), big.mark = ","), "files"),
    c(format(n_data, big.mark = ","),   "data files"),
    c(format(n_columns, big.mark = ","),"columns"),
    c(.pct(n_lab, length(status)),      "columns labelled"),
    c(format(n_ind, big.mark = ","),    "per-participant files")
  )

  html_path <- file.path(out_dir, "report.html")
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  writeLines(.page(paper_id, source, cards, summary), html_path)

  list(
    success = TRUE, error = NA_character_, paper_id = paper_id, html_path = html_path,
    n_files = nrow(st), n_columns = n_columns,
    n_labelled = sum(status %in% c("labelled", "llm"), na.rm = TRUE),
    n_codebook_vars = if (!is.null(cov)) nrow(cov) else 0L
  )
}
