# Analysis of Terminal Output Transparency Issues

## Overview

This document outlines potential points of confusion and lack of transparency in the terminal output of a dataset indexing tool, from the perspective of a researcher trying to validate and trust the results.

The main issue is not a lack of information, but a mismatch between what is shown and what a user needs to interpret correctness, reliability, and usability.

---

## 1. Unclear Final Outcome per Dataset

The output does not clearly state whether a dataset:
- succeeded
- partially succeeded
- failed

Example:
Stage 3: psychds
  [psychds] all         ERROR: replacement has 3 rows, data has 100

Questions:
- Is the dataset unusable?
- Is partial output saved?
- Should this be investigated?

Similarly:
skipped — no columns.csv

Unclear whether this is expected behavior or an issue.

Problem: No explicit final verdict per dataset.

---

## 2. Opaque Role of the LLM

The LLM is used in multiple steps:
- classification
- granularity inference
- codebook parsing

Example:
→  data / ex2         combined

Unclear:
- What input was used (file name, content, structure)?
- What alternative classifications were possible?
- How confident the system is

Problem: Critical decisions are made by a black box without explanation.

---

## 3. Granularity is Poorly Defined

Example:
granularity  individual  ^Exp[0-9]+_[0-9]+\.dat$

Issues:
- Meaning of "individual" vs "combined" is not explained
- Regex appears without context
- Relationship between folder-level and file-level aggregation is unclear

Also:
data_granularity: 154 individual, 0 combined

vs earlier:
→ data / ex2 combined

Problem: Internal terminology is exposed without user-level explanation.

---

## 4. File Type Classification is Underspecified

Categories include:
- data
- asset
- suppl
- code
- softw
- output
- other

But:
- No definitions are provided
- Boundaries are unclear

Examples:
CSV as output — data boundary
output plots classified not as asset

Problem: Inconsistent and unexplained classification logic.

---

## 5. Silent Failures in Column Extraction

Example:
Extracting columns + statistics from 0 data file(s)
No columns extracted

Despite:
data=154

Unclear:
- Why files were skipped
- Whether formats are unsupported
- Whether parsing failed

Problem: Silent failure with no explanation.

---

## 6. Codebook Matching is Hard to Interpret

Example:
coverage: {"unmatched_in_data":10,"matched":1}

Questions:
- Is this good or bad?
- What counts as a match?

Also:
labelled=1  unlabelled=78
status=ok

Problem: “ok” does not reflect poor matching performance.

---

## 7. PsychDS Stage Errors are Cryptic

Example:
ERROR: replacement has 109 rows, data has 185

Issues:
- Looks like a raw internal error
- No explanation of context
- No guidance for resolution

Another example:
no_data_files

Despite earlier indication that data exists.

Problem: Internal errors leak without interpretation.

---

## 8. Inconsistent Grouping Logic

Group labels include:
- ex1, ex2, ...
- shared
- pilot1, pilot2
- variants like ex6b

Example:
complex groups: pilot6a + ex4b-ex4g letter suffixes + sharedex4b edge case

Unclear:
- How groups are inferred
- Whether based on filenames, folders, or content

Problem: Grouping logic is not transparent.

---

## 9. Misleading Progress Indicators

Example:
Querying LLM [====] 1/1

Issues:
- Always shows 1/1
- No sense of total workload
- Not informative for long processes

Problem: Progress bars do not reflect real progress.

---

## 10. Skips, Fallbacks, and Retries Lack Context

Examples:
[skipped: unreadable or empty]
fallback to LLM
structured extraction failed
retry 1/4

Unclear:
- Why failures occur
- What fallback changes
- Whether retries indicate instability

Problem: Important events are logged but not explained.

---

## 11. Metrics Lack Interpretation

Examples:
columns=2074
labelled=405

Missing:
- Benchmarks
- Expected ranges
- Warnings for low-quality results

Problem: Raw numbers without context are not actionable.

---

## 12. No Cross-Stage Sanity Checks

Situations that should raise warnings:
- Data detected but no columns extracted
- Codebook present but minimal matches
- Errors in later stages after earlier success

No explicit signals such as:
- “Dataset likely problematic”
- “Low confidence result”

Problem: No system-level validation feedback.

---

## Summary

Key issues:
- Internal logic is exposed without explanation
- Failures are logged but not interpreted
- LLM decisions are opaque
- No clear trust signal for dataset usability

---

## Recommended Improvements

1. Add explicit dataset-level verdict:
   - success / partial / failed
   - with short explanation

2. Provide minimal reasoning for LLM decisions

3. Turn silent failures into warnings

4. Define core concepts:
   - granularity
   - data vs output
   - grouping logic

5. Add sanity checks and quality indicators:
   - low codebook match warning
   - parsing failure warning
   - inconsistent stage outputs

---

## Bottom Line

The output is technically rich, but not decision-friendly.  
A researcher can follow the steps, but cannot confidently judge correctness or usability.
