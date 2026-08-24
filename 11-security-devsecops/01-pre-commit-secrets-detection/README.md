<!-- markdownlint-disable MD013 MD033 MD051 MD060 -->
# 01 - Pre-Commit Git Secrets Detection Suite

> A production-grade **Shift-Left DevSecOps** repository protection suite featuring multi-engine secrets scanning with **Gitleaks** and **Yelp detect-secrets**, custom regex and Shannon entropy rule definitions, baseline technical-debt management, and automated pre-commit Git hook interceptors.

---

## 📋 Table of Contents

1. [Architectural Overview & Lifecycle](#-architectural-overview--lifecycle)
   - [Git Hook Interception Flowchart](#git-hook-interception-flowchart)
   - [Shift-Left Security Philosophy](#shift-left-security-philosophy)
2. [Theoretical Deep-Dive for Beginners](#-theoretical-deep-dive-for-beginners)
   - [The Problem: Why Secrets in Git are Catastrophic](#the-problem-why-secrets-in-git-are-catastrophic)
   - [Scanning Paradigms: Regex Pattern Matching vs. Shannon Entropy](#scanning-paradigms-regex-pattern-matching-vs-shannon-entropy)
   - [The Mathematical Foundation of Shannon Entropy](#the-mathematical-foundation-of-shannon-entropy)
   - [Dual-Engine Strategy: Gitleaks vs. Yelp detect-secrets](#dual-engine-strategy-gitleaks-vs-yelp-detect-secrets)
   - [Managing Technical Debt: The Baseline Pattern](#managing-technical-debt-the-baseline-pattern)
   - [False Positives vs. False Negatives](#false-positives-vs-false-negatives)
3. [Repository & Directory Structure](#-repository--directory-structure)
4. [Prerequisites & System Setup](#-prerequisites--system-setup)
5. [Quickstart Guide (Docker & Isolated Sandbox)](#-quickstart-guide-docker--isolated-sandbox)
6. [Step-by-Step Hands-On Guide](#-step-by-step-hands-on-guide)
   - [Step 1: Inspect Pre-Commit Hook Configuration](#step-1-inspect-pre-commit-hook-configuration)
   - [Step 2: Explore Custom Gitleaks TOML Ruleset](#step-2-explore-custom-gitleaks-toml-ruleset)
   - [Step 3: Analyze Yelp detect-secrets Baseline Mechanics](#step-3-analyze-yelp-detect-secrets-baseline-mechanics)
   - [Step 4: Execute the Python Shannon Entropy & Secrets Analyzer](#step-4-execute-the-python-shannon-entropy--secrets-analyzer)
   - [Step 5: Test Clean Code Commits](#step-5-test-clean-code-commits)
   - [Step 6: Simulate Real-World Credential Leaks & Observe Blocking](#step-6-simulate-real-world-credential-leaks--observe-blocking)
   - [Step 7: Configure Allowlists & Exemption Policies](#step-7-configure-allowlists--exemption-policies)
   - [Step 8: Run the Complete Automated Test Suite](#step-8-run-the-complete-automated-test-suite)
7. [Enterprise Remediation Runbook](#-enterprise-remediation-runbook)
8. [Troubleshooting & Common Gotchas](#-troubleshooting--common-gotchas)
9. [Resource Teardown & Complete Cleanup](#-resource-teardown--complete-cleanup)

---

## 🏛️ Architectural Overview & Lifecycle

### Git Hook Interception Flowchart

```mermaid
flowchart TD
    subgraph DeveloperWorkspace ["💻 Developer Workspace"]
        CodeChanges["Edit Source Code / Configs"] --> Staging["git add <file> (Staged in Index)"]
        Staging --> CommitCommand["git commit -m 'feat: implement payment gateway'"]
    end

    subgraph PreCommitRunner ["🛡️ Pre-Commit Hook Framework (.pre-commit-config.yaml)"]
        CommitCommand --> TriggerHook[".git/hooks/pre-commit interceptor executes"]
        
        subgraph ScanningEngines ["🔍 Multi-Engine Security Scanners"]
            TriggerHook --> GitleaksEngine["Gitleaks CLI Engine<br/>• Custom .gitleaks.toml<br/>• High-precision Regex Patterns<br/>• Shannon Entropy Verification<br/>• Keyword Anchors"]
            TriggerHook --> DetectSecretsEngine["Yelp detect-secrets Engine<br/>• .secrets.baseline Audit<br/>• High-Entropy String Heuristics<br/>• AST & Keyword Plugin Matrix"]
            TriggerHook --> HygieneSuite["Repository Hygiene Hooks<br/>• trailing-whitespace<br/>• end-of-file-fixer<br/>• check-yaml / check-json<br/>• check-added-large-files"]
        end
    end

    subgraph DecisionEvaluation ["⚖️ Security Gate Policy Engine"]
        GitleaksEngine --> RuleCheck{New Secret Detected & Not Allowlisted?}
        DetectSecretsEngine --> RuleCheck
        HygieneSuite --> RuleCheck

        RuleCheck -- "YES (Violation Found)" --> RejectCommit["❌ COMMIT REJECTED<br/>• Exit Code != 0<br/>• Redacted Secret Location Output<br/>• Remediation Instructions Displayed<br/>• Working tree & index remain uncommitted"]
        RuleCheck -- "NO (Clean Code or Allowed)" --> AcceptCommit["✅ COMMIT ACCEPTED<br/>• Git creates new immutable commit object<br/>• Ready for push to remote repository"]
    end

    subgraph AnalyticsCli ["📊 Python Security Engine (secrets_analyzer.py)"]
        TriggerHook -. Telemetry / Reporting .-> EntropyCalc["Shannon Entropy Calculation"]
        EntropyCalc --> JsonSarif["JSON & SARIF Security Exports"]
    end
```

### Shift-Left Security Philosophy

In traditional software delivery models, security evaluations often occurred at the very end of the development cycle (during penetration testing or manual code reviews prior to production deployment). This reactive paradigm is known as **Shift-Right**.

**Shift-Left DevSecOps** moves security checks directly to the developer's local workstation, executing automated validation before code ever leaves the local environment.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                      SHIFT-LEFT DEVSECOPS PARADIGM                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [Developer Machine]  ──►  [Local Git Hook]  ──►  [CI/CD Pipeline]     │
│        ▲                         ▲                        │             │
│        │                         │                        ▼             │
│   Code Writing          PRE-COMMIT SCANNING       Container Scans       │
│   & Editing            (Gitleaks + Baseline)     & Deployment Gate      │
│                                  │                                      │
│                                  ▼                                      │
│                      BLOCKED BEFORE COMMITTING!                         │
│                    Cost to fix: < 30 seconds                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

Benefits of Shift-Left Secrets Detection:

1. **Zero Exposure Window**: Secrets are blocked before they are committed to the local Git object database, preventing accidental push to public or private remote repositories.
2. **Drastic Cost Reduction**: Remediating a secret before committing takes seconds. Remediating a pushed secret requires revoking credentials across infrastructure, rotating API keys, updating applications, auditing access logs, and rewriting Git history.
3. **Automated Enforcement**: Developers do not need to manually remember checklists; hooks run automatically on every `git commit`.

---

## 🧠 Theoretical Deep-Dive for Beginners

### The Problem: Why Secrets in Git are Catastrophic

Git is a **content-addressable immutable object store**. When you commit a file into Git:

- Git compresses the contents and stores it in a blob object (`.git/objects/`).
- Even if you immediately create a second commit deleting the file or removing the secret, **the secret remains forever in Git history**.
- Anyone with read access to the repository can run `git log -p` or `git checkout <commit-hash>` to view the exposed credential.
- Automated bots continuously scan GitHub and public repositories within milliseconds of a push, exploiting exposed AWS keys or database passwords before humans can react.

### Scanning Paradigms: Regex Pattern Matching vs. Shannon Entropy

Secret detection engines generally employ two complementary paradigms:

#### 1. Deterministic Regular Expressions (Regex)

Many cloud providers and SaaS services use structured prefixes for their credentials:

- AWS Access Keys start with `AKIA` or `ASIA` followed by 16 alphanumeric uppercase characters.
- GitHub Personal Access Tokens start with `ghp_` or `github_pat_`.
- Slack Webhooks follow `https://hooks.slack.com/services/T.../B.../...`.
- OpenAI API Keys start with `sk-` or `sk-proj-`.

Regex scanning is **fast and deterministic**, but cannot detect arbitrary, unstructured secret passwords or internal tokens without high false-positive rates.

#### 2. Shannon Entropy Analysis

To detect unstructured secrets (such as random database passwords or cryptographic signing keys), scanners evaluate the **information entropy** (randomness) of character sequences.

Natural English code contains low randomness due to repetitive grammar and character frequency (e.g. `getUserProfile`, `database_connection`). Cryptographically generated keys, however, exhibit near-uniform character distribution, yielding high entropy values.

---

### The Mathematical Foundation of Shannon Entropy

Claude Shannon's information theory defines the entropy $H(X)$ of a string $X$ as:

$$H(X) = -\sum_{i=1}^{n} P(x_i) \cdot \log_2 P(x_i)$$

Where:

- $n$ is the number of distinct characters in the string.
- $P(x_i) = \frac{\text{count}(x_i)}{\text{total length}}$ is the empirical probability of character $x_i$ appearing in the string.
- $\log_2 P(x_i)$ measures the information content in bits.

#### Entropy Scale & Classification Reference Table

| Entropy Range ($H$) | Typical Data Type | Example | Classification |
| :--- | :--- | :--- | :--- |
| **$0.0 - 2.5$ bits/char** | English words, numbers, repetitive text | `password123`, `application_port` | Low Randomness (Standard code/variable) |
| **$2.5 - 3.5$ bits/char** | Standard camelCase/snake_case variable names | `processPaymentTransactionHandler` | Moderate Randomness (Normal code) |
| **$3.5 - 4.2$ bits/char** | Hexadecimal hashes, Base64 with keywords | `a1b2c3d4e5f67890abcdef1234567890` | Elevated Randomness (Suspicious token) |
| **$> 4.2$ bits/char** | True cryptographic keys, Base64 secrets | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` | High Randomness (**Probable Secret**) |

---

### Dual-Engine Strategy: Gitleaks vs. Yelp detect-secrets

This project integrates two complementary scanning engines in `.pre-commit-config.yaml`:

```text
┌──────────────────────────────────────┬──────────────────────────────────────┐
│          GITLEAKS ENGINE             │         YELP DETECT-SECRETS          │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ • Written in Go (Ultra-fast)         │ • Written in Python                  │
│ • Rich TOML declarative rule config │ • Heuristic & AST plugin suite       │
│ • Pattern regex + entropy filter     │ • Robust baseline workflow           │
│ • Keyword anchors minimize overhead  │ • Tracks line/hash state in JSON     │
│ • Protects uncommitted staging diffs │ • Ideal for legacy repo onboarding   │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

### Managing Technical Debt: The Baseline Pattern

In existing enterprise repositories, running a secret scanner for the first time often surfaces hundreds of historical items (test mocks, deprecated configurations, or low-entropy false positives).

If a pre-commit hook immediately blocks all commits until all historical findings are resolved, development halts.

The **Baseline Pattern** solves this:

1. **Initial Snapshot**: Run `detect-secrets scan > .secrets.baseline` to record all existing findings.
2. **Audit Verification**: Run `detect-secrets audit .secrets.baseline` to label false positives or track known technical debt.
3. **Commit Guard**: The pre-commit hook checks staged changes against `.secrets.baseline`. **Existing baselined entries are ignored, but any NEW secret immediately fails the commit**.

---

### False Positives vs. False Negatives

- **False Positive (FP)**: The scanner flags a benign string as a secret (e.g. an innocent mock UUID or placeholder `EXAMPLE_KEY_123`). Handled via `.gitleaks.toml` `[allowlist]` or `.secrets.baseline`.
- **False Negative (FN)**: A real secret bypasses detection. Prevented by combining regex rules with high-entropy checks and multi-character charset plugins.

---

## 📁 Repository & Directory Structure

```text
11-security-devsecops/01-pre-commit-secrets-detection/
├── .gitignore                      # Excludes sandboxes, caches, and test artifacts
├── .markdownlint.json              # Markdownlint rules configuration
├── .pre-commit-config.yaml         # Pre-commit hook framework multi-engine configuration
├── .gitleaks.toml                  # Custom Gitleaks regex rules, entropy limits & allowlists
├── .secrets.baseline               # Yelp detect-secrets baseline file for legacy debt management
├── requirements.txt                # Python dependencies (pre-commit, detect-secrets, pyyaml)
├── secrets_analyzer.py             # CLI analytics engine for Shannon entropy & JSON reporting
├── test_secret_blocking.sh         # End-to-end automated testing suite with sandbox verification
├── cleanup.sh                      # Teardown script for containers, volumes, and temporary caches
├── Dockerfile                      # Self-contained multi-arch containerized test environment
├── docker-compose.yml              # Compose definition for isolated sandbox execution
├── README.md                       # Comprehensive beginner-friendly documentation
└── test_fixtures/
    ├── clean_code/
    │   ├── app.py                  # Clean Python API client using environment variables
    │   ├── config.yaml             # Clean YAML configuration without credentials
    │   └── auth_service.js         # Clean JS auth middleware
    └── mock_secrets/
        ├── aws_credentials.env     # Intentional mock AWS access key & secret key
        ├── github_token.py         # Intentional mock GitHub personal access token (ghp_...)
        ├── private_key.pem         # Intentional mock RSA Private Key PEM block
        ├── slack_webhook.json      # Intentional mock Slack incoming webhook URL
        ├── jwt_secret.js           # Intentional mock hardcoded JWT HMAC secret
        └── allowlisted_mock_token.py # Mock token configured in allowlist to verify exemptions
```

---

## 🔧 Prerequisites & System Setup

This mini-project supports two execution modes:

### Mode A: Docker Sandbox (Recommended - Zero Host Tool Installation)

- **Docker**: Version 24.0+
- **Docker Compose**: Version 2.20+
- Works on macOS (including Apple Silicon `arm64`), Linux (`x86_64` / `aarch64`), and Windows (WSL2).

### Mode B: Local Host Environment

- **Python**: 3.10+
- **Git**: 2.30+
- **pip packages**: `pip install -r requirements.txt`
- **Gitleaks CLI** (optional for standalone scans): `brew install gitleaks` (macOS) or download from [Gitleaks Releases](https://github.com/gitleaks/gitleaks/releases).

---

## 🚀 Quickstart Guide (Docker & Isolated Sandbox)

To build and run the entire suite inside an isolated Docker container:

```bash
# 1. Navigate to the project directory
cd 11-security-devsecops/01-pre-commit-secrets-detection

# 2. Build the Docker sandbox image
docker compose build

# 3. Execute the automated test suite in an isolated container
docker compose run --rm secrets-detector
```

---

## 📖 Step-by-Step Hands-On Guide

### Step 1: Inspect Pre-Commit Hook Configuration

Review `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
        name: Detect Hardcoded Secrets (Gitleaks)
        entry: gitleaks protect --verbose --redact --staged --config=.gitleaks.toml
        language: golang
        pass_filenames: false

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        name: Detect Secrets Baseline Compliance (detect-secrets)
        args: ['--baseline', '.secrets.baseline']
```

---

### Step 2: Explore Custom Gitleaks TOML Ruleset

Inspect `.gitleaks.toml`. Notice how rules specify both a regular expression and an optional `entropy` threshold and `keywords` anchor to keep scans lightning fast:

```toml
[[rules]]
id = "aws-secret-access-key"
description = "Detected AWS Secret Access Key"
regex = '''(?i)(?:aws_secret_access_key|aws_secret_key|secret_access_key|aws_secret)\s*(?:=|:)\s*['"]?([A-Za-z0-9/+=]{40})['"]?'''
entropy = 3.5
secretGroup = 1
keywords = ["aws_secret_access_key", "secret_access_key", "aws_secret"]
```

---

### Step 3: Analyze Yelp detect-secrets Baseline Mechanics

View `.secrets.baseline`:

```json
{
  "version": "1.5.0",
  "plugins_used": [
    { "name": "AWSKeyDetector" },
    { "name": "Base64HighEntropyString", "limit": 4.5 },
    { "name": "HexHighEntropyString", "limit": 3.0 },
    { "name": "PrivateKeyDetector" },
    { "name": "SlackDetector" }
  ],
  "results": {
    "test_fixtures/mock_secrets/allowlisted_mock_token.py": [
      {
        "type": "Secret Keyword",
        "hashed_secret": "3c9c0fb649e339f604ed005080c6ed0ec49e4e42",
        "is_secret": false
      }
    ]
  }
}
```

---

### Step 4: Execute the Python Shannon Entropy & Secrets Analyzer

Calculate the entropy of different sample strings:

```bash
# Evaluate natural English text (low entropy)
python3 secrets_analyzer.py --calc-entropy "user_authentication_handler_service"

# Evaluate a mock AWS secret key (high entropy)
python3 secrets_analyzer.py --calc-entropy "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

Scan the mock test fixtures directly:

```bash
# Scan mock secrets directory
python3 secrets_analyzer.py --scan-dir test_fixtures/mock_secrets
```

---

### Step 5: Test Clean Code Commits

Scan clean code fixtures to verify zero false positives:

```bash
python3 secrets_analyzer.py --scan-dir test_fixtures/clean_code --strict
```

Output:

```text
==============================================================================
  🛡️  DEVSECOPS PRE-COMMIT SECRETS SCAN REPORT
==============================================================================
 Total Secrets Discovered: 0
  ✅ [CLEAN] No hardcoded secrets or credentials detected!
```

---

### Step 6: Simulate Real-World Credential Leaks & Observe Blocking

When `test_secret_blocking.sh` stages a file containing a mock credential (such as `aws_credentials.env` or `github_token.py`), Gitleaks intercepts the staging area and halts the commit:

```text
    ○
    │    遺伝子 Gitleaks
    ╶─────────────────────────────────────────────────
    Finding:     AWS_ACCESS_KEY_ID=AKIAIOSFODNN7INVALID
    Secret:      AKIAIOSFODNN7INVALID
    RuleID:      aws-access-key-id
    Entropy:     3.25
    File:        aws_credentials.env
    Line:        3

    ❌ [FAIL] Commit rejected due to secrets detection policy!
```

---

### Step 7: Configure Allowlists & Exemption Policies

When a benign test fixture or documentation example triggers a false positive, add it to `.gitleaks.toml`:

```toml
[allowlist]
description = "Allowlist for documentation and mock test fixtures"
paths = [
    '''test_fixtures/mock_secrets/allowlisted_mock_token\.py$'''
]
regexes = [
    '''sk-mock-allowlisted-demo-key-1234567890abcdef'''
]
```

Test that the allowlisted file passes validation:

```bash
python3 secrets_analyzer.py --file test_fixtures/mock_secrets/allowlisted_mock_token.py
```

---

### Step 8: Run the Complete Automated Test Suite

Execute the automated end-to-end verification script:

```bash
# Run locally (if local tools are installed)
./test_secret_blocking.sh

# Or run inside Docker container
docker compose run --rm secrets-detector
```

Sample output:

```text
======================================================================
  🧪 STARTING PRE-COMMIT GIT SECRETS DETECTION TEST SUITE
======================================================================
▶ [Step 0/7] Checking environment dependencies...
  [PASS] git CLI is installed
  [PASS] python3 is installed
  [PASS] gitleaks CLI is installed
  [PASS] detect-secrets CLI is installed
  [PASS] pre-commit framework is installed
▶ [Step 1/7] Creating isolated ephemeral Git sandbox...
  [PASS] Ephemeral sandbox Git repository initialized
▶ [Step 2/7] Testing Clean Code Commits (Expecting SUCCESS)...
  [PASS] Pre-commit hooks pass on clean application code
  [PASS] Git commit successfully created for clean code
▶ [Step 3/7] Testing Secret Blocking on Staged Leaks...
  [PASS] Pre-commit blocked AWS Credentials Leak (AKIA & Secret Key)
  [PASS] Pre-commit blocked GitHub Personal Access Token (ghp_...)
  [PASS] Pre-commit blocked RSA Private Cryptographic Key (PEM Block)
  [PASS] Pre-commit blocked Slack Incoming Webhook URL
  [PASS] Pre-commit blocked Hardcoded JWT Signing Secret
▶ [Step 4/7] Testing Allowlist & Baseline Exceptions...
  [PASS] Allowlisted mock token is permitted by policy
▶ [Step 5/7] Testing Direct Gitleaks Scanner against Mock Fixtures...
  [PASS] Direct Gitleaks scanner flags mock secrets directory
▶ [Step 6/7] Testing detect-secrets Baseline Scanning...
  [PASS] detect-secrets scan executed successfully on clean fixtures
▶ [Step 7/7] Validating secrets_analyzer.py CLI and JSON Report...
  [PASS] secrets_analyzer.py passes clean code in strict mode
  [PASS] secrets_analyzer.py discovers secrets and exports JSON report
  [PASS] Shannon entropy calculation verified: Shannon Entropy: 4.7821 bits/char

======================================================================
  📊 TEST SUITE SUMMARY
  Total Tests Evaluated : 15
  Passed                : 15
  Failed                : 0
======================================================================
🎉 ALL PRE-COMMIT GIT SECRETS TESTS PASSED SUCCESSFULLY!
```

---

## 🛡️ Enterprise Remediation Runbook

If a secret is ever accidentally committed or pushed before hooks are installed:

1. **Immediately Revoke and Rotate**:
   - Consider the secret compromised immediately.
   - Go to the provider console (AWS IAM, GitHub Settings, Stripe Dashboard) and deactivate/rotate the credential.
2. **Remove Secret from Working Tree**:
   - Replace the hardcoded string with an environment variable (`os.environ["SECRET_NAME"]`) or HashiCorp Vault lookup.
3. **Purge from Git History**:
   - Use `git-filter-repo` or BFG Repo-Cleaner:

     ```bash
     # Example using git-filter-repo
     git filter-repo --replace-text <(echo "leaked_secret_string==>REDACTED")
     ```

4. **Force-Push with Caution**:
   - Force push rewritten branches to remote (`git push origin --force --all`).

---

## 🔍 Troubleshooting & Common Gotchas

### 1. `pre-commit` command not found

- **Fix**: Install pre-commit using `pip install pre-commit` or run via Docker Compose.

### 2. Gitleaks Golang compilation delay on first pre-commit run

- **Cause**: On initial execution, pre-commit downloads and caches the Go toolchain for Gitleaks.
- **Fix**: Subsequent runs use the cached binary in `.pre-commit-cache/` and execute in milliseconds.

### 3. False positives on long random IDs or hashes

- **Fix**: Add the specific pattern or file path to `.gitleaks.toml` `[allowlist]` or update `.secrets.baseline` with `detect-secrets scan --update .secrets.baseline`.

---

## 🧹 Resource Teardown & Complete Cleanup

To clean up all containers, images, named volumes, caches, and test sandboxes after completing the mini-project:

```bash
# Default cleanup: Removes containers, networks, volumes, and temporary test sandboxes
./cleanup.sh

# Complete purge: Also removes downloaded/built Docker images
./cleanup.sh --all
```

Output:

```text
======================================================================
  🧹 Cleaning Up Pre-Commit Git Secrets Detection Suite Resources
======================================================================
▶ [1/3] Tearing down containers, network, and named cache volumes...
  [OK] Container 'pre-commit-secrets-detector' stopped and removed.
  [OK] Named volume 'pre_commit_secrets_cache' deleted.

▶ [2/3] Purging Git Secrets Detector container image...
  [OK] Docker image 'pre-commit-secrets-suite:v1.0.0' removed.

▶ [3/3] Removing local temporary sandboxes, reports, and cache...
  [OK] Temporary files, sandboxes, and generated reports cleaned.

✨ Environment is completely clean! Ready for subsequent projects.
```
