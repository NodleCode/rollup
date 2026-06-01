#!/bin/bash
# =============================================================================
# upgrade_collection_factory_zksync.sh
#
# Orchestration wrapper for upgrading the user collections system on ZkSync Era.
# Companion to ops/deploy_collection_factory_zksync.sh; drives
# script/UpgradeCollectionFactory.s.sol through the same safety scaffolding the
# deploy uses (L1-file move/restore, --zksync compile, artifact gates, mainnet
# guard, post-broadcast asserts, source verification).
#
# THREE ACTIONS (see spec §9.4 and the Forge script's NatSpec):
#   UPGRADE_FACTORY  Deploy new CollectionFactory logic + upgradeToAndCall on the
#                    proxy. Changes the factory's EIP-1967 implementation slot.
#                    Optional REINIT_DATA env runs a reinitializer in the same tx.
#   SET_IMPL_721     Deploy new UserCollection721 impl + setImplementation721.
#                    Affects FUTURE collections only; existing ones are immutable.
#   SET_IMPL_1155    Same for UserCollection1155.
#
# USAGE:
#   # Dry run (no broadcast):
#   ./ops/upgrade_collection_factory_zksync.sh testnet UPGRADE_FACTORY
#
#   # Broadcast:
#   ./ops/upgrade_collection_factory_zksync.sh testnet SET_IMPL_721 --broadcast
#   ./ops/upgrade_collection_factory_zksync.sh mainnet UPGRADE_FACTORY --broadcast
#
# REQUIRED ENVIRONMENT VARIABLES (loaded from .env-test / .env-prod):
#   - DEPLOYER_PRIVATE_KEY:    Key holding DEFAULT_ADMIN_ROLE on the factory proxy.
#   - COLLECTION_FACTORY_PROXY (or FACTORY_PROXY): factory proxy address.
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   - L2_RPC:               Override the default zkSync RPC URL.
#   - REINIT_DATA:          (UPGRADE_FACTORY only) ABI-encoded reinitializer call.
#   - LAYOUT_REVIEWED:      Set to "YES" to acknowledge a storage-layout change
#                           (only appended fields are safe — see §6.3 / §9.4).
#   - CONFIRM_MAINNET:      Set to "YES" to skip the mainnet confirmation prompt.
#   - COMPILER_VERSION / ZKSOLC_VERSION: source-verification version overrides.
#
# NOTE: prefer a keystore/--account over a raw private key for mainnet — raw
# keys passed to `cast --private-key` are visible in `ps`.
# =============================================================================

# Exit on any error; fail pipelines if any stage fails (not just the last).
set -eo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NETWORK="${1:-testnet}"
ACTION="${2:-}"
BROADCAST="${3:-}"

case "$NETWORK" in
  testnet)
    ENV_FILE=".env-test"
    EXPLORER_URL="https://sepolia.explorer.zksync.io"
    VERIFIER_URL="https://explorer.sepolia.era.zksync.dev/contract_verification"
    ;;
  mainnet)
    ENV_FILE=".env-prod"
    EXPLORER_URL="https://explorer.zksync.io"
    VERIFIER_URL="https://zksync2-mainnet-explorer.zksync.io/contract_verification"
    ;;
  *)
    echo "Error: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
    exit 1
    ;;
esac

# Map the action to the contract it deploys, its source identifier, and the
# committed storage-layout baseline used for the pre-upgrade diff.
case "$ACTION" in
  UPGRADE_FACTORY)
    TARGET_CONTRACT="CollectionFactory"
    TARGET_SRC="src/collections/CollectionFactory.sol:CollectionFactory"
    LAYOUT_BASELINE="src/collections/layouts/CollectionFactory.v1.json"
    ;;
  SET_IMPL_721)
    TARGET_CONTRACT="UserCollection721"
    TARGET_SRC="src/collections/UserCollection721.sol:UserCollection721"
    LAYOUT_BASELINE="src/collections/layouts/UserCollection721.v1.json"
    ;;
  SET_IMPL_1155)
    TARGET_CONTRACT="UserCollection1155"
    TARGET_SRC="src/collections/UserCollection1155.sol:UserCollection1155"
    LAYOUT_BASELINE="src/collections/layouts/UserCollection1155.v1.json"
    ;;
  *)
    echo "Error: ACTION (arg 2) must be one of: UPGRADE_FACTORY, SET_IMPL_721, SET_IMPL_1155."
    echo "Usage: $0 <testnet|mainnet> <ACTION> [--broadcast]"
    exit 1
    ;;
esac

