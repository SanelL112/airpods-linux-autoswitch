#!/usr/bin/env python3
"""Generate a WirePlumber drop-in overriding bluez5.hardware-database with an AirPods Pro regex quirk."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_INPUT = Path("/usr/share/spa-0.2/bluez5/bluez-hardware.conf")
DEFAULT_OUTPUT = (
    Path.home()
    / ".config/wireplumber/wireplumber.conf.d/50-bluez-airpods.conf"
)

EXACT_RULE = '{ name = "AirPods Pro", no-features = [ msbc-alt1, msbc-alt1-rtl ] },'
REGEX_RULE = '{ name = "~AirPods Pro", no-features = [ msbc-alt1, msbc-alt1-rtl ] },'


def build_hardware_db(raw_text: str) -> str:
    """Insert regex AirPods Pro rule right after upstream exact match and strip comments."""
    if '"~AirPods Pro"' in raw_text:
        updated = raw_text
    elif EXACT_RULE in raw_text:
        updated = raw_text.replace(
            EXACT_RULE, f"{EXACT_RULE}\n    {REGEX_RULE}", 1
        )
    else:
        raise ValueError(
            "Expected upstream 'AirPods Pro' rule not found in bluez-hardware.conf"
        )

    cleaned_lines = [re.sub(r"#.*", "", line).strip() for line in updated.splitlines()]
    return "\n".join(line for line in cleaned_lines if line)


def render_conf(body: str) -> str:
    """Wrap stripped quirks DB into a WirePlumber monitor.bluez.properties fragment."""
    return (
        "# Override BlueZ hardware quirk DB so custom-named 'AirPods Pro' matches upstream quirk rule\n"
        "monitor.bluez.properties = {\n"
        f"  bluez5.hardware-database = {json.dumps(body)}\n"
        "}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--stdout", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        return 1

    conf_text = render_conf(build_hardware_db(args.input.read_text(encoding="utf-8")))

    if args.stdout or args.dry_run:
        if args.dry_run and not args.stdout:
            print(f"[dry-run] Would write {len(conf_text)} bytes to {args.output}")
        else:
            sys.stdout.write(conf_text)
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(conf_text, encoding="utf-8")
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
