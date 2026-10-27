#!/bin/bash
# =============================================================================
# deploy_fundraising_zksync.sh
#
# Deployment script for the fundraising system (FundraiserFactory) on ZkSync Era.
#
# OVERVIEW:
# ---------
# Deploys a single immutable FundraiserFactory. There is no implementation
# contract and no proxy: the factory creates each Fundraiser with `new`, and
# zksolc registers that bytecode as a factory dependency at compile time.
#
# Mirrors ops/deploy_collection_factory_zksync.sh:
#   - Temp-move L1-incompatible files (SSTORE2/EXTCODECOPY) so zksolc compiles
#   - Forge build with --zksync, skip tests
#   - Run the Forge script via --broadcast (or dry-run without)
#   - Source verification via ops/verify_zksync_contracts.py (the ZkSync
#     verifier rejects absolute source paths, which forge sends)
#   - Append the deployed address to .env-test or .env-prod
#
# WHY factoryDependencies IS GATED BELOW:
# ---------------------------------------
# On EraVM, `create` is lowered to a ContractDeployer call keyed on a bytecode
# hash the operator must already know. If FundraiserFactory's factoryDependencies
# are empty, createFundraiser reverts at runtime on-chain while passing every
# EVM-profile test. This is the same failure mode that sank the original
# Clones.clone() design in collections.
#
# USAGE:
# ------
#   ./ops/deploy_fundraising_zksync.sh testnet              # dry run
#   ./ops/deploy_fundraising_zksync.sh testnet --broadcast
#   ./ops/deploy_fundraising_zksync.sh mainnet --broadcast
#
# REQUIRED ENVIRONMENT VARIABLES (loaded from .env-test / .env-prod):
# -------------------------------------------------------------------
#   - DEPLOYER_PRIVATE_KEY:  Private key with ETH for gas
#   - N_FUNDRAISING_ADMIN:   Address holding DEFAULT_ADMIN_ROLE. Should be the
#                            multisig that administers the other production
#                            contracts, not an EOA.
#   - N_FUNDRAISING_TOKENS:  Comma-separated ERC-20 addresses allowed at launch
#
# OPTIONAL ENVIRONMENT VARIABLES:
# -------------------------------
#   - N_FUNDRAISING_FEE_BPS:        Fee rate, default 0. Capped by MAX_FEE_BPS.
#   - N_FUNDRAISING_FEE_RECIPIENT:  Required only when the rate is non-zero.
#   - L2_RPC:                       Override the default RPC for the network
#   - COMPILER_VERSION / ZKSOLC_VERSION: passed to source verification
#   - CONFIRM_MAINNET=YES:          Skip the interactive mainnet prompt
#   - RUN_MAINNET_SMOKE_TEST=true:  Allow the smoke test to create a permanent
#                                   fundraise on mainnet; default skips it
#
# NOTE: For mainnet, prefer a keystore/--account over a raw private key in the
# env file — raw keys passed to `cast --private-key` are visible in `ps`.
#
# =============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NETWORK="${1:-testnet}"
BROADCAST="${2:-}"

case "$NETWORK" in
  testnet)
    ENV_FILE=".env-test"
    EXPLORER_URL="https://sepolia.explorer.zksync.io"
    VERIFIER_URL="https://explorer.sepolia.era.zksync.dev/contract_verification"
    CHAIN_ID="300"
    DEFAULT_RPC="https://sepolia.era.zksync.dev"
    ;;
  mainnet)
    ENV_FILE=".env-prod"
    EXPLORER_URL="https://explorer.zksync.io"
    VERIFIER_URL="https://zksync2-mainnet-explorer.zksync.io/contract_verification"
    CHAIN_ID="324"
    DEFAULT_RPC="https://mainnet.era.zksync.io"
    ;;
  *)
    echo "Error: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
    exit 1
    ;;
esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# =============================================================================
# Pre-flight
# =============================================================================

