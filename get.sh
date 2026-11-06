#!/bin/bash
# M-01 Companion one-line installer for Mac: downloads the app package from this site and runs its installer.
# It only installs the app itself (into Applications); the AI is set up inside the app.
set -e
URL="https://elvis071114-coder.github.io/m01/downloads/M-01-Companion-Mac.zip"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/m01.XXXXXX")"
echo "下載 M-01 Companion… / Downloading M-01 Companion…"
curl -fL --progress-bar -o "$TMP/m01.zip" "$URL"
/usr/bin/ditto -x -k "$TMP/m01.zip" "$TMP/app"
bash "$TMP/app/安裝 M-01 Companion.command"
rm -rf "$TMP"
