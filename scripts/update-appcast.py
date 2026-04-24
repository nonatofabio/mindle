#!/usr/bin/env python3
"""Insert a new <item> into docs/appcast.xml for a just-released version.

Called from the GitHub Actions release workflow after the DMG has been
signed by Sparkle's sign_update tool. The script appends the new release
just before </channel>, keeping older releases in the feed so users on
older versions can still see a consistent update chain.

Arguments (positional):
  version        e.g. "1.3.0"
  build_number   e.g. "42"
  ed_signature   base64 EdDSA signature of the DMG (from sign_update)
  length         byte length of the DMG (from sign_update)

Environment (optional):
  APPCAST_PATH   path to appcast.xml (default: docs/appcast.xml)
  REPO           GitHub repo "owner/name" (default: nonatofabio/mindle)
"""
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

if len(sys.argv) != 5:
    print(__doc__, file=sys.stderr)
    sys.exit(2)

version, build_number, ed_signature, length = sys.argv[1:5]
repo = os.environ.get("REPO", "nonatofabio/mindle")
appcast = Path(os.environ.get("APPCAST_PATH", "docs/appcast.xml"))

tag = f"v{version}"
pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
release_url = f"https://github.com/{repo}/releases/tag/{tag}"
download_url = f"https://github.com/{repo}/releases/download/{tag}/Mindle.dmg"

# The <description> CDATA holds the HTML Sparkle renders in the update
# dialog. A short line + a link to GitHub for the full notes + a subtle
# Buy-me-a-coffee link at the bottom (never a gate, just a tip option).
description_html = (
    f'<p>Release {version}. '
    f'<a href="{release_url}">Full release notes on GitHub</a>.</p>'
    '<hr>'
    '<p style="text-align: center; font-size: 0.85em; color: #7d6b52; '
    'margin-top: 1.5em;">'
    '<a href="https://buymeacoffee.com/nonatofabio" '
    'style="color: #8c5520; text-decoration: none;">☕ Buy me a coffee</a>'
    '</p>'
)

item_xml = (
    f'    <item>\n'
    f'      <title>Version {version}</title>\n'
    f'      <pubDate>{pub_date}</pubDate>\n'
    f'      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n'
    f'      <sparkle:version>{build_number}</sparkle:version>\n'
    f'      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n'
    f'      <description><![CDATA[{description_html}]]></description>\n'
    f'      <enclosure url="{download_url}" '
    f'sparkle:edSignature="{ed_signature}" '
    f'length="{length}" '
    f'type="application/octet-stream" />\n'
    f'    </item>\n'
)

existing = appcast.read_text()
if f"<title>Version {version}</title>" in existing:
    print(f"Version {version} already present in {appcast}; skipping.")
    sys.exit(0)

if "</channel>" not in existing:
    print(f"error: {appcast} has no </channel>; malformed?", file=sys.stderr)
    sys.exit(1)

updated = existing.replace("</channel>", item_xml + "  </channel>", 1)
appcast.write_text(updated)
print(f"Prepended Version {version} item to {appcast}")
