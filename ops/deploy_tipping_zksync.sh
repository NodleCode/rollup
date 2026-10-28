#!/usr/bin/env bash
# Deploys the immutable Tipping contract on zkSync (Sepolia or mainnet) with forge --zksync.
# zksolc cannot compile the L1-only SwarmRegistryL1Upgradeable (EXTCODECOPY), so the L1-only
# files are moved aside for the compile and restored on exit, exactly as
# ops/deploy_collection_factory_zksync.sh and ops/upgrade_collection_factory_zksync.sh do.
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=0x… N_TIPPING_ADMIN=0x… N_TIPPING_SIGNER=0x… \
#     ops/deploy_tipping_zksync.sh <testnet|mainnet> [--broadcast]
#
# Without --broadcast the script simulates only. The broadcast JSON lands in
# broadcast/DeployTippingZkSync.s.sol/<chainId>/run-latest.json; verify afterwards with
# python3 ops/verify_zksync_contracts.py --broadcast <that file>.
set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK="${1:-}"; BROADCAST="${2:-}"
case "$NETWORK" in
  testnet) RPC_URL="${L2_RPC:-https://sepolia.era.zksync.dev}" ;;
  mainnet) RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}" ;;
  *) echo "usage: $0 <testnet|mainnet> [--broadcast]"; exit 1 ;;
esac
: "${DEPLOYER_PRIVATE_KEY:?}" "${N_TIPPING_ADMIN:?}" "${N_TIPPING_SIGNER:?}"
[[ "$DEPLOYER_PRIVATE_KEY" == 0x* ]] || export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY}"
if [[ "$NETWORK" == "mainnet" && "$BROADCAST" == "--broadcast" && "${CONFIRM_MAINNET:-}" != "YES" ]]; then
  echo "mainnet broadcast requires CONFIRM_MAINNET=YES"; exit 1
fi

L1_BACKUP_DIR="/tmp/rollup-l1-backup-tipping"
restore_l1_contracts() {
  [ -d "$L1_BACKUP_DIR" ] || return 0
  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" ] && mv "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" src/swarms/
  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" ] && mv "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" test/
  [ -d "$L1_BACKUP_DIR/upgrade-demo" ] && mv "$L1_BACKUP_DIR/upgrade-demo" test/
  [ -f "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" ] && mv "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" script/
  [ -f "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" ] && mv "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" script/
  rm -rf "$L1_BACKUP_DIR"
  echo "L1-only contracts restored"
}
move_l1_contracts() {
  [ -d "$L1_BACKUP_DIR" ] && restore_l1_contracts
  mkdir -p "$L1_BACKUP_DIR"
  [ -f src/swarms/SwarmRegistryL1Upgradeable.sol ] && mv src/swarms/SwarmRegistryL1Upgradeable.sol "$L1_BACKUP_DIR/"
  [ -f test/SwarmRegistryL1.t.sol ] && mv test/SwarmRegistryL1.t.sol "$L1_BACKUP_DIR/"
  [ -d test/upgrade-demo ] && mv test/upgrade-demo "$L1_BACKUP_DIR/"
  [ -f script/DeploySwarmUpgradeable.s.sol ] && mv script/DeploySwarmUpgradeable.s.sol "$L1_BACKUP_DIR/"
  [ -f script/UpgradeSwarm.s.sol ] && mv script/UpgradeSwarm.s.sol "$L1_BACKUP_DIR/"
  echo "L1-only contracts moved aside for the zksync compile"
}
trap restore_l1_contracts EXIT
move_l1_contracts

echo "network=$NETWORK rpc=$RPC_URL admin=$N_TIPPING_ADMIN signer=$N_TIPPING_SIGNER broadcast=${BROADCAST:-no}"
forge script script/DeployTippingZkSync.s.sol --rpc-url "$RPC_URL" --zksync --skip test ${BROADCAST:+--broadcast --slow}