if [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
  CHAIN_ID="324"
else
  RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
  CHAIN_ID="300"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Normalize an address or 32-byte left-padded slot word to a comparable form:
# lowercase, 0x-prefixed, low 20 bytes only.
_norm_addr() {
  local hex="${1#0x}"
  hex=$(echo "$hex" | tr '[:upper:]' '[:lower:]')
  echo "0x${hex: -40}"
}

ADMIN_ROLE_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

# =============================================================================
# Pre-flight
# =============================================================================

preflight_checks() {
  log_info "Running pre-flight checks (action: $ACTION, network: $NETWORK)..."
  cd "$PROJECT_ROOT"

  if ! command -v forge &> /dev/null; then
    log_error "forge not found. Install foundry-zksync."
    exit 1
  fi
  if ! forge --version | grep -q "zksync"; then
    log_error "forge does not have ZkSync support. Install with: foundryup-zksync"
    exit 1
  fi
  if ! command -v cast &> /dev/null; then
    log_error "cast not found. Install foundry."
    exit 1
  fi
  if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file '$ENV_FILE' not found."
    exit 1
  fi

  set -a
  source "$ENV_FILE"
  set +a

  if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    log_error "DEPLOYER_PRIVATE_KEY not set in $ENV_FILE (must hold DEFAULT_ADMIN_ROLE)"
    exit 1
  fi
  if [[ "$DEPLOYER_PRIVATE_KEY" != 0x* ]]; then
    export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY}"
  fi

  # Resolve the factory proxy: explicit FACTORY_PROXY wins, else the address the
  # deploy script wrote to the env file as COLLECTION_FACTORY_PROXY.
  PROXY="${FACTORY_PROXY:-${COLLECTION_FACTORY_PROXY:-}}"
  if [ -z "$PROXY" ]; then
    log_error "No factory proxy address. Set FACTORY_PROXY or COLLECTION_FACTORY_PROXY in $ENV_FILE."
    exit 1
  fi
  export FACTORY_PROXY="$PROXY"
  export ACTION

  log_info "Factory proxy: $PROXY"

  # Mainnet guardrail.
  if [ "$NETWORK" = "mainnet" ] && [ "$BROADCAST" = "--broadcast" ]; then
    if [ "${CONFIRM_MAINNET:-}" = "YES" ]; then
      log_warning "CONFIRM_MAINNET=YES set — proceeding with mainnet upgrade without prompt."
    else
      log_warning "About to run '$ACTION' against ZkSync MAINNET factory $PROXY (irreversible)."
      read -r -p "Type 'YES' to confirm mainnet upgrade: " confirm
      if [ "$confirm" != "YES" ]; then
        log_error "Mainnet upgrade aborted by user."
        exit 1
      fi
    fi
  fi

  log_success "Pre-flight checks passed"
}

# =============================================================================
# L1-incompatible file move/restore (so `forge ... --zksync` compiles the tree).
# Mirrors ops/deploy_collection_factory_zksync.sh.
# =============================================================================

L1_BACKUP_DIR="/tmp/rollup-l1-backup-collections-upgrade"

move_l1_contracts() {
  log_info "Moving L1-incompatible contracts to temporary location..."
  if [ -d "$L1_BACKUP_DIR" ]; then
    log_warning "Found previous backup, restoring first..."
    restore_l1_contracts 2>/dev/null || true
  fi
  mkdir -p "$L1_BACKUP_DIR"

  [ -f "src/swarms/SwarmRegistryL1Upgradeable.sol" ] && \
    mv "src/swarms/SwarmRegistryL1Upgradeable.sol" "$L1_BACKUP_DIR/"
  [ -f "test/SwarmRegistryL1.t.sol" ] && \
    mv "test/SwarmRegistryL1.t.sol" "$L1_BACKUP_DIR/"
  [ -d "test/upgrade-demo" ] && \
    mv "test/upgrade-demo" "$L1_BACKUP_DIR/"
  [ -f "script/DeploySwarmUpgradeable.s.sol" ] && \
    mv "script/DeploySwarmUpgradeable.s.sol" "$L1_BACKUP_DIR/"
  [ -f "script/UpgradeSwarm.s.sol" ] && \
    mv "script/UpgradeSwarm.s.sol" "$L1_BACKUP_DIR/"

  log_success "L1 contracts moved to $L1_BACKUP_DIR"
}

