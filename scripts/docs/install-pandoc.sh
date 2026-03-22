#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "Updating package lists..."
sudo apt update

echo "Installing Pandoc and LaTeX dependencies..."
# texlive-xetex provides the xelatex engine
# texlive-latex-extra provides advanced geometry and table packages
sudo apt install -y pandoc texlive-xetex texlive-fonts-recommended texlive-latex-extra

echo "Installation complete! You can now generate PDFs."