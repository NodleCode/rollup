#!/bin/bash
# =============================================================================
# verify_fundraiser.sh
#
# Verify a single Fundraiser on the ZKsync block explorer.
#
# Fundraises are created by the factory, not by the deploy script, so they never
# appear in a broadcast file and ops/verify_zksync_contracts.py cannot pick them
# up. Every constructor argument is readable from the contract itself, so this
# reconstructs them from chain — no deployment record needed, and anyone can run
# it against a fundraise they did not create.
#
# USAGE:
#   ./ops/verify_fundraiser.sh <address> [testnet|mainnet]
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ADDRESS="${1:-}"
NETWORK="${2:-testnet}"

[ -n "$ADDRESS" ] || { echo "Usage: $0 <address> [testnet|mainnet]"; exit 1; }

case "$NETWORK" in
  testnet) RPC="${L2_RPC:-https://sepolia.era.zksync.dev}"
           VERIFIER="https://explorer.sepolia.era.zksync.dev/contract_verification" ;;
  mainnet) RPC="${L2_RPC:-https://mainnet.era.zksync.io}"
           VERIFIER="https://zksync2-mainnet-explorer.zksync.io/contract_verification" ;;
  *) echo "Unknown network '$NETWORK'. Use testnet or mainnet."; exit 1 ;;
esac

cd "$PROJECT_ROOT"

# `forge verify-contract` recompiles and has no --skip, so the L1-only contracts
# zksolc rejects must be moved aside exactly as the deploy scripts do.
BK="/tmp/rollup-l1-verify-fundraiser"
restore() {
  [ -d "$BK" ] || return 0
  [ -f "$BK/SwarmRegistryL1Upgradeable.sol" ] && mv "$BK/SwarmRegistryL1Upgradeable.sol" src/swarms/
  [ -f "$BK/SwarmRegistryL1.t.sol" ] && mv "$BK/SwarmRegistryL1.t.sol" test/
  [ -d "$BK/upgrade-demo" ] && mv "$BK/upgrade-demo" test/
  [ -f "$BK/DeploySwarmUpgradeable.s.sol" ] && mv "$BK/DeploySwarmUpgradeable.s.sol" script/
  [ -f "$BK/UpgradeSwarm.s.sol" ] && mv "$BK/UpgradeSwarm.s.sol" script/
  rmdir "$BK" 2>/dev/null || true
}
trap restore EXIT

echo "Reading constructor parameters from $ADDRESS..."

NAME=$(cast call "$ADDRESS" 'name()(string)' --rpc-url "$RPC")
TOKEN=$(cast call "$ADDRESS" 'token()(address)' --rpc-url "$RPC")
GOAL=$(cast call "$ADDRESS" 'goal()(uint128)' --rpc-url "$RPC" | awk '{print $1}')
DEADLINE=$(cast call "$ADDRESS" 'deadline()(uint40)' --rpc-url "$RPC" | awk '{print $1}')
ON_MISSED=$(cast call "$ADDRESS" 'onMissed()(uint8)' --rpc-url "$RPC")
ORGANIZER=$(cast call "$ADDRESS" 'organizer()(address)' --rpc-url "$RPC")
FEE_BPS=$(cast call "$ADDRESS" 'feeBps()(uint16)' --rpc-url "$RPC")
FACTORY=$(cast call "$ADDRESS" 'factory()(address)' --rpc-url "$RPC")
MIN=$(cast call "$ADDRESS" 'minContribution()(uint128)' --rpc-url "$RPC" | awk '{print $1}')
MAX=$(cast call "$ADDRESS" 'maxTotalContributions()(uint128)' --rpc-url "$RPC" | awk '{print $1}')

# The beneficiary may have been repointed after success via setPayoutAddress, in
# which case the current value is NOT what the constructor received. Recover the
# original from the FundraiserCreated event on the factory instead.
BENEFICIARY=$(cast call "$ADDRESS" 'beneficiary()(address)' --rpc-url "$RPC")
CHANGED=$(cast logs --rpc-url "$RPC" --address "$ADDRESS" \
  "PayoutAddressChanged(address,address)" --from-block 1 2>/dev/null | grep -c "topics" || true)
if [ "${CHANGED:-0}" -gt 0 ]; then
  echo "  note: payout address was changed after deployment; recovering the original"
  ORIGINAL=$(cast logs --rpc-url "$RPC" --address "$ADDRESS" \
    "PayoutAddressChanged(address,address)" --from-block 1 2>/dev/null \
    | grep -oE "0x0{24}[0-9a-f]{40}" | head -1 | sed 's/0x0\{24\}/0x/')
  [ -n "$ORIGINAL" ] && BENEFICIARY="$ORIGINAL"
fi

echo "  name=$NAME token=$TOKEN goal=$GOAL deadline=$DEADLINE onMissed=$ON_MISSED"
echo "  beneficiary=$BENEFICIARY organizer=$ORGANIZER feeBps=$FEE_BPS factory=$FACTORY"

ARGS=$(cast abi-encode \
  "constructor((string,address,uint128,uint40,uint8,address,uint128,uint128),address,uint16,address)" \
  "($NAME,$TOKEN,$GOAL,$DEADLINE,$ON_MISSED,$BENEFICIARY,$MIN,$MAX)" \
  "$ORGANIZER" "$FEE_BPS" "$FACTORY")

mkdir -p "$BK"
mv src/swarms/SwarmRegistryL1Upgradeable.sol "$BK/" 2>/dev/null || true
mv test/SwarmRegistryL1.t.sol "$BK/" 2>/dev/null || true
mv test/upgrade-demo "$BK/" 2>/dev/null || true
mv script/DeploySwarmUpgradeable.s.sol "$BK/" 2>/dev/null || true
mv script/UpgradeSwarm.s.sol "$BK/" 2>/dev/null || true

FOUNDRY_PROFILE=zksync forge verify-contract "$ADDRESS" \
  src/fundraising/Fundraiser.sol:Fundraiser \
  --zksync --verifier zksync --verifier-url "$VERIFIER" \
  --constructor-args "$ARGS" --watch