restore_l1_contracts() {
  [ -d "$L1_BACKUP_DIR" ] || return 0
  log_info "Restoring L1 contracts from backup..."

  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" ] && \
    mv "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" "src/swarms/"
  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" ] && \
    mv "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" "test/"
  [ -d "$L1_BACKUP_DIR/upgrade-demo" ] && \
    mv "$L1_BACKUP_DIR/upgrade-demo" "test/"
  [ -f "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" ] && \
    mv "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" "script/"
  [ -f "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" ] && \
    mv "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" "script/"

  rm -rf "$L1_BACKUP_DIR"
  log_success "L1 contracts restored"
}

trap restore_l1_contracts EXIT

# =============================================================================
# Compile
# =============================================================================

compile_contracts() {
  log_info "Compiling contracts with Forge for ZkSync..."
  forge build --zksync --skip test
  log_success "Compilation complete"
}

# =============================================================================
# Artifact gates (action-specific).
# =============================================================================

verify_artifacts() {
  if [ "$ACTION" = "UPGRADE_FACTORY" ]; then
    # The new factory logic must still register ERC1967Proxy as a factoryDep,
    # or createCollection* would revert at runtime on EraVM.
    log_info "Verifying CollectionFactory factoryDependencies are populated..."
    local artifact="zkout/CollectionFactory.sol/CollectionFactory.json"
    if [ ! -f "$artifact" ]; then
      log_error "Compiled artifact not found: $artifact"
      exit 1
    fi
    local dep_count
    if ! dep_count=$(jq -r '.factoryDependencies | length' "$artifact" 2>&1); then
      log_error "jq failed parsing $artifact: $dep_count"
      exit 1
    fi
    if [ -z "$dep_count" ] || [ "$dep_count" -eq 0 ]; then
      log_error "CollectionFactory.factoryDependencies is empty — factory cannot deploy proxies."
      exit 1
    fi
    log_success "factoryDependencies populated ($dep_count entries)"
  else
    # New collection impl must not expose an upgrade selector (no UUPSUpgradeable),
    # or the §1.3 per-collection immutability promise breaks.
    log_info "Verifying $TARGET_CONTRACT exposes no upgrade selectors..."
    local artifact="zkout/${TARGET_CONTRACT}.sol/${TARGET_CONTRACT}.json"
    if [ ! -f "$artifact" ]; then
      log_error "Compiled artifact not found: $artifact"
      exit 1
    fi
    local forbidden='["upgradeTo","upgradeToAndCall","proxiableUUID"]'
    local hits
    if ! hits=$(jq -r --argjson f "$forbidden" \
      '[.abi[] | select(.type=="function") | .name] | map(select(. as $n | $f | index($n))) | length' \
      "$artifact" 2>&1); then
      log_error "jq failed parsing $artifact: $hits"
      exit 1
    fi
    if [ -z "$hits" ] || [ "$hits" -ne 0 ]; then
      log_error "$TARGET_CONTRACT exposes an upgrade selector — must not inherit UUPSUpgradeable."
      exit 1
    fi
    log_success "$TARGET_CONTRACT: no upgrade selectors"
  fi
}

# =============================================================================
# Storage-layout gate (spec §6.3 / §9.4).
# Compares the layout of the contract being deployed against its committed
# baseline. Identical → proceed. Any difference → require explicit
# acknowledgement (LAYOUT_REVIEWED=YES or interactive), because only APPENDED
# fields are upgrade-safe and that judgement is a human one.
# =============================================================================

check_storage_layout() {
  log_info "Diffing $TARGET_CONTRACT storage layout against $LAYOUT_BASELINE..."

  if [ ! -f "$LAYOUT_BASELINE" ]; then
    log_error "Storage-layout baseline not found: $LAYOUT_BASELINE"
    exit 1
  fi

  # Project only the layout-relevant fields; astId changes per compile and is
  # not part of the storage contract.
  local proj='.storage | map({label: .label, slot: .slot, offset: .offset, type: .type})'
  local current_layout baseline_layout
  current_layout=$(forge inspect "$TARGET_CONTRACT" storageLayout --json 2>/dev/null | jq -S "$proj")
  baseline_layout=$(jq -S "$proj" "$LAYOUT_BASELINE")

  if [ "$current_layout" = "$baseline_layout" ]; then
    log_success "Storage layout matches baseline (no slot/offset changes)"
    return 0
  fi

  log_warning "Storage layout DIFFERS from the committed baseline:"
  diff <(echo "$baseline_layout") <(echo "$current_layout") || true
  log_warning "Only APPENDED fields (consuming __gap) are upgrade-safe; any moved/"
  log_warning "resized prior slot corrupts storage. Update the baseline JSON in the"
  log_warning "same PR and review the diff (spec §9.4) before proceeding."

  if [ "${LAYOUT_REVIEWED:-}" = "YES" ]; then
    log_warning "LAYOUT_REVIEWED=YES set — proceeding despite layout change."
    return 0
  fi
  if [ "$BROADCAST" != "--broadcast" ]; then
    log_warning "Dry run — continuing so you can inspect the diff. Set LAYOUT_REVIEWED=YES to broadcast."
    return 0
  fi
  read -r -p "Layout changed. Type 'REVIEWED' to confirm you've verified it is append-only: " ack
  if [ "$ack" != "REVIEWED" ]; then
    log_error "Upgrade aborted — storage layout change not acknowledged."
    exit 1
  fi
}

