#!/usr/bin/env bash
#
# create-collection-1155.sh
#
# Operator action: create one ERC-1155 user collection via the factory, then
# mint the edition. Uses `cast` directly (foundry-zksync) instead of forge
# script. See src/collections/doc/backend-integration.md (§2-3).
#
# The broadcasting key MUST hold OPERATOR_ROLE on the factory proxy. The
# collection is created with NO admin; COLLECTION_OWNER gets OWNER_ROLE +
# MINTER_ROLE, and the operator is auto-granted MINTER_ROLE (so it can mint
# immediately).
#
# Flow:
#   1. Read-only pre-flight (operator role, externalId unused).
#   2. createCollection1155(params, externalId).
#   3. Read collectionByExternalId(externalId) -> new address.
#   4. mint(MINT_TO, TOKEN_ID, MINT_AMOUNT, 0x).
#
# Usage:
#   ./script/create-collection-1155.sh              # dry-run: checks only, no tx
#   ./script/create-collection-1155.sh --broadcast  # actually send transactions
#
# Required env:
#   OPERATOR_PRIVATE_KEY      Key holding OPERATOR_ROLE (pays gas).
#   L2_RPC                    zkSync Era RPC URL.
#   COLLECTION_FACTORY_PROXY  Factory ERC1967 proxy address.
#   COLLECTION_OWNER          Creator wallet (OWNER_ROLE + MINTER_ROLE).
#   CONTRACT_URI              Collection-metadata JSON URI (ipfs://<cid>).
#   TOKEN_URI                 ERC-1155 token-metadata JSON URI (ipfs://<cid>).
#   EXTERNAL_ID_SEED          Non-empty, globally-unique string (CREATE2 salt).
#   MINT_AMOUNT               Quantity to mint (e.g. 20000).
#
# Optional env:
#   MINT_TO                   Mint recipient. Default: COLLECTION_OWNER.
#   TOKEN_ID                  ERC-1155 id to mint. Default: 0.
#   ROYALTY_RECIPIENT         ERC-2981 recipient. Default: 0x0 (none).
#   ROYALTY_BPS               Basis points (500 = 5%). Default: 0 (none).
set -euo pipefail

BROADCAST=0
if [ "${1:-}" = "--broadcast" ]; then BROADCAST=1; fi

ZERO_ADDR="0x0000000000000000000000000000000000000000"

# --- required ---
: "${OPERATOR_PRIVATE_KEY:?set OPERATOR_PRIVATE_KEY}"
: "${L2_RPC:?set L2_RPC}"
: "${COLLECTION_FACTORY_PROXY:?set COLLECTION_FACTORY_PROXY}"
: "${COLLECTION_OWNER:?set COLLECTION_OWNER}"
: "${CONTRACT_URI:?set CONTRACT_URI}"
: "${TOKEN_URI:?set TOKEN_URI}"
: "${EXTERNAL_ID_SEED:?set EXTERNAL_ID_SEED}"
: "${MINT_AMOUNT:?set MINT_AMOUNT}"

# --- optional defaults ---
MINT_TO="${MINT_TO:-$COLLECTION_OWNER}"
TOKEN_ID="${TOKEN_ID:-0}"
ROYALTY_RECIPIENT="${ROYALTY_RECIPIENT:-$ZERO_ADDR}"
ROYALTY_BPS="${ROYALTY_BPS:-0}"

OPERATOR_ADDR=$(cast wallet address --private-key "$OPERATOR_PRIVATE_KEY")
EXTERNAL_ID=$(cast keccak "$EXTERNAL_ID_SEED")
OPERATOR_ROLE=$(cast keccak "OPERATOR_ROLE")

