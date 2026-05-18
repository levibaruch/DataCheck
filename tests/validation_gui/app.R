# app.R  —  Validation GUI
# Human ground-truth labelling tool for pipeline structure.csv outputs.
#
# Launch from :  shiny::runApp("tests/validation_gui")
# Launch from repo root:    shiny::runApp("tests/validation_gui")

library(shiny)
library(bslib)

# ── Locate data_check root ────────────────────────────────────────────────────

local({
  if (is.null(getOption("dc_root"))) {
    root <- normalizePath(file.path(getwd(), "../.."))
    if (!dir.exists(file.path(root, "outputs"))) {
      stop("Cannot locate outputs/ directory. Expected at: ", file.path(root, "outputs"))
    }
    options(
      dc_root      = root,
      dc_gt_dir    = file.path(root, "tests", "ground_truth")
    )
  }
})

source(file.path(getOption("dc_root"), "tests", "validation_gui", "gt_store.R"))
source(file.path(getOption("dc_root"), "tests", "validation_gui", "preview.R"))

# ── Constants ─────────────────────────────────────────────────────────────────

TYPE_MAP <- c(
  "1" = "data", "2" = "code", "3" = "codebook", "4" = "supplemental",
  "5" = "readme", "6" = "asset", "7" = "output", "8" = "other",
  "9" = "software"
)
VALID_TYPES <- unname(TYPE_MAP)

TYPE_ABBREV <- c(
  data = "dat", code = "cod", codebook = "cbk", supplemental = "sup",
  readme = "rdm", asset = "ast", other = "oth", output = "out",
  software = "sfw"
)

# ── JavaScript ────────────────────────────────────────────────────────────────

THEME_INIT_JS <- '
// Apply saved theme before page renders to avoid flash of wrong theme
(function () {
  var t = localStorage.getItem("dc-theme") || "dark";
  document.documentElement.setAttribute("data-theme", t);
})();
'

KB_JS <- '
document.addEventListener("DOMContentLoaded", function() {

  // Sync toggle button label to current theme
  var curTheme = document.documentElement.getAttribute("data-theme") || "dark";
  var toggleBtn = document.getElementById("theme_toggle");
  if (toggleBtn) toggleBtn.textContent = curTheme === "dark" ? "\u2600 Light" : "\u263e Dark";

  // Theme toggle
  window.toggleTheme = function() {
    var html  = document.documentElement;
    var cur   = html.getAttribute("data-theme") || "dark";
    var next  = cur === "dark" ? "light" : "dark";
    html.setAttribute("data-theme", next);
    localStorage.setItem("dc-theme", next);
    var btn = document.getElementById("theme_toggle");
    if (btn) btn.textContent = next === "dark" ? "\u2600 Light" : "\u263e Dark";
  };

  // Custom message: focus the group text input
  Shiny.addCustomMessageHandler("focus_group", function(msg) {
    var el = document.getElementById("group_val");
    if (el) { el.focus(); el.select(); }
  });

  // File row click — passes idx + modifier keys to server
  window.fileRowClick = function(e, idx) {
    Shiny.setInputValue("file_click",
      {idx: idx, shift: e.shiftKey, meta: e.metaKey || e.ctrlKey},
      {priority: "event"});
  };

  // ── XML search + column highlight (fully client-side) ─────────────────────
  var _xmlColTerms = [];
  var _xmlQuery    = "";

  function xmlEscHtml(s) {
    return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
  }

  function xmlRender() {
    var el = document.getElementById("xml_text_content");
    if (!el) return;
    var raw = el.textContent;
    if (!raw || !raw.trim()) return;
    var esc = xmlEscHtml(raw);
    var isDark = document.documentElement.getAttribute("data-theme") === "dark";

    _xmlColTerms.forEach(function(t) {
      if (!t || t.length < 2) return;
      var tEsc = xmlEscHtml(t);
      var tRe  = new RegExp("\\b" + tEsc.replace(/[.*+?^${}()|[\\]\\\\]/g,"\\\\$&") + "\\b", "gi");
      var bg   = isDark ? "rgba(76,175,80,0.35)" : "#c8f0c8";
      var fg   = isDark ? "#a5d6a7" : "#1b5e20";
      esc = esc.replace(tRe, function(m) {
        return "<mark style=\\"background:" + bg + ";color:" + fg + ";padding:0;\\">" + m + "</mark>";
      });
    });

    var hits = 0;
    if (_xmlQuery && _xmlQuery.length >= 1) {
      var qEsc = xmlEscHtml(_xmlQuery);
      var qRe  = new RegExp(qEsc.replace(/[.*+?^${}()|[\\]\\\\]/g,"\\\\$&"), "gi");
      var bg2  = isDark ? "rgba(255,202,40,0.45)" : "#fff176";
      var fg2  = isDark ? "#fff8e1" : "#5d4037";
      esc = esc.replace(qRe, function(m) {
        hits++;
        return "<mark style=\\"background:" + bg2 + ";color:" + fg2 + ";padding:0;\\">" + m + "</mark>";
      });
    }

    el.innerHTML = esc;

    var ctr = document.getElementById("xml_hit_count");
    if (ctr) {
      if (_xmlQuery.length >= 1) {
        ctr.textContent = hits > 0 ? hits + " match" + (hits === 1 ? "" : "es") : "no matches";
        ctr.style.color = hits > 0 ? (isDark ? "#a5d6a7" : "#2e7d32") : "#999";
      } else if (_xmlColTerms.length > 0) {
        ctr.textContent = _xmlColTerms.length + " col" + (_xmlColTerms.length === 1 ? "" : "s") + " highlighted";
        ctr.style.color = isDark ? "#80deea" : "#00695c";
      } else {
        ctr.textContent = "";
      }
    }
  }

  window.xmlSetSearch = function(query) {
    _xmlQuery = query || "";
    xmlRender();
  };

  window.xmlSetColumns = function(terms) {
    _xmlColTerms = terms || [];
    _xmlQuery    = "";
    var inp = document.getElementById("xml_search_input");
    if (inp) inp.value = "";
    xmlRender();
  };

  Shiny.addCustomMessageHandler("set_xml_columns", function(msg) {
    window.xmlSetColumns(msg.terms || []);
  });

  // Re-apply highlighting whenever #xml_text_content appears (renderUI is async)
  (function() {
    var _observer = new MutationObserver(function(mutations) {
      mutations.forEach(function(m) {
        m.addedNodes.forEach(function(node) {
          if (!node.querySelector) return;
          var el = node.id === "xml_text_content" ? node : node.querySelector("#xml_text_content");
          if (el) xmlRender();
        });
      });
    });
    _observer.observe(document.body, { childList: true, subtree: true });
  })();

  // Custom message: enable/disable the data_granularity buttons
  Shiny.addCustomMessageHandler("set_data_granularity_disabled", function(msg) {
    var wrap = document.getElementById("data_granularity_ui");
    if (!wrap) return;
    wrap.querySelectorAll("button").forEach(function(btn) { btn.disabled = msg.disabled; });
    wrap.style.opacity = msg.disabled ? "0.35" : "1";
  });

  // Custom message: enable/disable the data_format buttons
  Shiny.addCustomMessageHandler("set_data_format_disabled", function(msg) {
    var wrap = document.getElementById("data_format_ui");
    if (!wrap) return;
    wrap.querySelectorAll("button").forEach(function(btn) { btn.disabled = msg.disabled; });
    wrap.style.opacity = msg.disabled ? "0.35" : "1";
  });

  document.addEventListener("focusin", function(e) {
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
      Shiny.setInputValue("text_focused", true, {priority: "event"});
    }
  });
  document.addEventListener("focusout", function(e) {
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
      Shiny.setInputValue("text_focused", false, {priority: "event"});
    }
  });

  document.addEventListener("keydown", function(e) {
    if (e.metaKey && e.key === "Enter") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "cmd_enter",   ts: Date.now()}, {priority: "event"});
      return;
    }
    if (e.metaKey && e.key === "[") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "cmd_bracket", ts: Date.now()}, {priority: "event"});
      return;
    }
    if (e.metaKey && e.key === "/") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "cmd_slash",   ts: Date.now()}, {priority: "event"});
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "escape", ts: Date.now()}, {priority: "event"});
      return;
    }
    if (e.key === "PageUp") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "page_up",   ts: Date.now()}, {priority: "event"});
      return;
    }
    if (e.key === "PageDown") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "page_down", ts: Date.now()}, {priority: "event"});
      return;
    }
    var inText = document.activeElement &&
      (document.activeElement.tagName === "INPUT" ||
       document.activeElement.tagName === "TEXTAREA");
    if (inText) return;

    if (e.key === "Tab") {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: "tab", ts: Date.now()}, {priority: "event"});
      return;
    }
    var k = e.key.toLowerCase();
    if (["1","2","3","4","5","6","7","8","9","i","c","g","t","r"].indexOf(k) !== -1) {
      e.preventDefault();
      Shiny.setInputValue("key_press", {key: k, ts: Date.now()}, {priority: "event"});
    }
  });
});
'

# ── CSS ───────────────────────────────────────────────────────────────────────

APP_CSS <- "
/* ════════════════════════════════════════════════════════════════
   LAYOUT — always applies
   ════════════════════════════════════════════════════════════════ */
html, body { height: 100%; overflow: hidden; }
.bslib-sidebar-layout { height: 100vh; }
.bslib-sidebar-layout > .main { height: 100%; overflow: hidden; }

