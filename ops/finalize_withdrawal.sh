#!/usr/bin/env bash
# Derive finalizeWithdrawal params for an L2 withdrawal tx, obtain the inclusion proof on zkSync Era and finalize the withdrawal.
#
# Simplified approach based on the zkSync Era RPC mapping:
#  - _l2BatchNumber → l1BatchNumber (from zks_getTransactionDetails)
#  - _l2TxNumberInBatch → l1BatchTxIndex (from zks_getTransactionDetails)  
#  - _l2MessageIndex → id from zks_getL2ToL1LogProof
#  - _message → exact bytes sent with L2_MESSENGER.sendToL1 (reconstructed from tx input)
#  - _merkleProof → proof[] from zks_getL2ToL1LogProof
#
# Usage:
#   finalize_withdrawal.sh <TX_HASH>
#
# Requirements: curl, jq, python3, and Foundry (cast) in PATH.

set -euo pipefail

if [ ${#@} -lt 1 ]; then
  echo "Usage: $0 <TX_HASH>" >&2
  exit 1
fi

source .env

# Check required environment variables
required_vars=("L1_RPC" "L1_BRIDGE" "L2_RPC")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        print_error "Required environment variable $var is not set!"
        exit 1
    fi
done

TX_HASH="$1"

json() { jq -r "$1"; }

echo "[i] Fetching transaction receipt…" >&2
RECEIPT=$(curl -s -X POST "$L2_RPC" -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TX_HASH\"]}")

L1_BATCH_NUMBER=$(echo "$RECEIPT" | json '.result.l1BatchNumber')
L1_BATCH_TX_INDEX=$(echo "$RECEIPT" | json '.result.l1BatchTxIndex')

if [ "$L1_BATCH_NUMBER" = "null" ] || [ -z "$L1_BATCH_NUMBER" ]; then
  echo "[!] Could not read l1BatchNumber from receipt. Full receipt:" >&2
  echo "$RECEIPT" >&2
  exit 1
fi

echo "[i] Fetching transaction input…" >&2
TX=$(curl -s -X POST "$L2_RPC" -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getTransactionByHash\",\"params\":[\"$TX_HASH\"]}")
INPUT=$(echo "$TX" | json '.result.input')
if [ "$INPUT" = "null" ] || [ -z "$INPUT" ]; then
  echo "[!] Could not read input from transaction. Full tx:" >&2
  echo "$TX" >&2
  exit 1
fi

# Decode L2Bridge.withdraw(address,uint256) calldata to extract l1Receiver and amount without external deps.
# Calldata layout: 4-byte selector + 32-byte slot (address right-padded 20) + 32-byte slot (uint256 amount)
DATA=${INPUT#0x}
if [ ${#DATA} -lt 8 ]; then
  echo "[!] Calldata too short." >&2
  exit 1
fi

# First arg (address) occupies bytes 4..36 (64 hex chars). Take the last 40 hex chars for the address.
ARG1_32=${DATA:8:64}
ADDR_HEX="0x${ARG1_32:24:40}"

# Second arg (uint256 amount) occupies bytes 36..68 (next 64 hex chars).
AMOUNT_HEX="0x${DATA:72:64}"

# Build the exact L2->L1 message bytes expected by L1: abi.encodePacked(selector, address, uint256)
SELECTOR=$(cast sig "finalizeWithdrawal(address,uint256)")
SEL_NO0X=${SELECTOR#0x}
ADDR_NO0X=${ADDR_HEX#0x}
AMT_NO0X=${AMOUNT_HEX#0x}

# Packed message: 4 (selector) + 20 (address) + 32 (amount) = 56 bytes
MESSAGE="0x${SEL_NO0X}${ADDR_NO0X}${AMT_NO0X}"

# Helper: parse hex to decimal
to_dec() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then echo ""; return; fi
  if [[ "$v" =~ ^0x[0-9a-fA-F]+$ ]]; then
    python3 - "$v" <<'PY'
import sys
h = sys.argv[1]
print(int(h, 16))
PY
  else
    echo "$v"
  fi
}

L2_BATCH_DEC=$(to_dec "$L1_BATCH_NUMBER")
L2_TXNUM_DEC=$(to_dec "$L1_BATCH_TX_INDEX")

echo "--- derived inputs ---"
printf "l1BatchNumber:   %s (dec: %s)\n" "$L1_BATCH_NUMBER" "$L2_BATCH_DEC"
printf "l1BatchTxIndex:  %s (dec: %s)\n" "$L1_BATCH_TX_INDEX" "$L2_TXNUM_DEC"
printf "l1Receiver:      %s\n" "$ADDR_HEX"
printf "amount:          %s\n" "$AMOUNT_HEX"
printf "message:         %s\n" "$MESSAGE"
echo

# Resolve L1 Mailbox from L1 bridge if provided
if [ ${#@} -ge 5 ]; then
  BRIDGE_ADDR="$L1_BRIDGE"
  MAILBOX_ADDR=$(cast call "$BRIDGE_ADDR" "L1_MAILBOX()(address)" --rpc-url "$L1_RPC" 2>/dev/null || true)
  if [ -n "$MAILBOX_ADDR" ]; then
    echo "[i] L1 Bridge -> Mailbox: $MAILBOX_ADDR" >&2
    # Check if this is the expected Sepolia Mailbox
    MAILBOX_LC=$(echo "$MAILBOX_ADDR" | tr 'A-Z' 'a-z')
  fi
fi

# Call zks_getL2ToL1LogProof to get the message index and proof
echo "[i] Calling zks_getL2ToL1LogProof…" >&2
LOG_PROOF=$(curl -s -X POST "$L2_RPC" -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zks_getL2ToL1LogProof\",\"params\":[\"$TX_HASH\"]}")

LOG_ERR=$(echo "$LOG_PROOF" | jq -r '.error.message // empty')
if [ -n "$LOG_ERR" ]; then
  echo "[!] Log proof RPC error: $LOG_ERR" >&2
  echo "$LOG_PROOF" | jq . >&2
  exit 1
fi

echo "--- zks_getL2ToL1LogProof response ---" >&2
echo "$LOG_PROOF" | jq . >&2

# Extract fields from proof result
L2_MESSAGE_INDEX=$(echo "$LOG_PROOF" | jq -r '.result.id // null')
MERKLE_PROOF_JSON=$(echo "$LOG_PROOF" | jq -c '.result.proof // []')

if [ "$L2_MESSAGE_INDEX" = "null" ] || [ -z "$L2_MESSAGE_INDEX" ]; then
  echo "[!] Could not get l2MessageIndex from proof response" >&2
  exit 1
fi

L2_MSG_INDEX_DEC=$(to_dec "$L2_MESSAGE_INDEX")

echo
echo "--- finalizeWithdrawal args ---"
printf "_l2BatchNumber (dec):     %s\n" "${L2_BATCH_DEC}"
printf "_l2MessageIndex (dec):    %s\n" "${L2_MSG_INDEX_DEC}"
printf "_l2TxNumberInBatch (dec): %s\n" "${L2_TXNUM_DEC}"
printf "_message (56 bytes):      %s\n" "$MESSAGE"
printf "_merkleProof (len):       %s\n" "$(echo "$MERKLE_PROOF_JSON" | jq 'length')"

# Emit a compact JSON payload for programmatic consumption
jq -nc \
  --argjson l2BatchNumber ${L2_BATCH_DEC:-null} \
  --argjson l2MessageIndex ${L2_MSG_INDEX_DEC:-null} \
  --argjson l2TxNumberInBatch ${L2_TXNUM_DEC:-null} \
  --arg message "$MESSAGE" \
  --argjson merkleProof "$MERKLE_PROOF_JSON" \
  '{ l2BatchNumber: $l2BatchNumber, l2MessageIndex: $l2MessageIndex, l2TxNumberInBatch: $l2TxNumberInBatch, message: $message, merkleProof: $merkleProof }'

# Build bytes32[] arg string for cast CLI
MERKLE_PROOF_ARG=$(echo "$MERKLE_PROOF_JSON" | jq -r '[.[]] | "[" + (join(",")) + "]"')

echo
echo "--- cast send command to be sent ---"

echo "cast send \"$L1_BRIDGE\" \"finalizeWithdrawal(uint256,uint256,uint16,bytes,bytes32[])\" \\
  ${L2_BATCH_DEC:-0} ${L2_MSG_INDEX_DEC:-0} ${L2_TXNUM_DEC:-0} \\
  ${MESSAGE} '${MERKLE_PROOF_ARG}' \\
  --rpc-url \"$L1_RPC\" -i"

# Basic sanity: require a non-empty proof and message index
PROOF_LEN=$(echo "$MERKLE_PROOF_JSON" | jq 'length')
if [ "$PROOF_LEN" -gt 0 ] && [ -n "${L2_MSG_INDEX_DEC:-}" ] && [ "${L2_MSG_INDEX_DEC:-null}" != "null" ]; then
  echo "[i] Executing finalizeWithdrawal via cast (interactive)…" >&2
  cast send "$L1_BRIDGE" "finalizeWithdrawal(uint256,uint256,uint16,bytes,bytes32[])" \
    "${L2_BATCH_DEC:-0}" "${L2_MSG_INDEX_DEC:-0}" "${L2_TXNUM_DEC:-0}" \
    "$MESSAGE" "$MERKLE_PROOF_ARG" \
    --rpc-url "$L1_RPC" -i
else
  echo "[!] Missing proof or message index; skipping cast execution." >&2
fi
