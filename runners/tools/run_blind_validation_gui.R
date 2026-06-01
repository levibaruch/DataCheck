# run_blind_validation_gui.R
# ─────────────────────────────────────────────────────────────────────────────
# Blind validation: a *config* of the existing validation GUI
# (tests/validation_gui) — not a separate tool. Same app, launched with options
# that change its behaviour:
#
#   - dc_show_llm_preview = FALSE  → no LLM-predicted type / group / granularity /
#                                    format shown anywhere; dropdowns start empty.
#   - dc_sample_newest    = 50     → expose only the 50 newest papers (largest ID).
#   - dc_gt_dir = tests/ground_truth_blind
#                                  → ground truth saved to a separate directory,
#                                    so it doesn't mix with the main GT set
#                                    (writes to tests/ground_truth_blind/osf/<id>.csv).
#
# Edit the constants below to tweak the config.
#
# Usage (from repo root):   Rscript runners/tools/run_blind_validation_gui.R
# Usage (interactive):      source("runners/tools/run_blind_validation_gui.R")
# ─────────────────────────────────────────────────────────────────────────────

dc_root <- normalizePath(".")

options(
  dc_root             = dc_root,
  dc_gt_dir           = file.path(dc_root, "tests", "ground_truth_blind"),
  dc_show_llm_preview = FALSE,
  dc_sample_newest    = 50L
)

shiny::runApp(file.path(dc_root, "tests", "validation_gui"))
