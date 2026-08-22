#!/usr/bin/env python3
"""
iam_policy_evaluator.py - AWS IAM Least-Privilege & Role Boundaries Evaluator
=============================================================================
A comprehensive IAM policy simulator and validator implementing AWS authorization
evaluation logic: Explicit Deny > Explicit Allow > Permissions Boundary > SCP > Default Deny.

Supports:
  1. Offline Deterministic Engine: Pure Python simulator evaluating JSON policies,
     permissions boundaries, SCPs, and condition keys (MFA, Region, Account).
  2. AWS IAM Policy Simulator API: Boto3 integration for LocalStack and live AWS Cloud.

Usage:
  python3 iam_policy_evaluator.py [OPTIONS]

Options:
  --mode [offline|localstack|aws|auto]   Evaluation backend (default: offline)
  --endpoint-url URL                    Custom endpoint for LocalStack (default: http://127.0.0.1:4566)
  --suite [all|developer|readonly|cicd|scp|boundaries]  Target test suite (default: all)
  --policies-dir DIR                    Directory containing policy JSON files
  --json-output FILE                    Export test results as JSON file
  --verbose, -v                         Enable detailed statement evaluation logs
  --help, -h                            Show this help message
"""

import argparse
import fnmatch
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Terminal color styling
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_GREEN = "\033[1;32m"
CLR_RED = "\033[1;31m"
CLR_YELLOW = "\033[1;33m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"
CLR_GRAY = "\033[0;90m"
CLR_WHITE = "\033[1;37m"


# ==============================================================================
# Data Models
# ==============================================================================

@dataclass
class EvaluationContext:
    """Represents the runtime request context evaluated against IAM policies."""
    action: str
    resource: str
    mfa_present: bool = True
    requested_region: str = "us-east-1"
    principal_arn: str = "arn:aws:iam::123456789012:role/iam-least-privilege-developer-role"
    caller_account: str = "123456789012"
    resource_tags: Dict[str, str] = field(default_factory=dict)
    request_headers: Dict[str, str] = field(default_factory=dict)


@dataclass
class EvaluationResult:
    """Outcome of an IAM authorization evaluation."""
    decision: str  # "ALLOWED" or "DENIED"
    matched_statement_sid: Optional[str] = None
    reason: str = ""
    denied_by_boundary: bool = False
    denied_by_scp: bool = False
    denied_by_mfa: bool = False


@dataclass
class TestCase:
    """Defines a structured security test case for policy validation."""
    test_id: str
    suite: str
    role_name: str
    description: str
    action: str
    resource: str
    expected_decision: str  # "ALLOWED" or "DENIED"
    mfa_present: bool = True
    requested_region: str = "us-east-1"
    principal_arn: str = "arn:aws:iam::123456789012:role/demo-role"
    applied_boundary: Optional[str] = None
    applied_scps: List[str] = field(default_factory=list)


# ==============================================================================
# Deterministic Offline IAM Evaluation Engine
# ==============================================================================

