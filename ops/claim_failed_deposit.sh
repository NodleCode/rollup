#!/usr/bin/env bash
# Script to monitor a failed L2 transaction and automatically execute claimFailedDeposit once committed to L1
# Usage: claim_failed_deposit.sh <L2_TX_HASH>

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <L1_SENDER> <L2_TX_HASH>"
    echo "Example: $0 0x49dDBe122B410d4C4A5b1A77030903e6CD391c62 0x1b6b0b00d89cbf6d39d2235449cf9c209399cc3a4c6a0b0da901a446bf3c6d36"
    exit 1
fi

source .env

# Check required environment variables
required_vars=("L1_RPC" "L1_BRIDGE" "L2_RPC")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required environment variable $var is not set!"
        exit 1
    fi
done

L1_SENDER="$1"
L2_TX_HASH="$2"

# Helper function to convert hex to decimal
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

echo "🔍 Monitoring failed transaction: $L2_TX_HASH"
echo "⏳ Polling every 30 seconds until L1 batch commitment..."
echo

while true; do
    echo "$(date): Checking transaction details..."
    
    # Get transaction details
    RESPONSE=$(curl -s -X POST "$L2_RPC" \
        -H "Content-Type: application/json" \
        -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"zks_getTransactionDetails\",
            \"params\": [\"$L2_TX_HASH\"],
            \"id\": 1
        }")
    
    # Extract commit hash
    COMMIT_HASH=$(echo "$RESPONSE" | jq -r '.result.ethCommitTxHash // empty')
    
    if [ -n "$COMMIT_HASH" ] && [ "$COMMIT_HASH" != "null" ]; then
        echo "✅ Transaction committed to L1!"
        echo "📜 L1 Commit Transaction: $COMMIT_HASH"
        break
    else
        echo "⏳ Transaction not yet committed to L1. Waiting..."
        echo "Sleeping 30 seconds..."
        echo "----------------------------------------"
        sleep 30
    fi
done

echo
echo "🔧 Getting transaction receipt for batch details..."

# Get the receipt to extract batch information
RECEIPT=$(curl -s -X POST "$L2_RPC" \
    -H "Content-Type: application/json" \
    -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"eth_getTransactionReceipt\",
        \"params\": [\"$L2_TX_HASH\"],
        \"id\": 1
    }")

# Extract L1 batch information
L1_BATCH_NUMBER=$(echo "$RECEIPT" | jq -r '.result.l1BatchNumber // empty')
L1_BATCH_TX_INDEX=$(echo "$RECEIPT" | jq -r '.result.l1BatchTxIndex // empty')

if [ -z "$L1_BATCH_NUMBER" ] || [ "$L1_BATCH_NUMBER" = "null" ]; then
    echo "❌ Could not extract L1 batch information from receipt"
    echo "Receipt response:"
    echo "$RECEIPT" | jq .
    exit 1
fi

L2_BATCH_DEC=$(to_dec "$L1_BATCH_NUMBER")
L2_TXNUM_DEC=$(to_dec "$L1_BATCH_TX_INDEX")

echo "📊 Extracted batch information:"
echo "  L1 Batch Number: $L1_BATCH_NUMBER (dec: $L2_BATCH_DEC)"
echo "  L1 Batch Tx Index: $L1_BATCH_TX_INDEX (dec: $L2_TXNUM_DEC)"

# Get the original L1 deposit transaction to find the depositor and amount
echo
echo "� Finding original L1 deposit details..."

# Check the deposit amount recorded for this transaction
DEPOSIT_AMOUNT=$(cast call "$L1_BRIDGE" "depositAmount(address,bytes32)(uint256)" \
    "$L1_SENDER" "$L2_TX_HASH" --rpc-url "$L1_RPC" 2>/dev/null || echo "0")

if [ "$DEPOSIT_AMOUNT" = "0" ]; then
    echo "❌ No deposit amount found for depositor $L1_SENDER and tx hash $L2_TX_HASH"
    echo "This might not be a valid failed deposit or the depositor address is incorrect"
    exit 1
fi

echo "💰 Found deposit amount: $DEPOSIT_AMOUNT wei"

# Generate failure proof using the L2→L1 log approach
echo
echo "🧾 Generating failure proof using L2→L1 log..."

# First, get the transaction receipt to find the L2→L1 log index
echo "📄 Getting L2 transaction receipt..."
L2_RECEIPT_RESPONSE=$(curl -s -X POST "$L2_RPC" \
    -H "Content-Type: application/json" \
    -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"eth_getTransactionReceipt\", 
        \"params\": [\"$L2_TX_HASH\"],
        \"id\": 1
    }")

echo "📋 L2 Receipt response:"
echo "$L2_RECEIPT_RESPONSE" | jq . 2>/dev/null || echo "Invalid JSON response"

# Extract logs from the receipt to find the L2→L1 log
L2_LOGS=$(echo "$L2_RECEIPT_RESPONSE" | jq -c '.result.logs // []')
L2_LOG_COUNT=$(echo "$L2_LOGS" | jq 'length' 2>/dev/null || echo "0")

echo "📊 Found $L2_LOG_COUNT logs in L2 transaction"

# The bootloader's log index is always 0
L2_TO_L1_LOG_INDEX=0

# Now get the L2→L1 log proof for this specific log
echo "🔍 Getting L2→L1 log proof..."

