#!/usr/bin/env python3
"""Generate pg_regress expected files from labeled template branches."""

import argparse
import sys
from pathlib import Path


class TemplateError(ValueError):
    """Invalid regression template input."""


def render_template(lines, labels):
    """Select one branch per block, preserving literal output bytes."""
    result = []
    # None means outside a block; [] means waiting for its first branch.
    branches = None
    block_line = None

    for number, line in enumerate(lines, 1):
        tag = line.rstrip(b"\r\n")
        if tag == b"@@ BEGIN @@":
            if branches is not None:
                raise TemplateError(f"line {number}: nested @@ BEGIN @@")
            branches = []
            block_line = number
        elif tag == b"@@ DEFAULT @@" or tag.startswith(b"@@ WHEN "):
            if branches is None:
                raise TemplateError(
                    f"line {number}: branch outside @@ BEGIN @@"
                )
            if tag == b"@@ DEFAULT @@":
                if any(names is None for names, _ in branches):
                    raise TemplateError(
                        f"line {number}: duplicate @@ DEFAULT @@"
                    )
                names = None
            else:
                if not tag.endswith(b" @@"):
                    raise TemplateError(
                        f"line {number}: expected @@ WHEN LABEL ... @@"
                    )
                names = set(
                    tag[8:-3].decode("utf-8", "surrogateescape").split()
                )
                if not names:
                    raise TemplateError(
                        f"line {number}: @@ WHEN requires a label"
                    )
            # Each branch holds (labels, lines); None marks the default.
            branches.append((names, []))
        elif tag == b"@@ END @@":
            if branches is None:
                raise TemplateError(
                    f"line {number}: @@ END @@ outside @@ BEGIN @@"
                )
            default = [text for names, text in branches if names is None]
            if not default:
                raise TemplateError(
                    f"line {block_line}: missing @@ DEFAULT @@"
                )
            # Match any active label; select at END to detect conflicts.
            matches = [
                (names & labels, text)
                for names, text in branches
                if names is not None and names & labels
            ]
            if len(matches) > 1:
                conflicts = ", ".join(
                    sorted(name for names, _ in matches for name in names)
                )
                raise TemplateError(
                    f"line {block_line}: multiple branches match labels: "
                    f"{conflicts}"
                )
            result.extend(matches[0][1] if matches else default[0])
            branches = None
        elif branches is None:
            result.append(line)
        elif not branches:
            raise TemplateError(
                f"line {number}: expected @@ DEFAULT @@ "
                "or @@ WHEN LABEL ... @@"
            )
        else:
            branches[-1][1].append(line)

    if branches is not None:
        raise TemplateError(f"line {block_line}: missing @@ END @@")
    return b"".join(result)


def generate_expected(source, destination, labels):
    """Expand each template into an ordinary expected file."""
    templates = sorted(source.glob("*.out"))
    if not templates:
        raise TemplateError(f"{source}: no expected files found")

    for template in templates:
        try:
            with template.open("rb") as stream:
                expected = render_template(stream, labels)
        except TemplateError as error:
            raise TemplateError(f"{template}: {error}") from error
        (destination / template.name).write_bytes(expected)


def main():
    """Parse arguments and report generation errors."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source", type=Path, help="maintained expected directory"
    )
    parser.add_argument(
        "destination", type=Path, help="generated expected directory"
    )
    parser.add_argument("labels", nargs="*", help="active environment labels")
    args = parser.parse_args()

    try:
        generate_expected(args.source, args.destination, set(args.labels))
    except (OSError, TemplateError) as error:
        print(f"regression template error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