echo "=== Plan ==="
echo "Factory:          $COLLECTION_FACTORY_PROXY"
echo "Operator:         $OPERATOR_ADDR"
echo "Owner:            $COLLECTION_OWNER"
echo "Contract URI:     $CONTRACT_URI"
echo "Token URI:        $TOKEN_URI"
echo "Royalty:          $ROYALTY_BPS bps -> $ROYALTY_RECIPIENT"
echo "External id seed: $EXTERNAL_ID_SEED"
echo "External id:      $EXTERNAL_ID"
echo "Mint:             $MINT_AMOUNT of id $TOKEN_ID -> $MINT_TO"
echo ""

# --- pre-flight (read-only) ---
echo "=== Pre-flight ==="
HAS_ROLE=$(cast call "$COLLECTION_FACTORY_PROXY" "hasRole(bytes32,address)(bool)" "$OPERATOR_ROLE" "$OPERATOR_ADDR" --rpc-url "$L2_RPC")
echo "operator holds OPERATOR_ROLE: $HAS_ROLE"
if [ "$HAS_ROLE" != "true" ]; then
  echo "ERROR: operator $OPERATOR_ADDR lacks OPERATOR_ROLE on the factory." >&2
  exit 1
fi

EXISTING=$(cast call "$COLLECTION_FACTORY_PROXY" "collectionByExternalId(bytes32)(address)" "$EXTERNAL_ID" --rpc-url "$L2_RPC")
echo "collectionByExternalId(externalId): $EXISTING"
if [ "$EXISTING" != "$ZERO_ADDR" ]; then
  echo "ERROR: externalId already used -> $EXISTING. Change EXTERNAL_ID_SEED." >&2
  exit 1
fi

if [ "$ROYALTY_BPS" != "0" ] && [ "$ROYALTY_RECIPIENT" = "$ZERO_ADDR" ]; then
  echo "ERROR: ROYALTY_BPS > 0 requires a non-zero ROYALTY_RECIPIENT." >&2
  exit 1
fi
echo ""

# CreateParams1155 tuple: (owner, uri, contractURI, royaltyRecipient, royaltyBps, additionalMinters[])
PARAMS="($COLLECTION_OWNER,$TOKEN_URI,$CONTRACT_URI,$ROYALTY_RECIPIENT,$ROYALTY_BPS,[])"

if [ "$BROADCAST" -ne 1 ]; then
  echo "DRY-RUN ok. Re-run with --broadcast to send. Would execute:"
  echo "  1) createCollection1155($PARAMS, $EXTERNAL_ID)"
  echo "  2) mint($MINT_TO, $TOKEN_ID, $MINT_AMOUNT, 0x)"
  exit 0
fi

# --- 1. create ---
echo "=== Creating collection ==="
cast send "$COLLECTION_FACTORY_PROXY" \
  "createCollection1155((address,string,string,address,uint96,address[]),bytes32)" \
  "$PARAMS" "$EXTERNAL_ID" \
  --rpc-url "$L2_RPC" --private-key "$OPERATOR_PRIVATE_KEY" --zksync

# --- 2. resolve address ---
COLLECTION=$(cast call "$COLLECTION_FACTORY_PROXY" "collectionByExternalId(bytes32)(address)" "$EXTERNAL_ID" --rpc-url "$L2_RPC")
echo "New collection: $COLLECTION"
if [ "$COLLECTION" = "$ZERO_ADDR" ]; then
  echo "ERROR: collection address still zero after create — investigate." >&2
  exit 1
fi

# --- 3. mint ---
echo "=== Minting $MINT_AMOUNT of id $TOKEN_ID to $MINT_TO ==="
cast send "$COLLECTION" \
  "mint(address,uint256,uint256,bytes)" \
  "$MINT_TO" "$TOKEN_ID" "$MINT_AMOUNT" 0x \
  --rpc-url "$L2_RPC" --private-key "$OPERATOR_PRIVATE_KEY" --zksync

echo ""
echo "=== Done ==="
echo "Collection: $COLLECTION"
echo "Balance check:"
echo "  cast call $COLLECTION 'balanceOf(address,uint256)(uint256)' $MINT_TO $TOKEN_ID --rpc-url \$L2_RPC"
