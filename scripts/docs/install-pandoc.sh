#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "Updating package lists..."
sudo apt update

echo "Installing Pandoc, LaTeX engines, and professional fonts..."
# texlive-xetex: PDF engine
# fonts-liberation: For 'Liberation Serif' (Modern Times New Roman alternative)
# fonts-dejavu: For 'DejaVu Sans Mono' (Clean code blocks)
sudo apt install -y \
  pandoc \
  texlive-xetex \
  texlive-fonts-recommended \
  texlive-latex-extra \
  fonts-liberation \
  fonts-dejavu

echo "Refreshing font cache..."
sudo fc-cache -f -v

echo "Installation complete! The environment is ready for professional PDF generation."