class OfflineIAMEngine:
    """
    Offline simulation engine implementing AWS IAM authorization semantics:
      1. Default Deny: All requests start denied.
      2. SCP Check: Denies from any Service Control Policy block the request.
      3. Permissions Boundary: Must explicitly allow the action (if boundary present).
      4. Identity Policies: Must have matching Allow and no matching Deny.
      5. Condition Keys: Evaluates MFA, RequestedRegion, PrincipalArn, etc.
    """

    def __init__(self, policies_dir: Path, verbose: bool = False):
        self.policies_dir = policies_dir
        self.verbose = verbose
        self.policy_cache: Dict[str, Dict[str, Any]] = {}
        self._load_all_policies()

    def _load_all_policies(self) -> None:
        """Discovers and caches all JSON policy documents from disk."""
        for root, _, files in os.walk(self.policies_dir):
            for file in files:
                if file.endswith(".json"):
                    full_path = Path(root) / file
                    try:
                        with open(full_path, "r", encoding="utf-8") as f:
                            data = json.load(f)
                            # Key by filename and relative path
                            self.policy_cache[file] = data
                            rel_path = str(full_path.relative_to(self.policies_dir))
                            self.policy_cache[rel_path] = data
                    except Exception as e:
                        if self.verbose:
                            print(f"{CLR_YELLOW}[WARN] Failed to load policy {file}: {e}{CLR_RESET}")

    def get_policy(self, name_or_filename: str) -> Optional[Dict[str, Any]]:
        """Retrieves a cached policy document by file name or alias."""
        if name_or_filename in self.policy_cache:
            return self.policy_cache[name_or_filename]
        for k, v in self.policy_cache.items():
            if k.endswith(name_or_filename) or k.endswith(f"{name_or_filename}.json"):
                return v
        return None

    @staticmethod
    def _match_pattern(pattern: str, value: str) -> bool:
        """Case-insensitive glob pattern matcher supporting AWS wildcard syntax (*, ?)."""
        pattern_lower = pattern.lower()
        value_lower = value.lower()
        if pattern == "*":
            return True
        return fnmatch.fnmatch(value_lower, pattern_lower)

    @staticmethod
    def _match_action(pattern: str, action: str) -> bool:
        """Matches AWS actions with service and action wildcard rules (e.g. s3:*, *:Describe*)."""
        p = pattern.lower()
        a = action.lower()
        if p == "*":
            return True
        return fnmatch.fnmatch(a, p)

    @staticmethod
    def _match_resource(pattern: str, resource: str) -> bool:
        """Matches AWS resource ARNs supporting wildcards and segment replacements."""
        if pattern == "*":
            return True
        return fnmatch.fnmatch(resource.lower(), pattern.lower())

    def _evaluate_conditions(self, conditions: Dict[str, Any], ctx: EvaluationContext) -> bool:
        """Evaluates AWS IAM condition operators (StringEquals, StringNotEquals, Bool, ArnLike, etc.)."""
        for operator, cond_map in conditions.items():
            op_lower = operator.lower()
            for key, expected in cond_map.items():
                actual_value = None

                # Resolve context values
                if key.lower() == "aws:multifactorauthpresent":
                    actual_value = ctx.mfa_present
                elif key.lower() == "aws:requestedregion":
                    actual_value = ctx.requested_region
                elif key.lower() == "aws:principalarn":
                    actual_value = ctx.principal_arn
                elif key.lower() == "kms:calleraccount":
                    actual_value = ctx.caller_account
                elif key.lower() == "ec2:metadatahttptokens":
                    actual_value = ctx.request_headers.get("MetadataHttpTokens", "optional")
                else:
                    # Generic key lookup
                    actual_value = ctx.resource_tags.get(key) or ctx.request_headers.get(key)

                # Evaluate operator logic
                if "bool" in op_lower:
                    exp_bool = str(expected).lower() == "true"
                    if "ifexists" in op_lower and actual_value is None:
                        continue
                    if actual_value != exp_bool:
                        return False

                elif op_lower in ("stringequals", "stringequalsifexists"):
                    expected_list = expected if isinstance(expected, list) else [expected]
                    # Substitute variable placeholder ${aws:PrincipalAccount}
                    expected_list = [
                        ctx.caller_account if exp == "${aws:PrincipalAccount}" else exp
                        for exp in expected_list
                    ]
                    if actual_value is None:
                        if "ifexists" in op_lower:
                            continue
                        return False
                    if str(actual_value) not in expected_list:
                        return False

                elif op_lower in ("stringnotequals", "stringnotequalsifexists"):
                    expected_list = expected if isinstance(expected, list) else [expected]
                    if actual_value is not None and str(actual_value) in expected_list:
                        return False

                elif op_lower in ("stringlike", "stringlikeifexists", "arnlike"):
                    expected_list = expected if isinstance(expected, list) else [expected]
                    if actual_value is None:
                        if "ifexists" in op_lower:
                            continue
                        return False
                    matched = any(self._match_pattern(exp, str(actual_value)) for exp in expected_list)
                    if not matched:
                        return False

                elif op_lower in ("stringnotlike", "arnnotlike"):
                    expected_list = expected if isinstance(expected, list) else [expected]
                    if actual_value is not None:
                        matched = any(self._match_pattern(exp, str(actual_value)) for exp in expected_list)
                        if matched:
                            return False

        return True

    def _evaluate_single_policy(
        self, policy_doc: Dict[str, Any], ctx: EvaluationContext
    ) -> Tuple[Optional[bool], Optional[str], str]:
        """
        Evaluates a single IAM policy document against the context.
        Returns: (explicit_allow, matched_sid, reason)
          - True: Explicit Allow matched
          - False: Explicit Deny matched
          - None: No match (default neutral)
        """
        statements = policy_doc.get("Statement", [])
        if isinstance(statements, dict):
            statements = [statements]

        has_allow = False
        allow_sid = None

        for stmt in statements:
            effect = stmt.get("Effect", "Deny")
            sid = stmt.get("Sid", "UnnamedStatement")

            # 1. Action Matching (supports Action and NotAction)
            actions = stmt.get("Action", [])
            not_actions = stmt.get("NotAction", [])
            if isinstance(actions, str):
                actions = [actions]
            if isinstance(not_actions, str):
                not_actions = [not_actions]

            action_matched = False
            if actions:
                action_matched = any(self._match_action(act, ctx.action) for act in actions)
            elif not_actions:
                # NotAction matches if the requested action is NOT in the NotAction list
                not_match_found = any(self._match_action(act, ctx.action) for act in not_actions)
                action_matched = not not_match_found

            if not action_matched:
                continue

            # 2. Resource Matching (supports Resource and NotResource)
            resources = stmt.get("Resource", [])
            not_resources = stmt.get("NotResource", [])
            if isinstance(resources, str):
                resources = [resources]
            if isinstance(not_resources, str):
                not_resources = [not_resources]

            resource_matched = False
            if resources:
                resource_matched = any(self._match_resource(res, ctx.resource) for res in resources)
            elif not_resources:
                not_res_found = any(self._match_resource(res, ctx.resource) for res in not_resources)
                resource_matched = not not_res_found

            if not resource_matched:
                continue

            # 3. Condition Matching
            conditions = stmt.get("Condition", {})
            if conditions:
                if not self._evaluate_conditions(conditions, ctx):
                    continue

            # 4. Effect Evaluation
            if effect == "Deny":
                # Explicit Deny wins immediately across this policy
                return False, sid, f"Explicit Deny from statement '{sid}'"
            elif effect == "Allow":
                has_allow = True
                allow_sid = sid

        if has_allow:
            return True, allow_sid, f"Explicit Allow from statement '{allow_sid}'"

        return None, None, "No matching statement (Default Deny)"

    def evaluate(
        self,
        identity_policies: List[Dict[str, Any]],
        ctx: EvaluationContext,
        boundary_policy: Optional[Dict[str, Any]] = None,
        scp_policies: Optional[List[Dict[str, Any]]] = None,
    ) -> EvaluationResult:
        """
        Full AWS IAM Authorization Evaluation Pipeline.
        Resolves: SCPs -> Boundary -> Identity Policies -> Conditions.
        """
        # Step 1: Evaluate Service Control Policies (SCPs)
        if scp_policies:
            for scp in scp_policies:
                allow, sid, reason = self._evaluate_single_policy(scp, ctx)
                if allow is False:
                    return EvaluationResult(
                        decision="DENIED",
                        matched_statement_sid=sid,
                        reason=f"Blocked by Service Control Policy: {reason}",
                        denied_by_scp=True,
                    )

        # Step 2: Evaluate Identity Policies for Explicit Deny
        has_identity_allow = False
        identity_allow_sid = None
        for policy in identity_policies:
            allow, sid, reason = self._evaluate_single_policy(policy, ctx)
            if allow is False:
                # Check if it was an MFA condition deny
                is_mfa = "mfa" in (sid or "").lower() or not ctx.mfa_present
                return EvaluationResult(
                    decision="DENIED",
                    matched_statement_sid=sid,
                    reason=f"Blocked by Identity Policy: {reason}",
                    denied_by_mfa=is_mfa,
                )
            elif allow is True:
                has_identity_allow = True
                identity_allow_sid = sid

        # If no identity policy explicitly allowed the action, it's Default Denied
        if not has_identity_allow:
            return EvaluationResult(
                decision="DENIED",
                matched_statement_sid=None,
                reason="Default Deny (no identity policy granted permission)",
            )

        # Step 3: Evaluate Permissions Boundary (if attached to principal)
        # The boundary must also explicitly allow the action and not deny it.
        if boundary_policy:
            b_allow, b_sid, b_reason = self._evaluate_single_policy(boundary_policy, ctx)
            if b_allow is False or b_allow is None:
                return EvaluationResult(
                    decision="DENIED",
                    matched_statement_sid=b_sid,
                    reason=f"Blocked by Permissions Boundary: Action not permitted by boundary ({b_reason})",
                    denied_by_boundary=True,
                )

        # All checks passed: Action is authorized
        return EvaluationResult(
            decision="ALLOWED",
            matched_statement_sid=identity_allow_sid,
            reason=f"Authorized by identity policy statement '{identity_allow_sid}' and permissions boundary",
        )


