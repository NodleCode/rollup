#!/usr/bin/env bash
# Canary for the zkSync legacy-Mailbox deprecation
# (https://github.com/zkSync-Community-Hub/zksync-developers/discussions/1147).
#
# Reports the Era protocol version and whether the deprecated
# Mailbox.requestL2Transaction entrypoint still accepts calls. Exits non-zero
# the moment enforcement is detected, so it can run on a cron/CI schedule:
#
#   ./ops/check_zksync_deprecation.sh mainnet
#   ./ops/check_zksync_deprecation.sh sepolia
#
# Optional: override the RPC with L1_RPC.

set -euo pipefail

NETWORK="${1:-mainnet}"

case "$NETWORK" in
    mainnet)
        RPC="${L1_RPC:-https://ethereum-rpc.publicnode.com}"
        DIAMOND="0x32400084C286CF3E17e7B677ea9583e60a000324"
        ;;
    sepolia)
        RPC="${L1_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
        DIAMOND="0x9A6DE0f62Aa270A8bCB1e2610078650D539B1Ef9"
        ;;
    *)
        echo "Usage: $0 [mainnet|sepolia]" >&2
        exit 2
        ;;
esac

echo "Network:  $NETWORK"
echo "Diamond:  $DIAMOND"

PACKED=$(cast call "$DIAMOND" "getProtocolVersion()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
MAJOR=$((PACKED >> 32))
MINOR=$((PACKED & 0xFFFFFFFF))
echo "Protocol: v${MAJOR}.${MINOR}"

# Simulate the deprecated deposit entrypoint with a minimal request. The zero
# address is used as the caller because eth_call requires the sender to hold
# the attached value, and address(0) always does.
BASE_COST=$(cast call "$DIAMOND" "l2TransactionBaseCost(uint256,uint256,uint256)(uint256)" \
    30000000000 750000 800 --rpc-url "$RPC" | awk '{print $1}')

if cast call "$DIAMOND" \
    "requestL2Transaction(address,uint256,bytes,uint256,uint256,bytes[],address)(bytes32)" \
    0x0000000000000000000000000000000000000001 0 0x 750000 800 '[]' \
    0x0000000000000000000000000000000000000001 \
    --value "$BASE_COST" \
    --from 0x0000000000000000000000000000000000000000 \
    --rpc-url "$RPC" > /dev/null 2>&1; then
    echo "Legacy requestL2Transaction: still ACCEPTED — deprecation not yet enforced"
    exit 0
else
    echo "Legacy requestL2Transaction: REVERTED — deprecation may now be enforced on $NETWORK!"
    echo "Verify manually, then execute the cutover per ops/bridgehub-migration-cutover.md"
    exit 1
fi
