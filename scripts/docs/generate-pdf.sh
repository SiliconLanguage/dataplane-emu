#!/bin/bash

# Define file paths relative to the repository root
INPUT_FILE="docs/publications/eliminating-os-kernel/README.md"
OUTPUT_FILE="docs/publications/eliminating-os-kernel/eliminating-os-kernel.pdf"

echo "Generating whitepaper PDF from $INPUT_FILE..."

# Run Pandoc with the single-column, professional whitepaper configuration
pandoc "$INPUT_FILE" \
  -o "$OUTPUT_FILE" \
  --pdf-engine=xelatex \
  -V geometry:margin=1in \
  -V fontsize=11pt \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue

echo "Success! PDF generated at: $OUTPUT_FILE"