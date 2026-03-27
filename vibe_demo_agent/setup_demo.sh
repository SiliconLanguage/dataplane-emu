#!/bin/bash
clear
echo -e "\033[96m>>> SiliconLanguage Foundry Setup <<<\033[0m\n"

# 1. Load existing .env if it exists
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi

# 2. Check for missing variables
if [ -z "$SPEECH_KEY" ]; then
    read -p "Enter Azure Speech Key: " SPEECH_KEY
    echo "SPEECH_KEY=\"$SPEECH_KEY\"" >> .env
fi

if [ -z "$SPEECH_REGION" ]; then
    read -p "Enter Azure Region (e.g., westus2): " SPEECH_REGION
    echo "SPEECH_REGION=\"$SPEECH_REGION\"" >> .env
fi

echo -e "\n\033[96m[1/4] Creating fresh native WSL venv...\033[0m"
rm -rf venv
python3 -m venv venv
source venv/bin/activate

echo -e "\033[96m[2/4] Installing SDKs (Azure + Dotenv)...\033[0m"
pip install --upgrade pip
pip install azure-cognitiveservices-speech python-dotenv

echo -e "\n\033[92m[SUCCESS] Environment locked. Credentials saved to .env\033[0m"
echo -e "\033[93mNext: Run 'source run_demo.sh' to start the pitch.\033[0m"
