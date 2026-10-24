#!/usr/bin/env python3
"""Expand regression output templates through pg_regress's psql launcher."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class TemplateError(ValueError):
    pass


def line_body(text):
    if text.endswith("\r\n"):
        return text[:-2]
    return text[:-1] if text.endswith("\n") else text


def read_text(path):
    with path.open(encoding="utf-8", errors="surrogateescape", newline="") as stream:
        return stream.read()


def write_text(path, text):
    with path.open("w", encoding="utf-8", errors="surrogateescape", newline="") as stream:
        stream.write(text)


def parse_template(text):
    """Return nodes containing one or more alternative sequences of lines."""
    nodes = []
    branches = None
    block_line = None
    for number, text in enumerate(text.splitlines(keepends=True), 1):
        tag = line_body(text)
        if tag == "@oneof@":
            if branches is not None:
                raise TemplateError(f"line {number}: nested @oneof@")
            branches = [[]]
            block_line = number
        elif tag in ("@or@", "@end@"):
            if branches is None:
                raise TemplateError(f"line {number}: {tag} outside @oneof@")
            if tag == "@or@":
                branches.append([])
            else:
                if len(branches) < 2:
                    raise TemplateError(f"line {block_line}: @oneof@ needs at least two branches")
                nodes.append(branches)
                branches = None
        else:
            pattern = None
            if tag.startswith("@regex@"):
                if not tag.startswith("@regex@ "):
                    raise TemplateError(f"line {number}: expected '@regex@ PATTERN'")
                try:
                    pattern = re.compile(tag[len("@regex@ "):])
                except re.error as error:
                    raise TemplateError(f"line {number}: {error}") from error
            line = (number, text, pattern)
            if branches is None:
                nodes.append([[line]])
            else:
                branches[-1].append(line)
    if branches is not None:
        raise TemplateError(f"line {block_line}: missing @end@")
    return nodes


def line_matches(line, actual):
    _, text, pattern = line
    if pattern is None:
        return text == actual
    if text.endswith("\n") != actual.endswith("\n"):
        return False
    return pattern.fullmatch(line_body(actual)) is not None


def matching_prefix(branch, actual, position):
    matched = 0
    for line in branch:
        if position + matched == len(actual) or not line_matches(line, actual[position + matched]):
            break
        matched += 1
    return matched


def render_failure(nodes, actual, position):
    """Keep literal expectations in the diff and expand matching regex lines."""
    result = list(actual[:position])
    for branches in nodes:
        branch = max(branches, key=lambda candidate: matching_prefix(candidate, actual, position))
        for line in branch:
            if position < len(actual) and line_matches(line, actual[position]):
                result.append(actual[position])
            else:
                result.append(line[1])
            if position < len(actual):
                position += 1
    return "".join(result)


def expand_template(nodes, output):
    """Match the complete output, retaining all viable alternative positions."""
    actual = output.splitlines(keepends=True)
    positions = {0}
    for index, branches in enumerate(nodes):
        next_positions = set()
        for position in positions:
            for branch in branches:
                if matching_prefix(branch, actual, position) == len(branch):
                    next_positions.add(position + len(branch))
        if not next_positions:
            position = max(positions)
            line_numbers = [line[0] for branch in branches for line in branch]
            message = f"template line {min(line_numbers)}: mismatch at output line {position + 1}"
            return render_failure(nodes[index:], actual, position), message
        positions = next_positions
    if len(actual) in positions:
        return output, None
    position = max(positions)
    return "".join(actual[:position]), f"unexpected output at line {position + 1}"


def prepare(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    templates = sorted(source.glob("*.out.in"))
    for template in templates:
        parse_template(read_text(template))
    # Rebuild the generated directory so removed alternatives cannot affect a run.
    for old in destination.glob("*.out"):
        old.unlink()
    for old in destination.glob("*.match"):
        old.unlink()
    for expected in source.glob("*.out"):
        shutil.copyfile(expected, destination / expected.name)
    for template in templates:
        shutil.copyfile(template, destination / template.stem)


def launch(source, destination, command):
    appname = os.environ.get("PGAPPNAME", "")
    if not appname.startswith("pg_regress/"):
        raise TemplateError("launcher requires PGAPPNAME=pg_regress/TEST")
    test = appname[len("pg_regress/"):]
    if not test or Path(test).name != test:
        raise TemplateError("invalid regression test name")
    template = source / (test + ".out.in")
    if not template.exists():
        return subprocess.run(command).returncode
    nodes = parse_template(read_text(template))
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    sys.stdout.buffer.write(process.stdout)
    sys.stdout.buffer.flush()
    expected, error = expand_template(nodes, process.stdout.decode("utf-8", errors="surrogateescape"))
    write_text(destination / (test + ".out"), expected)
    diagnostic = destination / (test + ".match")
    if error:
        write_text(diagnostic, f"{template}: {error}\n")
    elif diagnostic.exists():
        diagnostic.unlink()
    return process.returncode or int(error is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "launch"))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            prepare(args.source, args.destination)
            return 0
        if not args.command:
            raise TemplateError("launcher requires a command")
        return launch(args.source, args.destination, args.command)
    except (OSError, TemplateError) as error:
        print(f"regression template error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
