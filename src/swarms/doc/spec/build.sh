#!/usr/bin/env bash
# =============================================================================
# build.sh — Build the Swarm System specification PDF
#
# Renders Mermaid diagrams to images, then converts the consolidated
# markdown specification to a styled PDF.
#
# USAGE:
#   ./src/swarms/doc/spec/build.sh
#
# OUTPUT:
#   src/swarms/doc/spec/swarm-specification.pdf
#
# REQUIREMENTS (installed automatically on first run):
#   - Node.js >= 18
#   - @mermaid-js/mermaid-cli (mmdc) — renders Mermaid diagrams
#   - md-to-pdf — converts Markdown to PDF via Puppeteer
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INPUT="swarm-specification.md"
RENDERED="swarm-specification.rendered.md"
OUTPUT="swarm-specification.pdf"
CSS="pdf-style.css"
MERMAID_CFG="mermaid-config.json"
IMG_DIR="mermaid-images"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[build]${NC} $1"; }
ok()   { echo -e "${GREEN}[done]${NC} $1"; }
fail() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# CI environments (GitHub Actions) need --no-sandbox for Puppeteer/Chrome
PUPPETEER_ARGS=""
if [ "${CI:-}" = "true" ]; then
  log "CI detected — enabling --no-sandbox for Chrome"
  PUPPETEER_CFG="$SCRIPT_DIR/.puppeteer-ci.json"
  echo '{"args":["--no-sandbox","--disable-setuid-sandbox"]}' > "$PUPPETEER_CFG"
  PUPPETEER_ARGS="-p $PUPPETEER_CFG"
fi

# ---------------------------------------------------------------------------
# 1. Check / install dependencies
# ---------------------------------------------------------------------------

if ! command -v node &>/dev/null; then
  fail "Node.js is required but not installed."
fi

# Find binaries — they may be hoisted to the project root node_modules
find_bin() {
  local name="$1"
  local dir="$SCRIPT_DIR"
  while [ "$dir" != "/" ]; do
    if [ -x "$dir/node_modules/.bin/$name" ]; then
      echo "$dir/node_modules/.bin/$name"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

MMDC="$(find_bin mmdc || true)"
MD2PDF="$(find_bin md-to-pdf || true)"

if [ -z "$MMDC" ] || [ -z "$MD2PDF" ]; then
  log "Installing dependencies..."
  npm install --no-save @mermaid-js/mermaid-cli md-to-pdf 2>&1
  MMDC="$(find_bin mmdc)" || fail "mmdc not found after install"
  MD2PDF="$(find_bin md-to-pdf)" || fail "md-to-pdf not found after install"
  ok "Dependencies installed"
fi

log "Using mmdc: $MMDC"
log "Using md-to-pdf: $MD2PDF"

# ---------------------------------------------------------------------------
# 2. Render Mermaid code blocks → PNG images
# ---------------------------------------------------------------------------

log "Rendering Mermaid diagrams..."

mkdir -p "$IMG_DIR"

# mmdc can process a markdown file directly:
#   - finds all ```mermaid blocks
#   - renders each to an image
#   - outputs a new markdown with image references
"$MMDC" \
  -i "$INPUT" \
  -o "$RENDERED" \
  -e png \
  -b white \
  -c "$MERMAID_CFG" \
  -a "$IMG_DIR" \
  $PUPPETEER_ARGS \
  -q 2>&1 || fail "Mermaid rendering failed"

ok "Mermaid diagrams rendered to $IMG_DIR/"

# ---------------------------------------------------------------------------
# 3. Convert rendered Markdown → PDF
# ---------------------------------------------------------------------------

log "Generating PDF..."

LAUNCH_OPTS=""
if [ "${CI:-}" = "true" ]; then
  LAUNCH_OPTS='--launch-options {"args":["--no-sandbox","--disable-setuid-sandbox"]}'
fi

"$MD2PDF" "$RENDERED" \
  --stylesheet "$CSS" \
  $LAUNCH_OPTS \
  --pdf-options '{"format":"A4","margin":{"top":"25mm","bottom":"25mm","left":"20mm","right":"20mm"},"printBackground":true,"displayHeaderFooter":true,"headerTemplate":"<span></span>","footerTemplate":"<div style=\"width:100%;text-align:center;font-size:9px;color:#888;padding:0 20mm;\"><span>Nodle Swarm System — Technical Specification</span><span style=\"float:right;\">Page <span class=\"pageNumber\"></span> of <span class=\"totalPages\"></span></span></div>"}' \
  2>&1 || fail "PDF generation failed"

# md-to-pdf names output based on input filename
if [ -f "swarm-specification.rendered.pdf" ]; then
  mv "swarm-specification.rendered.pdf" "$OUTPUT"
fi

ok "PDF generated: $SCRIPT_DIR/$OUTPUT"

# ---------------------------------------------------------------------------
# 4. Clean up intermediate files
# ---------------------------------------------------------------------------

rm -f "$RENDERED"

log "Build complete!"
echo ""
echo "  📄 $SCRIPT_DIR/$OUTPUT"
echo ""
