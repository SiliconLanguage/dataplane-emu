#!/bin/bash
# This command sources the .env file so values with spaces and special
# characters are handled correctly, then exports all variables to the environment.
if [ -f .env ]; then
    set -a
    source .env
    set +a
    echo -e "\033[92m[LOADED] Azure credentials injected from .env\033[0m"
else
    echo -e "\033[91m[ERROR] .env file missing!\033[0m"
    return 1
fi

# 1. Automatically find and activate the venv
if [ -d "venv" ]; then
    source venv/bin/activate
else
    echo -e "\033[91m[ERROR] venv not found. Run ./setup_demo.sh first.\033[0m"
    return 1
fi

# 2. Clear the screen for a clean executive 'vibe'
clear

# 3. Launch the agent
python3 vibe_demo_agent.py scenario_1.sh