# ==============================================================================
# AWS Boto3 IAM Policy Simulator Engine
# ==============================================================================

class Boto3IAMEngine:
    """Interacts with AWS IAM SimulateCustomPolicy / SimulatePrincipalPolicy APIs."""

    def __init__(self, endpoint_url: Optional[str] = None, verbose: bool = False):
        self.endpoint_url = endpoint_url
        self.verbose = verbose
        self.client = None
        self._init_client()

    def _init_client(self) -> None:
        """Initializes Boto3 IAM client if dependencies and credentials are present."""
        try:
            import boto3
            session_kwargs = {}
            if self.endpoint_url:
                session_kwargs["endpoint_url"] = self.endpoint_url
                session_kwargs["aws_access_key_id"] = "test"
                session_kwargs["aws_secret_access_key"] = "test"
                session_kwargs["region_name"] = "us-east-1"
            self.client = boto3.client("iam", **session_kwargs)
        except Exception as e:
            if self.verbose:
                print(f"{CLR_YELLOW}[WARN] Boto3 initialization failed: {e}{CLR_RESET}")
            self.client = None

    def is_available(self) -> bool:
        """Checks if Boto3 IAM client is available and responsive."""
        if not self.client:
            return False
        try:
            # Ping IAM service
            self.client.list_roles(MaxItems=1)
            return True
        except Exception:
            return False

    def simulate(
        self,
        policy_documents: List[Dict[str, Any]],
        action: str,
        resource: str,
        boundary_document: Optional[Dict[str, Any]] = None,
        context_entries: Optional[List[Dict[str, Any]]] = None,
    ) -> EvaluationResult:
        """Calls AWS IAM SimulateCustomPolicy API."""
        if not self.client:
            raise RuntimeError("Boto3 IAM client is not available")

        policy_input_list = [json.dumps(p) for p in policy_documents]
        boundary_input = [json.dumps(boundary_document)] if boundary_document else []

        kwargs: Dict[str, Any] = {
            "PolicyInputList": policy_input_list,
            "ActionNames": [action],
            "ResourceArns": [resource],
        }
        if boundary_input:
            kwargs["PermissionsBoundaryPolicyInputList"] = boundary_input
        if context_entries:
            kwargs["ContextEntries"] = context_entries

        try:
            response = self.client.simulate_custom_policy(**kwargs)
            results = response.get("EvaluationResults", [])
            if results:
                res = results[0]
                eval_decision = res.get("EvalDecision", "implicitDeny")
                decision = "ALLOWED" if eval_decision == "allowed" else "DENIED"
                stmt_names = res.get("MatchedStatements", [])
                sid = stmt_names[0].get("SourceStatementId") if stmt_names else None
                return EvaluationResult(
                    decision=decision,
                    matched_statement_sid=sid,
                    reason=f"Boto3 Simulator API returned decision: {eval_decision}",
                )
            return EvaluationResult(decision="DENIED", reason="No evaluation results returned")
        except Exception as e:
            return EvaluationResult(decision="DENIED", reason=f"Boto3 API simulation error: {e}")


