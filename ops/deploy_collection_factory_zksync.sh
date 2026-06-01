#!/bin/bash
# =============================================================================
# deploy_collection_factory_zksync.sh
#
# Automated deployment script for the user collections system
# (CollectionFactory + UserCollection721 + UserCollection1155) on ZkSync Era.
#
# OVERVIEW:
# ---------
# Deploys the upgradeable user collections system to ZkSync Era using Foundry
# with --zksync (zksolc compiler).
#
# Mirrors the swarms deployment pattern (ops/deploy_swarm_contracts_zksync.sh):
#   - Temp-move L1-incompatible files (SSTORE2/EXTCODECOPY) so zksolc compiles
#   - Forge build with --zksync, skip tests
#   - Run the Forge script via --broadcast (or dry-run without)
#   - Source code verification via ops/verify_zksync_contracts.py (the
#     ZkSync verifier rejects forge --verify and forge verify-contract)
#   - Append deployed addresses to .env-test or .env-prod
#
# Collections itself has no SSTORE2/EXTCODECOPY usage, but `forge build --zksync`
# compiles the entire tree, so files like SwarmRegistryL1Upgradeable and
# test/upgrade-demo/TestUpgradeOnAnvil still need to be moved out of the way.
#
# CONTRACT ARCHITECTURE:
# ----------------------
# - UserCollection721 implementation (deployed behind a per-collection ERC1967Proxy)
# - UserCollection1155 implementation (deployed behind a per-collection ERC1967Proxy)
# - CollectionFactory logic + ERC1967Proxy (UUPS-upgradeable factory)
#
# USAGE:
# ------
#   # Testnet dry run:
#   ./ops/deploy_collection_factory_zksync.sh testnet
#
#   # Testnet (actual deployment):
#   ./ops/deploy_collection_factory_zksync.sh testnet --broadcast
#
#   # Mainnet:
#   ./ops/deploy_collection_factory_zksync.sh mainnet --broadcast
#
# REQUIRED ENVIRONMENT VARIABLES (loaded from .env-test / .env-prod):
# -------------------------------------------------------------------
#   - DEPLOYER_PRIVATE_KEY: Private key with ETH for gas
#   - N_FACTORY_ADMIN:      Multisig that will hold DEFAULT_ADMIN_ROLE on the factory
#   - N_FACTORY_OPERATOR:   Backend service address that will hold OPERATOR_ROLE
#
# OPTIONAL ENVIRONMENT VARIABLES:
# -------------------------------
#   - L2_RPC:               Override the default zkSync RPC URL for the network
#   - OPERATOR_PRIVATE_KEY: Key holding OPERATOR_ROLE, used to sign the post-deploy
#                           createCollection721 smoke test. If unset, the smoke
#                           test runs only when the deployer EOA is the operator.
#   - COMPILER_VERSION:     solc version passed to source verification (default 0.8.26)
#   - ZKSOLC_VERSION:       zksolc version passed to source verification (default v1.5.15)
#   - CONFIRM_MAINNET:      Set to "YES" to skip the interactive mainnet confirmation
#                           prompt (for non-interactive/CI mainnet runs)
#   - RUN_MAINNET_SMOKE_TEST: Set to "true" to allow the smoke test to create a
#                           (permanent) collection on mainnet; default skips it
#
# NOTE: For mainnet, prefer a keystore/--account over a raw private key in the
# env file — raw keys passed to `cast --private-key` are visible in `ps`.
#
# =============================================================================

# Exit on any error, and make pipelines fail if ANY stage fails (not just the
# last). Without pipefail, `forge ... | tee log` would mask a failed deploy
# because tee's exit status (0) would win. See H1 in the deploy-script review.
set -eo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NETWORK="${1:-testnet}"
BROADCAST="${2:-}"

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