preflight_checks() {
  log_info "Running pre-flight checks..."
  cd "$PROJECT_ROOT"

  command -v forge >/dev/null || { log_error "forge not found. Install foundry-zksync."; exit 1; }
  forge --version | grep -q "zksync" || { log_error "forge lacks ZkSync support. Run: foundryup-zksync"; exit 1; }
  command -v cast >/dev/null || { log_error "cast not found."; exit 1; }
  command -v jq >/dev/null || { log_error "jq not found."; exit 1; }

  [ -f "$ENV_FILE" ] || { log_error "Environment file '$ENV_FILE' not found."; exit 1; }

  set -a; source "$ENV_FILE"; set +a

  [ -n "$DEPLOYER_PRIVATE_KEY" ] || { log_error "DEPLOYER_PRIVATE_KEY not set in $ENV_FILE"; exit 1; }
  [ -n "$N_FUNDRAISING_ADMIN" ]  || { log_error "N_FUNDRAISING_ADMIN not set in $ENV_FILE"; exit 1; }
  [ -n "$N_FUNDRAISING_TOKENS" ] || { log_error "N_FUNDRAISING_TOKENS not set in $ENV_FILE (comma-separated ERC-20 addresses)"; exit 1; }

  # vm.envUint rejects a key without the 0x prefix.
  [[ "$DEPLOYER_PRIVATE_KEY" != 0x* ]] && export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY}"

  export N_FUNDRAISING_FEE_BPS="${N_FUNDRAISING_FEE_BPS:-0}"
  export N_FUNDRAISING_FEE_RECIPIENT="${N_FUNDRAISING_FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}"

  # The factory rejects this too; failing here saves a broadcast round-trip.
  if [ "$N_FUNDRAISING_FEE_BPS" != "0" ] && \
     [ "$(_lower "$N_FUNDRAISING_FEE_RECIPIENT")" = "0x0000000000000000000000000000000000000000" ]; then
    log_error "N_FUNDRAISING_FEE_BPS is non-zero but N_FUNDRAISING_FEE_RECIPIENT is unset."
    exit 1
  fi

  RPC_URL="${L2_RPC:-$DEFAULT_RPC}"

  # An admin that is an EOA is legal but almost never intended in production:
  # DEFAULT_ADMIN_ROLE controls the token allow-list and fee parameters.
  local admin_code
  admin_code=$(cast code "$N_FUNDRAISING_ADMIN" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
  if [ "$admin_code" = "0x" ]; then
    log_warning "N_FUNDRAISING_ADMIN ($N_FUNDRAISING_ADMIN) is an EOA, not a contract."
    log_warning "Production contracts here are administered by a multisig. Confirm this is intended."
  else
    log_success "Admin is a contract (multisig): $N_FUNDRAISING_ADMIN"
  fi

  # Every allow-listed token must actually be an ERC-20 on this network. A wrong
  # or non-existent token address here is unrecoverable: it is baked into the
  # constructor and fundraises would collect a token nobody holds.
  IFS=',' read -ra _TOKENS <<< "$N_FUNDRAISING_TOKENS"
  for t in "${_TOKENS[@]}"; do
    t="$(echo "$t" | xargs)"
    local code sym dec
    code=$(cast code "$t" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    if [ "$code" = "0x" ]; then
      log_error "Token $t has no contract code on $NETWORK."
      exit 1
    fi
    sym=$(cast call "$t" 'symbol()(string)' --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
    dec=$(cast call "$t" 'decimals()(uint8)' --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
    log_success "Token $t -> symbol=$sym decimals=$dec"
  done

  if [ "$NETWORK" = "mainnet" ] && [ "$BROADCAST" = "--broadcast" ]; then
    if [ "${CONFIRM_MAINNET:-}" = "YES" ]; then
      log_warning "CONFIRM_MAINNET=YES set — proceeding without prompt."
    else
      log_warning "About to deploy to ZkSync MAINNET. The factory is IMMUTABLE:"
      log_warning "  MAX_FEE_BPS and MAX_DURATION can never be changed after this."
      log_warning "  Admin:  $N_FUNDRAISING_ADMIN"
      log_warning "  Tokens: $N_FUNDRAISING_TOKENS"
      log_warning "  Fee:    ${N_FUNDRAISING_FEE_BPS} bps -> $N_FUNDRAISING_FEE_RECIPIENT"
      read -r -p "Type 'YES' to confirm mainnet deployment: " confirm
      [ "$confirm" = "YES" ] || { log_error "Aborted by user."; exit 1; }
    fi
  fi

  log_success "Pre-flight checks passed"
}

# =============================================================================
# Temporarily move L1-incompatible contracts so zksolc can compile the tree.
# =============================================================================

L1_BACKUP_DIR="/tmp/rollup-l1-backup-fundraising-deploy"

move_l1_contracts() {
  log_info "Moving L1-incompatible contracts to temporary location..."
  if [ -d "$L1_BACKUP_DIR" ]; then
    log_warning "Found previous backup, restoring first..."
    restore_l1_contracts 2>/dev/null || true
  fi
  mkdir -p "$L1_BACKUP_DIR"

  [ -f "src/swarms/SwarmRegistryL1Upgradeable.sol" ] && mv "src/swarms/SwarmRegistryL1Upgradeable.sol" "$L1_BACKUP_DIR/"
  [ -f "test/SwarmRegistryL1.t.sol" ] && mv "test/SwarmRegistryL1.t.sol" "$L1_BACKUP_DIR/"
  [ -d "test/upgrade-demo" ] && mv "test/upgrade-demo" "$L1_BACKUP_DIR/"
  [ -f "script/DeploySwarmUpgradeable.s.sol" ] && mv "script/DeploySwarmUpgradeable.s.sol" "$L1_BACKUP_DIR/"
  [ -f "script/UpgradeSwarm.s.sol" ] && mv "script/UpgradeSwarm.s.sol" "$L1_BACKUP_DIR/"

  log_success "L1 contracts moved to $L1_BACKUP_DIR"
}

restore_l1_contracts() {
  [ -d "$L1_BACKUP_DIR" ] || return 0
  log_info "Restoring L1 contracts from backup..."
  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" ] && mv "$L1_BACKUP_DIR/SwarmRegistryL1Upgradeable.sol" "src/swarms/"
  [ -f "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" ] && mv "$L1_BACKUP_DIR/SwarmRegistryL1.t.sol" "test/"
  [ -d "$L1_BACKUP_DIR/upgrade-demo" ] && mv "$L1_BACKUP_DIR/upgrade-demo" "test/"
  [ -f "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" ] && mv "$L1_BACKUP_DIR/DeploySwarmUpgradeable.s.sol" "script/"
  [ -f "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" ] && mv "$L1_BACKUP_DIR/UpgradeSwarm.s.sol" "script/"
  rm -rf "$L1_BACKUP_DIR"
  log_success "L1 contracts restored"
}

trap restore_l1_contracts EXIT

# =============================================================================
# Compile + artifact gates
# =============================================================================

compile_contracts() {
  log_info "Compiling contracts with Forge for ZkSync..."
  forge build --zksync --skip test
  log_success "Compilation complete"
}

verify_build_artifacts() {
  log_info "Verifying FundraiserFactory factoryDependencies are populated..."

  local artifact="zkout/FundraiserFactory.sol/FundraiserFactory.json"
  [ -f "$artifact" ] || { log_error "Compiled artifact not found: $artifact"; exit 1; }

  local dep_count
  dep_count=$(jq -r '.factoryDependencies | length' "$artifact" 2>/dev/null || echo "")
  if [ -z "$dep_count" ] || [ "$dep_count" -eq 0 ]; then
    log_error "FundraiserFactory.factoryDependencies is empty."
    log_error "createFundraiser would revert on EraVM while passing every EVM-profile test."
    exit 1
  fi
  log_success "factoryDependencies populated ($dep_count entries)"

  # The Fundraiser must be constructor-configured and immutable. An initializer
  # or upgrade selector appearing here means someone reintroduced a proxy shape.
  log_info "Verifying Fundraiser exposes no initializer or upgrade selectors..."
  local fartifact="zkout/Fundraiser.sol/Fundraiser.json"
  [ -f "$fartifact" ] || { log_error "Compiled artifact not found: $fartifact"; exit 1; }

  local hits
  hits=$(jq -r '[.abi[] | select(.type=="function") | .name]
                | map(select(. == "initialize" or . == "upgradeTo" or . == "upgradeToAndCall" or . == "proxiableUUID"))
                | length' "$fartifact")
  if [ "$hits" -ne 0 ]; then
    log_error "Fundraiser exposes an initializer or upgrade selector."
    log_error "Each fundraise is a full contract configured by its constructor — see the design spec, section 6."
    exit 1
  fi
  log_success "Fundraiser is constructor-configured with no upgrade surface"
}

# =============================================================================
# Deploy
# =============================================================================

deploy_contracts() {
  log_info "Deploying FundraiserFactory to ZkSync ($NETWORK)..."

  FORGE_ARGS=(
    "script" "script/DeployFundraiserFactory.s.sol:DeployFundraiserFactory"
    "--rpc-url" "$RPC_URL" "--chain-id" "$CHAIN_ID" "--zksync"
  )

  if [ "$BROADCAST" = "--broadcast" ]; then
    FORGE_ARGS+=("--broadcast" "--slow")
  else
    log_warning "DRY RUN MODE - Add '--broadcast' to actually deploy"
    log_info "Would deploy with:"
    log_info "  Admin:  $N_FUNDRAISING_ADMIN"
    log_info "  Tokens: $N_FUNDRAISING_TOKENS"
    log_info "  Fee:    ${N_FUNDRAISING_FEE_BPS} bps -> $N_FUNDRAISING_FEE_RECIPIENT"
    log_info "  RPC:    $RPC_URL"
    forge "${FORGE_ARGS[@]}"
    return 0
  fi

  DEPLOY_LOG="/tmp/fundraising-deploy-$$.txt"
  forge "${FORGE_ARGS[@]}" 2>&1 | tee "$DEPLOY_LOG"

  FUNDRAISER_FACTORY=$(grep -oE 'FundraiserFactory: +0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}')
  if [ -z "$FUNDRAISER_FACTORY" ]; then
    log_error "Could not extract the factory address from deploy output"
    cat "$DEPLOY_LOG"
    exit 1
  fi

  rm -f "$DEPLOY_LOG"
  log_success "Deployment complete: $FUNDRAISER_FACTORY"
}

# =============================================================================
# Post-deploy sanity checks
# =============================================================================

verify_deployment() {
  [ "$BROADCAST" = "--broadcast" ] || return 0
  log_info "Verifying deployment..."

  local ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

  local has_admin
  has_admin=$(cast call "$FUNDRAISER_FACTORY" "hasRole(bytes32,address)(bool)" \
    "$ADMIN_ROLE" "$N_FUNDRAISING_ADMIN" --rpc-url "$RPC_URL")
  [ "$has_admin" = "true" ] || { log_error "DEFAULT_ADMIN_ROLE not granted to $N_FUNDRAISING_ADMIN"; exit 1; }
  log_success "Admin role granted to $N_FUNDRAISING_ADMIN"

  # The deployer must NOT retain admin — the script grants it to N_FUNDRAISING_ADMIN only.
  local deployer_addr deployer_is_admin
  deployer_addr=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
  deployer_is_admin=$(cast call "$FUNDRAISER_FACTORY" "hasRole(bytes32,address)(bool)" \
    "$ADMIN_ROLE" "$deployer_addr" --rpc-url "$RPC_URL")
  if [ "$deployer_is_admin" = "true" ] && \
     [ "$(_lower "$deployer_addr")" != "$(_lower "$N_FUNDRAISING_ADMIN")" ]; then
    log_error "Deployer $deployer_addr unexpectedly holds DEFAULT_ADMIN_ROLE."
    exit 1
  fi
  log_success "Deployer holds no admin role beyond the configured admin"

  IFS=',' read -ra _TOKENS <<< "$N_FUNDRAISING_TOKENS"
  for t in "${_TOKENS[@]}"; do
    t="$(echo "$t" | xargs)"
    local allowed
    allowed=$(cast call "$FUNDRAISER_FACTORY" "isTokenAllowed(address)(bool)" "$t" --rpc-url "$RPC_URL")
    [ "$allowed" = "true" ] || { log_error "Token $t is not allow-listed on the deployed factory"; exit 1; }
    log_success "Token allow-listed: $t"
  done

  local fee_bps fee_recipient max_fee max_duration
  fee_bps=$(cast call "$FUNDRAISER_FACTORY" "feeBps()(uint16)" --rpc-url "$RPC_URL")
  fee_recipient=$(cast call "$FUNDRAISER_FACTORY" "feeRecipient()(address)" --rpc-url "$RPC_URL")
  max_fee=$(cast call "$FUNDRAISER_FACTORY" "MAX_FEE_BPS()(uint16)" --rpc-url "$RPC_URL")
  max_duration=$(cast call "$FUNDRAISER_FACTORY" "MAX_DURATION()(uint40)" --rpc-url "$RPC_URL")

  [ "$fee_bps" = "$N_FUNDRAISING_FEE_BPS" ] || { log_error "feeBps mismatch: on-chain $fee_bps != configured $N_FUNDRAISING_FEE_BPS"; exit 1; }
  log_success "feeBps=$fee_bps recipient=$fee_recipient"
  log_success "Immutable bounds: MAX_FEE_BPS=$max_fee MAX_DURATION=$max_duration"

  log_success "Post-deploy sanity checks passed"
}

# =============================================================================
# Smoke test — the empirical check that EraVM deployment works at runtime.
# =============================================================================

smoke_test_createFundraiser() {
  [ "$BROADCAST" = "--broadcast" ] || return 0

  # Creates a real, PERMANENT contract. On mainnet that pollutes the registry,
  # so skip unless explicitly opted in.
  if [ "$NETWORK" = "mainnet" ] && [ "${RUN_MAINNET_SMOKE_TEST:-}" != "true" ]; then
    log_warning "Skipping createFundraiser smoke test on mainnet (would create a permanent contract)."
    log_warning "Set RUN_MAINNET_SMOKE_TEST=true to run it intentionally."
    return 0
  fi

  log_info "Running end-to-end smoke test: createFundraiser..."

  IFS=',' read -ra _TOKENS <<< "$N_FUNDRAISING_TOKENS"
  local token deployer_addr deadline ext
  token="$(echo "${_TOKENS[0]}" | xargs)"
  deployer_addr=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
  deadline=$(( $(cast block latest -f timestamp --rpc-url "$RPC_URL") + 3600 ))
  ext=$(cast keccak "smoke-$(date +%s)")

  cast send "$FUNDRAISER_FACTORY" \
    "createFundraiser((string,address,uint128,uint40,uint8,address,address,uint128,uint128),bytes32)" \
    "(Smoke,$token,1000,$deadline,0,$deployer_addr,$deployer_addr,0,0)" "$ext" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --zksync \
    || { log_error "createFundraiser reverted on-chain"; exit 1; }

  log_success "Smoke test passed: createFundraiser succeeded on EraVM"
}

# =============================================================================
# Source verification
# =============================================================================

verify_source_code() {
  [ "$BROADCAST" = "--broadcast" ] || return 0
  log_info "Verifying source code on block explorer..."

  local broadcast_json="broadcast/DeployFundraiserFactory.s.sol/${CHAIN_ID}/run-latest.json"
  if [ ! -f "$broadcast_json" ]; then
    log_warning "Broadcast file not found: $broadcast_json — skipping source verification"
    return 0
  fi
  if ! command -v python3 >/dev/null; then
    log_warning "python3 not found — skipping source verification"
    return 0
  fi

  # Non-fatal: the contracts are already deployed, this just needs a manual retry.
  local exit_code=0
  python3 "$SCRIPT_DIR/verify_zksync_contracts.py" \
    --broadcast "$broadcast_json" \
    --verifier-url "$VERIFIER_URL" \
    --compiler-version "${COMPILER_VERSION:-0.8.26}" \
    --zksolc-version "${ZKSOLC_VERSION:-v1.5.15}" \
    --project-root "$PROJECT_ROOT" || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    log_success "Source code verified on block explorer"
  else
    log_warning "Source verification failed (deployment itself succeeded)"
    log_info "Retry: python3 ops/verify_zksync_contracts.py --broadcast $broadcast_json --verifier-url $VERIFIER_URL"
  fi
}

# =============================================================================
# Record the address
# =============================================================================

update_env_file() {
  [ "$BROADCAST" = "--broadcast" ] || return 0
  log_info "Updating $ENV_FILE with the deployed address..."

  if grep -q "^FUNDRAISER_FACTORY=" "$ENV_FILE"; then
    sed -i.bak '/^# Fundraising/d' "$ENV_FILE"
    sed -i.bak '/^FUNDRAISER_FACTORY=/d' "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  fi

  cat >> "$ENV_FILE" << EOF

# Fundraising (ZkSync Era - deployed $(date +%Y-%m-%d))
FUNDRAISER_FACTORY=$FUNDRAISER_FACTORY
EOF

  log_success "Environment file updated"
}

print_summary() {
  echo ""
  echo "=============================================="
  echo "  DEPLOYMENT SUMMARY"
  echo "=============================================="
  echo ""
  echo "Network:  $NETWORK"
  echo "Explorer: $EXPLORER_URL"
  echo ""

  if [ "$BROADCAST" != "--broadcast" ]; then
    echo "Mode: DRY RUN (no contracts deployed)"
    echo ""
    echo "To deploy for real:"
    echo "  $0 $NETWORK --broadcast"
    return 0
  fi

  echo "FundraiserFactory: $FUNDRAISER_FACTORY"
  echo "  Explorer:        $EXPLORER_URL/address/$FUNDRAISER_FACTORY"
  echo ""
  echo "Configuration:"
  echo "  Admin:  $N_FUNDRAISING_ADMIN"
  echo "  Tokens: $N_FUNDRAISING_TOKENS"
  echo "  Fee:    ${N_FUNDRAISING_FEE_BPS} bps -> $N_FUNDRAISING_FEE_RECIPIENT"
  echo ""
  echo "Each fundraise is created by the factory as its own contract."
  echo "Only the factory needs verifying."
  echo ""
  echo "=============================================="
}

main() {
  echo ""
  echo "=============================================="
  echo "  ZkSync Fundraising Deployment"
  echo "=============================================="
  echo ""

  cd "$PROJECT_ROOT"

  preflight_checks
  move_l1_contracts
  compile_contracts
  verify_build_artifacts
  deploy_contracts
  verify_deployment
  smoke_test_createFundraiser
  verify_source_code
  update_env_file
  print_summary
}

main "$@"
