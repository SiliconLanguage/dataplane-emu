#!/bin/bash

# Stop the script if any command fails
set -e

# Define file paths relative to the repository root
INPUT_FILE="docs/publications/eliminating-os-kernel/README.md"
OUTPUT_FILE="docs/publications/eliminating-os-kernel/eliminating-os-kernel.pdf"

echo "Generating whitepaper PDF from $INPUT_FILE..."

# Run Pandoc with the single-column, professional whitepaper configuration
pandoc "$INPUT_FILE" \
  -o "$OUTPUT_FILE" \
  --pdf-engine=xelatex \
  -V author="Ping Long" \
  -V institution="SiliconLanguage Foundry" \
  -V geometry:margin=1in \
  -V fontsize=11pt \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue \
  -V mainfont="Liberation Serif" \
  -V sansfont="Liberation Sans" \
  -V monofont="DejaVu Sans Mono" \
  -V linestretch=1.2

echo "Success! PDF generated at: $OUTPUT_FILE"