# Normalize an address or a 32-byte left-padded slot word to a comparable form:
# lowercase, 0x-prefixed, low 20 bytes only. Lets us compare `cast storage`
# output (padded) against a plain address regardless of case/padding.
_norm_addr() {
  local hex="${1#0x}"
  hex=$(echo "$hex" | tr '[:upper:]' '[:lower:]')
  # Keep the rightmost 40 hex chars (20 bytes).
  echo "0x${hex: -40}"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
  log_info "Running pre-flight checks..."

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
    log_error "DEPLOYER_PRIVATE_KEY not set in $ENV_FILE"
    exit 1
  fi

  if [ -z "$N_FACTORY_ADMIN" ]; then
    log_error "N_FACTORY_ADMIN not set in $ENV_FILE (must be the factory admin multisig)"
    exit 1
  fi

  if [ -z "$N_FACTORY_OPERATOR" ]; then
    log_error "N_FACTORY_OPERATOR not set in $ENV_FILE (must be the backend service address)"
    exit 1
  fi

  if [[ "$DEPLOYER_PRIVATE_KEY" != 0x* ]]; then
    export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY}"
  fi

  # Mainnet guardrail: require explicit confirmation before an irreversible
  # broadcast. Set CONFIRM_MAINNET=YES to bypass for non-interactive runs.
  if [ "$NETWORK" = "mainnet" ] && [ "$BROADCAST" = "--broadcast" ]; then
    if [ "${CONFIRM_MAINNET:-}" = "YES" ]; then
      log_warning "CONFIRM_MAINNET=YES set — proceeding with mainnet broadcast without prompt."
    else
      log_warning "About to deploy to ZkSync MAINNET (irreversible)."
      log_warning "  Admin:    $N_FACTORY_ADMIN"
      log_warning "  Operator: $N_FACTORY_OPERATOR"
      read -r -p "Type 'YES' to confirm mainnet deployment: " confirm
      if [ "$confirm" != "YES" ]; then
        log_error "Mainnet deployment aborted by user."
        exit 1
      fi
    fi
  fi

  log_success "Pre-flight checks passed"
}

# =============================================================================
# Temporarily move L1-incompatible contracts so zksolc can compile the tree.
# Mirrors the move/restore pattern in ops/deploy_swarm_contracts_zksync.sh.
# =============================================================================

L1_BACKUP_DIR="/tmp/rollup-l1-backup-collections-deploy"

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
# Build-artifact verification — factoryDependencies must be populated.
# Empty factoryDependencies on CollectionFactory means createCollection*
# would revert at runtime on EraVM (the original Clones.clone() bug).
# =============================================================================

verify_build_artifacts() {
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
    log_error "CollectionFactory.factoryDependencies is empty or unreadable."
    log_error "This means the factory cannot deploy per-collection proxies on EraVM."
    log_error "Refer to design §3.5.2 / §7.2 row 15b — ERC1967Proxy must appear in factoryDeps."
    exit 1
  fi

  log_success "factoryDependencies populated ($dep_count entries)"
}

# =============================================================================
# Implementation permanence (EraVM artifact gate).
#
# The Foundry opcode-walker test (test/collections/*.t.sol) asserts "no
# SELFDESTRUCT" against the EVM-compiled bytecode. That check does NOT carry
# over to the deployed artifact: EraVM uses a different bytecode format and ISA,
# and `selfdestruct` is unsupported at the VM level — so the impl can't be wiped
# on the target chain regardless. What CAN still regress is the impl
# accidentally exposing an upgrade entry point (e.g. someone adds
# `UUPSUpgradeable` later), which would break the §1.3 per-collection
# immutability promise. Function selectors are VM-agnostic, so we gate on the
# zksolc-emitted ABI of the actual deployed implementations.
# =============================================================================

verify_implementation_permanence() {
  log_info "Verifying implementation ABIs expose no upgrade selectors..."

  local impls=(
    "zkout/UserCollection721.sol/UserCollection721.json"
    "zkout/UserCollection1155.sol/UserCollection1155.json"
  )
  local forbidden='["upgradeTo","upgradeToAndCall","proxiableUUID"]'

  for artifact in "${impls[@]}"; do
    if [ ! -f "$artifact" ]; then
      log_error "Compiled artifact not found: $artifact"
      exit 1
    fi

    local hits
    if ! hits=$(jq -r --argjson f "$forbidden" \
      '[.abi[] | select(.type=="function") | .name] | map(select(. as $n | $f | index($n))) | length' \
      "$artifact" 2>&1); then
      log_error "jq failed parsing $artifact: $hits"
      exit 1
    fi

    if [ -z "$hits" ] || [ "$hits" -ne 0 ]; then
      log_error "$artifact exposes an upgrade selector (proxiableUUID/upgradeTo*)."
      log_error "Implementations must NOT inherit UUPSUpgradeable — see design §3.5.2 / §7.2 row 15b."
      exit 1
    fi

    log_success "$(basename "$artifact"): no upgrade selectors"
  done
}