.file-row__status { flex-shrink:0; width:12px; text-align:center; font-size:0.85em; }
.file-row__name   { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.file-row__type   { flex-shrink:0; font-size:0.65em; font-weight:700; padding:1px 4px; border-radius:3px;
                    letter-spacing:0.04em; text-transform:uppercase; }

.type-btn-row { display:grid; grid-template-columns:repeat(8,1fr); gap:5px; margin-bottom:6px; }
.tbtn {
  display:flex !important; flex-direction:column; align-items:center; justify-content:center;
  padding:8px 3px 7px !important; border-radius:5px !important; width:100%;
  box-sizing:border-box; text-align:center !important; line-height:1.2;
  box-shadow:none !important; text-transform:none !important; letter-spacing:0 !important;
  cursor:pointer; transition:background 0.12s, border-color 0.12s, color 0.12s !important;
}
.tbtn:focus, .tbtn:active { outline:none !important; box-shadow:none !important; }
.tbtn__key   { display:block; font-size:0.68em; font-weight:400; line-height:1; margin-bottom:3px; }
.tbtn__label { display:block; font-size:0.88em; font-weight:600; }

.file-hdr__top    { display:flex; align-items:flex-start; justify-content:space-between; gap:10px; margin-bottom:6px; }
.file-hdr__name   { font-size:0.97em; font-weight:600; word-break:break-all; line-height:1.35; }
.file-hdr__path   { font-size:0.72em; margin-top:2px; overflow:hidden; text-overflow:ellipsis;
                    white-space:nowrap; max-width:480px; }
.file-hdr__counter      { flex-shrink:0; text-align:right; white-space:nowrap; }
.file-hdr__counter .num { font-size:1.5em; font-weight:700; line-height:1; font-variant-numeric:tabular-nums; }
.file-hdr__counter .denom { font-size:0.78em; display:block; font-variant-numeric:tabular-nums; }
.file-hdr__meta   { display:flex; align-items:center; gap:6px; flex-wrap:wrap; font-size:0.77em; }
.file-hdr__dot    { opacity:0.3; }

.dc-progress__label { font-size:0.79em; display:flex; justify-content:space-between;
                       margin-bottom:5px; font-variant-numeric:tabular-nums; }
.dc-progress__label strong { font-weight:600; }
.dc-progress__track { height:4px; border-radius:2px; overflow:hidden; }
.dc-progress__fill  { height:100%; background:linear-gradient(90deg,#4caf50 0%,#2196f3 100%);
                       border-radius:2px; transition:width 0.4s ease; min-width:3px; }

.pred-override { display:flex; align-items:center; gap:7px; padding:6px 10px;
                 border-radius:5px; font-size:0.79em; margin-bottom:8px;
                 border:1px solid; animation:fadeIn 0.15s ease; }
.pred-override__lbl { }
@keyframes fadeIn { from { opacity:0; transform:translateY(-2px); } to { opacity:1; transform:none; } }

.dc-ctrl-bar { flex-shrink:0; padding:10px 16px 13px; border-top:1px solid; }

.theme-toggle-btn { background:transparent; border-radius:4px;
                    font-size:0.72em; padding:2px 8px; cursor:pointer;
                    transition:all 0.1s; border-width:1px; border-style:solid; }
#file_list_ui .file-row {
  display:flex; align-items:center; gap:5px; padding:5px 7px; border-radius:4px;
  cursor:pointer; margin-bottom:2px; font-size:0.79em; border-left:3px solid transparent;
  transition:background 0.1s, color 0.1s; line-height:1.3;
}

details > summary { font-size:0.75em; font-weight:700; letter-spacing:0.05em;
                    text-transform:uppercase; cursor:pointer; padding:3px 0; user-select:none; }

/* ════════════════════════════════════════════════════════════════
   LIGHT MODE  (default — flatly bootstrap base)
   ════════════════════════════════════════════════════════════════ */

/* File list */
#file_list_ui .file-row                { color: rgba(0,0,0,0.42); }
#file_list_ui .file-row:hover          { background:rgba(0,0,0,0.04) !important; color:rgba(0,0,0,0.78) !important; }
#file_list_ui .file-row.is-unvisited   { background:transparent; }
#file_list_ui .file-row.is-validated   { background:rgba(46,125,50,0.07); border-left-color:#4caf50; color:rgba(0,0,0,0.58); }
#file_list_ui .file-row.is-skipped     { background:rgba(230,81,0,0.05);  border-left-color:#ff8f00; color:rgba(0,0,0,0.48); }
#file_list_ui .file-row.is-current        { background:rgba(21,101,192,0.09) !important; border-left-color:#1565c0 !important; color:#0d1117 !important; font-weight:600; }
#file_list_ui .file-row.is-bulk-selected  { background:rgba(21,101,192,0.05); border-left-color:#90caf9; color:rgba(0,0,0,0.62); }

/* Type badges — light */
.tbadge-data         { background:#e8f5e9; color:#2e7d32; }
.tbadge-code         { background:#e3f2fd; color:#1565c0; }
.tbadge-codebook     { background:#fff8e1; color:#e65100; }
.tbadge-supplemental { background:#f3e5f5; color:#6a1b9a; }
.tbadge-readme       { background:#e0f2f1; color:#00695c; }
.tbadge-asset        { background:#fce4ec; color:#880e4f; }
.tbadge-other        { background:#eceff1; color:#455a64; }
.tbadge-output       { background:#e0f7fa; color:#006064; }
.tbadge-software     { background:#fff3e0; color:#e65100; }

/* Data format sub-type badges — light */
.tbadge-df-tabular { background:#ecf5ec; color:#388e3c; font-size:0.72em; padding:1px 5px; border-radius:3px; font-weight:600; margin-left:3px; }
.tbadge-df-raw     { background:#fff8e1; color:#f57c00; font-size:0.72em; padding:1px 5px; border-radius:3px; font-weight:600; margin-left:3px; }

/* Data format sub-type badges — light */
.tbadge-df-tabular { background:#ecf5ec; color:#388e3c; font-size:0.72em; padding:1px 5px; border-radius:3px; font-weight:600; margin-left:3px; }
.tbadge-df-raw     { background:#fff8e1; color:#f57c00; font-size:0.72em; padding:1px 5px; border-radius:3px; font-weight:600; margin-left:3px; }

/* Type buttons — light */
.tbtn { border:1.5px solid rgba(0,0,0,0.13) !important; background:rgba(0,0,0,0.02) !important; color:rgba(0,0,0,0.45) !important; }
.tbtn:hover { background:rgba(0,0,0,0.06) !important; color:rgba(0,0,0,0.75) !important; border-color:rgba(0,0,0,0.25) !important; }
.tbtn__key { opacity:0.4; }
.tbtn-data.tbtn-active         { border-color:#2e7d32 !important; background:rgba(46,125,50,0.1) !important;   color:#1b5e20 !important; box-shadow:0 0 8px rgba(46,125,50,0.2) !important; }
.tbtn-code.tbtn-active         { border-color:#1565c0 !important; background:rgba(21,101,192,0.1) !important;  color:#0d47a1 !important; box-shadow:0 0 8px rgba(21,101,192,0.2) !important; }
.tbtn-codebook.tbtn-active     { border-color:#e65100 !important; background:rgba(230,81,0,0.1) !important;    color:#bf360c !important; box-shadow:0 0 8px rgba(230,81,0,0.2) !important; }
.tbtn-supplemental.tbtn-active { border-color:#6a1b9a !important; background:rgba(106,27,154,0.1) !important;  color:#4a148c !important; box-shadow:0 0 8px rgba(106,27,154,0.2) !important; }
.tbtn-readme.tbtn-active       { border-color:#00695c !important; background:rgba(0,105,92,0.1) !important;    color:#004d40 !important; box-shadow:0 0 8px rgba(0,105,92,0.2) !important; }
.tbtn-asset.tbtn-active        { border-color:#880e4f !important; background:rgba(136,14,79,0.1) !important;   color:#560027 !important; box-shadow:0 0 8px rgba(136,14,79,0.2) !important; }
.tbtn-other.tbtn-active        { border-color:#455a64 !important; background:rgba(69,90,100,0.1) !important;   color:#263238 !important; box-shadow:0 0 8px rgba(69,90,100,0.2) !important; }
.tbtn-output.tbtn-active       { border-color:#006064 !important; background:rgba(0,96,100,0.1) !important;    color:#004d40 !important; box-shadow:0 0 8px rgba(0,96,100,0.2) !important; }
.tbtn-software.tbtn-active     { border-color:#e65100 !important; background:rgba(230,101,0,0.1) !important;   color:#bf360c !important; box-shadow:0 0 8px rgba(230,101,0,0.2) !important; }

/* File header — light */
.file-hdr         { padding:11px 16px 10px; border-bottom:1px solid #dee2e6; background:#f8f9fa; margin-bottom:10px; }
.file-hdr__name   { color:#1f2328; }
.file-hdr__path   { color:#8c959f; }
.file-hdr__counter .num   { color:#1f2328; }
.file-hdr__counter .denom { color:#8c959f; }
.file-hdr__meta   { color:#57606a; }

/* Progress bar — light */
.dc-progress { margin:2px 0 4px; }
.dc-progress__label        { color:#57606a; }
.dc-progress__label strong { color:#1f2328; }
.dc-progress__track        { background:rgba(0,0,0,0.08); }

/* Prediction override — light */
.pred-override     { background:#fff8e1; border-color:#ffb300; color:#e65100; }
.pred-override__lbl { color:#57606a; }

/* Control bar — light */
.dc-ctrl-bar { background:#f8f9fa; border-top-color:#dee2e6; }

/* Theme toggle — light */
.theme-toggle-btn { border-color:rgba(0,0,0,0.2); color:rgba(0,0,0,0.5); }
.theme-toggle-btn:hover { border-color:rgba(0,0,0,0.4); color:rgba(0,0,0,0.8); background:rgba(0,0,0,0.04); }

/* Details — light */
details > summary { color:rgba(0,0,0,0.38); }
details > summary:hover { color:rgba(0,0,0,0.65); }
hr { border-color:#dee2e6 !important; margin:8px 0 !important; }

/* XML panel — light */
#xml_text_content { background:#fafafa !important; border:1px solid #dee2e6 !important;
                    color:#333 !important; line-height:1.6; }

/* ════════════════════════════════════════════════════════════════
   DARK MODE  — overrides everything above
   ════════════════════════════════════════════════════════════════ */

/* Bootstrap component overrides for dark mode */
[data-theme='dark'] body,
[data-theme='dark'] .bslib-sidebar-layout { background:#0d1117 !important; color:#c9d1d9 !important; }
[data-theme='dark'] .bslib-sidebar-layout > .sidebar { background:#161b22 !important; border-right-color:#30363d !important; }
[data-theme='dark'] .navbar { background:#161b22 !important; border-bottom:1px solid #30363d !important; }
[data-theme='dark'] label  { color:#8b949e !important; }
[data-theme='dark'] .form-control, [data-theme='dark'] .form-select {
  background:#21262d !important; border-color:#30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] .form-control:focus, [data-theme='dark'] .form-select:focus {
  border-color:#58a6ff !important; box-shadow:0 0 0 2px rgba(88,166,255,0.2) !important; }
[data-theme='dark'] .form-check-input { background-color:#21262d !important; border-color:#30363d !important; }
[data-theme='dark'] .form-check-input:checked { background-color:#58a6ff !important; border-color:#58a6ff !important; }
[data-theme='dark'] .form-check-label { color:#8b949e !important; }
[data-theme='dark'] .selectize-input  { background:#21262d !important; border-color:#30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] .selectize-dropdown { background:#21262d !important; border-color:#30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] .selectize-dropdown-content .option:hover,
[data-theme='dark'] .selectize-dropdown-content .option.active { background:#30363d !important; }
[data-theme='dark'] .modal-content  { background:#161b22 !important; border-color:#30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] .modal-header, [data-theme='dark'] .modal-footer { border-color:#30363d !important; }
[data-theme='dark'] .modal-title    { color:#f0f6fc !important; }
[data-theme='dark'] .btn-close      { filter:invert(1) !important; }
[data-theme='dark'] .btn-outline-secondary { border-color:#30363d !important; color:#8b949e !important; }
[data-theme='dark'] .btn-outline-secondary:hover { background:#30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] .btn-primary    { background:#58a6ff !important; border-color:#58a6ff !important; color:#0d1117 !important; font-weight:600; }
[data-theme='dark'] .btn-primary:hover { background:#79c0ff !important; border-color:#79c0ff !important; }
[data-theme='dark'] .table          { color:#c9d1d9 !important; border-color:#30363d !important; }
[data-theme='dark'] .table th       { background:#21262d !important; color:#f0f6fc !important; border-color:#30363d !important; }
[data-theme='dark'] .table td       { border-color:#21262d !important; }
[data-theme='dark'] .table-striped > tbody > tr:nth-child(odd) > td { background:rgba(255,255,255,0.02) !important; }
[data-theme='dark'] .alert-warning  { background:rgba(255,179,0,0.1) !important; border-color:rgba(255,179,0,0.3) !important; color:#e6a817 !important; }
[data-theme='dark'] .shiny-notification { background:#161b22 !important; border:1px solid #30363d !important; color:#c9d1d9 !important; }
[data-theme='dark'] pre { background:rgba(0,0,0,0.35) !important; border:1px solid #30363d !important; color:rgba(255,255,255,0.78) !important; }
[data-theme='dark'] .bslib-sidebar-layout > .main { background:#0d1117; }

/* File list — dark */
[data-theme='dark'] #file_list_ui .file-row              { color:rgba(255,255,255,0.38); }
[data-theme='dark'] #file_list_ui .file-row:hover        { background:rgba(255,255,255,0.07) !important; color:rgba(255,255,255,0.8) !important; }
[data-theme='dark'] #file_list_ui .file-row.is-validated { background:rgba(76,175,80,0.07); border-left-color:#4caf50; color:rgba(255,255,255,0.55); }
[data-theme='dark'] #file_list_ui .file-row.is-skipped   { background:rgba(255,202,40,0.06); border-left-color:#ffca28; color:rgba(255,255,255,0.45); }
[data-theme='dark'] #file_list_ui .file-row.is-current        { background:rgba(255,255,255,0.1) !important; border-left-color:#64b5f6 !important; color:#ffffff !important; font-weight:600; }
[data-theme='dark'] #file_list_ui .file-row.is-bulk-selected  { background:rgba(100,181,246,0.1); border-left-color:#64b5f6; color:rgba(255,255,255,0.7); }

/* Type badges — dark */
[data-theme='dark'] .tbadge-data         { background:rgba(76,175,80,0.22);   color:#81c784; }
[data-theme='dark'] .tbadge-code         { background:rgba(100,181,246,0.22); color:#90caf9; }
[data-theme='dark'] .tbadge-codebook     { background:rgba(255,202,40,0.22);  color:#ffd54f; }
[data-theme='dark'] .tbadge-supplemental { background:rgba(206,147,216,0.22); color:#e1bee7; }
[data-theme='dark'] .tbadge-readme       { background:rgba(77,208,225,0.22);  color:#80deea; }
[data-theme='dark'] .tbadge-asset        { background:rgba(244,143,177,0.22); color:#fce4ec; }
[data-theme='dark'] .tbadge-other        { background:rgba(144,164,174,0.22); color:#b0bec5; }
[data-theme='dark'] .tbadge-output       { background:rgba(0,188,212,0.22);   color:#80deea; }
[data-theme='dark'] .tbadge-software     { background:rgba(255,183,77,0.22);  color:#ffcc80; }
[data-theme='dark'] .tbadge-df-tabular  { background:rgba(102,187,106,0.18); color:#a5d6a7; }
[data-theme='dark'] .tbadge-df-raw      { background:rgba(255,183,77,0.18);  color:#ffe082; }

/* Type buttons — dark */
[data-theme='dark'] .tbtn { border-color:rgba(255,255,255,0.13) !important; background:rgba(255,255,255,0.04) !important; color:rgba(255,255,255,0.45) !important; }
[data-theme='dark'] .tbtn:hover { background:rgba(255,255,255,0.1) !important; color:rgba(255,255,255,0.85) !important; border-color:rgba(255,255,255,0.28) !important; }
[data-theme='dark'] .tbtn__key { opacity:0.45; }
[data-theme='dark'] .tbtn-data.tbtn-active         { border-color:#4caf50 !important; background:rgba(76,175,80,0.22) !important;   color:#a5d6a7 !important; box-shadow:0 0 10px rgba(76,175,80,0.25) !important; }
[data-theme='dark'] .tbtn-code.tbtn-active         { border-color:#64b5f6 !important; background:rgba(100,181,246,0.22) !important; color:#90caf9 !important; box-shadow:0 0 10px rgba(100,181,246,0.25) !important; }
[data-theme='dark'] .tbtn-codebook.tbtn-active     { border-color:#ffca28 !important; background:rgba(255,202,40,0.22) !important;  color:#ffd54f !important; box-shadow:0 0 10px rgba(255,202,40,0.25) !important; }
[data-theme='dark'] .tbtn-supplemental.tbtn-active { border-color:#ce93d8 !important; background:rgba(206,147,216,0.22) !important; color:#e1bee7 !important; box-shadow:0 0 10px rgba(206,147,216,0.25) !important; }
[data-theme='dark'] .tbtn-readme.tbtn-active       { border-color:#4dd0e1 !important; background:rgba(77,208,225,0.22) !important;  color:#80deea !important; box-shadow:0 0 10px rgba(77,208,225,0.25) !important; }
[data-theme='dark'] .tbtn-asset.tbtn-active        { border-color:#f48fb1 !important; background:rgba(244,143,177,0.22) !important; color:#fce4ec !important; box-shadow:0 0 10px rgba(244,143,177,0.25) !important; }
[data-theme='dark'] .tbtn-other.tbtn-active        { border-color:#90a4ae !important; background:rgba(144,164,174,0.22) !important; color:#b0bec5 !important; box-shadow:0 0 10px rgba(144,164,174,0.25) !important; }
[data-theme='dark'] .tbtn-output.tbtn-active       { border-color:#00bcd4 !important; background:rgba(0,188,212,0.22) !important;  color:#80deea !important; box-shadow:0 0 10px rgba(0,188,212,0.25) !important; }
[data-theme='dark'] .tbtn-software.tbtn-active     { border-color:#ffb300 !important; background:rgba(255,179,0,0.22) !important;  color:#ffe082 !important; box-shadow:0 0 10px rgba(255,179,0,0.25) !important; }

/* Granularity buttons — light */
.dg-btn { border:1.5px solid rgba(0,0,0,0.13) !important; background:rgba(0,0,0,0.02) !important; color:rgba(0,0,0,0.45) !important; font-size:0.8em !important; padding:3px 10px !important; }
.dg-btn:hover { background:rgba(0,0,0,0.06) !important; color:rgba(0,0,0,0.75) !important; border-color:rgba(0,0,0,0.25) !important; }
.dg-btn.dg-active { border-color:#2e7d32 !important; background:rgba(46,125,50,0.1) !important; color:#1b5e20 !important; font-weight:700; box-shadow:0 0 8px rgba(46,125,50,0.2) !important; }

/* Granularity buttons — dark */
[data-theme='dark'] .dg-btn { border-color:rgba(255,255,255,0.13) !important; background:rgba(255,255,255,0.04) !important; color:rgba(255,255,255,0.45) !important; }
[data-theme='dark'] .dg-btn:hover { background:rgba(255,255,255,0.1) !important; color:rgba(255,255,255,0.85) !important; border-color:rgba(255,255,255,0.28) !important; }
[data-theme='dark'] .dg-btn.dg-active { border-color:#4caf50 !important; background:rgba(76,175,80,0.22) !important; color:#a5d6a7 !important; box-shadow:0 0 10px rgba(76,175,80,0.25) !important; }

/* Data format buttons — light */
.df-btn { border:1.5px solid rgba(0,0,0,0.13) !important; background:rgba(0,0,0,0.02) !important; color:rgba(0,0,0,0.45) !important; font-size:0.8em !important; padding:3px 10px !important; }
.df-btn:hover { background:rgba(0,0,0,0.06) !important; color:rgba(0,0,0,0.75) !important; border-color:rgba(0,0,0,0.25) !important; }
.df-btn.df-active-tabular { border-color:#388e3c !important; background:rgba(56,142,60,0.1) !important; color:#1b5e20 !important; font-weight:700; box-shadow:0 0 8px rgba(56,142,60,0.2) !important; }
.df-btn.df-active-raw     { border-color:#f57c00 !important; background:rgba(245,124,0,0.1)  !important; color:#e65100 !important; font-weight:700; box-shadow:0 0 8px rgba(245,124,0,0.2)  !important; }

/* Data format buttons — dark */
[data-theme='dark'] .df-btn { border-color:rgba(255,255,255,0.13) !important; background:rgba(255,255,255,0.04) !important; color:rgba(255,255,255,0.45) !important; }
[data-theme='dark'] .df-btn:hover { background:rgba(255,255,255,0.1) !important; color:rgba(255,255,255,0.85) !important; border-color:rgba(255,255,255,0.28) !important; }
[data-theme='dark'] .df-btn.df-active-tabular { border-color:#66bb6a !important; background:rgba(102,187,106,0.22) !important; color:#a5d6a7 !important; box-shadow:0 0 10px rgba(102,187,106,0.25) !important; }
[data-theme='dark'] .df-btn.df-active-raw     { border-color:#ffa726 !important; background:rgba(255,167,38,0.22)  !important; color:#ffe082  !important; box-shadow:0 0 10px rgba(255,167,38,0.25)  !important; }

/* File header — dark */
[data-theme='dark'] .file-hdr         { background:rgba(255,255,255,0.025); border-bottom-color:rgba(255,255,255,0.09); }
[data-theme='dark'] .file-hdr__name   { color:#ffffff; }
[data-theme='dark'] .file-hdr__path   { color:rgba(255,255,255,0.28); }
[data-theme='dark'] .file-hdr__counter .num   { color:#ffffff; }
[data-theme='dark'] .file-hdr__counter .denom { color:rgba(255,255,255,0.35); }
[data-theme='dark'] .file-hdr__meta   { color:rgba(255,255,255,0.4); }

/* Progress bar — dark */
[data-theme='dark'] .dc-progress__label        { color:rgba(255,255,255,0.45); }
[data-theme='dark'] .dc-progress__label strong { color:rgba(255,255,255,0.85); }
[data-theme='dark'] .dc-progress__track        { background:rgba(255,255,255,0.1); }

/* Prediction override — dark */
[data-theme='dark'] .pred-override      { background:rgba(255,202,40,0.09); border-color:rgba(255,202,40,0.28); color:#ffd54f; }
[data-theme='dark'] .pred-override__lbl { color:rgba(255,255,255,0.45); }

/* Control bar — dark */
[data-theme='dark'] .dc-ctrl-bar { background:rgba(0,0,0,0.25); border-top-color:rgba(255,255,255,0.09); }

/* Theme toggle — dark */
[data-theme='dark'] .theme-toggle-btn { border-color:rgba(255,255,255,0.18); color:rgba(255,255,255,0.5); }
[data-theme='dark'] .theme-toggle-btn:hover { border-color:rgba(255,255,255,0.4); color:rgba(255,255,255,0.85); background:rgba(255,255,255,0.06); }

/* Details, hr — dark */
[data-theme='dark'] details > summary { color:rgba(255,255,255,0.38); }
[data-theme='dark'] details > summary:hover { color:rgba(255,255,255,0.68); }
[data-theme='dark'] hr { border-color:rgba(255,255,255,0.09) !important; }

/* XML panel — dark */
[data-theme='dark'] #xml_text_content { background:rgba(0,0,0,0.3) !important; border-color:rgba(255,255,255,0.09) !important; color:rgba(255,255,255,0.72) !important; }

/* Bulk selection banner */
.bulk-banner { display:flex; align-items:center; gap:8px; padding:5px 10px; margin-bottom:6px;
               border-radius:5px; font-size:0.8em; border:1px solid;
               background:rgba(21,101,192,0.07); border-color:rgba(21,101,192,0.3); color:#1565c0; }
[data-theme='dark'] .bulk-banner { background:rgba(100,181,246,0.1); border-color:rgba(100,181,246,0.3); color:#90caf9; }
.bulk-banner__count { font-weight:700; }
.bulk-banner__hint  { opacity:0.6; font-size:0.9em; }
.btn-select-uv { background:transparent !important; border:none !important; box-shadow:none !important;
                 font-size:0.72em; cursor:pointer; padding:0 !important;
                 text-decoration:underline; opacity:0.55; color:#000 !important; }
.btn-select-uv:hover { opacity:1 !important; }
[data-theme='dark'] .btn-select-uv { color:rgba(255,255,255,0.55) !important; }
[data-theme='dark'] .btn-select-uv:hover { color:rgba(255,255,255,0.9) !important; }
.btn-select-uv--delete { color:#c0392b !important; }
[data-theme='dark'] .btn-select-uv--delete { color:rgba(239,154,154,0.7) !important; }
[data-theme='dark'] .btn-select-uv--delete:hover { color:rgba(239,154,154,1) !important; }

/* Open-folder button */
.btn-open-folder { background:transparent !important; border:none !important; box-shadow:none !important;
                   font-size:1em; cursor:pointer; opacity:0.35; padding:0 !important; line-height:1;
                   transition:opacity 0.15s; margin-top:4px; display:block; }
.btn-open-folder:hover { opacity:0.85 !important; }
[data-theme='dark'] .btn-open-folder { opacity:0.3; }
[data-theme='dark'] .btn-open-folder:hover { opacity:0.8 !important; }
"

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- page_sidebar(
  title = div(
    style = "display:flex; align-items:center; gap:10px; width:100%;",
    span("Validation GUI"),
    tags$button(
      id      = "theme_toggle",
      class   = "theme-toggle-btn",
      onclick = "toggleTheme()",
      "\u2600 Light"   # updated by JS on load
    )
  ),
  theme    = bs_theme(bootswatch = "flatly"),
  fillable = TRUE,
  tags$head(
    tags$script(HTML(THEME_INIT_JS)),
    tags$script(HTML(KB_JS)),
    tags$style(HTML(APP_CSS))
  ),

  sidebar = sidebar(
    width    = 300,
    fillable = TRUE,
    div(
      style = "display:flex; align-items:flex-end; gap:6px; margin-bottom:4px;",
      div(style = "flex:1;",
          selectInput("sort_by", "Sort papers by",
                      choices  = c("Number" = "number",
                                   "Completedness" = "completedness",
                                   "Repo size" = "size"),
                      selected = "number",
                      width    = "100%")),
      div(style = "padding-bottom:1px;",
          checkboxInput("sort_desc", "\u2193 Desc", value = FALSE))
    ),
    selectInput("paper_id", "Paper", choices = character(0)),
    uiOutput("progress_bar_ui"),
    tags$hr(),
    div(
      style = "display:flex; align-items:center; justify-content:space-between; margin-bottom:4px;",
      uiOutput("bulk_count_ui"),
      div(
        style = "display:flex; gap:4px;",
        actionButton("btn_select_uv",     "Select all unvalidated", class = "btn-select-uv"),
        actionButton("btn_delete_paper",  "Delete annotations",     class = "btn-select-uv btn-select-uv--delete")
      )
    ),
    uiOutput("orphan_banner_ui"),
    div(style = "overflow-y:auto; flex:1; min-height:0;",
        uiOutput("file_list_ui"))
  ),

  # ── Main panel — flex column, footer always visible ──────────────────────────
  div(
    style = "display:flex; flex-direction:column; height:100%; overflow:hidden;",

    # Context area (takes all remaining space, scrolls internally)
    div(
      style = "flex:1; min-height:0; overflow:hidden; display:flex; flex-direction:column;",
      uiOutput("context_header_ui"),
      # Side-by-side panels
      div(
        style = "flex:1; min-height:0; display:flex; overflow:hidden;",
        # Left: paper text + folder tree
        div(
          style = "flex:1; min-width:0; overflow-y:auto; padding:0 12px 8px 16px; border-right:1px solid rgba(128,128,128,0.15);",
          uiOutput("xml_panel_ui"),
          tags$details(
            style = "margin-top:6px;",
            tags$summary("Repository tree"),
            uiOutput("folder_tree_ui")
          )
        ),
        # Right: siblings + file preview
        div(
          style = "flex:1; min-width:0; overflow-y:auto; padding:0 16px 8px 12px;",
          uiOutput("preview_ui")
        )
      )
    ),

    # Label controls — anchored at bottom
    div(
      class = "dc-ctrl-bar",
      uiOutput("bulk_banner_ui"),
      uiOutput("prediction_note_ui"),
      uiOutput("type_buttons_ui"),
      div(
        style = "display:flex; align-items:flex-end; gap:12px; margin-top:6px;",
        div(style = "flex:1; min-width:120px; max-width:220px;",
            textInput("group_val", tags$small("Group"), value = "",
                      placeholder = "ex1, shared, na …")),
        uiOutput("data_granularity_ui"),
        uiOutput("data_format_ui"),
        div(
          style = "margin-left:auto; display:flex; gap:6px; padding-bottom:4px;",
          actionButton("btn_back", "\u2190 Prev",      class = "btn-sm btn-outline-secondary"),
          actionButton("btn_skip", "Skip",              class = "btn-sm btn-outline-secondary"),
          actionButton("btn_save", "Save & Next \u2192", class = "btn-sm btn-primary")
        )
      )
    )
  )
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  rv <- reactiveValues(
    annotator     = "",
    papers        = character(0),
    paper_id      = NULL,
    structure     = NULL,
    gt            = empty_gt(),
    current_idx   = 1L,
    status        = character(0),  # named: "unvisited"/"validated"/"skipped"
    selected_type         = NA_character_,
    data_granularity_val  = "",
    data_format_val       = "",
    skipped            = integer(0),
    xml                = NULL,     # list(title, abstract, body) or NULL
    col_names          = character(0),
    paper_completion   = character(0), # named character: paper_id → "complete"|"partial"|"none"
    paper_size         = integer(0),   # named integer:   paper_id → n_files in structure.csv
    label_update_only  = FALSE,       # TRUE = updateSelectInput is label-only, skip paper reload
    bulk_selected      = integer(0)   # indices of files selected for bulk labelling
  )

  # ── T019: Startup annotator dialog ──────────────────────────────────────────

  showModal(modalDialog(
    title      = "Who is annotating?",
    textInput("annotator_input", "Your name or initials", placeholder = "e.g. LB"),
    footer     = actionButton("btn_start", "Start \u2192", class = "btn-primary"),
    easyClose  = FALSE
  ))

  observeEvent(input$btn_start, {
    name <- trimws(input$annotator_input)
    if (nchar(name) == 0) {
      showNotification("Please enter your name or initials.", type = "error")
      return()
    }
    rv$annotator <- name
    removeModal()
    papers     <- discover_papers()
    completion <- paper_is_complete(papers)
    sizes      <- get_paper_sizes(papers)
    rv$papers           <- papers
    rv$paper_completion <- completion
    rv$paper_size       <- sizes
    updateSelectInput(session, "paper_id",
                      choices  = make_paper_choices(papers, completion),
                      selected = if (length(papers) > 0) papers[1] else NULL)
  })

  # ── Sort controls ────────────────────────────────────────────────────────────

  sort_papers <- function(papers, by, desc) {
    if (length(papers) == 0) return(papers)
    ord <- switch(by,
      number = order(papers, decreasing = desc),
      completedness = {
        rank <- c(complete = 0L, partial = 1L, none = 2L)
        v <- rank[rv$paper_completion[papers]]
        v[is.na(v)] <- 2L
        order(v, decreasing = desc)
      },
      size = order(rv$paper_size[papers], decreasing = desc),
      order(papers, decreasing = desc)   # fallback
    )
    papers[ord]
  }

  observeEvent(
    list(input$sort_by, input$sort_desc),
    {
      req(length(rv$papers) > 0, !is.null(input$sort_by))
      cur    <- isolate(input$paper_id)
      sorted <- sort_papers(rv$papers, input$sort_by, isTRUE(input$sort_desc))
      rv$papers <- sorted   # keep rv$papers in sync so auto-advance respects sort
      choices <- make_paper_choices(sorted, rv$paper_completion)
      updateSelectInput(session, "paper_id",
                        choices  = choices,
                        selected = cur)
    },
    ignoreInit = TRUE
  )

  # ── T008: Paper selection ────────────────────────────────────────────────────

  observeEvent(input$paper_id, {
    if (isTRUE(rv$label_update_only)) {
      rv$label_update_only <- FALSE
      return()
    }
    req(nchar(trimws(input$paper_id)) > 0)
    pid <- input$paper_id
    struct <- tryCatch(load_structure(pid), error = function(e) {
      showNotification(paste("Failed to load structure.csv:", conditionMessage(e)),
                       type = "error")
      NULL
    })
    req(!is.null(struct))

    rv$paper_id  <- pid
    rv$structure <- struct
    rv$xml       <- load_paper_xml(pid)

    col_path  <- file.path(get_outputs_dir(), "osf", pid, "columns.csv")
    col_names <- character(0)
    if (file.exists(col_path)) {
      tryCatch({
        col_df <- read.csv(col_path, stringsAsFactors = FALSE)
        if ("column_name" %in% names(col_df)) {
          nms       <- trimws(col_df$column_name)
          col_names <- unique(nms[!is.na(nms) & nchar(nms) >= 2])
        }
      }, error = function(e) invisible(NULL))
    }
    rv$col_names <- col_names
    session$sendCustomMessage("set_xml_columns", list(terms = col_names))

    gt <- read_gt(pid)
    rv$gt <- gt

    # GT rows whose rel_path no longer exists in structure.csv. Usually caused
    # by pipeline transforms that happen post-annotation — multi-object RData /
    # multi-sheet Excel files getting exploded into per-object CSVs (originals
    # deleted), or dir sanitization rewriting parent paths. Surfaced in the
    # sidebar so the annotator can clear stale entries and re-label the new
    # files manually.
    rv$orphan_gt <- if (nrow(gt) > 0)
      setdiff(gt$rel_path, struct$rel_path) else character(0)

    n  <- nrow(struct)
    st <- setNames(rep("unvisited", n), struct$rel_path)
    st[names(st) %in% gt$rel_path] <- "validated"
    rv$status  <- st
    rv$skipped <- integer(0)

    first_uv <- which(st != "validated")
    rv$current_idx <- if (length(first_uv) > 0) unname(first_uv[1]) else 1L

    load_file(rv$current_idx)
  })

  # ── T017: Load file into controls ───────────────────────────────────────────

  load_file <- function(idx) {
    req(!is.null(rv$structure))
    if (idx < 1L || idx > nrow(rv$structure)) return()
    row    <- rv$structure[idx, ]
    gt_row <- rv$gt[rv$gt$rel_path == row$rel_path, ]
    if (nrow(gt_row) > 0) {
      rv$selected_type        <- gt_row$type_gt[1]
      rv$data_granularity_val <- if (!is.na(gt_row$data_granularity_gt[1]))
                                   gt_row$data_granularity_gt[1] else ""
      rv$data_format_val      <- if ("data_format_gt" %in% names(gt_row) &&
                                      !is.na(gt_row$data_format_gt[1]))
                                   gt_row$data_format_gt[1] else ""
      updateTextInput(session, "group_val", value = gt_row$group_gt[1])
    } else {
      rv$selected_type        <- if (!is.na(row$type)) row$type else "other"
      rv$data_granularity_val <- if ("data_granularity" %in% names(row) &&
                                      !is.na(row$data_granularity))
                                   row$data_granularity else ""
      rv$data_format_val      <- if ("data_format" %in% names(row) &&
                                      !is.na(row$data_format))
                                   row$data_format else ""
      updateTextInput(session, "group_val", value = row$group)
    }
  }

  # ── T012: data_granularity disable for non-data types ───────────────────────

  observe({
    sel     <- isolate(rv$selected_type)
    is_data <- !is.na(sel) && sel == "data"
    if (!is_data && nzchar(isolate(rv$data_granularity_val)))
      rv$data_granularity_val <- ""
    session$sendCustomMessage("set_data_granularity_disabled", list(disabled = !is_data))
  }) |> bindEvent(rv$selected_type, ignoreInit = FALSE)

  # data_format disable for non-data types
  observe({
    sel     <- isolate(rv$selected_type)
    is_data <- !is.na(sel) && sel == "data"
    if (!is_data && nzchar(isolate(rv$data_format_val)))
      rv$data_format_val <- ""
    session$sendCustomMessage("set_data_format_disabled", list(disabled = !is_data))
  }) |> bindEvent(rv$selected_type, ignoreInit = FALSE)

  # ── T009/T010: File list click + type button clicks ──────────────────────────

  observeEvent(input$file_click, {
    req(!is.null(rv$structure))
    click <- input$file_click
    idx   <- suppressWarnings(as.integer(click$idx))
    if (is.na(idx) || idx < 1L || idx > nrow(rv$structure)) return()

    if (isTRUE(click$shift)) {
      # Range select: anchor at current_idx, extend to clicked idx
      lo <- min(rv$current_idx, idx)
      hi <- max(rv$current_idx, idx)
      rv$bulk_selected <- seq.int(lo, hi)
      rv$current_idx   <- idx
      load_file(idx)
    } else if (isTRUE(click$meta)) {
      # Toggle individual file without navigating
      if (idx %in% rv$bulk_selected) {
        rv$bulk_selected <- rv$bulk_selected[rv$bulk_selected != idx]
      } else {
        rv$bulk_selected <- sort(unique(c(rv$bulk_selected, idx)))
      }
    } else {
      # Normal click: clear selection, navigate
      rv$bulk_selected <- integer(0)
      rv$current_idx   <- idx
      load_file(idx)
    }
  })

  for (.i in seq_along(TYPE_MAP)) {
    local({
      type_val <- TYPE_MAP[[.i]]
      btn_id   <- paste0("type_btn_", type_val)
      observeEvent(input[[btn_id]], {
        rv$selected_type <- type_val
      }, ignoreInit = TRUE)
    })
  }

  # ── T021/T022: Keyboard dispatch ─────────────────────────────────────────────

  observeEvent(input$key_press, {
    k <- input$key_press$key
    switch(k,
      "1" = { rv$selected_type <- "data" },
      "2" = { rv$selected_type <- "code" },
      "3" = { rv$selected_type <- "codebook" },
      "4" = { rv$selected_type <- "supplemental" },
      "5" = { rv$selected_type <- "readme" },
      "6" = { rv$selected_type <- "asset" },
      "7" = { rv$selected_type <- "output" },
      "8" = { rv$selected_type <- "other" },
      "9" = { rv$selected_type <- "software" },
      "i" = {
        if (!is.na(rv$selected_type) && rv$selected_type == "data")
          rv$data_granularity_val <- if (rv$data_granularity_val == "individual") "" else "individual"
      },
      "c" = {
        if (!is.na(rv$selected_type) && rv$selected_type == "data")
          rv$data_granularity_val <- if (rv$data_granularity_val == "combined") "" else "combined"
      },
      "t" = {
        if (!is.na(rv$selected_type) && rv$selected_type == "data")
          rv$data_format_val <- if (rv$data_format_val == "tabular") "" else "tabular"
      },
      "r" = {
        if (!is.na(rv$selected_type) && rv$selected_type == "data")
          rv$data_format_val <- if (rv$data_format_val == "raw") "" else "raw"
      },
      "g"           = { session$sendCustomMessage("focus_group", list()) },
      "tab"         = { do_skip() },
      "cmd_enter"   = { do_save() },
      "cmd_bracket" = { do_back() },
      "cmd_slash"   = { show_kb_help() },
      "escape"      = { rv$bulk_selected <- integer(0) },
      "page_up"     = { navigate_paper(-1L) },
      "page_down"   = { navigate_paper(+1L) }
    )
  })

  # ── T013: Save action ────────────────────────────────────────────────────────

  do_save <- function() {
    req(!is.null(rv$structure), !is.na(rv$selected_type), nchar(rv$annotator) > 0)

    # Targets: bulk selection (if active) or just the current file
    targets <- if (length(rv$bulk_selected) > 1) rv$bulk_selected else rv$current_idx
    targets  <- targets[targets >= 1L & targets <= nrow(rv$structure)]
    if (length(targets) == 0L) return()

    dg_save  <- if (rv$selected_type == "data" && nzchar(rv$data_granularity_val))
                  rv$data_granularity_val else NA_character_
    df_save  <- if (rv$selected_type == "data" && nzchar(rv$data_format_val))
                  rv$data_format_val else NA_character_
    now      <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
    grp      <- trimws(input$group_val)

    for (i in targets) {
      row     <- rv$structure[i, ]
      new_row <- data.frame(
        paper_id             = rv$paper_id,
        rel_path             = row$rel_path,
        type_gt              = rv$selected_type,
        group_gt             = grp,
        data_granularity_gt  = dg_save,
        data_format_gt       = df_save,
        validated_at         = now,
        annotator            = rv$annotator,
        stringsAsFactors     = FALSE
      )
      rv$gt <- upsert_gt(rv$gt, new_row)
      rv$status[row$rel_path] <- "validated"
    }

    write_gt(rv$paper_id, rv$gt)
    rv$skipped       <- rv$skipped[!rv$skipped %in% targets]
    rv$bulk_selected <- integer(0)

    advance_to_next()
  }

  observeEvent(input$btn_save, { do_save() })

  # ── T014: Skip action ────────────────────────────────────────────────────────

  do_skip <- function() {
    req(!is.null(rv$structure))
    idx <- rv$current_idx
    if (idx >= 1L && idx <= nrow(rv$structure)) {
      rp <- rv$structure$rel_path[idx]
      if (rv$status[rp] != "validated") rv$status[rp] <- "skipped"
      rv$skipped <- unique(c(rv$skipped, idx))
    }
    advance_to_next()
  }

  observeEvent(input$btn_skip, { do_skip() })

  # ── T014: Back action ────────────────────────────────────────────────────────

  do_back <- function() {
    req(!is.null(rv$structure))
    new_idx <- max(1L, rv$current_idx - 1L)
    rv$current_idx <- new_idx
    load_file(new_idx)
  }

  observeEvent(input$btn_back, { do_back() })

  # ── Bulk selection actions ───────────────────────────────────────────────────

  observeEvent(input$btn_clear_selection, {
    rv$bulk_selected <- integer(0)
  })

  observeEvent(input$btn_select_uv, {
    req(!is.null(rv$structure))
    rv$bulk_selected <- which(rv$status != "validated")
  })

  # ── Delete all annotations for current paper ─────────────────────────────────

  observeEvent(input$btn_delete_paper, {
    req(!is.null(rv$paper_id))
    showModal(modalDialog(
      title     = "Delete annotations",
      p(sprintf("Delete all ground-truth annotations for paper %s? This cannot be undone.", rv$paper_id)),
      footer    = tagList(
        modalButton("Cancel"),
        actionButton("confirm_delete_paper", "Delete", class = "btn-danger")
      ),
      easyClose = TRUE
    ))
  })

  observeEvent(input$confirm_delete_paper, {
    removeModal()
    pid      <- rv$paper_id
    gt_file  <- file.path(get_gt_dir(), "osf", paste0(pid, ".csv"))
    if (file.exists(gt_file)) file.remove(gt_file)

    # Reset GT state and file statuses for this paper
    rv$gt     <- empty_gt()
    if (!is.null(rv$structure)) {
      rv$status <- setNames(rep("unvisited", nrow(rv$structure)),
                            rv$structure$rel_path)
    }
    rv$skipped        <- integer(0)
    rv$bulk_selected  <- integer(0)
    rv$current_idx    <- 1L
    load_file(1L)

    # Update paper completion label in selector
    rv$paper_completion[pid] <- "none"
    rv$label_update_only     <- TRUE
    updateSelectInput(session, "paper_id",
                      choices  = make_paper_choices(rv$papers, rv$paper_completion),
                      selected = pid)
    showNotification(paste0("Annotations deleted for paper ", pid), type = "message", duration = 3)
  })

  # ── Open current file's folder in Finder ─────────────────────────────────────

  observeEvent(input$btn_open_folder, {
    req(!is.null(rv$structure))
    idx <- rv$current_idx
    if (idx < 1L || idx > nrow(rv$structure)) return()
    folder <- dirname(rv$structure$path[idx])
    system2("open", folder)
  })

  # ── Paper navigation (PageUp / PageDown) ────────────────────────────────────

  navigate_paper <- function(delta) {
    papers  <- rv$papers
    cur_pos <- match(rv$paper_id, papers)
    if (is.na(cur_pos)) return()
    new_pos <- cur_pos + delta
    if (new_pos < 1L || new_pos > length(papers)) return()
    updateSelectInput(session, "paper_id", selected = papers[new_pos])
  }

  # ── Advance to next unvalidated file ────────────────────────────────────────

  advance_to_next <- function() {
    req(!is.null(rv$structure))
    idx        <- rv$current_idx
    candidates <- which(rv$status != "validated")
    forward    <- candidates[candidates > idx]

    if (length(forward) > 0) {
      rv$current_idx <- unname(forward[1])
      load_file(unname(forward[1]))
    } else if (length(candidates) > 0) {
      rv$current_idx <- unname(candidates[1])
      load_file(unname(candidates[1]))
    } else {
      papers     <- rv$papers
      cur_paper  <- rv$paper_id
      cur_pos    <- match(cur_paper, papers)
      # Mark current paper complete and rebuild labeled choices
      rv$paper_completion[cur_paper] <- "complete"
      new_choices <- make_paper_choices(papers, rv$paper_completion)

      # Jump to the next *unfinished* paper (skip already-complete ones)
      remaining   <- papers[seq_along(papers) > cur_pos]
      next_paper  <- {
        incomplete <- remaining[rv$paper_completion[remaining] != "complete"]
        if (length(incomplete) > 0) incomplete[1L] else NULL
      }

      if (!is.null(next_paper)) {
        showNotification(paste0("Paper complete! Moving to ", next_paper),
                         type = "message", duration = 3)
        updateSelectInput(session, "paper_id",
                          choices  = new_choices,
                          selected = next_paper)
      } else {
        showNotification("All papers complete!", type = "message", duration = 5)
        rv$label_update_only <- TRUE
        updateSelectInput(session, "paper_id",
                          choices  = new_choices,
                          selected = cur_paper)
      }
    }
  }

  # ── T023: Keyboard help modal ────────────────────────────────────────────────

  show_kb_help <- function() {
    showModal(modalDialog(
      title     = "Keyboard shortcuts",
      size      = "l",
      easyClose = TRUE,
      tags$table(
        class = "table table-sm table-bordered",
        tags$thead(tags$tr(tags$th("Key"), tags$th("Action"))),
        tags$tbody(
          tags$tr(tags$td(HTML("<kbd>1</kbd>\u2013<kbd>8</kbd>")),
                  tags$td("Select type: data / code / codebook / supplemental / readme / asset / other / output")),
          tags$tr(tags$td(HTML("<kbd>I</kbd>")),
                  tags$td("Toggle individual (active only when type = data)")),
          tags$tr(tags$td(HTML("<kbd>C</kbd>")),
                  tags$td("Toggle combined (active only when type = data)")),
          tags$tr(tags$td(HTML("<kbd>G</kbd>")),
                  tags$td("Move focus to the group text input")),
          tags$tr(tags$td(HTML("<kbd>\u2318\u23ce</kbd>")),
                  tags$td("Save labels and advance to next unvalidated file")),
          tags$tr(tags$td(HTML("<kbd>Tab</kbd>")),
                  tags$td("Skip current file (no save)")),
          tags$tr(tags$td(HTML("<kbd>\u2318[</kbd>")),
                  tags$td("Go back to previous file")),
          tags$tr(tags$td(HTML("<kbd>\u2318/</kbd>")),
                  tags$td("Show this keyboard reference")),
          tags$tr(tags$td(HTML("<kbd>Shift</kbd>+click")),
                  tags$td("Range-select files for bulk labelling")),
          tags$tr(tags$td(HTML("<kbd>\u2318</kbd>+click")),
                  tags$td("Toggle individual file into bulk selection")),
          tags$tr(tags$td(HTML("<kbd>Esc</kbd>")),
                  tags$td("Clear bulk selection"))
        )
      ),
      footer = modalButton("Close")
    ))
  }

  # ── Rendered outputs ──────────────────────────────────────────────────────────

  # Bulk selection count (sidebar, above file list)
  output$bulk_count_ui <- renderUI({
    n <- length(rv$bulk_selected)
    if (n == 0L) return(NULL)
    tags$span(
      style = "font-size:0.72em; font-weight:600; color:#1565c0;",
      sprintf("%d selected", n)
    )
  })

  # Bulk banner (control bar, above type buttons)
  output$bulk_banner_ui <- renderUI({
    n <- length(rv$bulk_selected)
    if (n <= 1L) return(NULL)
    tags$div(
      class = "bulk-banner",
      tags$span(class = "bulk-banner__count", sprintf("%d files selected", n)),
      tags$span(class = "bulk-banner__hint", "\u2014 type + Save applies to all"),
      tags$span(style = "margin-left:auto;",
        actionButton("btn_clear_selection", "Clear",
                     class = "btn-sm btn-outline-secondary",
                     style = "padding:1px 8px; font-size:0.8em;")
      )
    )
  })

  # Progress bar
  output$progress_bar_ui <- renderUI({
    req(!is.null(rv$structure))
    n_v <- sum(rv$status == "validated")
    n_t <- length(rv$status)
    pct <- if (n_t > 0) round(100 * n_v / n_t) else 0
    tags$div(
      class = "dc-progress",
      tags$div(
        class = "dc-progress__label",
        HTML(sprintf("<strong>%d</strong> / %d validated", n_v, n_t)),
        tags$span(sprintf("%d%%", pct))
      ),
      tags$div(
        class = "dc-progress__track",
        tags$div(class = "dc-progress__fill",
                 style = sprintf("width:%d%%", pct))
      )
    )
  })

  # Apply pipeline dir-sanitization rule (0_index.R step 2 / helper.R
  # `sanitize_basename`) to each component of a rel_path. Used to map a
  # pre-sanitize GT rel_path onto its post-sanitize structure rel_path.
  sanitize_relpath <- function(rp) {
    if (is.na(rp) || !nzchar(rp)) return(rp)
    max_words <- if (exists("MAX_DIR_WORDS")) MAX_DIR_WORDS else 5L
    parts <- strsplit(rp, "/", fixed = TRUE)[[1]]
    # Pipeline sanitizes directory names only — the filename (last component)
    # is preserved verbatim. Apply the same boundary here.
    n <- length(parts)
    if (n <= 1) return(rp)
    dirs <- parts[seq_len(n - 1L)]
    fname <- parts[n]
    fixed <- vapply(dirs, function(name) {
      # Skip components already clean (matches the guard in 0_index.R:217)
      if (!grepl("[^A-Za-z0-9_.\\-]", name)) return(name)
      words <- strsplit(trimws(name), "\\s+")[[1]]
      words <- gsub("[^A-Za-z0-9_\\-]", "", words)
      words <- words[nchar(words) > 0]
      paste(head(words, max_words), collapse = "_")
    }, character(1))
    paste(c(fixed, fname), collapse = "/")
  }

  # For an orphan GT rel_path, return its sanitized counterpart if and only if
  # it (a) differs from the original, (b) is present in structure.csv,
  # (c) is not already covered by another GT row. Otherwise NA — not repointable.
  resolve_orphan_repoint <- function(rp) {
    if (is.null(rv$structure) || is.null(rv$gt)) return(NA_character_)
    candidate <- sanitize_relpath(rp)
    if (identical(candidate, rp)) return(NA_character_)
    if (!candidate %in% rv$structure$rel_path) return(NA_character_)
    if (candidate %in% rv$gt$rel_path) return(NA_character_)
    candidate
  }

  # Orphan-GT banner: stale GT entries whose rel_path is not in structure.csv
  # (e.g. xlsm/RData exploded into CSVs after annotation; sanitize renamed
  # a parent dir). Annotator can drop the stale entry and re-label manually,
  # or Repoint when the path differs only by directory sanitization.
  output$orphan_banner_ui <- renderUI({
    req(!is.null(rv$orphan_gt))
    if (length(rv$orphan_gt) == 0) return(NULL)
    rows <- lapply(seq_along(rv$orphan_gt), function(i) {
      rp        <- rv$orphan_gt[i]
      repoint   <- resolve_orphan_repoint(rp)
      tags$div(
        style = "display:flex; gap:6px; padding:3px 6px; font-size:11px; align-items:center;",
        tags$span(rp,
                  title = rp,
                  style = "flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:monospace;"),
        if (!is.na(repoint)) tags$button(
          "Repoint",
          title   = sprintf("Rewrite to: %s", repoint),
          class   = "btn btn-sm btn-outline-primary",
          style   = "padding:0 6px; font-size:10px; line-height:1.4;",
          onclick = sprintf(
            "Shiny.setInputValue('orphan_repoint_click', %d, {priority:'event'})",
            i)
        ),
        tags$button(
          "Drop",
          class   = "btn btn-sm btn-outline-danger",
          style   = "padding:0 6px; font-size:10px; line-height:1.4;",
          onclick = sprintf(
            "Shiny.setInputValue('orphan_del_click', %d, {priority:'event'})",
            i)
        )
      )
    })
    tagList(
      tags$details(open = NA,
        tags$summary(
          style = "color:#e65100; font-weight:600; cursor:pointer; padding:4px 0;",
          sprintf("⚠ %d stale GT entr%s (file no longer on disk)",
                  length(rv$orphan_gt),
                  if (length(rv$orphan_gt) == 1) "y" else "ies")
        ),
        tags$div(
          style = "max-height:160px; overflow-y:auto; border-top:1px solid rgba(128,128,128,0.2); margin-top:2px;",
          rows
        )
      ),
      tags$hr(style = "margin:6px 0;")
    )
  })

  # Drop a stale GT row when "Drop" is clicked in the orphan banner.
  observeEvent(input$orphan_del_click, {
    req(!is.null(rv$orphan_gt), !is.null(rv$paper_id))
    i <- as.integer(input$orphan_del_click)
    if (is.na(i) || i < 1L || i > length(rv$orphan_gt)) return()
    rp <- rv$orphan_gt[i]
    rv$gt        <- rv$gt[rv$gt$rel_path != rp, , drop = FALSE]
    rv$orphan_gt <- rv$orphan_gt[-i]
    write_gt(rv$paper_id, rv$gt)
    showNotification(paste0("Dropped stale GT: ", rp),
                     type = "message", duration = 3)
  })

  # Repoint a stale GT row to its sanitized rel_path (Mode 3: dir was renamed
  # by pipeline sanitization after annotation). Rewrites the rel_path in place.
  observeEvent(input$orphan_repoint_click, {
    req(!is.null(rv$orphan_gt), !is.null(rv$paper_id))
    i <- as.integer(input$orphan_repoint_click)
    if (is.na(i) || i < 1L || i > length(rv$orphan_gt)) return()
    rp     <- rv$orphan_gt[i]
    new_rp <- resolve_orphan_repoint(rp)
    if (is.na(new_rp)) {
      showNotification(paste0("Cannot repoint: ", rp), type = "warning",
                       duration = 4)
      return()
    }
    rv$gt$rel_path[rv$gt$rel_path == rp] <- new_rp
    rv$orphan_gt    <- rv$orphan_gt[-i]
    rv$status[new_rp] <- "validated"
    write_gt(rv$paper_id, rv$gt)
    showNotification(paste0("Repointed GT → ", new_rp),
                     type = "message", duration = 3)
  })

  # T009: File list
  output$file_list_ui <- renderUI({
    req(!is.null(rv$structure))
    cur  <- rv$current_idx
    bulk <- rv$bulk_selected
    rows <- lapply(seq_len(nrow(rv$structure)), function(i) {
      row      <- rv$structure[i, ]
      stat     <- rv$status[row$rel_path]
      is_cur   <- identical(i, cur)
      is_bulk  <- !is_cur && i %in% bulk

      css_class <- paste(
        "file-row",
        if (is_cur)              "is-current",
        if (is_bulk)             "is-bulk-selected",
        if (stat == "validated") "is-validated",
        if (stat == "skipped")   "is-skipped",
        if (stat == "unvisited") "is-unvisited"
      )

      status_icon <- switch(stat,
        "validated" = "\u2713",   # ✓
        "skipped"   = "\u2013",   # –
        "\u00b7"                  # ·
      )

      # Show GT type if validated, else LLM prediction
      type_shown <- if (stat == "validated") {
        gt_row <- rv$gt[rv$gt$rel_path == row$rel_path, ]
        if (nrow(gt_row) > 0) gt_row$type_gt[1] else row$type
      } else {
        row$type
      }
      abbrev <- if (!is.na(type_shown) && type_shown %in% names(TYPE_ABBREV))
        TYPE_ABBREV[type_shown]
      else if (!is.na(type_shown))
        substr(type_shown, 1, 3)
      else
        NA_character_

      df_badge <- if (isTRUE(row$type == "data") &&
                       "data_format" %in% names(row) &&
                       !is.na(row$data_format))
        tags$span(class = paste0("tbadge-df-", row$data_format), row$data_format)
      else
        NULL

      tags$div(
        class   = css_class,
        onclick = sprintf("fileRowClick(event,%d)", i),
        tags$span(class = "file-row__status", status_icon),
        tags$span(class = "file-row__name",   row$filename),
        if (!is.na(abbrev))
          tags$span(class = paste0("file-row__type tbadge-", type_shown), abbrev),
        df_badge
      )
    })
    do.call(tagList, rows)
  })

  # T010: Type buttons
  output$type_buttons_ui <- renderUI({
    sel  <- rv$selected_type
    btns <- lapply(seq_along(TYPE_MAP), function(i) {
      val       <- TYPE_MAP[[i]]
      is_active <- !is.na(sel) && sel == val
      cls       <- paste0("btn tbtn tbtn-", val, if (is_active) " tbtn-active" else "")
      actionButton(
        inputId = paste0("type_btn_", val),
        label   = HTML(sprintf(
          '<span class="tbtn__key">%d</span><span class="tbtn__label">%s</span>',
          i, val
        )),
        class = cls
      )
    })
    div(class = "type-btn-row", do.call(tagList, btns))
  })

  # T011: Granularity buttons
  output$data_granularity_ui <- renderUI({
    val <- rv$data_granularity_val
    mk_btn <- function(id, label, key, v) {
      is_active <- !is.na(val) && val == v
      actionButton(id,
        HTML(sprintf('<span class="tbtn__key">%s</span><span class="tbtn__label">%s</span>',
                     key, label)),
        class = paste0("btn dg-btn", if (is_active) " dg-active" else "")
      )
    }
    div(style = "display:flex; flex-direction:column; gap:3px;",
      tags$small("data_granularity"),
      div(style = "display:flex; gap:6px;",
        mk_btn("btn_dg_individual", "individual", "I", "individual"),
        mk_btn("btn_dg_combined",   "combined",   "C", "combined")
      )
    )
  })

  observeEvent(input$btn_dg_individual, {
    rv$data_granularity_val <- if (rv$data_granularity_val == "individual") "" else "individual"
  }, ignoreInit = TRUE)

  observeEvent(input$btn_dg_combined, {
    rv$data_granularity_val <- if (rv$data_granularity_val == "combined") "" else "combined"
  }, ignoreInit = TRUE)

  # Data format buttons
  output$data_format_ui <- renderUI({
    val <- rv$data_format_val
    mk_btn <- function(id, label, key, v) {
      is_active <- !is.na(val) && val == v
      actionButton(id,
        HTML(sprintf('<span class="tbtn__key">%s</span><span class="tbtn__label">%s</span>',
                     key, label)),
        class = paste0("btn df-btn", if (is_active) paste0(" df-active-", v) else "")
      )
    }
    div(style = "display:flex; flex-direction:column; gap:3px;",
      tags$small("data_format"),
      div(style = "display:flex; gap:6px;",
        mk_btn("btn_df_tabular", "tabular", "T", "tabular"),
        mk_btn("btn_df_raw",     "raw",     "R", "raw")
      )
    )
  })

  observeEvent(input$btn_df_tabular, {
    rv$data_format_val <- if (rv$data_format_val == "tabular") "" else "tabular"
  }, ignoreInit = TRUE)

  observeEvent(input$btn_df_raw, {
    rv$data_format_val <- if (rv$data_format_val == "raw") "" else "raw"
  }, ignoreInit = TRUE)

  # T034: Prediction mismatch note
  output$prediction_note_ui <- renderUI({
    req(!is.null(rv$structure))
    idx <- rv$current_idx
    if (idx < 1L || idx > nrow(rv$structure)) return(NULL)
    machine <- rv$structure$type[idx]
    sel     <- rv$selected_type
    if (!is.na(sel) && !is.na(machine) && sel != machine) {
      tags$div(
        class = "pred-override",
        tags$span(class = "pred-override__lbl", "LLM predicted:"),
        tags$span(
          class = paste0("file-row__type tbadge-", machine),
          style = "padding:2px 7px; font-size:0.8em;",
          machine
        ),
        tags$span(class = "pred-override__lbl",
                  style = "margin-left:4px;",
                  "\u2192 overriding")
      )
    }
  })

  # T031: Context header
  output$context_header_ui <- renderUI({
    req(!is.null(rv$structure))
    idx <- rv$current_idx
    if (idx < 1L || idx > nrow(rv$structure)) return(NULL)
    row  <- rv$structure[idx, ]
    path <- row$path

    fsize <- tryCatch({
      s <- file.info(path)$size
      if (is.na(s) || is.null(s)) "?"
      else if (s >= 1e9) sprintf("%.1f GB", s / 1e9)
      else if (s >= 1e6) sprintf("%.1f MB", s / 1e6)
      else if (s >= 1e3) sprintf("%.1f KB", s / 1e3)
      else paste0(as.integer(s), " B")
    }, error = function(e) "?")

    sentinel_note <- if (isTRUE(row$is_sentinel)) {
      tags$div(
        class = "alert alert-warning py-1 px-2 mb-2",
        style = "font-size:0.8em;",
        tags$strong("Aggregate folder"),
        " \u2014 labels apply to the folder as a whole."
      )
    }

    tags$div(
      class = "file-hdr",
      sentinel_note,
      tags$div(
        class = "file-hdr__top",
        tags$div(
          style = "flex:1; min-width:0;",
          tags$div(class = "file-hdr__name", row$filename),
          tags$div(class = "file-hdr__path", row$rel_path)
        ),
        tags$div(
          class = "file-hdr__counter",
          tags$span(class = "num", as.character(idx)),
          tags$span(class = "denom", sprintf("/ %d", nrow(rv$structure))),
          actionButton("btn_open_folder", "\U0001f4c2",
                       class = "btn-open-folder",
                       title = "Open folder in Finder")
        )
      ),
      tags$div(
        class = "file-hdr__meta",
        tags$span(toupper(row$ext)),
        tags$span(class = "file-hdr__dot", "\u00b7"),
        tags$span(fsize),
        tags$span(class = "file-hdr__dot", "\u00b7"),
        tags$span(
          class = paste0("file-row__type tbadge-", row$type),
          style = "padding:2px 7px; font-size:0.78em;",
          row$type
        ),
        tags$span(
          class = "file-row__type",
          style = "padding:2px 7px; font-size:0.78em; border-radius:3px; font-weight:700; background:rgba(128,128,128,0.12); color:inherit; opacity:0.7;",
          paste("grp:", row$group)
        ),
        if (!is.na(row$data_granularity) && row$data_granularity == "individual")
          tags$span(
            class = "file-row__type tbadge-codebook",
            style = "padding:2px 7px; font-size:0.78em;",
            "individual"
          )
      )
    )
  })

  # T033: Folder tree
  output$folder_tree_ui <- renderUI({
    req(!is.null(rv$structure))
    cur_rp <- if (rv$current_idx >= 1L && rv$current_idx <= nrow(rv$structure))
      rv$structure$rel_path[rv$current_idx] else ""

    lines <- mapply(function(rp, fn, tp, grp) {
      depth  <- length(strsplit(rp, "/", fixed = TRUE)[[1]]) - 1L
      indent <- paste(rep("  ", max(0L, depth)), collapse = "")
      marker <- if (rp == cur_rp) "\u25cf" else " "
      sprintf("%s%s %-28s  [%s/%s]", indent, marker,
              substr(fn, 1, 28), tp, grp)
    }, rv$structure$rel_path, rv$structure$filename,
       rv$structure$type,     rv$structure$group,
       SIMPLIFY = TRUE)

    tags$pre(
      style = "font-size:0.72em; max-height:220px; overflow-y:auto; margin:0;",
      paste(lines, collapse = "\n")
    )
  })

  # T032+T033: File preview + sibling list
  output$preview_ui <- renderUI({
    req(!is.null(rv$structure))
    idx <- rv$current_idx
    if (idx < 1L || idx > nrow(rv$structure)) return(NULL)
    row    <- rv$structure[idx, ]
    parent <- dirname(row$rel_path)

    sibs <- rv$structure[dirname(rv$structure$rel_path) == parent, ]
    sib_lines <- sprintf(
      "  %s%s  [%s]",
      sibs$filename,
      ifelse(sibs$rel_path == row$rel_path, "  \u2190 current", ""),
      sibs$type
    )
    sib_block <- tags$div(
      tags$small(tags$strong(sprintf("Siblings in %s/", parent))),
      tags$pre(
        style = "font-size:0.75em; max-height:200px; overflow-y:auto; margin-bottom:4px;",
        paste(sib_lines, collapse = "\n")
      )
    )

    preview_block <- tags$div(
      style = "border:1px solid rgba(128,128,128,0.2); border-radius:4px; padding:8px;",
      render_preview(row$path, row$ext)
    )

    tagList(sib_block, tags$hr(), preview_block)
  })

  # ── Paper XML preview (searchable, highlighting fully client-side) ───────────

  output$xml_panel_ui <- renderUI({
    xml <- rv$xml
    if (is.null(xml)) return(NULL)

    parts <- character(0)
    if (nchar(xml$title) > 0)
      parts <- c(parts, paste0("[TITLE]\n", xml$title))
    if (nchar(xml$abstract) > 0)
      parts <- c(parts, paste0("[ABSTRACT]\n", xml$abstract))
    if (nchar(xml$body) > 0)
      parts <- c(parts, paste0("[BODY]\n", xml$body))
    raw_text <- paste(parts, collapse = "\n\n---\n\n")

    tags$details(
      open  = "",
      style = "margin-top:10px; margin-bottom:4px;",
      tags$summary(
        "Paper text",
        tags$span(id = "xml_hit_count",
                  style = "font-size:0.85em; margin-left:8px; font-weight:400; text-transform:none; letter-spacing:0;",
                  "")
      ),
      div(
        style = "padding:6px 0 2px;",
        div(
          style = "display:flex; align-items:center; gap:6px; margin-bottom:6px;",
          tags$input(
            id          = "xml_search_input",
            type        = "text",
            class       = "form-control form-control-sm",
            placeholder = "Search paper text\u2026",
            oninput     = "xmlSetSearch(this.value)",
            style       = "max-width:320px;"
          )
        ),
        div(
          id    = "xml_text_content",
          style = paste(
            "max-height:60vh; overflow-y:auto; font-size:0.77em;",
            "white-space:pre-wrap; word-break:break-word;",
            "border-radius:4px; padding:8px; line-height:1.55;"
          ),
          HTML(htmltools::htmlEscape(raw_text))
        )
      )
    )
  })

  # ── T037: Session summary on exit ────────────────────────────────────────────

  onStop(function() {
    pid       <- isolate(rv$paper_id)
    struct    <- isolate(rv$structure)
    if (is.null(pid) || is.null(struct)) return()
    status    <- isolate(rv$status)
    gt        <- isolate(rv$gt)
    annotator <- isolate(rv$annotator)
    n_v  <- sum(status == "validated")
    n_t  <- length(status)
    corr <- 0L
    if (nrow(gt) > 0) {
      m <- merge(gt,
                 struct[, intersect(c("rel_path", "type", "group", "data_granularity"),
                                    names(struct))],
                 by = "rel_path", all.x = TRUE)
      corr <- sum(!is.na(m$type_gt) & !is.na(m$type) & m$type_gt != m$type,
                  na.rm = TRUE)
    }
    gt_path <- file.path(get_gt_dir(), "osf", paste0(pid, ".csv"))
    cat("\n=== Validation session complete ===\n")
    cat(sprintf("  Annotator:   %s\n",  annotator))
    cat(sprintf("  Paper:       %s\n",  pid))
    cat(sprintf("  Validated:   %d / %d files\n", n_v, n_t))
    cat(sprintf("  Corrections: %d  (type differs from LLM prediction)\n", corr))
    cat(sprintf("  Saved to:    %s\n",  gt_path))
    cat("===================================\n\n")
  })
}

shinyApp(ui, server)
