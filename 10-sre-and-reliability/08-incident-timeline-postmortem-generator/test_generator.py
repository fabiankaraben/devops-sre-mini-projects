#!/usr/bin/env python3
"""
test_generator.py - Comprehensive Validation Suite for SRE Postmortem Generator
================================================================================
Tests timeline chronology, SRE metrics calculations (MTTD, MTTA, MTTM, MTTR),
RCA formatting, JSON/Markdown/HTML rendering, and multi-incident fixtures.
Built with standard library unittest for seamless execution in any environment.
"""

import json
import os
import tempfile
import unittest

from postmortem_generator import (
    IncidentIngestor,
    PostmortemRenderer,
    SREPostmortemCalculator,
    format_duration,
    generate_postmortem,
    list_available_incidents,
    parse_iso8601_utc,
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(SCRIPT_DIR, "mock_incident_logs")


class TestPostmortemGenerator(unittest.TestCase):

    def test_format_duration(self):
        self.assertEqual(format_duration(0), "0s")
        self.assertEqual(format_duration(45), "45s")
        self.assertEqual(format_duration(360), "6m 0s")
        self.assertEqual(format_duration(365), "6m 5s")
        self.assertEqual(format_duration(3660), "1h 1m 0s")

    def test_parse_iso8601_utc(self):
        dt = parse_iso8601_utc("2026-08-26T14:26:00Z")
        self.assertEqual(dt.year, 2026)
        self.assertEqual(dt.month, 8)
        self.assertEqual(dt.day, 26)
        self.assertEqual(dt.hour, 14)
        self.assertEqual(dt.minute, 26)
        self.assertEqual(dt.second, 0)

    def test_timeline_chronological_sorting(self):
        incident_path = os.path.join(DATA_DIR, "INC-402")
        ingestor = IncidentIngestor(incident_path)
        timeline = ingestor.build_complete_timeline()

        self.assertGreaterEqual(len(timeline), 15)

        # Assert monotonic chronological ordering
        for i in range(len(timeline) - 1):
            self.assertLessEqual(
                timeline[i].epoch_timestamp,
                timeline[i + 1].epoch_timestamp,
                f"Timeline out of order: {timeline[i].timestamp_utc} > {timeline[i+1].timestamp_utc}"
            )

    def test_sre_metrics_calculation_inc402(self):
        incident_path = os.path.join(DATA_DIR, "INC-402")
        ingestor = IncidentIngestor(incident_path)
        meta = ingestor.load_meta()
        timeline = ingestor.build_complete_timeline()
        metrics = SREPostmortemCalculator.compute_metrics(meta, timeline)

        # 14:20 to 14:26 = 6 minutes (360 seconds)
        self.assertEqual(metrics.mttd_seconds, 360.0)
        self.assertEqual(metrics.mttd_formatted, "6m 0s")

        # 14:26 to 14:29 = 3 minutes (180 seconds)
        self.assertEqual(metrics.mtta_seconds, 180.0)
        self.assertEqual(metrics.mtta_formatted, "3m 0s")

        # 14:29 to 14:48 = 19 minutes (1140 seconds)
        self.assertEqual(metrics.mttm_seconds, 1140.0)
        self.assertEqual(metrics.mttm_formatted, "19m 0s")

        # 14:20 to 14:55 = 35 minutes (2100 seconds)
        self.assertEqual(metrics.mttr_seconds, 2100.0)
        self.assertEqual(metrics.mttr_formatted, "35m 0s")

        self.assertEqual(metrics.availability_pct, 70.57)
        self.assertEqual(metrics.error_budget_consumed_pct, 42.8)
        self.assertEqual(metrics.failed_requests, 14200)
        self.assertEqual(metrics.total_requests_affected, 48250)

    def test_markdown_generation_structure(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            res = generate_postmortem("INC-402", DATA_DIR, tmp_dir, output_format="markdown")
            md_file = res["files_generated"]["markdown"]
            self.assertTrue(os.path.exists(md_file))

            with open(md_file, "r", encoding="utf-8") as f:
                content = f.read()

            # Check required sections
            self.assertIn("# Postmortem Report: [INC-402]", content)
            self.assertIn("## 1. Executive Summary", content)
            self.assertIn("## 2. Key SRE Operational Metrics", content)
            self.assertIn("## 3. Incident Response Team", content)
            self.assertIn("## 4. Visual Incident Progression", content)
            self.assertIn("```mermaid", content)
            self.assertIn("## 5. Detailed Chronological Timeline", content)
            self.assertIn("## 6. Root Cause Analysis (5-Whys)", content)
            self.assertIn("### Why #1:", content)
            self.assertIn("## 7. Lessons Learned", content)
            self.assertIn("## 8. Preventative Action Items", content)
            self.assertTrue(content.endswith("\n"))

    def test_json_schema_validity(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            res = generate_postmortem("INC-402", DATA_DIR, tmp_dir, output_format="json")
            json_file = res["files_generated"]["json"]
            self.assertTrue(os.path.exists(json_file))

            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            self.assertEqual(data["metadata"]["incident_id"], "INC-402")
            self.assertIn("sre_metrics", data)
            self.assertEqual(data["sre_metrics"]["mttd_seconds"], 360.0)
            self.assertIn("timeline_events", data)
            self.assertGreaterEqual(len(data["timeline_events"]), 15)
            self.assertIn("generated_at", data)

    def test_html_generation(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            res = generate_postmortem("INC-402", DATA_DIR, tmp_dir, output_format="html")
            html_file = res["files_generated"]["html"]
            self.assertTrue(os.path.exists(html_file))

            with open(html_file, "r", encoding="utf-8") as f:
                content = f.read()

            self.assertIn("<!DOCTYPE html>", content)
            self.assertIn("[INC-402]", content)
            self.assertIn("MTTD (Detection)", content)
            self.assertIn("5-Whys Root Cause Analysis", content)

    def test_multi_incident_support(self):
        incidents = list_available_incidents(DATA_DIR)
        self.assertIn("INC-402", incidents)
        self.assertIn("INC-501", incidents)
        self.assertIn("INC-305", incidents)

        with tempfile.TemporaryDirectory() as tmp_dir:
            for inc_id in incidents:
                res = generate_postmortem(inc_id, DATA_DIR, tmp_dir, output_format="all")
                self.assertEqual(res["incident_id"], inc_id)
                self.assertIn("markdown", res["files_generated"])
                self.assertIn("json", res["files_generated"])
                self.assertIn("html", res["files_generated"])

    def test_validation_mode(self):
        res = generate_postmortem("INC-402", DATA_DIR, "/tmp", validate_only=True)
        self.assertEqual(res["status"], "VALID")
        self.assertGreaterEqual(res["event_count"], 15)

    def test_missing_incident_error_handling(self):
        with self.assertRaises(FileNotFoundError):
            generate_postmortem("INC-NON-EXISTENT", DATA_DIR, "/tmp")


if __name__ == "__main__":
    unittest.main(verbosity=2)