# =============================================================================
# Deploy
# =============================================================================

deploy_contracts() {
  log_info "Deploying CollectionFactory to ZkSync ($NETWORK)..."

  if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
    CHAIN_ID="324"
  else
    RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
    CHAIN_ID="300"
  fi

  FORGE_ARGS=(
    "script"
    "script/DeployCollectionFactoryZkSync.s.sol:DeployCollectionFactoryZkSync"
    "--rpc-url" "$RPC_URL"
    "--chain-id" "$CHAIN_ID"
    "--zksync"
  )

  if [ "$BROADCAST" = "--broadcast" ]; then
    FORGE_ARGS+=("--broadcast" "--slow")
    # NOTE: We do NOT add --verify here. forge script --verify sends absolute
    # source paths which the ZkSync verifier rejects. Source code verification
    # is handled separately in verify_source_code() using the helper Python
    # script that rewrites imports to project-rooted paths.
  else
    log_warning "DRY RUN MODE - Add '--broadcast' to actually deploy"
    log_info "Would deploy with:"
    log_info "  N_FACTORY_ADMIN:    $N_FACTORY_ADMIN"
    log_info "  N_FACTORY_OPERATOR: $N_FACTORY_OPERATOR"
    log_info "  RPC:                $RPC_URL"
    return 0
  fi

  DEPLOY_LOG="/tmp/collections-deploy-$$.txt"

  forge "${FORGE_ARGS[@]}" 2>&1 | tee "$DEPLOY_LOG"

  if [ "$BROADCAST" = "--broadcast" ]; then
    COLLECTION_FACTORY_PROXY=$(grep -o 'CollectionFactory Proxy: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | grep -o '0x[0-9a-fA-F]*')
    COLLECTION_FACTORY_IMPL=$(grep -o 'CollectionFactory Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | grep -o '0x[0-9a-fA-F]*')
    USER_COLLECTION_721_IMPL=$(grep -o 'UserCollection721 Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | grep -o '0x[0-9a-fA-F]*')
    USER_COLLECTION_1155_IMPL=$(grep -o 'UserCollection1155 Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | grep -o '0x[0-9a-fA-F]*')

    if [ -z "$COLLECTION_FACTORY_PROXY" ] || [ -z "$COLLECTION_FACTORY_IMPL" ] \
       || [ -z "$USER_COLLECTION_721_IMPL" ] || [ -z "$USER_COLLECTION_1155_IMPL" ]; then
      log_error "Could not extract all addresses from deploy output"
      log_info "Full output saved to: $DEPLOY_LOG"
      cat "$DEPLOY_LOG"
      exit 1
    fi
    log_success "Deployment complete!"
  fi

  rm -f "$DEPLOY_LOG"
}

# =============================================================================
# Post-deploy sanity checks
# =============================================================================

verify_deployment() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Verifying deployment..."

  if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
  else
    RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
  fi

  local ADMIN_ROLE_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
  local OPERATOR_ROLE_HASH
  OPERATOR_ROLE_HASH=$(cast keccak "OPERATOR_ROLE")

  log_info "Checking DEFAULT_ADMIN_ROLE granted to admin..."
  HAS_ADMIN=$(cast call "$COLLECTION_FACTORY_PROXY" \
    "hasRole(bytes32,address)(bool)" \
    "$ADMIN_ROLE_HASH" "$N_FACTORY_ADMIN" --rpc-url "$RPC_URL")
  if [ "$HAS_ADMIN" != "true" ]; then
    log_error "DEFAULT_ADMIN_ROLE is NOT granted to $N_FACTORY_ADMIN (got: $HAS_ADMIN)"
    exit 1
  fi
  log_success "Admin role granted: $HAS_ADMIN"

  log_info "Checking OPERATOR_ROLE granted to operator..."
  HAS_OP=$(cast call "$COLLECTION_FACTORY_PROXY" \
    "hasRole(bytes32,address)(bool)" \
    "$OPERATOR_ROLE_HASH" "$N_FACTORY_OPERATOR" --rpc-url "$RPC_URL")
  if [ "$HAS_OP" != "true" ]; then
    log_error "OPERATOR_ROLE is NOT granted to $N_FACTORY_OPERATOR (got: $HAS_OP)"
    exit 1
  fi
  log_success "Operator role granted: $HAS_OP"

  log_info "Checking implementation pointers..."
  IMPL_721=$(cast call "$COLLECTION_FACTORY_PROXY" "erc721Implementation()(address)" --rpc-url "$RPC_URL")
  IMPL_1155=$(cast call "$COLLECTION_FACTORY_PROXY" "erc1155Implementation()(address)" --rpc-url "$RPC_URL")
  if [ "$(_norm_addr "$IMPL_721")" != "$(_norm_addr "$USER_COLLECTION_721_IMPL")" ]; then
    log_error "erc721Implementation mismatch: on-chain $IMPL_721 != deployed $USER_COLLECTION_721_IMPL"
    exit 1
  fi
  if [ "$(_norm_addr "$IMPL_1155")" != "$(_norm_addr "$USER_COLLECTION_1155_IMPL")" ]; then
    log_error "erc1155Implementation mismatch: on-chain $IMPL_1155 != deployed $USER_COLLECTION_1155_IMPL"
    exit 1
  fi
  log_success "erc721Implementation:  $IMPL_721"
  log_success "erc1155Implementation: $IMPL_1155"

  log_info "Checking EIP-1967 implementation slot points at factory logic..."
  IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
  STORED_IMPL=$(cast storage "$COLLECTION_FACTORY_PROXY" "$IMPL_SLOT" --rpc-url "$RPC_URL")
  # The slot stores a left-padded 32-byte word; compare the low 20 bytes.
  if [ "$(_norm_addr "$STORED_IMPL")" != "$(_norm_addr "$COLLECTION_FACTORY_IMPL")" ]; then
    log_error "EIP-1967 slot mismatch: stored $STORED_IMPL != factory logic $COLLECTION_FACTORY_IMPL"
    exit 1
  fi
  log_success "EIP-1967 stored impl: $STORED_IMPL"

  log_success "Post-deploy sanity checks passed"
}

# =============================================================================
# End-to-end smoke test — exercise createCollection721 on the live network.
# This is the empirical check that the EraVM-compiled output works at runtime.
# =============================================================================

smoke_test_createCollection() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  # The smoke test creates a real, PERMANENT collection (collections are
  # immutable and the externalId is consumed forever). On mainnet that pollutes
  # the production registry, so skip it unless explicitly opted in.
  if [ "$NETWORK" = "mainnet" ] && [ "${RUN_MAINNET_SMOKE_TEST:-}" != "true" ]; then
    log_warning "Skipping createCollection721 smoke test on mainnet (would create a permanent collection)."
    log_warning "Set RUN_MAINNET_SMOKE_TEST=true to run it intentionally."
    return 0
  fi

  log_info "Running end-to-end smoke test: createCollection721..."

  local rpc
  if [ "$NETWORK" = "mainnet" ]; then
    rpc="${L2_RPC:-https://mainnet.era.zksync.io}"
  else
    rpc="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
  fi

  # Determine which private key holds OPERATOR_ROLE for signing.
  # Production typically separates the deployer EOA from the operator multisig
  # or backend key; only run the smoke test if we have a key that can sign.
  local signer_key
  if [ -n "$OPERATOR_PRIVATE_KEY" ]; then
    signer_key="$OPERATOR_PRIVATE_KEY"
    [[ "$signer_key" != 0x* ]] && signer_key="0x${signer_key}"
  else
    local deployer_addr
    deployer_addr=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
    if [ "$(echo "$deployer_addr" | tr '[:upper:]' '[:lower:]')" = "$(echo "$N_FACTORY_OPERATOR" | tr '[:upper:]' '[:lower:]')" ]; then
      signer_key="$DEPLOYER_PRIVATE_KEY"
    else
      log_warning "Skipping smoke test: deployer address ($deployer_addr) is not the operator ($N_FACTORY_OPERATOR), and OPERATOR_PRIVATE_KEY is not set."
      log_warning "To run the smoke test against a multisig/separate operator, export OPERATOR_PRIVATE_KEY with a key that holds OPERATOR_ROLE."
      return 0
    fi
  fi

  # Build a minimal CreateParams721 calldata. owner = operator,
  # additionalMinters = empty array, royaltyBps = 0, simple URIs.
  local extId
  extId=$(cast keccak "smoke-$(date +%s)")

  log_info "Calling createCollection721($extId)..."
  # CreateParams721 fields per src/collections/interfaces/CollectionTypes.sol:
  # (address owner, string name, string symbol, string baseURI, string contractURI,
  #  address royaltyRecipient, uint96 royaltyBps, address[] additionalMinters)
  cast send "$COLLECTION_FACTORY_PROXY" \
    "createCollection721((address,string,string,string,string,address,uint96,address[]),bytes32)" \
    "($N_FACTORY_OPERATOR,Smoke,SMK,ipfs://smoke/,ipfs://smoke.json,$N_FACTORY_OPERATOR,0,[])" \
    "$extId" \
    --rpc-url "$rpc" \
    --private-key "$signer_key" \
    --zksync \
    || { log_error "createCollection721 reverted on-chain"; exit 1; }

  # Read the resulting collection address from the mapping.
  local collection
  collection=$(cast call "$COLLECTION_FACTORY_PROXY" \
    "collectionByExternalId(bytes32)(address)" "$extId" --rpc-url "$rpc")

  log_info "Smoke collection deployed at: $collection"

  # Assert non-empty code at the collection address.
  local code_size
  code_size=$(cast code "$collection" --rpc-url "$rpc" | wc -c)
  if [ "$code_size" -lt 10 ]; then
    log_error "Smoke collection has empty bytecode"
    exit 1
  fi

  # Assert EIP-1967 impl slot equals expected impl.
  local EIP1967_IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
  local stored
  stored=$(cast storage "$collection" "$EIP1967_IMPL_SLOT" --rpc-url "$rpc")
  if [ "$(_norm_addr "$stored")" != "$(_norm_addr "$USER_COLLECTION_721_IMPL")" ]; then
    log_error "Smoke collection EIP-1967 slot mismatch: stored $stored != expected impl $USER_COLLECTION_721_IMPL"
    exit 1
  fi
  log_info "EIP-1967 impl slot: $stored (matches expected impl: $USER_COLLECTION_721_IMPL)"

  log_success "Smoke test passed: createCollection721 succeeded; collection has code; EIP-1967 slot verified"
}

# =============================================================================
# Source code verification on the block explorer
# =============================================================================

verify_source_code() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Verifying source code on block explorer..."

  if [ "$NETWORK" = "mainnet" ]; then
    CHAIN_ID="324"
  else
    CHAIN_ID="300"
  fi

  BROADCAST_JSON="broadcast/DeployCollectionFactoryZkSync.s.sol/${CHAIN_ID}/run-latest.json"
  if [ ! -f "$BROADCAST_JSON" ]; then
    log_error "Broadcast file not found: $BROADCAST_JSON"
    log_warning "Skipping source code verification"
    return 1
  fi

  if ! command -v python3 &> /dev/null; then
    log_error "python3 not found. Install Python 3.8+ for source code verification."
    log_warning "Skipping source code verification"
    return 1
  fi

  # Versions default to the toolchain this script was written against; override
  # via COMPILER_VERSION / ZKSOLC_VERSION when the installed toolchain differs,
  # otherwise verification silently fails on a version mismatch.
  # Capture the exit code WITHOUT letting `set -e` abort here: source
  # verification failing is non-fatal (the contracts are already deployed), it
  # just needs a manual retry. The `|| exit_code=$?` keeps set -e from killing
  # the script before we can warn.
  local exit_code=0
  python3 "$SCRIPT_DIR/verify_zksync_contracts.py" \
    --broadcast "$BROADCAST_JSON" \
    --verifier-url "$VERIFIER_URL" \
    --compiler-version "${COMPILER_VERSION:-0.8.26}" \
    --zksolc-version "${ZKSOLC_VERSION:-v1.5.15}" \
    --project-root "$PROJECT_ROOT" || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    log_success "All contracts source-code verified on block explorer!"
  else
    log_warning "Some contracts failed source verification (deployment itself succeeded)"
    log_info "Retry manually: python3 ops/verify_zksync_contracts.py --broadcast $BROADCAST_JSON --verifier-url $VERIFIER_URL"
  fi
}

# =============================================================================
# Append deployed addresses to env file
# =============================================================================

update_env_file() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Updating $ENV_FILE with deployed addresses..."

  TIMESTAMP=$(date +%Y-%m-%d)

  if grep -q "COLLECTION_FACTORY_PROXY" "$ENV_FILE"; then
    log_info "Updating existing collections addresses in $ENV_FILE..."
    sed -i.bak '/^# User Collections/,/^$/d' "$ENV_FILE"
    sed -i.bak '/^COLLECTION_FACTORY_PROXY=/d' "$ENV_FILE"
    sed -i.bak '/^COLLECTION_FACTORY_IMPL=/d' "$ENV_FILE"
    sed -i.bak '/^USER_COLLECTION_721_IMPL=/d' "$ENV_FILE"
    sed -i.bak '/^USER_COLLECTION_1155_IMPL=/d' "$ENV_FILE"
    sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  fi

  cat >> "$ENV_FILE" << EOF

# User Collections (ZkSync Era - deployed $TIMESTAMP)
COLLECTION_FACTORY_PROXY=$COLLECTION_FACTORY_PROXY
COLLECTION_FACTORY_IMPL=$COLLECTION_FACTORY_IMPL
USER_COLLECTION_721_IMPL=$USER_COLLECTION_721_IMPL
USER_COLLECTION_1155_IMPL=$USER_COLLECTION_1155_IMPL
EOF

  log_success "Environment file updated"
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
  echo ""
  echo "=============================================="
  echo "  DEPLOYMENT SUMMARY"
  echo "=============================================="
  echo ""
  echo "Network: $NETWORK"
  echo "Explorer: $EXPLORER_URL"
  echo ""

  if [ "$BROADCAST" != "--broadcast" ]; then
    echo "Mode: DRY RUN (no contracts deployed)"
    echo ""
    echo "To deploy for real, run:"
    echo "  $0 $NETWORK --broadcast"
    return 0
  fi

  echo "Deployed Contracts:"
  echo "-------------------"
  echo ""
  echo "CollectionFactory:"
  echo "  Proxy:          $COLLECTION_FACTORY_PROXY"
  echo "  Implementation: $COLLECTION_FACTORY_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$COLLECTION_FACTORY_PROXY"
  echo ""
  echo "UserCollection721:"
  echo "  Implementation: $USER_COLLECTION_721_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$USER_COLLECTION_721_IMPL"
  echo ""
  echo "UserCollection1155:"
  echo "  Implementation: $USER_COLLECTION_1155_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$USER_COLLECTION_1155_IMPL"
  echo ""
  echo "Configuration:"
  echo "  Admin:    $N_FACTORY_ADMIN"
  echo "  Operator: $N_FACTORY_OPERATOR"
  echo ""
  echo "=============================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo ""
  echo "=============================================="
  echo "  ZkSync User Collections Deployment"
  echo "=============================================="
  echo ""

  cd "$PROJECT_ROOT"

  preflight_checks
  move_l1_contracts
  compile_contracts
  verify_build_artifacts
  verify_implementation_permanence
  deploy_contracts
  verify_deployment
  smoke_test_createCollection
  verify_source_code
  update_env_file
  print_summary
}

main "$@"
