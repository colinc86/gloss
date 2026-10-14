#!/usr/bin/env python3
"""Writes Gloss/About/Acknowledgments.txt: the license (and any NOTICE) of every package the app resolves, then the
theme palettes' notices. Run it after adding or updating a package; a test fails when a resolved package is missing.

    scripts/acknowledgments.py [--checkouts <SourcePackages/checkouts>]

The license texts come from Xcode's package checkouts, so build the app once first.
"""
import argparse
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(ROOT, "Gloss.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
THEMES = os.path.join(ROOT, "Gloss/Themes/ThemeLicenses.txt")
OUT = os.path.join(ROOT, "Gloss/About/Acknowledgments.txt")
HEADER = """Gloss acknowledgments

Gloss is open source under the MIT License. It is built on the packages below, each under its own license, and
its syntax themes adapt the palettes credited at the end.
"""


def checkouts_dir(given):
    if given:
        return given
    found = sorted(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Gloss-*/SourcePackages/checkouts")))
    if len(found) != 1:
        problem = "no package checkouts found; build the app once" if not found else f"{len(found)} DerivedData folders for Gloss"
        sys.exit(f"acknowledgments: {problem}, or pass --checkouts")
    return found[0]


def first(directory, prefixes):
    for name in sorted(os.listdir(directory)):
        if os.path.isfile(os.path.join(directory, name)) and name.lower().split(".")[0] in prefixes:
            return os.path.join(directory, name)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkouts")
    checkouts = checkouts_dir(parser.parse_args().checkouts)
    with open(RESOLVED) as f:
        pins = sorted(json.load(f)["pins"], key=lambda pin: pin["identity"])
    sections = [HEADER]
    for pin in pins:
        name = pin["location"].rstrip("/").split("/")[-1].removesuffix(".git")
        directory = os.path.join(checkouts, name)
        if not os.path.isdir(directory):
            sys.exit(f"acknowledgments: no checkout of {name} in {checkouts}")
        license_file = first(directory, ("license", "licence", "copying"))
        if not license_file:
            sys.exit(f"acknowledgments: {name} has no license file")
        state = pin["state"]
        version = state.get("version") or state.get("revision", "")[:12]
        parts = [f"== {pin['identity']} {version} ==", pin["location"].removesuffix(".git"), ""]
        with open(license_file, encoding="utf-8", errors="replace") as f:
            parts.append(f.read().strip())
        notice = first(directory, ("notice",))
        if notice:
            with open(notice, encoding="utf-8", errors="replace") as f:
                parts += ["", f.read().strip()]
        sections.append("\n".join(parts))
    with open(THEMES, encoding="utf-8") as f:
        sections.append("== Theme palettes ==\n" + f.read().strip())
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n\n\n".join(sections) + "\n")
    print(f"acknowledgments: wrote {len(pins)} packages to {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
