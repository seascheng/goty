#!/usr/bin/env python3
"""Insert (or replace) a release item at the top of appcast.xml's
channel. Called by swift-app/release.sh with the values Sparkle needs;
the file is plain text on purpose — no XML rewriter touches the parts
it does not manage (the same discipline as GhosttyConfigDocument).

    update_appcast.py appcast.xml --version 0.1.0 --build 1 \
        --url https://github.com/seascheng/goty/releases/download/v0.1.0/Goty-0.1.0-arm64.dmg \
        --signature <edSignature> --length <bytes> \
        --notes-file dist/notes.md
"""
import argparse
import datetime
import html
import pathlib
import sys

ITEM = """  <item>
    <title>Version {version} (Build {build})</title>
    <pubDate>{pub_date}</pubDate>
    <sparkle:version>{build}</sparkle:version>
    <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[<ul>{items}</ul>]]></description>
    <enclosure url="{url}"
               type="application/octet-stream"
               sparkle:edSignature="{signature}"
               length="{length}" />
  </item>
"""


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("appcast", type=pathlib.Path)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--notes-file", type=pathlib.Path)
    p.add_argument("--notes")
    args = p.parse_args()

    if args.notes_file:
        lines = [l.strip() for l in args.notes_file.read_text().splitlines() if l.strip()]
    else:
        lines = [l.strip() for l in (args.notes or "").splitlines() if l.strip()]
    bullets = "".join(f"<li>{html.escape(l)}</li>" for l in lines) or \
        f"<li>Goty {args.version}</li>"

    item = ITEM.format(
        version=args.version, build=args.build,
        pub_date=datetime.datetime.now(datetime.timezone.utc)
            .strftime("%a, %d %b %Y %H:%M:%S +0000"),
        items=bullets, url=args.url, signature=args.signature, length=args.length)

    text = args.appcast.read_text()
    marker = f"    <sparkle:version>{args.build}</sparkle:version>"
    if marker in text:  # same build re-released: replace that item whole
        start = text.index("  <item>", 0, text.index(marker))
        end = text.index("  </item>", text.index(marker)) + len("  </item>")
        text = text[:start] + item.rstrip("\n") + text[end:]
    elif "<item>" in text:  # newest first
        text = text.replace("  <item>", item + "  <item>", 1)
    else:
        text = text.replace("  </channel>", item + "  </channel>")
    args.appcast.write_text(text)
    print(f"appcast: {args.version} (build {args.build}) → {args.appcast}")


if __name__ == "__main__":
    sys.exit(main())