# =============================================================================
# On-chain admin-key + pre-state checks (broadcast only, read-only, pre-upgrade).
# =============================================================================

PRE_IMPL_721=""
PRE_IMPL_1155=""

capture_pre_state() {
  log_info "Verifying the deployer key holds DEFAULT_ADMIN_ROLE..."
  local deployer
  deployer=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
  local is_admin
  is_admin=$(cast call "$PROXY" "hasRole(bytes32,address)(bool)" \
    "$ADMIN_ROLE_HASH" "$deployer" --rpc-url "$RPC_URL")
  if [ "$is_admin" != "true" ]; then
    log_error "Deployer $deployer does NOT hold DEFAULT_ADMIN_ROLE on $PROXY — upgrade would revert."
    exit 1
  fi
  log_success "Deployer $deployer holds DEFAULT_ADMIN_ROLE"

  PRE_IMPL_721=$(cast call "$PROXY" "erc721Implementation()(address)" --rpc-url "$RPC_URL")
  PRE_IMPL_1155=$(cast call "$PROXY" "erc1155Implementation()(address)" --rpc-url "$RPC_URL")
  log_info "Pre-upgrade erc721Implementation:  $PRE_IMPL_721"
  log_info "Pre-upgrade erc1155Implementation: $PRE_IMPL_1155"
}

# =============================================================================
# Run the upgrade
# =============================================================================

NEW_IMPL=""

run_upgrade() {
  local forge_args=(
    "script"
    "script/UpgradeCollectionFactory.s.sol:UpgradeCollectionFactory"
    "--rpc-url" "$RPC_URL"
    "--chain-id" "$CHAIN_ID"
    "--zksync"
  )

  if [ "$BROADCAST" != "--broadcast" ]; then
    log_warning "DRY RUN MODE - Add '--broadcast' to actually upgrade"
    log_info "Would run action '$ACTION' on proxy $PROXY via $RPC_URL"
    [ -n "${REINIT_DATA:-}" ] && log_info "  REINIT_DATA present (reinitializer migration)"
    return 0
  fi

  capture_pre_state

  forge_args+=("--broadcast" "--slow")

  local upgrade_log="/tmp/collections-upgrade-$$.txt"
  forge "${forge_args[@]}" 2>&1 | tee "$upgrade_log"

  NEW_IMPL=$(grep -o 'New Implementation: 0x[0-9a-fA-F]*' "$upgrade_log" | tail -1 | grep -o '0x[0-9a-fA-F]*')
  rm -f "$upgrade_log"

  if [ -z "$NEW_IMPL" ]; then
    log_error "Could not extract the new implementation address from the upgrade output."
    exit 1
  fi
  log_success "Upgrade broadcast. New implementation: $NEW_IMPL"
}

# =============================================================================
# Post-upgrade verification (broadcast only) — assert, don't just print.
# =============================================================================

