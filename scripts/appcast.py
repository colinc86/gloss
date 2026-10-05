#!/usr/bin/env python3
"""Adds a release to Gloss's Sparkle appcast, newest first, creating the feed if it doesn't exist."""
import argparse
import email.utils
import os
import re

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Gloss</title>
    <link>https://github.com/colinc86/gloss/releases</link>
    <description>Gloss releases</description>
    <language>en</language>
"""
FOOTER = """  </channel>
</rss>
"""
# Sparkle shows the notes in a web view: the system font, and the reader's light or dark appearance.
STYLE = """<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 0 4px; }
h1, h2, h3 { font-size: 1.05em; margin: 1em 0 .4em; }
ul, ol { padding-left: 1.4em; }
code { font: 12px ui-monospace, SF Mono, Menlo, monospace; }
a { color: -apple-system-control-accent; }
</style>
"""


def item(args, notes):
    signature = re.search(r'sparkle:edSignature="([^"]+)"', args.signature)
    length = re.search(r'length="(\d+)"', args.signature)
    if not signature or not length:
        raise SystemExit(f"appcast: can't read sign_update's output: {args.signature}")
    html = (STYLE + notes).replace("]]>", "]]]]><![CDATA[>")
    return f"""    <item>
      <title>Gloss {args.version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{html}]]></description>
      <enclosure url="{args.url}" type="application/octet-stream" sparkle:edSignature="{signature.group(1)}" length="{length.group(1)}"/>
    </item>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("feed")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes", required=True)
    args = parser.parse_args()
    with open(args.notes, encoding="utf-8") as f:
        notes = f.read()
    if os.path.exists(args.feed):
        with open(args.feed, encoding="utf-8") as f:
            feed = f.read()
        marker = "    <item>"
        index = feed.find(marker)
        if index < 0:
            index = feed.index("  </channel>")
        feed = feed[:index] + item(args, notes) + feed[index:]
    else:
        feed = HEADER + item(args, notes) + FOOTER
    with open(args.feed, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