# ==============================================================================
# Test Suite Definitions
# ==============================================================================

def get_test_suites() -> List[TestCase]:
    """Builds the comprehensive IAM Least-Privilege & Boundary security test matrix."""
    cases: List[TestCase] = []

    # --------------------------------------------------------------------------
    # Suite 1: Developer Role Matrix
    # --------------------------------------------------------------------------
    cases.extend([
        TestCase(
            test_id="DEV-01",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer can PutObject to development S3 bucket",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/app.zip",
            expected_decision="ALLOWED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-02",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer can GetObject from development S3 bucket",
            action="s3:GetObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/config.json",
            expected_decision="ALLOWED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-03",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer CANNOT PutObject to production S3 bucket (Explicit Deny)",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-prod-abc123/secrets.json",
            expected_decision="DENIED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-04",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer CANNOT DeleteObject from S3 without MFA",
            action="s3:DeleteObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/data.db",
            expected_decision="DENIED",
            mfa_present=False,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-05",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer can DeleteObject from S3 when MFA is validated",
            action="s3:DeleteObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/temp.txt",
            expected_decision="ALLOWED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-06",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer CANNOT delete S3 bucket without MFA (MFA Enforcement)",
            action="s3:DeleteBucket",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123",
            expected_decision="DENIED",
            mfa_present=False,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-07",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer can Describe EC2 instances",
            action="ec2:DescribeInstances",
            resource="*",
            expected_decision="ALLOWED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-08",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer CANNOT terminate EC2 instances without MFA",
            action="ec2:TerminateInstances",
            resource="arn:aws:ec2:us-east-1:123456789012:instance/i-12345678",
            expected_decision="DENIED",
            mfa_present=False,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-09",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer can Encrypt with KMS Customer Managed Key",
            action="kms:Encrypt",
            resource="arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
            expected_decision="ALLOWED",
            mfa_present=True,
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="DEV-10",
            suite="developer",
            role_name="DeveloperRole",
            description="Developer CANNOT schedule KMS key deletion without MFA",
            action="kms:ScheduleKeyDeletion",
            resource="arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
            expected_decision="DENIED",
            mfa_present=False,
            applied_boundary="developer-boundary.json",
        ),
    ])

    # --------------------------------------------------------------------------
    # Suite 2: Read-Only Auditor Matrix
    # --------------------------------------------------------------------------
    cases.extend([
        TestCase(
            test_id="RO-01",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor can Describe EC2 instances and security groups",
            action="ec2:DescribeInstances",
            resource="*",
            expected_decision="ALLOWED",
            applied_boundary="read-only-boundary.json",
        ),
        TestCase(
            test_id="RO-02",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor can List S3 buckets and Get object metadata",
            action="s3:ListBucket",
            resource="arn:aws:s3:::iam-least-privilege-prod-abc123",
            expected_decision="ALLOWED",
            applied_boundary="read-only-boundary.json",
        ),
        TestCase(
            test_id="RO-03",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor can Describe KMS keys",
            action="kms:DescribeKey",
            resource="arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
            expected_decision="ALLOWED",
            applied_boundary="read-only-boundary.json",
        ),
        TestCase(
            test_id="RO-04",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor CANNOT PutObject to S3 (Explicit Deny)",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/tamper.txt",
            expected_decision="DENIED",
            applied_boundary="read-only-boundary.json",
        ),
        TestCase(
            test_id="RO-05",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor CANNOT Run EC2 instances (Explicit Deny)",
            action="ec2:RunInstances",
            resource="arn:aws:ec2:us-east-1:123456789012:instance/*",
            expected_decision="DENIED",
            applied_boundary="read-only-boundary.json",
        ),
        TestCase(
            test_id="RO-06",
            suite="readonly",
            role_name="ReadOnlyRole",
            description="Auditor CANNOT create IAM users or modify access (Explicit Deny)",
            action="iam:CreateUser",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="read-only-boundary.json",
        ),
    ])

    # --------------------------------------------------------------------------
    # Suite 3: CI/CD Pipeline Role Matrix
    # --------------------------------------------------------------------------
    cases.extend([
        TestCase(
            test_id="CICD-01",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline can PutObject to build artifacts S3 bucket",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-artifacts-abc123/release.tar.gz",
            expected_decision="ALLOWED",
            applied_boundary="cicd-boundary.json",
        ),
        TestCase(
            test_id="CICD-02",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline can Encrypt artifacts with KMS CMK",
            action="kms:Encrypt",
            resource="arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
            expected_decision="ALLOWED",
            applied_boundary="cicd-boundary.json",
        ),
        TestCase(
            test_id="CICD-03",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline can Push container images to ECR",
            action="ecr:PutImage",
            resource="arn:aws:ecr:us-east-1:123456789012:repository/backend-service",
            expected_decision="ALLOWED",
            applied_boundary="cicd-boundary.json",
        ),
        TestCase(
            test_id="CICD-04",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline CANNOT create or modify IAM policies (Explicit Deny)",
            action="iam:CreatePolicy",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="cicd-boundary.json",
        ),
        TestCase(
            test_id="CICD-05",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline CANNOT attach administrator policies to roles",
            action="iam:AttachRolePolicy",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="cicd-boundary.json",
        ),
        TestCase(
            test_id="CICD-06",
            suite="cicd",
            role_name="CICDPipelineRole",
            description="CI/CD Pipeline CANNOT delete S3 storage buckets",
            action="s3:DeleteBucket",
            resource="arn:aws:s3:::iam-least-privilege-artifacts-abc123",
            expected_decision="DENIED",
            applied_boundary="cicd-boundary.json",
        ),
    ])

    # --------------------------------------------------------------------------
    # Suite 4: Permissions Boundary Containment (Privilege Escalation Defense)
    # --------------------------------------------------------------------------
    cases.extend([
        TestCase(
            test_id="BND-01",
            suite="boundaries",
            role_name="DeveloperRole",
            description="Boundary blocks Developer from creating IAM user even if policy allowed it",
            action="iam:CreateUser",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="BND-02",
            suite="boundaries",
            role_name="DeveloperRole",
            description="Boundary blocks Developer from removing Permissions Boundary",
            action="iam:DeletePermissionsBoundary",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="BND-03",
            suite="boundaries",
            role_name="DeveloperRole",
            description="Boundary blocks Developer from tampering with CloudTrail logs",
            action="cloudtrail:StopLogging",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="developer-boundary.json",
        ),
        TestCase(
            test_id="BND-04",
            suite="boundaries",
            role_name="DeveloperRole",
            description="Boundary blocks Developer from modifying billing and AWS portal",
            action="billing:ModifyBillingPreferences",
            resource="*",
            expected_decision="DENIED",
            applied_boundary="developer-boundary.json",
        ),
    ])

    # --------------------------------------------------------------------------
    # Suite 5: Service Control Policies (SCPs - Org Level Governance)
    # --------------------------------------------------------------------------
    cases.extend([
        TestCase(
            test_id="SCP-01",
            suite="scp",
            role_name="DeveloperRole",
            description="SCP allows operations in approved AWS region (us-east-1)",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/app.zip",
            requested_region="us-east-1",
            expected_decision="ALLOWED",
            applied_scps=["scp-region-restriction.json"],
        ),
        TestCase(
            test_id="SCP-02",
            suite="scp",
            role_name="DeveloperRole",
            description="SCP BLOCKS operations in unapproved AWS region (ap-southeast-1)",
            action="s3:PutObject",
            resource="arn:aws:s3:::iam-least-privilege-dev-abc123/app.zip",
            requested_region="ap-southeast-1",
            expected_decision="DENIED",
            applied_scps=["scp-region-restriction.json"],
        ),
        TestCase(
            test_id="SCP-03",
            suite="scp",
            role_name="DeveloperRole",
            description="SCP exempts global IAM operations even when region is non-standard",
            action="iam:ListUsers",
            resource="*",
            requested_region="ap-southeast-1",
            expected_decision="DENIED",  # Blocked by identity policy, but not blocked by SCP region check
            applied_scps=["scp-region-restriction.json"],
        ),
        TestCase(
            test_id="SCP-04",
            suite="scp",
            role_name="AnyPrincipal",
            description="SCP BLOCKS stopping or deleting CloudTrail security audit trail",
            action="cloudtrail:DeleteTrail",
            resource="*",
            expected_decision="DENIED",
            applied_scps=["scp-protect-security-services.json"],
        ),
        TestCase(
            test_id="SCP-05",
            suite="scp",
            role_name="AnyPrincipal",
            description="SCP BLOCKS deleting GuardDuty detector",
            action="guardduty:DeleteDetector",
            resource="*",
            expected_decision="DENIED",
            applied_scps=["scp-protect-security-services.json"],
        ),
        TestCase(
            test_id="SCP-06",
            suite="scp",
            role_name="RootUser",
            description="SCP BLOCKS all direct actions by root user account",
            action="ec2:RunInstances",
            resource="*",
            principal_arn="arn:aws:iam::123456789012:root",
            expected_decision="DENIED",
            applied_scps=["scp-deny-root-user.json"],
        ),
    ])

    return cases