verify_upgrade() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Verifying upgrade outcome on-chain..."

  # Admin role must survive any upgrade.
  local has_admin deployer
  deployer=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
  has_admin=$(cast call "$PROXY" "hasRole(bytes32,address)(bool)" \
    "$ADMIN_ROLE_HASH" "$deployer" --rpc-url "$RPC_URL")
  if [ "$has_admin" != "true" ]; then
    log_error "DEFAULT_ADMIN_ROLE lost after upgrade — aborting (state may be corrupt)."
    exit 1
  fi

  local cur_721 cur_1155
  cur_721=$(cast call "$PROXY" "erc721Implementation()(address)" --rpc-url "$RPC_URL")
  cur_1155=$(cast call "$PROXY" "erc1155Implementation()(address)" --rpc-url "$RPC_URL")

  case "$ACTION" in
    UPGRADE_FACTORY)
      # EIP-1967 slot must now point at the new factory logic.
      local stored
      stored=$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$RPC_URL")
      if [ "$(_norm_addr "$stored")" != "$(_norm_addr "$NEW_IMPL")" ]; then
        log_error "EIP-1967 slot $stored != new factory logic $NEW_IMPL"
        exit 1
      fi
      # Impl pointers must be preserved across the logic upgrade.
      if [ "$(_norm_addr "$cur_721")" != "$(_norm_addr "$PRE_IMPL_721")" ]; then
        log_error "erc721Implementation changed across upgrade: $PRE_IMPL_721 -> $cur_721"
        exit 1
      fi
      if [ "$(_norm_addr "$cur_1155")" != "$(_norm_addr "$PRE_IMPL_1155")" ]; then
        log_error "erc1155Implementation changed across upgrade: $PRE_IMPL_1155 -> $cur_1155"
        exit 1
      fi
      log_success "Factory logic upgraded; impl pointers and admin role preserved"
      ;;
    SET_IMPL_721)
      if [ "$(_norm_addr "$cur_721")" != "$(_norm_addr "$NEW_IMPL")" ]; then
        log_error "erc721Implementation not updated: on-chain $cur_721 != new $NEW_IMPL"
        exit 1
      fi
      if [ "$(_norm_addr "$cur_1155")" != "$(_norm_addr "$PRE_IMPL_1155")" ]; then
        log_error "erc1155Implementation unexpectedly changed: $PRE_IMPL_1155 -> $cur_1155"
        exit 1
      fi
      log_success "erc721Implementation updated to $NEW_IMPL; 1155 pointer unchanged"
      ;;
    SET_IMPL_1155)
      if [ "$(_norm_addr "$cur_1155")" != "$(_norm_addr "$NEW_IMPL")" ]; then
        log_error "erc1155Implementation not updated: on-chain $cur_1155 != new $NEW_IMPL"
        exit 1
      fi
      if [ "$(_norm_addr "$cur_721")" != "$(_norm_addr "$PRE_IMPL_721")" ]; then
        log_error "erc721Implementation unexpectedly changed: $PRE_IMPL_721 -> $cur_721"
        exit 1
      fi
      log_success "erc1155Implementation updated to $NEW_IMPL; 721 pointer unchanged"
      ;;
  esac

  log_success "Post-upgrade verification passed"
}

# =============================================================================
# Source verification of the newly deployed contract (single-contract mode).
# =============================================================================

verify_source_code() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi
  if ! command -v python3 &> /dev/null; then
    log_warning "python3 not found — skipping source verification."
    return 0
  fi

  log_info "Verifying $TARGET_CONTRACT source on the block explorer ($NEW_IMPL)..."

  # All upgrade targets have parameterless constructors → no constructor args.
  local exit_code=0
  python3 "$SCRIPT_DIR/verify_zksync_contracts.py" \
    --address "$NEW_IMPL" \
    --contract "$TARGET_SRC" \
    --verifier-url "$VERIFIER_URL" \
    --compiler-version "${COMPILER_VERSION:-0.8.26}" \
    --zksolc-version "${ZKSOLC_VERSION:-v1.5.15}" \
    --project-root "$PROJECT_ROOT" || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    log_success "$TARGET_CONTRACT source-code verified"
  else
    log_warning "Source verification failed (upgrade itself succeeded). Retry manually:"
    log_warning "  python3 ops/verify_zksync_contracts.py --address $NEW_IMPL --contract $TARGET_SRC --verifier-url $VERIFIER_URL"
  fi
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
  echo ""
  echo "=============================================="
  echo "  UPGRADE SUMMARY"
  echo "=============================================="
  echo ""
  echo "Network:  $NETWORK"
  echo "Action:   $ACTION"
  echo "Proxy:    $PROXY"
  echo "Explorer: $EXPLORER_URL/address/$PROXY"
  echo ""
  if [ "$BROADCAST" != "--broadcast" ]; then
    echo "Mode: DRY RUN (nothing broadcast)"
    echo ""
    echo "To run for real:"
    echo "  $0 $NETWORK $ACTION --broadcast"
    return 0
  fi
  echo "New $TARGET_CONTRACT implementation: $NEW_IMPL"
  echo "Explorer: $EXPLORER_URL/address/$NEW_IMPL"
  echo ""
  echo "=============================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo ""
  echo "=============================================="
  echo "  ZkSync User Collections Upgrade"
  echo "=============================================="
  echo ""

  cd "$PROJECT_ROOT"

  preflight_checks
  move_l1_contracts
  compile_contracts
  verify_artifacts
  check_storage_layout
  run_upgrade
  verify_upgrade
  verify_source_code
  print_summary
}

main "$@"
