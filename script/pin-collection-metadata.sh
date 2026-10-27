#!/usr/bin/env bash
#
# pin-collection-metadata.sh
#
# Generates the ERC-1155 collection + token metadata JSON and pins both to
# Nodle IPFS (https://ipfs.nodle.com/v0/upload), then prints the CONTRACT_URI
# and TOKEN_URI to feed into CreateCollection1155ZkSync.s.sol.
#
# The upload API (Rocket) takes a multipart form field named `data` and returns
# a JSON array of CIDs, e.g. ["Qm..."].
#
# Usage:
#   IMAGE_CID=Qm... TITLE="..." DESCRIPTION="..." ./script/pin-collection-metadata.sh
#
# Defaults are set for "The Turtle - Nodle Private AI".
set -euo pipefail

# Defaults live in plain double-quoted assignments (not inside ${VAR:-...}) so the
# apostrophe in the description doesn't trip bash 3.2's parameter-default parser.
DEFAULT_IMAGE_CID="QmRqZ8o7PYSkoEbMKRNNUgoZi1Ry9ofXicAqR15BX9nG4p"
DEFAULT_TITLE="The Turtle - Nodle Private AI"
DEFAULT_DESCRIPTION="The Turtle is Nodle's private and local AI: a capable model that runs entirely on your device."
DEFAULT_UPLOAD_URL="https://ipfs.nodle.com/v0/upload"

IMAGE_CID="${IMAGE_CID:-$DEFAULT_IMAGE_CID}"
TITLE="${TITLE:-$DEFAULT_TITLE}"
DESCRIPTION="${DESCRIPTION:-$DEFAULT_DESCRIPTION}"
UPLOAD_URL="${UPLOAD_URL:-$DEFAULT_UPLOAD_URL}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Build the metadata JSON. Collection-level (contractURI) and token-level (uri)
# share the same name/description/image for this single-edition drop. jq -n
# guarantees correct escaping of the title/description.
jq -n --arg name "$TITLE" --arg desc "$DESCRIPTION" --arg img "ipfs://$IMAGE_CID" \
  '{name: $name, description: $desc, image: $img}' > "$workdir/collection.json"
cp "$workdir/collection.json" "$workdir/token.json"

pin() {
  file=$1
  resp=$(curl -fsS -X POST "$UPLOAD_URL" -H 'origin: https://clickapp.com' -F "data=@${file};type=application/json")
  if ! cid=$(printf '%s' "$resp" | jq -er '.[0]'); then
    echo "ERROR: unexpected upload response for $file: $resp" >&2
    exit 1
  fi
  printf '%s' "$cid"
}

echo "Pinning collection metadata (contractURI)..." >&2
CONTRACT_CID=$(pin "$workdir/collection.json")
echo "  -> $CONTRACT_CID" >&2

echo "Pinning token metadata (uri)..." >&2
TOKEN_CID=$(pin "$workdir/token.json")
echo "  -> $TOKEN_CID" >&2

echo "" >&2
echo "=== Pinned. Export these for CreateCollection1155ZkSync.s.sol ===" >&2
echo "export CONTRACT_URI=ipfs://$CONTRACT_CID"
echo "export TOKEN_URI=ipfs://$TOKEN_CID"