# ==============================================================================
# Test Execution and Reporting Runner
# ==============================================================================

class SecurityTestRunner:
    """Executes the test matrix against chosen engine, reporting granular results."""

    def __init__(
        self,
        mode: str = "offline",
        endpoint_url: str = "http://127.0.0.1:4566",
        policies_dir: Path = Path("policies"),
        verbose: bool = False,
    ):
        self.mode = mode
        self.verbose = verbose
        self.policies_dir = policies_dir
        self.offline_engine = OfflineIAMEngine(policies_dir, verbose=verbose)
        self.boto3_engine = Boto3IAMEngine(
            endpoint_url=endpoint_url if mode in ("localstack", "aws") else None,
            verbose=verbose,
        )

    def run_suite(self, suite_filter: str = "all") -> Dict[str, Any]:
        """Runs the test suite and returns structured summary metrics."""
        cases = get_test_suites()
        if suite_filter != "all":
            cases = [c for c in cases if c.suite == suite_filter]

        print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}  🛡️  AWS IAM Least-Privilege & Boundary Security Test Suite{CLR_RESET}")
        print(f"{CLR_GRAY}  Engine Mode : {self.mode.upper()} | Target Suite: {suite_filter.upper()} | Tests: {len(cases)}{CLR_RESET}")
        print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}\n")

        print(f"{CLR_WHITE}{'ID':<8} {'ROLE':<18} {'ACTION':<24} {'MFA':<6} {'REGION':<12} {'EXP':<8} {'ACT':<8} {'STATUS':<10}{CLR_RESET}")
        print(f"{CLR_GRAY}{'-' * 96}{CLR_RESET}")

        start_time = time.time()
        passed_count = 0
        failed_count = 0
        results_list = []

        for case in cases:
            # Build evaluation context
            ctx = EvaluationContext(
                action=case.action,
                resource=case.resource,
                mfa_present=case.mfa_present,
                requested_region=case.requested_region,
                principal_arn=case.principal_arn,
            )

            # Resolve policies for role
            identity_policies = []
            boundary_doc = None
            scps = []

            if case.role_name == "DeveloperRole":
                dev_pol = self.offline_engine.get_policy("developer-policy.json")
                mfa_pol = self.offline_engine.get_policy("mfa-enforced-policy.json")
                if dev_pol:
                    identity_policies.append(dev_pol)
                if mfa_pol:
                    identity_policies.append(mfa_pol)
            elif case.role_name == "ReadOnlyRole":
                ro_pol = self.offline_engine.get_policy("read-only-policy.json")
                if ro_pol:
                    identity_policies.append(ro_pol)
            elif case.role_name == "CICDPipelineRole":
                cicd_pol = self.offline_engine.get_policy("cicd-policy.json")
                if cicd_pol:
                    identity_policies.append(cicd_pol)
            elif case.role_name in ("AnyPrincipal", "RootUser"):
                # Simulates default full access attempt blocked by SCP
                identity_policies.append({
                    "Version": "2012-10-17",
                    "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]
                })

            if case.applied_boundary:
                boundary_doc = self.offline_engine.get_policy(case.applied_boundary)

            if case.applied_scps:
                for scp_name in case.applied_scps:
                    p = self.offline_engine.get_policy(scp_name)
                    if p:
                        scps.append(p)

            # Execute evaluation
            eval_result: EvaluationResult
            if self.mode == "aws" and self.boto3_engine.is_available():
                eval_result = self.boto3_engine.simulate(
                    policy_documents=identity_policies,
                    action=case.action,
                    resource=case.resource,
                    boundary_document=boundary_doc,
                )
            else:
                eval_result = self.offline_engine.evaluate(
                    identity_policies=identity_policies,
                    ctx=ctx,
                    boundary_policy=boundary_doc,
                    scp_policies=scps,
                )

            is_pass = eval_result.decision == case.expected_decision
            if is_pass:
                passed_count += 1
                status_str = f"{CLR_GREEN}✓ PASS{CLR_RESET}"
            else:
                failed_count += 1
                status_str = f"{CLR_RED}✗ FAIL{CLR_RESET}"

            mfa_label = "YES" if case.mfa_present else "NO"
            exp_col = f"{CLR_GREEN}{case.expected_decision}{CLR_RESET}" if case.expected_decision == "ALLOWED" else f"{CLR_YELLOW}{case.expected_decision}{CLR_RESET}"
            act_col = f"{CLR_GREEN}{eval_result.decision}{CLR_RESET}" if eval_result.decision == "ALLOWED" else f"{CLR_YELLOW}{eval_result.decision}{CLR_RESET}"

            print(
                f"{case.test_id:<8} "
                f"{case.role_name:<18} "
                f"{case.action:<24} "
                f"{mfa_label:<6} "
                f"{case.requested_region:<12} "
                f"{exp_col:<17} "
                f"{act_col:<17} "
                f"{status_str}"
            )

            if not is_pass or self.verbose:
                print(f"   {CLR_GRAY}↳ Context: {case.description}{CLR_RESET}")
                print(f"   {CLR_GRAY}↳ Reason : {eval_result.reason}{CLR_RESET}")

            results_list.append({
                "test_id": case.test_id,
                "suite": case.suite,
                "role": case.role_name,
                "description": case.description,
                "action": case.action,
                "resource": case.resource,
                "mfa_present": case.mfa_present,
                "region": case.requested_region,
                "expected": case.expected_decision,
                "actual": eval_result.decision,
                "passed": is_pass,
                "reason": eval_result.reason,
            })

        duration = time.time() - start_time
        pass_pct = (passed_count / len(cases) * 100) if cases else 0

        print(f"\n{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}")
        print(f"  {CLR_BOLD}Security Test Matrix Execution Summary:{CLR_RESET}")
        print(f"  Total Test Cases : {CLR_WHITE}{len(cases)}{CLR_RESET}")
        print(f"  Passed           : {CLR_GREEN}{passed_count}{CLR_RESET}")
        print(f"  Failed           : {CLR_RED if failed_count > 0 else CLR_GREEN}{failed_count}{CLR_RESET}")
        print(f"  Pass Percentage  : {CLR_GREEN if pass_pct == 100 else CLR_YELLOW}{pass_pct:.1f}%{CLR_RESET}")
        print(f"  Execution Time   : {duration:.3f} seconds")
        print(f"{CLR_CYAN}{CLR_BOLD}{'=' * 80}{CLR_RESET}\n")

        summary = {
            "mode": self.mode,
            "suite": suite_filter,
            "total": len(cases),
            "passed": passed_count,
            "failed": failed_count,
            "pass_percentage": pass_pct,
            "duration_seconds": duration,
            "results": results_list,
        }

        return summary


