#!/bin/bash
# screenshot.sh - Take a headless browser screenshot of a URL
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Uses Playwright with headless Chromium to capture a web page.
# Requires: npm install && npx playwright install chromium (in tests/)
#
# Useful for LuCI testing and visual verification.
#
# Usage:
#   ./screenshot.sh <url> [output.png]
#
# Examples:
#   ./screenshot.sh http://192.168.50.1/cgi-bin/luci/
#   ./screenshot.sh http://172.30.0.2/cgi-bin/luci/admin/services/ha-cluster luci-status.png

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests" && pwd)"

URL="${1:?Usage: $0 <url> [output.png]}"
OUTPUT="${2:-screenshot.png}"

# Use Playwright installed in tests/node_modules
NODE_PATH="$TESTS_DIR/node_modules" node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  await page.goto(process.argv[1], { waitUntil: 'networkidle', timeout: 30000 });
  await page.screenshot({ path: process.argv[2], fullPage: true });
  console.log('Screenshot saved: ' + process.argv[2]);
  await browser.close();
})().catch(e => { console.error('Error:', e.message); process.exit(1); });
" "$URL" "$OUTPUT"
