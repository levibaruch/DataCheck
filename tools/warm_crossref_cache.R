#!/usr/bin/env Rscript
# Pre-warm the CrossRef DOI metadata cache for every GROBID XML in XML_DIR.
# Idempotent: already-cached DOIs are skipped (no network). Safe to re-run.

suppressWarnings(suppressMessages({
  source("pipeline/helper.R")
  source("pipeline/3_psychds_convert.R")
}))

xml_dir   <- if (exists("XML_DIR")) XML_DIR else "/Volumes/Models/expanded_xml"
sleep_sec <- 0.002   # polite pause between *network* calls (cached hits skip it)

files <- sort(list.files(xml_dir, pattern = "\\.xml$", full.names = TRUE))
cat(sprintf("Warming CrossRef cache for %d XML files in %s\n", length(files), xml_dir))
cat(sprintf("Cache dir: %s\n\n", CROSSREF_CACHE_DIR))

n_ok <- 0L; n_miss <- 0L; n_cached <- 0L
for (i in seq_along(files)) {
  f       <- files[i]
  paper   <- sub("\\.xml$", "", basename(f))

  # Resolve a DOI: GROBID header DOI, else reconstruct for numeric Psych Sci ids
  xm  <- tryCatch(parse_grobid_xml(f), error = function(e) NULL)
  doi <- if (!is.null(xm) && !is.null(xm$doi)) xm$doi else NA_character_
  if (is.na(clean_doi(doi)) && grepl("^[0-9]{10,}$", paper))
    doi <- paste0("10.1177/", paper)

  base <- clean_doi(doi)
  if (is.na(base)) {
    cat(sprintf("[%4d/%4d] %-22s  no DOI — skip\n", i, length(files), paper))
    next
  }

  # Was it already cached? (check both candidate forms fetch_crossref_meta tries)
  cands <- unique(c(base, sub("([0-9])[a-z]+$", "\\1", base)))
  cached_before <- any(file.exists(
    file.path(CROSSREF_CACHE_DIR, paste0(sanitize_id(cands), ".json"))))

  meta <- tryCatch(fetch_crossref_meta(doi), error = function(e) NULL)

  if (cached_before) {
    n_cached <- n_cached + 1L
  } else if (!is.null(meta)) {
    n_ok <- n_ok + 1L
    cat(sprintf("[%4d/%4d] %-22s  OK  %s (%s)\n", i, length(files), paper,
                if (!is.null(meta$journal)) meta$journal else "?",
                if (!is.null(meta$pub_year)) meta$pub_year else "?"))
    Sys.sleep(sleep_sec)
  } else {
    n_miss <- n_miss + 1L
    cat(sprintf("[%4d/%4d] %-22s  MISS (%s)\n", i, length(files), paper, base))
    Sys.sleep(sleep_sec)
  }
}

cat(sprintf("\nDone. fetched=%d  already-cached=%d  no-record=%d  total=%d\n",
            n_ok, n_cached, n_miss, length(files)))