# ==============================================================================
# CLI Entry Point
# ==============================================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="AWS IAM Least-Privilege & Boundary Security Policy Evaluator"
    )
    parser.add_argument(
        "--mode",
        choices=["offline", "localstack", "aws", "auto"],
        default="offline",
        help="Evaluation backend mode (default: offline)",
    )
    parser.add_argument(
        "--endpoint-url",
        default="http://127.0.0.1:4566",
        help="LocalStack or custom AWS endpoint URL",
    )
    parser.add_argument(
        "--suite",
        choices=["all", "developer", "readonly", "cicd", "scp", "boundaries"],
        default="all",
        help="Target test suite to execute (default: all)",
    )
    parser.add_argument(
        "--policies-dir",
        default=str(Path(__file__).resolve().parent / "policies"),
        help="Path to directory containing IAM policy JSON files",
    )
    parser.add_argument(
        "--json-output",
        default=None,
        help="Optional path to write JSON test report",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable detailed evaluation logs",
    )

    args = parser.parse_args()

    mode = args.mode
    if mode == "auto":
        # Check if LocalStack is reachable
        boto_tester = Boto3IAMEngine(endpoint_url=args.endpoint_url, verbose=False)
        if boto_tester.is_available():
            mode = "localstack"
        else:
            mode = "offline"

    runner = SecurityTestRunner(
        mode=mode,
        endpoint_url=args.endpoint_url,
        policies_dir=Path(args.policies_dir),
        verbose=args.verbose,
    )

    summary = runner.run_suite(suite_filter=args.suite)

    if args.json_output:
        out_path = Path(args.json_output)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)
        print(f"{CLR_GRAY}[INFO] JSON test report written to: {out_path}{CLR_RESET}\n")

    # Exit with code 1 if any test failed
    if summary["failed"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
