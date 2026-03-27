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

# 1. OS Dependency Check (Audio Routing)
if ! command -v ffplay &> /dev/null; then
    echo -e "${MAGENTA}[SYSTEM] ffplay not found. Installing ffmpeg for neural audio routing...${RESET}"
    sudo apt update && sudo apt install -y ffmpeg
else
    echo -e "${GREEN}[SYSTEM] Audio dependencies verified (ffmpeg).${RESET}"
fi

echo -e "\n\033[96m[1/5] Creating fresh native WSL venv...\033[0m"
rm -rf venv
python3 -m venv venv
source venv/bin/activate

echo -e "\033[96m[2/5] Installing SDKs (Azure + Dotenv)...\033[0m"
pip install --upgrade pip
pip install azure-cognitiveservices-speech python-dotenv

echo -e "\033[96m[3/5] Building dataplane-emu engine...\033[0m"
(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cmake -B build -DWITH_SPDK=OFF . && cmake --build build -j"$(nproc)")

echo -e "\033[96m[4/5] Installing passwordless sudo for XFS demo probe...\033[0m"
sudo bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/install-demo-sudoers.sh"

echo -e "\033[96m[5/5] Verifying xfsprogs...\033[0m"
if ! command -v mkfs.xfs &>/dev/null; then
    echo -e "\033[93m[WARN] mkfs.xfs not found. Install with: sudo apt install xfsprogs\033[0m"
else
    echo -e "\033[92m  mkfs.xfs found.\033[0m"
fi

#prompt will instantly shrink down and transform back to: 
#(silicon-fabric) vibe_demo_agent λ
# 1. Ensure you are in the correct directory
cd ~/dataplane-emu/vibe_demo_agent
# 2. Deactivate the current long-prompt environment
deactivate 2>/dev/null || true

# 3. Rename the default (venv) tag to our proprietary brand
sed -i 's/(venv)/(silicon-fabric)/g' venv/bin/activate

# 4. Inject the short, dynamic Monad prompt at the end of the activation script
echo 'export PS1="\[\033[90m\](silicon-fabric) \[\033[36m\]\W \[\033[35m\]λ \[\033[0m\]"' >> venv/bin/activate

# 5. Reload the freshly fixed environment
source venv/bin/activate

echo -e "\n\033[92m[SUCCESS] Environment locked. Credentials saved to .env\033[0m"
echo -e "\033[93mNext: Run 'source run_demo.sh' to start the pitch.\033[0m"
