# 🚀 dataplane-emu: Infrastructure Automation

This directory contains the automation suite to provision and manage a high-performance [AWS Graviton3](https://aws.amazon.com/ec2/instance-types/c7g/) development environment. It is optimized for **SPDK (Storage Performance Development Kit)**, **Kernel Bypass**, and high-speed C++ storage development.

## ⚙️ 0. Prerequisites & Tooling

Before running the automation scripts or deploying infrastructure, ensure you have the following tools installed and configured on your local machine:

### A. AWS CLI
The AWS Command Line Interface is required to interact with your AWS account and launch instances.
1. **Install:** Follow the [official AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) for your operating system (Windows, macOS, or Linux).
2. **Configure:** Open your terminal and run the configuration wizard:
   ```bash
   aws configure
   ```
   You will be prompted to enter your:
   * **AWS Access Key ID**
   * **AWS Secret Access Key**
   * **Default region name** (e.g., `us-east-1` or `us-west-2`)
   * **Default output format** (e.g., `json`)

### B. Terraform
Terraform is used for any infrastructure-as-code (IaC) state management in this project.
1. **Install:** Follow the [official HashiCorp Terraform installation guide](https://developer.hashicorp.com/terraform/install) for your OS. Here are quick commands for common environments:
   * **macOS (Homebrew):** ```bash
     brew tap hashicorp/tap
     brew install hashicorp/tap/terraform
     ```
   * **Windows (Chocolatey):** ```powershell
     choco install terraform
     ```
     *(Alternatively, download the binary directly from the official guide).*
   * **Linux (Ubuntu/Debian):**
     ```bash
     wget -O - [https://apt.releases.hashicorp.com/gpg](https://apt.releases.hashicorp.com/gpg) | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
     echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] [https://apt.releases.hashicorp.com](https://apt.releases.hashicorp.com) $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
     sudo apt update && sudo apt install terraform
     ```
2. **Verify:** Run `terraform --version` to ensure it is installed correctly.

---

## 📂 Directory Structure

* `provision-graviton.sh`: AWS CLI script to launch a `c7gd` instance with local NVMe.
* `iam-role-setup.sh`: Sets up IAM permissions for passwordless access to AWS services.
* `cloud-init-userdata.yaml`: Bootstraps the OS, installs `clang`, and sets up the SPDK rehydration service.
* `start-graviton.ps1`: Windows PowerShell script to sync local IP with Cloudflare and SSH into the machine.
* `.env.template`: A template for your private infrastructure secrets.

---

## 🔒 1. Security & Secrets Management (Setup)

To prevent leaking sensitive info like your GitHub Personal Access Token or Cloudflare API Tokens, we use environment variables.

**Create your local secret file:**
```bash
cp scripts/spdk-aws/.env.template scripts/spdk-aws/.env
```

**Edit `.env`:** Add your actual credentials.
* `CF_API_TOKEN`: Your Cloudflare DNS Token.
* `GITHUB_TOKEN`: Your GitHub Classic PAT.
* `DEV_DOMAIN`: Your target domain (e.g., `graviton.siliconlanguage.com`).
* `DEV_SSH_KEY`: The local path to your `.pem` key.

*Note: Double check that `.env` is added to `.gitignore`. **Never commit this file.***

---

## 🏗️ 2. Provisioning the Infrastructure

### Step A: One-time IAM Setup
Run this once per AWS account to create the necessary execution roles:
```bash
bash scripts/spdk-aws/iam-role-setup.sh
```

### Step B: Launch the Instance
This script finds the latest Amazon Linux 2023 ARM64 AMI and launches the Graviton node:
```bash
cd scripts/spdk-aws/
bash provision-graviton.sh
```

---

## 🛰️ 3. Connecting to the Instance

### From Windows (PowerShell)
The `start-graviton.ps1` script automatically updates your Cloudflare DNS to point to your current home/office IP and launches the SSH session.

**Load your environment variables:**
```powershell
Get-Content scripts/spdk-aws/.env | Foreach-Object {
    $name, $value = $_.Split('=', 2)
    [System.Environment]::SetEnvironmentVariable($name, $value.Trim('"'), "Process")
}
```

**Run the gateway script:**
```powershell
.\scripts\spdk-aws\start-graviton.ps1
```

---

## 🛠️ 4. Hybrid Storage Topology

The automation implements a specialized storage layout:
* **EBS Volume (Persistence):** The OS, compiler (`clang`), and SPDK source reside here.
* **NVMe Instance Store (Performance):** The ephemeral Nitro SSD is left raw and automatically bound to the `uio_pci_generic` user-space driver on boot via the `spdk-dev.service`.

### Manual Rehydration
If you need to manually re-bind the hardware or check hugepage allocation:
```bash
sudo /usr/local/bin/rehydrate-spdk.sh
```

---

## 🧪 5. Verification

Once logged in, verify the Kernel Bypass is active by running the SPDK identify tool:
```bash
cd ~/project/spdk
sudo LD_LIBRARY_PATH=./build/lib ./build/bin/spdk_nvme_identify -r "trtype:PCIe traddr:0000:00:1f.0"
```

If you see "Amazon EC2 NVMe Instance Storage", the bypass is successful.