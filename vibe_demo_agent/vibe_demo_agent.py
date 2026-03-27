#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import argparse
from dotenv import load_dotenv

# Load the .env file immediately
load_dotenv()

# Pre-flight Credential Check
SPEECH_KEY = os.environ.get('SPEECH_KEY')
SPEECH_REGION = os.environ.get('SPEECH_REGION')

CYAN = '\033[96m'
GREEN = '\033[92m'
BLUE = '\033[94m'
YELLOW = '\033[93m'
PURPLE = '\033[95m'
RED = '\033[1;91m'
RESET = '\033[0m'

_LOGO_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logo.sh')

def print_logo():
    subprocess.run(['bash', _LOGO_SCRIPT])
    print(f"  >> SYSTEMS ARCHITECTURE | HW/SW CO-DESIGN | AI INFRASTRUCTURE\n")

if not SPEECH_KEY or not SPEECH_REGION:
    print(f"\n{RED}[SYSTEM HALTED] Azure Speech Credentials Missing.{RESET}")
    print(f"{RED}The .env file is either missing or empty.{RESET}")
    print(f"{RED}Please run 'source setup_demo.sh' to initialize the environment before presenting.{RESET}\n")
    sys.exit(1)

# Only import the Azure SDK if we know we have the keys to use it
import azure.cognitiveservices.speech as speechsdk

def play_audio(file_path):
    if sys.platform == "darwin":
        subprocess.run(["afplay", file_path])
    else:
        subprocess.run(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", file_path])

def speak(text, index):
    print(f"{CYAN}>> Demo Agent: '{text}'{RESET}")
    speech_file_path = f"/tmp/vibe_demo_voice_{index}.wav"

    speech_config = speechsdk.SpeechConfig(subscription=SPEECH_KEY, region=SPEECH_REGION)
    speech_config.speech_synthesis_voice_name = "en-US-ChristopherNeural"
    speech_config.set_speech_synthesis_output_format(
        speechsdk.SpeechSynthesisOutputFormat.Riff48Khz16BitMonoPcm
    )

    # No AudioOutputConfig: synthesize to memory so result.audio_data is the
    # complete WAV. Writing audio_data once avoids the double-write corruption
    # that occurs when AudioOutputConfig(filename=...) writes the file and then
    # the manual write overwrites it with a potentially empty or partial buffer.
    speech_synthesizer = speechsdk.SpeechSynthesizer(speech_config=speech_config, audio_config=None)

    result = speech_synthesizer.speak_text(text)
    if result.reason != speechsdk.ResultReason.SynthesizingAudioCompleted:
        print(f"{YELLOW}[WARNING] TTS failed (reason: {result.reason}). Skipping voice line.{RESET}")
        return
    with open(speech_file_path, "wb") as f:
        f.write(result.audio_data)
        f.flush()
        os.fsync(f.fileno())
    play_audio(speech_file_path)

def trigger_easter_egg(voice_index):
    print_logo()

    pitch = (
        "Bridging hyperscale infrastructure and bare-metal performance "
        "requires global vision. "
        "Ping is exploring Partner Architect or Director-level opportunities. "
        "He leads teams and AI agents building systems "
        "that bypass the kernel, not the details. "
        "Let's scale the next-gen AI data plane together."
    )
    speak(pitch, voice_index)

def run_demo(script_path):
    try:
        with open(script_path, 'r') as file:
            lines = file.readlines()
    except FileNotFoundError:
        print(f"{RED}Error: Could not find script at {script_path}{RESET}")
        sys.exit(1)

    print_logo()
    print(f"{GREEN}Starting Vibe Demo: {script_path}{RESET}\n")
    voice_index = 0
    
    in_block = False
    block_delimiter = ""
    block_buffer = ""

    try:
        for original_line in lines:
            line = original_line.strip()
            
            if in_block:
                block_buffer += original_line
                if line == block_delimiter:
                    in_block = False
                    subprocess.run(block_buffer, shell=True, executable='/bin/bash')
                    time.sleep(0.5)
                continue

            if not line:
                continue
                
            if line.startswith("# VOICE:"):
                text = line.replace("# VOICE:", "").strip()
                speak(text, voice_index)
                voice_index += 1
            elif line.startswith("# HIRE_ME"):
                trigger_easter_egg(voice_index)
                voice_index += 1
            elif line.startswith("# WAIT:"):
                seconds = float(line.replace("# WAIT:", "").strip())
                time.sleep(seconds)
            elif line.startswith("#"):
                continue
            else:
                if "cat <<" in line:
                    in_block = True
                    parts = line.split("<<")
                    block_delimiter = parts[1].strip().strip("'").strip('"')
                    block_buffer = original_line
                else:
                    # Silently run echo and sleep to preserve the magic trick
                    if line.startswith("echo") or line.startswith("sleep"):
                        subprocess.run(line, shell=True, executable='/bin/bash')
                    else:
                        print(f"\n{GREEN}$ {line}{RESET}")
                        subprocess.run(line, shell=True, executable='/bin/bash')
                        time.sleep(0.5)
                        
    except KeyboardInterrupt:
        print(f"\n{CYAN}Demo interrupted. Exiting gracefully.{RESET}")
        sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run a bash script with Azure Neural TTS voiceovers.")
    parser.add_argument("script", help="Path to the .sh demo script")
    args = parser.parse_args()
    run_demo(args.script)
