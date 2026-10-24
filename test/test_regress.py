#!/usr/bin/env python3
"""Tests for output matching and the pg_regress launcher boundary."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import regress


class MatchingTests(unittest.TestCase):
    def check_match(self, template, output, matches=True):
        expected, error = regress.expand_template(regress.parse_template(template), output)
        self.assertEqual(error is None, matches, error)
        if matches:
            self.assertEqual(expected, output)
        return expected

    def test_literal_whitespace_and_eof(self):
        for output in (" value \n", "value \n", " value\n", " value ", " value \nextra\n"):
            with self.subTest(output=output):
                self.check_match(" value \n", output, output == " value \n")
        self.check_match("", "")
        self.check_match("", "extra\n", False)

    def test_regex_matches_one_complete_line(self):
        template = "before\n@regex@    InitPlan (expr_1|1)\nafter\n"
        for name in ("expr_1", "1"):
            self.check_match(template, f"before\n   InitPlan {name}\nafter\n")
        for output in ("before\n   InitPlan 2\nafter\n", "before\n   InitPlan 1 suffix\nafter\n",
                       "before\nInitPlan 1\nafter\n", "before\n   InitPlan 1\nextra\nafter\n"):
            self.check_match(template, output, False)
        self.check_match("@regex@ .*\n", "one\ntwo\n", False)
        self.check_match("@regex@ id=[0-9]+\r\n", "id=42\r\n")
        self.check_match("@regex@ id=[0-9]+\n", "id=42", False)

    def test_alternatives_and_empty_branches(self):
        template = "a\n@oneof@\nold\n@or@\nnew\nextra\n@end@\nz\n"
        self.check_match(template, "a\nold\nz\n")
        self.check_match(template, "a\nnew\nextra\nz\n")
        self.check_match(template, "a\nnew\nz\n", False)
        self.check_match(template, "a\nold\nextra\nz\n", False)
        for template in ("@oneof@\n@or@\nhelp\n@end@\nend\n",
                         "@oneof@\nhelp\n@or@\n@end@\nend\n"):
            self.check_match(template, "end\n")
            self.check_match(template, "help\nend\n")

    def test_branch_selection_uses_following_context(self):
        template = "@oneof@\na\n@or@\na\nb\n@end@\nb\n"
        self.check_match(template, "a\nb\n")
        self.check_match(template, "a\nb\nb\n")
        self.check_match(template, "a\nb\nb\nb\n", False)

    def test_regex_inside_block(self):
        template = "@oneof@\n@regex@ ERROR: ORA-(00001|01456)\n@or@\nOK\n@end@\n"
        for output in ("OK\n", "ERROR: ORA-00001\n", "ERROR: ORA-01456\n"):
            self.check_match(template, output)
        self.check_match(template, "ERROR: ORA-00942\n", False)

    def test_failure_rendering_preserves_literal_expectation(self):
        template = "@regex@ id=[0-9]+\nexpected\n"
        expected = self.check_match(template, "id=42\nwrong\n", False)
        self.assertEqual(expected, "id=42\nexpected\n")

    def test_invalid_templates_report_line_numbers(self):
        for text, number in (("@or@\n", 1), ("@end@\n", 1), ("@oneof@\na\n@end@\n", 1),
                             ("a\n@oneof@\n", 2), ("@oneof@\n@oneof@\n", 2),
                             ("@regex@ [\n", 1), ("@regex@\n", 1)):
            with self.subTest(text=text):
                with self.assertRaisesRegex(regress.TemplateError, f"line {number}:"):
                    regress.parse_template(text)


class LauncherTests(unittest.TestCase):
    def test_prepare_and_launcher_preserve_output_and_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            destination = root / "generated"
            source.mkdir()
            (source / "probe.out.in").write_text("@regex@ id=[0-9]+\nexpected\n")
            (source / "plain.out").write_text("plain\n")
            destination.mkdir()
            (destination / "probe_0.out").write_text("stale\n")
            regress.prepare(source, destination)
            self.assertFalse((destination / "probe_0.out").exists())
            self.assertEqual((destination / "plain.out").read_text(), "plain\n")
            env = dict(os.environ, PGAPPNAME="pg_regress/probe")
            prefix = [sys.executable, str(Path(regress.__file__).resolve()), "launch",
                      str(source), str(destination), sys.executable, "-c"]
            for actual, status, expected_status in (("id=42\nexpected\n", 0, 0),
                                                     ("id=42\nwrong\n", 0, 1),
                                                     ("id=42\nexpected\n", 7, 7)):
                with self.subTest(actual=actual, status=status):
                    command = f"import sys; sys.stdout.write({actual!r}); sys.exit({status})"
                    process = subprocess.run(prefix + [command], env=env, capture_output=True)
                    self.assertEqual(process.stdout, actual.encode())
                    self.assertEqual(process.stderr, b"")
                    self.assertEqual(process.returncode, expected_status)
                    if expected_status == 1:
                        self.assertIn("template line 2", (destination / "probe.match").read_text())
                    else:
                        self.assertFalse((destination / "probe.match").exists())

    def test_literal_regex_marker_cannot_turn_failure_into_success(self):
        template = "@regex@ impossible\n"
        expected, error = regress.expand_template(regress.parse_template(template), template)
        self.assertEqual(expected, template)
        self.assertIsNotNone(error)


if __name__ == "__main__":
    unittest.main()
