<!-- markdownlint-disable MD013 MD033 MD051 -->
# Mini-Project 09: Automated Terraform Drift Detection and Alerting

> **Domain**: 06. Infrastructure as Code (IaC)  
> **Level**: Intermediate to Advanced  
> **Infrastructure**: Local (LocalStack / Docker + Cron) or Cloud (AWS Free Tier + GitHub Actions)  

---

## 📋 Table of Contents

1. [Project Overview & Learning Objectives](#-project-overview--learning-objectives)
2. [What is Infrastructure Drift? Causes & Security Risks](#-what-is-infrastructure-drift-causes--security-risks)
3. [How Terraform Detects Drift: `-detailed-exitcode` & JSON Schema](#-how-terraform-detects-drift--detailed-exitcode--json-schema)
4. [The Drift Detection & Alerting Architecture](#-the-drift-detection--alerting-architecture)
5. [Slack Block Kit Notifications & Rich Formatting](#-slack-block-kit-notifications--rich-formatting)
6. [Remediation Strategies: Detection vs Self-Healing](#-remediation-strategies-detection-vs-self-healing)
7. [Architecture & Execution Flow](#-architecture--execution-flow)
8. [Directory & File Structure](#-directory--file-structure)
9. [Prerequisites & Environment Setup](#-prerequisites--environment-setup)
10. [Step-by-Step Hands-On Guide](#-step-by-step-hands-on-guide)
11. [Deploying to Real Production AWS Cloud & Slack](#-deploying-to-real-production-aws-cloud--slack)
12. [Automated Testing & Verification Suite](#-automated-testing--verification-suite)
13. [Troubleshooting & FAQs](#-troubleshooting--faqs)
14. [Teardown & Cleanup](#-teardown--cleanup)

---

## 🎯 Project Overview & Learning Objectives

In an ideal Site Reliability Engineering (SRE) ecosystem, 100% of cloud resources are provisioned and modified exclusively through Infrastructure as Code (IaC) pull requests. In reality, **Infrastructure Drift** occurs continuously:

- An engineer logs into the AWS console during an incident to open port `8080` or `22` and forgets to codify the change.
- A rogue automation script alters resource tags or deletes a critical subnet.
- Security configurations quietly diverge, creating compliance violations and blind spots.

This mini-project demonstrates how to design, automate, and operate an **Automated Terraform / OpenTofu Drift Detection and Alerting System**.

The system periodically refreshes real cloud state against declared Terraform code, leverages `terraform plan -detailed-exitcode` to catch discrepancies, parses plan diffs into structured JSON, formats rich **Slack Block Kit** alert cards, and optionally triggers automated **self-healing remediation**.

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                    AUTOMATED TERRAFORM DRIFT DETECTION PIPELINE                     │
├──────────────────────────┬───────────────────────────┬──────────────────────────────┤
│ 1. Speculative Planning  │ 2. JSON Diff Parsing      │ 3. SRE Alerting & Healing    │
│    • -detailed-exitcode  │    • terraform show -json │    • Slack Block Kit cards   │
│    • Exit 0: In-Sync     │    • Attribute diffs      │    • Terminal visual banners │
│    • Exit 2: Drift Found │    • Rogue rule extraction│    • Auto-heal (--remediate) │
└──────────────────────────┴───────────────────────────┴──────────────────────────────┘
```

### What You Will Learn

- **Drift Mechanics**: Understanding why cloud state diverges from declarative state and how Terraform detects discrepancies.
- **Detailed Exit Codes**: Utilizing `terraform plan -detailed-exitcode` in automated CI/CD and cron pipelines (`0` = in-sync, `2` = drift detected, `1` = error).
- **JSON Plan Analysis**: Parsing `terraform show -json` output to extract attribute-level modifications (`before` vs `after` states).
- **Security Group Ingress Analysis**: Detecting unmanaged firewall ports and rogue CIDR blocks.
- **Slack Block Kit Formatting**: Constructing rich, interactive Slack incident notifications with status colors, diff snippets, and action buttons.
- **Automated Self-Healing Remediation**: Applying targeted reconciliation (`terraform apply <binary-plan>`) to bring live cloud infrastructure back in sync.
- **Offline Local Emulation**: Testing drift injection and detection against LocalStack / Moto with zero cloud costs.

---

## ⚠️ What is Infrastructure Drift? Causes & Security Risks

**Infrastructure Drift** is the divergence between the actual state of resources in your cloud environment and the expected state defined in your Git-versioned IaC repository.

```text
               Git Repository                    Real Cloud Environment
         ┌────────────────────────┐            ┌────────────────────────┐
         │ resource "aws_sg" {    │            │ Security Group in AWS  │
         │   ingress {            │  DIVERGES  │   ingress:             │
         │     from_port = 80     │ ─────────► │     • port 80 (HTTP)   │
         │     from_port = 443    │  (DRIFT!)  │     • port 443 (HTTPS) │
         │   }                    │            │   🚨• port 8080 (ROGUE)│
         │ }                      │            │   🚨• port 22 (SSH)    │
         └────────────────────────┘            └────────────────────────┘
```

### Primary Causes of Drift

1. **Emergency Hotfixes ("ClickOps")**: Responders manually altering security groups or routing tables during outages and never opening a follow-up PR.
2. **Shadow IT & Console Modifications**: Developers testing quick fixes directly in staging or production.
3. **Out-of-Band Automation**: External scripts or third-party SaaS tools creating or modifying tags and permissions without Terraform awareness.

### Critical Risks

- **Security Exposure**: Rogue ports (e.g. database ports or SSH open to `0.0.0.0/0`) remain unnoticed for months.
- **Accidental Deletion during Subsequent Deploys**: A future `terraform apply` may unintentionally overwrite or destroy critical manual configurations.
- **Compliance Failures**: SOC2, ISO27001, and PCI-DSS audits require verifiable proof that cloud state strictly matches audited code.

---

## 🔬 How Terraform Detects Drift: `-detailed-exitcode` & JSON Schema

### 1. The `-detailed-exitcode` Flag

By default, `terraform plan` returns an exit code of `0` regardless of whether changes are detected. Passing `-detailed-exitcode` changes this behavior:

| Exit Code | Meaning | SRE Pipeline Action |
| :---: | :--- | :--- |
| **`0`** | **Succeeded, diff is empty** | Infrastructure is In-Sync. Log OK and complete pipeline. |
| **`1`** | **Errored** | Plan failed (syntax error, network issue, credential failure). Trigger error alert. |
| **`2`** | **Succeeded, changes present** | **DRIFT DETECTED!** Parse diff, dispatch Slack alert, and optionally remediate. |

### 2. Exporting Plan Diffs to Structured JSON

When drift occurs (exit code 2), the plan binary is converted to JSON via:

```bash
terraform show -json logs/tfplan.binary > logs/tfplan.json
```

The JSON schema exposes `resource_changes`:

```json
{
  "format_version": "1.2",
  "resource_changes": [
    {
      "address": "aws_security_group.web_sg",
      "type": "aws_security_group",
      "change": {
        "actions": ["update"],
        "before": {
          "ingress": [
            { "from_port": 80, "to_port": 80, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"] },
            { "from_port": 443, "to_port": 443, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"] },
            { "from_port": 8080, "to_port": 8080, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"] }
          ]
        },
        "after": {
          "ingress": [
            { "from_port": 80, "to_port": 80, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"] },
            { "from_port": 443, "to_port": 443, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"] }
          ]
        }
      }
    }
  ]
}
```

Notice that Terraform plans to **remove** port 8080 because it exists in the cloud (`before`) but is absent from the declared code (`after`)!

---

## 🏛️ The Drift Detection & Alerting Architecture

```text
                          ┌────────────────────────┐
                          │   Cron / CI Pipeline   │
                          └───────────┬────────────┘
                                      │ (Trigger every hour)
                                      ▼
                          ┌────────────────────────┐
                          │   drift_detector.sh    │
                          └───────────┬────────────┘
                                      │
                 ┌────────────────────┴────────────────────┐
                 │ terraform plan -detailed-exitcode       │
                 ▼                                         ▼
         ┌───────────────┐                         ┌───────────────┐
         │ Exit Code: 0  │                         │ Exit Code: 2  │
         │  (In Sync)    │                         │(Drift Found!) │
         └───────┬───────┘                         └───────┬───────┘
                 │                                         │
                 ▼                                         ▼
         ┌───────────────┐                         ┌───────────────┐
         │ Log "In Sync" │                         │ terraform show│
         │ (Green Status)│                         │   -json ...   │
         └───────────────┘                         └───────┬───────┘
                                                           │
                                                           ▼
                                                   ┌───────────────┐
                                                   │slack_notifier │
                                                   │     .py       │
                                                   └───────┬───────┘
                                                           │
                                ┌──────────────────────────┴──────────────────────────┐
                                ▼                                                     ▼
                    ┌─────────────────────────┐                           ┌─────────────────────────┐
                    │ Slack Block Kit Webhook │                           │ Optional Auto-Healing   │
                    │  (Rich Team Alert Card) │                           │  --remediate (Apply)    │
                    └─────────────────────────┘                           └─────────────────────────┘
```

---

## 💬 Slack Block Kit Notifications & Rich Formatting

[`slack_notifier.py`](slack_notifier.py) converts the raw JSON plan into Slack's **Block Kit** format:

- **Color Coded**: Crimson Red (`#E01E5A`) for drift alerts; Forest Green (`#2EB67D`) for in-sync health checks.
- **Context Metadata**: Environment (`production`), detection timestamp, total drifted resource count.
- **Actionable Diffs**:
  - `🚨 Rogue Ingress Rule in Cloud: port 8080-8080/tcp from ['0.0.0.0/0']`
  - `~ Tag modified: Cloud 'Compliance=NON_COMPLIANT_BYPASS' vs IaC 'Compliance=Strict'`
- **Remediation Runbook Link**: Links directly to the on-call runbook and remediation command.

---

## 🛡️ Remediation Strategies: Detection vs Self-Healing

The drift detector supports two operational models:

### 1. Detection-Only Mode (Default)

- Generates the diff and dispatches alerts to Slack.
- Leaves human engineers in the loop to decide whether the drift was an intentional emergency change (which should be codified in Git) or a security hazard (which should be reverted).

### 2. Automated Self-Healing Mode (`--remediate`)

- Automatically runs `terraform apply <plan-binary>`.
- Overwrites rogue cloud modifications and resets cloud infrastructure to strictly match the Git repository.
- Ideal for production environments enforcing strict zero-drift policies.

---

## 🔄 Architecture & Execution Flow

```mermaid
sequenceDiagram
    autonumber
    actor Cron as Scheduled Runner / CI Pipeline
    participant Detector as drift_detector.sh
    participant TF as Terraform Engine
    participant Cloud as AWS / LocalStack APIs
    participant Notifier as slack_notifier.py
    participant Slack as Slack Channel (#devops-alerts)

    Cron->>Detector: Execute ./drift_detector.sh
    Detector->>TF: terraform plan -detailed-exitcode -out=tfplan.binary
    TF->>Cloud: Refresh and query current resource states
    Cloud-->>TF: Cloud State (Contains rogue Port 8080)
    TF-->>Detector: Plan calculated: 1 resource to change (Exit Code 2)

    rect rgb(255, 240, 240)
        Note over Detector,Slack: Drift Processing & Alerting
        Detector->>TF: terraform show -json tfplan.binary
        TF-->>Detector: Structured Plan JSON
        Detector->>Notifier: python3 slack_notifier.py --plan-json=...
        Notifier->>Notifier: Parse attribute diffs (Rogue port 8080 detected)
        Notifier->>Slack: POST /webhook (Block Kit Card with diff)
        Slack-->>Notifier: 200 OK (Alert displayed in channel)
    end

    opt When --remediate is enabled
        Detector->>TF: terraform apply tfplan.binary
        TF->>Cloud: Revoke rogue port 8080 & restore compliance tags
        Cloud-->>TF: Update confirmed
        Detector->>Detector: Verify zero-drift state (Exit Code 0)
    end
```

---

## 📂 Directory & File Structure

```text
06-infrastructure-as-code/09-terraform-drift-detection-alerting/
├── terraform/                        # Managed cloud infrastructure definitions
│   ├── versions.tf                   # Terraform and AWS provider versions
│   ├── variables.tf                  # Infrastructure parameters (CIDR, regions)
│   ├── main.tf                       # VPC, Subnet, Firewall SG, and S3 Bucket
│   └── outputs.tf                    # Exported resource IDs
├── drift_detector.sh                 # Main drift detection & remediation orchestrator
├── inject_drift.sh                   # Tool to inject intentional out-of-band cloud drift
├── slack_notifier.py                 # Plan JSON parser and Slack Block Kit formatter
├── test_drift_detection.sh           # Automated 12-test end-to-end test suite
├── drift_test.sh                     # Symlink to test suite
├── cleanup.sh                        # Standalone sanitation and teardown script
├── .gitignore                        # Workspace isolation rules
└── README.md                         # This educational documentation
```

---

## 💻 Prerequisites & Environment Setup

Ensure the following tools are installed on your machine:

1. **Docker / OrbStack**: Container runtime for local AWS emulation.
2. **OpenTofu (v1.6+) or Terraform (v1.6+)**: IaC execution engine (`brew install opentofu` or `brew install terraform`).
3. **AWS CLI (`aws`)**: Interacts with AWS/LocalStack APIs (`brew install awscli`).
4. **Python (v3.9+)**: Standard library execution for `slack_notifier.py`.
5. **`jq` & `curl`**: CLI utilities for JSON and HTTP operations.

Verify installed versions:

```bash
docker --version
tofu version || terraform version
aws --version
python3 --version
jq --version
```

---

## 🚀 Step-by-Step Hands-On Guide

### Step 1: Bootstrap Local AWS Emulation (Zero-Cost LocalStack)

Start the local emulator container on port `4566`:

```bash
# Export test credentials and LocalStack endpoint
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
export LOCALSTACK_ENDPOINT="http://127.0.0.1:4566"

# Start the emulator container
docker run -d --name localstack-drift-demo -p 4566:5000 motoserver/moto:latest

# Verify emulator is healthy
curl -s http://127.0.0.1:4566/
```

### Step 2: Deploy Baseline Cloud Infrastructure

Initialize and apply the baseline Terraform configuration:

```bash
cd terraform
tofu init
tofu apply -auto-approve
cd ..
```

This provisions:

- `drift-detection-fleet-vpc` (`10.0.0.0/16`) with `Compliance = "Strict"`.
- `drift-detection-fleet-web-sg` allowing only ports **80 (HTTP)** and **443 (HTTPS)**.
- `drift-detection-fleet-assets-bucket` S3 storage bucket.

### Step 3: Run Baseline Drift Detection (Verify In-Sync State)

Execute `drift_detector.sh` on the freshly applied infrastructure:

```bash
./drift_detector.sh
```

Output:

```text
======================================================================
  🔍 Automated Terraform Drift Detector & Alerting Engine
======================================================================
  IaC Engine:   tofu
  Environment:  production
  Auto-Heal:    false
  Log File:     .../logs/drift_detector.log

▶ [1/3] Running speculative plan (-detailed-exitcode)...
  [IN SYNC] Zero infrastructure drift detected. Cloud state strictly matches code.

✨ STATUS: IN-SYNC (Exit Code 0)
```

### Step 4: Simulate Out-of-Band Security Group Drift

Use `inject_drift.sh` to simulate an unauthorized modification via the AWS API (opening port `8080/tcp` to `0.0.0.0/0`):

```bash
./inject_drift.sh --scenario=security-group
```

Output:

```text
======================================================================
  ⚡ Terraform Out-of-Band Cloud Drift Injector
======================================================================
▶ Injecting Security Group Ingress Drift (Port 8080/tcp open to 0.0.0.0/0)...
  [DRIFT INJECTED] Unauthorized ingress rule added to SG: sg-xxxxxx
  Rule: TCP port 8080 from 0.0.0.0/0 (Not tracked in Terraform code!)
```

### Step 5: Detect the Injected Drift

Run the detector to catch the rogue modification:

```bash
./drift_detector.sh
```

Output:

```text
▶ [1/3] Running speculative plan (-detailed-exitcode)...
  [DRIFT DETECTED] Out-of-band cloud modifications found (Exit Code 2)!

▶ [2/3] Parsing binary plan into structured JSON...
▶ [3/3] Generating Slack Block Kit payload & formatting diff...

======================================================================
  📢 DRIFT ALERT REPORT: PRODUCTION ENVIRONMENT
======================================================================

  🔴 DRIFT DETECTED! 1 cloud resource(s) diverged from code:

  [1] UPDATE (Attribute Drift): aws_security_group.web_sg
      Type: aws_security_group
      ↳ Ingress Rules count changed: 3 in cloud vs 2 in IaC
      ↳ 🚨 Rogue Ingress Rule in Cloud: port 8080-8080/tcp from ['0.0.0.0/0']

======================================================================
```

### Step 6: Inspect the Generated Slack Block Kit Payload

View the formatted Slack message generated in [`logs/slack_payload.json`](logs/slack_payload.json):

```bash
cat logs/slack_payload.json | jq .
```

Notice the structured attachments, red status badge, and detailed diff ready to be posted to your on-call Slack channel!

### Step 7: Simulate Multi-Resource Tag Drift

Inject out-of-band tag tampering on the VPC:

```bash
./inject_drift.sh --scenario=tags
./drift_detector.sh
```

The detector now identifies both the rogue firewall port on the security group AND the tampered compliance tags on the VPC!

### Step 8: Execute Automated Self-Healing Remediation

Run the detector with the `--remediate` flag:

```bash
./drift_detector.sh --remediate
```

Output:

```text
🔧 AUTO-REMEDIATION REQUESTED
  Applying planned reconciliation to restore cloud resources to declared state...
  [REMEDIATED] Successfully reverted out-of-band drift!
  Verifying zero-drift state post-remediation...
  [VERIFIED] Infrastructure is fully back in sync.
```

Terraform automatically revoked the rogue ingress rule and restored the original compliance tags in the cloud.

### Step 9: Confirm Post-Remediation Zero-Drift State

Run the detector once more:

```bash
./drift_detector.sh
```

The system confirms: `✨ STATUS: IN-SYNC (Exit Code 0)`.

---

## ☁️ Deploying to Real Production AWS Cloud & Slack

### 1. Configure Real Slack Webhook

Create an Incoming Webhook in your Slack workspace and export the URL:

```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
```

Now, whenever `./drift_detector.sh` detects drift, it will post directly to your team's Slack channel.

### 2. Deploying to Real AWS Accounts

Update `terraform/terraform.tfvars`:

```hcl
aws_region        = "us-east-1"
environment       = "production"
enable_localstack = false
```

Authenticate with AWS and apply:

```bash
aws sso login --profile production-admin
cd terraform && tofu apply && cd ..
```

### 3. Automating with GitHub Actions Workflow

Create `.github/workflows/drift_detection.yml`:

```yaml
name: "Scheduled Drift Detection"

on:
  schedule:
    - cron: "0 * * * *" # Run every hour
  workflow_dispatch:

jobs:
  drift-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/DriftDetectorRole
          aws-region: us-east-1

      - name: Run Drift Detection
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
        run: |
          ./drift_detector.sh --env=production
```

---

## 🧪 Automated Testing & Verification Suite

Execute the complete end-to-end verification script:

```bash
./test_drift_detection.sh
```

### Test Suite Execution Output

```text
======================================================================
  🧪 Terraform Drift Detection & Alerting - Test Suite
======================================================================

▶ Step 1: Checking system prerequisites...
  [PASS] Test 1: All prerequisites verified (Docker, IaC engine, AWS CLI, Python 3, jq, curl)
         ↳ OpenTofu v1.12.6

▶ Step 2: Bootstrapping Local AWS Emulator container...
  [PASS] Test 2: Local AWS emulator started & ready for EC2/S3 APIs
         ↳ Port 4566

▶ Step 3: Validating HCL formatting & configuration syntax...
  [PASS] Test 3: HCL formatting, provider schema, and configuration validated

▶ Step 4: Provisioning baseline cloud infrastructure...
  [PASS] Test 4: Baseline resources provisioned (VPC, Subnet, Security Group, S3 Bucket)

▶ Step 5: Testing baseline drift detection (Expect Exit Code 0: IN-SYNC)...
  [PASS] Test 5: Baseline verified: In-Sync with zero drift (Exit Code 0)

▶ Step 6: Injecting out-of-band firewall rule (Port 8080/tcp)...
  [PASS] Test 6: Out-of-band ingress rule (port 8080) injected directly via AWS API

▶ Step 7: Detecting firewall rule drift via drift_detector.sh...
  [PASS] Test 7: Drift detector correctly returned Exit Code 2 (Drift Detected)

▶ Step 8: Verifying generated Slack Block Kit JSON payload...
  [PASS] Test 8: Slack Block Kit alert formatted with rogue ingress rule diff
         ↳ logs/slack_payload.json

▶ Step 9: Injecting tag drift on VPC and testing multi-resource detection...
  [PASS] Test 9: Multi-resource drift detected across Security Group and VPC tags

▶ Step 10: Executing automated drift remediation (--remediate)...
  [PASS] Test 10: Auto-remediation applied plan diff and reconciled cloud state to code

▶ Step 11: Confirming infrastructure is in-sync post-remediation...
  [PASS] Test 11: Post-remediation state confirmed strictly In-Sync (Exit Code 0)

▶ Step 12: Running cleanup.sh...
  [PASS] Test 12: cleanup.sh purged emulator container, state files, and logs

======================================================================
  🎉 ALL 12 TESTS PASSED! (12/12)
======================================================================
```

---

## ❓ Troubleshooting & FAQs

### 1. Why does `terraform plan` return exit code 2?

- **Explanation**: The `-detailed-exitcode` flag explicitly sets the exit code to `2` whenever diffs exist between state and configuration. This is not an error; it is the programmatic indicator of drift!

### 2. Can I exclude specific attributes from drift detection?

- **Tip**: In Terraform, use the `lifecycle { ignore_changes = [tags["LastUpdated"]] }` block on specific resources to prevent benign, expected out-of-band updates from triggering alerts.

### 3. How do I test Slack alerts without a live webhook?

- **Tip**: When `SLACK_WEBHOOK_URL` is omitted, `slack_notifier.py` prints the formatted terminal alert card and saves the payload to [`logs/slack_payload.json`](logs/slack_payload.json).

---

## 🧹 Teardown & Cleanup

After finishing all tests and experiments, purge all containers, temporary caches, and generated files to leave your environment clean for the next mini-project:

### Fast Cleanup (Containers, State Files, Binary Plans, and Logs)

```bash
./cleanup.sh
```

### Full Purge (Including Deep Caches)

```bash
./cleanup.sh --all
```

The cleanup script guarantees:

- The `localstack-drift-demo` emulator container is stopped and removed.
- All `.terraform/` directories and local `.tfstate` files are deleted.
- All binary plan files (`*.tfplan*`) and log outputs are purged.
- Zero leftover resources or files remain outside or inside the repository.
