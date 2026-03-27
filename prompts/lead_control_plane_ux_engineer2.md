You are the Lead Control Plane UX Engineer for our Agentic AI infrastructure. We need to update our local Python wrapper (`vibe_demo_agent.py`) to support a multi-cloud demonstration, transitioning from Azure Cobalt 100 to AWS Graviton3.

Please implement the following refactoring and new features:

1. **Parameter Processing:**
   - Update `argparse` to accept two distinct arguments: `--azure-host` and `--aws-host`. 
   - Ensure the script fails gracefully if these are not provided.

2. **The Interactive Multi-Cloud Pivot:**
   - After the Azure SSH subprocess and final TTS voiceover complete, pause the script and print the following prompt in Cyan (`\033[36m`):
     `>> Demo Agent: 'Would you like to verify the zero-copy data plane portability on AWS Graviton3 (Neoverse-V1)? (y/n): '`
   - Read the user's input. If the user types anything other than 'y' or 'yes', exit the script gracefully.

3. **The AWS Graviton3 "No-Fluff" Execution:**
   - If the user selects 'y', immediately clear the terminal and reprint our "SiliconLanguage" `λ` ASCII logo.
   - Do NOT use any TTS voiceovers or artificial typing delays for this stage. It must be brutally fast to contrast with the earlier explanation.
   - Use `subprocess.Popen` to execute the SSH command to the AWS host: 
     `ssh ec2-user@<aws_host_value> '/home/ec2-user/project/launch_arm_neoverse_demo_deterministic.sh --executive-demo'`
   - Stream the `stdout` directly to the terminal, preserving all ANSI colors.

4. **The `#OpenToWork` Closer:**
   - Once the AWS subprocess completes, print the following final sign-off in Magenta (`\033[35m`) and Cyan (`\033[36m`):
     
     ===========================================================================
     [SYSTEM] Multi-Cloud Bare-Metal Portability Confirmed.
     [STATUS] Azure Cobalt 100 (N2) & AWS Graviton3 (V1) fully saturated.
     
     >> Ping is currently exploring Principal Architect / Director opportunities.
     >> #OpenToWork | #AgenticAI | #HardwareSoftwareCoDesign
     ===========================================================================

CRITICAL: Keep all changes strictly within the Python UI logic. Do not modify any underlying C++ or bash scripts. Ensure the interactive input `input()` call does not block or break the terminal's ANSI state.
