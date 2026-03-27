data_dir <- file.path(dirname(dirname(rstudioapi::getSourceEditorContext()$path)), "data")
if (!dir.exists(data_dir)) data_dir <- "data"

paper_dirs <- list.dirs(data_dir, recursive = FALSE)
cat("Counting files in", length(paper_dirs), "paper directories...\n")

file_counts <- sapply(paper_dirs, function(d) {
  length(list.files(d, recursive = TRUE, all.files = FALSE))
})

cat("Summary:\n")
print(summary(file_counts))
cat("\nFile count percentiles:\n")
print(quantile(file_counts, probs = c(0.5, 0.75, 0.9, 0.95, 0.99, 1.0)))

# Cap x-axis at 95th percentile to show the bulk of the distribution
x_max <- as.integer(quantile(file_counts, 0.95))
cat(sprintf("\nPlotting up to %d files (95th percentile); %d repos excluded as outliers\n",
            x_max, sum(file_counts > x_max)))

counts_clipped <- file_counts[file_counts <= x_max]

# Break at every 20 files
breaks <- seq(0, x_max + 20, by = 20)

hist(
  counts_clipped,
  breaks = breaks,
  main = sprintf("Files per Data Repository (capped at %d, n=%d)", x_max, length(counts_clipped)),
  xlab = "Number of Files",
  ylab = "Number of Papers",
  col = "steelblue",
  border = "white",
  xlim = c(0, x_max)
)

# Vertical lines every 20 files (= each LLM batch boundary)
abline(v = breaks, col = adjustcolor("red", alpha.f = 0.4), lty = 2)