LOG_PROOF_RESPONSE=$(curl -s -X POST "$L2_RPC" \
    -H "Content-Type: application/json" \
    -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"zks_getL2ToL1LogProof\",
        \"params\": [\"$L2_TX_HASH\", $L2_TO_L1_LOG_INDEX],
        \"id\": 1
    }")

echo "📋 Log proof response:"
echo "$LOG_PROOF_RESPONSE" | jq . 2>/dev/null || echo "Invalid JSON response"

# Extract the Merkle proof from the response
MERKLE_PROOF_JSON=$(echo "$LOG_PROOF_RESPONSE" | jq -c '.result.proof // []' 2>/dev/null || echo "[]")
LOG_PROOF_ID=$(echo "$LOG_PROOF_RESPONSE" | jq -r '.result.id // null' 2>/dev/null || echo "null")

echo "🔍 Log proof ID: $LOG_PROOF_ID"
echo "🧾 Merkle proof length: $(echo "$MERKLE_PROOF_JSON" | jq 'length' 2>/dev/null || echo "0")"

# Final verification of proof
PROOF_LENGTH=$(echo "$MERKLE_PROOF_JSON" | jq 'length' 2>/dev/null || echo "0")
echo "🧾 Final Merkle proof length: $PROOF_LENGTH"

if [ "$PROOF_LENGTH" -eq 0 ]; then
    echo "⚠️  Still no valid proof found. This might indicate:"
    echo "   - The transaction hasn't generated an L2→L1 log yet"
    echo "   - The log index calculation is wrong"
    echo "   - The transaction needs more time to be provable"
    echo "🔧 Falling back to empty proof for testing..."
    MERKLE_PROOF_JSON="[]"
else
    echo "✅ Found valid Merkle proof with $PROOF_LENGTH elements"
fi

echo "🎯 Failure proof parameters:"
echo "  _l1Sender: $L1_SENDER"
echo "  _l2TxHash: $L2_TX_HASH"  
echo "  _l2BatchNumber (dec): $L2_BATCH_DEC"
echo "  _l2MessageIndex (dec): $LOG_PROOF_ID"
echo "  _l2TxNumberInBatch (dec): $L2_TXNUM_DEC"
echo "  _depositAmount: $DEPOSIT_AMOUNT wei"
echo "  _merkleProof: $MERKLE_PROOF_JSON"

# Build bytes32[] arg string for cast CLI (values like [0x...,0x...,...])
MERKLE_PROOF_ARG=$(echo "$MERKLE_PROOF_JSON" | jq -r '[.[]] | "[" + (join(",")) + "]"')

echo
echo "🎬 Executing claimFailedDeposit via cast..."

# Choose auth mode: use private key if provided, else interactive
AUTH_ARGS=(-i)
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    AUTH_ARGS=(--private-key "$DEPLOYER_PRIVATE_KEY")
fi

# Try the call and handle errors gracefully
if cast send "$L1_BRIDGE" "claimFailedDeposit(address,bytes32,uint256,uint256,uint16,bytes32[])" \
        "$L1_SENDER" "$L2_TX_HASH" "$L2_BATCH_DEC" "$LOG_PROOF_ID" "$L2_TXNUM_DEC" \
        "$MERKLE_PROOF_ARG" \
        --rpc-url "$L1_RPC" "${AUTH_ARGS[@]}"; then
    
    echo
    echo "✨ claimFailedDeposit execution completed successfully!"
    echo "🎉 Your deposited tokens should now be minted back to: $L1_SENDER"
    
    # Verify the claim worked by checking if the deposit amount is now zero
    NEW_DEPOSIT_AMOUNT=$(cast call "$L1_BRIDGE" "depositAmount(address,bytes32)(uint256)" \
        "$L1_SENDER" "$L2_TX_HASH" --rpc-url "$L1_RPC" 2>/dev/null || echo "0")
    
    if [ "$NEW_DEPOSIT_AMOUNT" = "0" ]; then
        echo "✅ Verified: Deposit amount cleared from bridge storage"
    else
        echo "⚠️  Warning: Deposit amount still shows: $NEW_DEPOSIT_AMOUNT"
    fi
    
else
    echo
    echo "❌ claimFailedDeposit execution failed!"
    echo
    echo "🔧 Possible issues and solutions:"
    echo "1. Merkle proof might be incorrect - the zkSync API may not provide the right proof format"
    echo "2. Transaction might not actually be in failed status yet"
    echo "3. The L2 message index might be wrong (tried 0, might need different value)"
    echo
    echo "🛠️  Debugging suggestions:"
    echo "- Check the transaction status on zkSync explorer"
    echo "- Verify the L1 batch has been finalized"
    echo "- Try calling with different message index values (1, 2, etc.)"
    echo "- Check if the transaction needs more time to be provable"
    
    echo
    echo "📋 Manual command to try with different parameters:"
    echo "cast send '$L1_BRIDGE' 'claimFailedDeposit(address,bytes32,uint256,uint256,uint16,bytes32[])' \\"
    echo "  $L1_SENDER $L2_TX_HASH $L2_BATCH_DEC [TRY_DIFFERENT_INDEX] $L2_TXNUM_DEC \\"
    echo "  '[DIFFERENT_PROOF]' \\"
    echo "  --rpc-url '$L1_RPC' -i"
fi
