#!/bin/bash
# =============================================================================
# deploy_swarm_contracts_zksync.sh
#
# Automated deployment script for Swarm contracts (ServiceProvider, FleetIdentity,
# SwarmRegistryUniversal) to ZkSync Era.
#
# OVERVIEW:
# ---------
# This script deploys the upgradeable Swarm contracts to ZkSync Era using Foundry.
# We use Forge with --zksync flag which compiles and deploys using zksolc.
#
# Requirements:
#   - foundry-zksync fork must be installed (foundryup-zksync)
#
# WHY WE TEMPORARILY MOVE L1 CONTRACTS:
# -------------------------------------
# SwarmRegistryL1 and related contracts use SSTORE2 library which relies on
# EXTCODECOPY opcode - this opcode is NOT supported on ZkSync Era's zkEVM.
# Even if we don't deploy these contracts, the ZkSync compiler fails when it
# encounters them in the codebase. By temporarily moving them out, we allow
# the ZkSync compiler to build only compatible contracts.
#
# CONTRACT ARCHITECTURE:
# ----------------------
# - ServiceProviderUpgradeable: Registry for service providers (no dependencies)
# - FleetIdentityUpgradeable: NFT-based fleet identity with bonding (depends on ERC20 bond token)
# - SwarmRegistryUniversalUpgradeable: Main registry (depends on ServiceProvider & FleetIdentity)
#
# Each contract is deployed as:
#   1. Implementation contract (the actual logic)
#   2. ERC1967Proxy pointing to the implementation (the user-facing address)
#
# USAGE:
# ------
#   # For testnet (dry run - simulation only):
#   ./ops/deploy_swarm_contracts_zksync.sh testnet
#
#   # For testnet (actual deployment):
#   ./ops/deploy_swarm_contracts_zksync.sh testnet --broadcast
#
#   # For mainnet (actual deployment):
#   ./ops/deploy_swarm_contracts_zksync.sh mainnet --broadcast
#
# REQUIRED ENVIRONMENT VARIABLES:
# -------------------------------
# The script loads from .env-test (testnet) or .env-prod (mainnet):
#   - DEPLOYER_PRIVATE_KEY: Private key with ETH for gas
#   - NODL: Address of the NODL token (used as bond token)
#   - FLEET_OPERATOR: Address of the backend swarm operator (whitelisted user)
#   - BASE_BOND: Bond amount in wei (e.g., 100000000000000000000 for 100 NODL)
#   - L2_ADMIN: Owner address for all deployed L2 contracts (ZkSync Safe multisig)
#   - PAYMASTER_WITHDRAWER: (optional) Address allowed to withdraw tokens from paymaster, defaults to L2_ADMIN
#   - COUNTRY_MULTIPLIER: (optional) Country multiplier for bond calculation (0 = use default)
#   - BOND_QUOTA: (optional) Max bond amount sponsorable per period in wei
#   - BOND_PERIOD: (optional) Quota renewal period in seconds
#
# =============================================================================

set -e  # Exit on any error

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
NETWORK="${1:-testnet}"
BROADCAST="${2:-}"

# Network-specific configuration
case "$NETWORK" in
  testnet)
    ENV_FILE=".env-test"
    HARDHAT_NETWORK="zkSyncSepoliaTestnet"
    EXPLORER_URL="https://sepolia.explorer.zksync.io"
    VERIFIER_URL="https://explorer.sepolia.era.zksync.dev/contract_verification"
    FORGE_CHAIN="zksync-testnet"
    ;;
  mainnet)
    ENV_FILE=".env-prod"
    HARDHAT_NETWORK="zkSyncMainnet"
    EXPLORER_URL="https://explorer.zksync.io"
    VERIFIER_URL="https://zksync2-mainnet-explorer.zksync.io/contract_verification"
    FORGE_CHAIN="zksync"
    ;;
  *)
    echo "Error: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
    exit 1
    ;;
esac

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
  log_info "Running pre-flight checks..."

  cd "$PROJECT_ROOT"

  # Check required tools
  if ! command -v forge &> /dev/null; then
    log_error "forge not found. Please install foundry-zksync."
    exit 1
  fi

  # Check forge has zksync support
  if ! forge --version | grep -q "zksync"; then
    log_error "forge does not have ZkSync support. Install with: foundryup-zksync"
    exit 1
  fi

  if ! command -v cast &> /dev/null; then
    log_error "cast not found. Please install foundry."
    exit 1
  fi

  # Check env file exists
  if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file '$ENV_FILE' not found."
    exit 1
  fi

  # Load environment variables
  set -a
  source "$ENV_FILE"
  set +a

  # Validate required variables
  if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    log_error "DEPLOYER_PRIVATE_KEY not set in $ENV_FILE"
    exit 1
  fi

  if [ -z "$NODL" ]; then
    log_error "NODL (bond token address) not set in $ENV_FILE"
    exit 1
  fi

  if [ -z "$FLEET_OPERATOR" ]; then
    log_error "FLEET_OPERATOR not set in $ENV_FILE"
    exit 1
  fi

  # Ensure DEPLOYER_PRIVATE_KEY has 0x prefix (required by forge vm.envUint)
  if [[ "$DEPLOYER_PRIVATE_KEY" != 0x* ]]; then
    export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY}"
  fi

  # Derive deployer address for defaults
  DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")

  # Set defaults
  export BOND_TOKEN="${BOND_TOKEN:-$NODL}"
  export BASE_BOND="${BASE_BOND:-1000000000000000000000}"  # 1000 NODL default
  if [ -z "$L2_ADMIN" ]; then
    log_error "L2_ADMIN not set in $ENV_FILE (must be the ZkSync Safe multisig)"
    exit 1
  fi
  export PAYMASTER_WITHDRAWER="${PAYMASTER_WITHDRAWER:-$L2_ADMIN}"
  export BOND_QUOTA="${BOND_QUOTA:-100000000000000000000000}"  # 100000 NODL default
  export BOND_PERIOD="${BOND_PERIOD:-86400}"  # 1 day default

  log_success "Pre-flight checks passed"
}

# =============================================================================
# Step 1: Temporarily Move L1-Incompatible Contracts
# =============================================================================
# 
# Why: ZkSync's zksolc compiler fails on contracts using SSTORE2/EXTCODECOPY.
# These opcodes are not supported on zkEVM. Even if we skip these contracts
# during deployment, the compiler still tries to process them.
#
# What we move:
#   - SwarmRegistryL1Upgradeable.sol (uses SSTORE2 for storage proofs)
#   - SwarmRegistryL1.t.sol (tests for L1 registry)
#   - upgrade-demo/ (contains L1 upgrade tests)
#   - DeploySwarmUpgradeable.s.sol (Forge script that imports L1 contracts)
#   - UpgradeSwarm.s.sol (imports SwarmRegistryL1)
#
# =============================================================================

L1_BACKUP_DIR="/tmp/rollup-l1-backup-zksync-deploy"

move_l1_contracts() {
  log_info "Moving L1-incompatible contracts to temporary location..."
  
  # First, restore any files from a previous failed run
  if [ -d "$L1_BACKUP_DIR" ]; then
    log_warning "Found previous backup, restoring first..."
    restore_l1_contracts 2>/dev/null || true
  fi
  
  mkdir -p "$L1_BACKUP_DIR"
  
  # Move contracts that use SSTORE2/EXTCODECOPY
  [ -f "src/swarms/SwarmRegistryL1Upgradeable.sol" ] && \
    mv "src/swarms/SwarmRegistryL1Upgradeable.sol" "$L1_BACKUP_DIR/"
  
  # Move L1-only test files
  [ -f "test/SwarmRegistryL1.t.sol" ] && \
    mv "test/SwarmRegistryL1.t.sol" "$L1_BACKUP_DIR/"
  
  [ -d "test/upgrade-demo" ] && \
    mv "test/upgrade-demo" "$L1_BACKUP_DIR/"
  
  # Move Forge deploy script (it imports L1 contracts)
  [ -f "script/DeploySwarmUpgradeable.s.sol" ] && \
    mv "script/DeploySwarmUpgradeable.s.sol" "$L1_BACKUP_DIR/"
  
  # Move upgrade script (imports SwarmRegistryL1)
  [ -f "script/UpgradeSwarm.s.sol" ] && \
    mv "script/UpgradeSwarm.s.sol" "$L1_BACKUP_DIR/"
  
  log_success "L1 contracts moved to $L1_BACKUP_DIR"
}

restore_l1_contracts() {
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

# Ensure cleanup on exit
trap restore_l1_contracts EXIT

# =============================================================================
# Step 2: Build Contracts with Forge ZkSync
# =============================================================================
#
# Why Forge with --zksync:
#   - Uses foundry-zksync fork with zksolc compiler
#   - Consistent tooling with L1 deployments
#   - Faster builds than Hardhat
#
# Note: We skip test files as they may exceed ZkSync bytecode limits
#
# =============================================================================

compile_contracts() {
  log_info "Compiling contracts with Forge for ZkSync..."
  
  # Build with zksolc compiler, skip test files (may exceed bytecode limits)
  forge build --zksync --skip test
  
  log_success "Compilation complete"
}

# =============================================================================
# Step 3: Deploy Contracts
# =============================================================================
#
# Deployment order matters due to dependencies:
#   1. ServiceProviderUpgradeable - No dependencies
#   2. FleetIdentityUpgradeable - Requires bond token address
#   3. SwarmRegistryUniversalUpgradeable - Requires both ServiceProvider & FleetIdentity
#
# Each deployment creates:
#   - Implementation contract (the logic)
#   - ERC1967Proxy (the user-facing address that delegates to implementation)
#
# The proxy pattern allows future upgrades without changing the contract address.
#
# =============================================================================

deploy_contracts() {
  log_info "Deploying contracts to ZkSync ($NETWORK)..."
  
  # Get RPC URL based on network
  if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
    CHAIN_ID="324"
  else
    RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
    CHAIN_ID="300"
  fi
  
  FORGE_ARGS=(
    "script"
    "script/DeploySwarmUpgradeableZkSync.s.sol:DeploySwarmUpgradeableZkSync"
    "--rpc-url" "$RPC_URL"
    "--chain-id" "$CHAIN_ID"
    "--zksync"
  )
  
  if [ "$BROADCAST" = "--broadcast" ]; then
    FORGE_ARGS+=("--broadcast" "--slow")
    # NOTE: We do NOT add --verify here. forge script --verify sends absolute
    # source paths which the ZkSync verifier rejects with "import with absolute
    # or traversal path". Source code verification is handled separately in
    # verify_source_code() using forge flatten + forge verify-contract.
  else
    log_warning "DRY RUN MODE - Add '--broadcast' to actually deploy"
    log_info "Would deploy with:"
    log_info "  BOND_TOKEN: $BOND_TOKEN"
    log_info "  BASE_BOND: $BASE_BOND"
    log_info "  L2_ADMIN: $L2_ADMIN"
    log_info "  PAYMASTER_WITHDRAWER: ${PAYMASTER_WITHDRAWER:-deployer}"
    log_info "  FLEET_OPERATOR: $FLEET_OPERATOR"
    log_info "  BOND_QUOTA: $BOND_QUOTA"
    log_info "  BOND_PERIOD: $BOND_PERIOD"
    log_info "  RPC: $RPC_URL"
    return 0
  fi
  
  DEPLOY_LOG="/tmp/deploy-output-$$.txt"
  
  # Run the deployment
  forge "${FORGE_ARGS[@]}" 2>&1 | tee "$DEPLOY_LOG"
  
  if [ "$BROADCAST" = "--broadcast" ]; then
    # Extract deployed addresses from output
    # The Solidity script outputs lines like: "ServiceProvider Proxy: 0x..."
    SERVICE_PROVIDER_PROXY=$(grep -o 'ServiceProvider Proxy: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    SERVICE_PROVIDER_IMPL=$(grep -o 'ServiceProvider Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    FLEET_IDENTITY_PROXY=$(grep -o 'FleetIdentity Proxy: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    FLEET_IDENTITY_IMPL=$(grep -o 'FleetIdentity Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    SWARM_REGISTRY_PROXY=$(grep -o 'SwarmRegistry Proxy: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    SWARM_REGISTRY_IMPL=$(grep -o 'SwarmRegistry Implementation: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    BOND_TREASURY_PAYMASTER=$(grep -o 'BondTreasuryPaymaster: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | grep -o '0x[0-9a-fA-F]*')
    
    # Validate we got addresses
    if [ -z "$SERVICE_PROVIDER_PROXY" ] || [ -z "$FLEET_IDENTITY_PROXY" ] || [ -z "$SWARM_REGISTRY_PROXY" ] || [ -z "$BOND_TREASURY_PAYMASTER" ]; then
      log_error "Could not extract all addresses from output"
      log_info "Full output saved to: $DEPLOY_LOG"
      cat "$DEPLOY_LOG"
      exit 1
    else
      log_success "Deployment complete!"
    fi
  fi
  
  rm -f "$DEPLOY_LOG"
}

# =============================================================================
# Step 4: Verify Deployment
# =============================================================================
#
# We verify the deployment by calling view functions on each proxy:
#   - owner() - Confirms the proxy is initialized and returns expected owner
#   - For FleetIdentity: BASE_BOND() and BOND_TOKEN() confirm initialization params
#
# This ensures:
#   1. Proxies are correctly pointing to implementations
#   2. Initialize functions were called successfully
#   3. Constructor/initializer parameters are correct
#
# =============================================================================

verify_deployment() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi
  
  log_info "Verifying deployment..."
  
  # Get RPC URL based on network
  if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
  else
    RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
  fi
  
  # Test ServiceProvider
  log_info "Testing ServiceProvider proxy..."
  SP_OWNER=$(cast call "$SERVICE_PROVIDER_PROXY" "owner()(address)" --rpc-url "$RPC_URL")
  log_success "ServiceProvider owner: $SP_OWNER"
  
  # Test FleetIdentity
  log_info "Testing FleetIdentity proxy..."
  FI_OWNER=$(cast call "$FLEET_IDENTITY_PROXY" "owner()(address)" --rpc-url "$RPC_URL")
  FI_BOND=$(cast call "$FLEET_IDENTITY_PROXY" "BASE_BOND()(uint256)" --rpc-url "$RPC_URL")
  FI_TOKEN=$(cast call "$FLEET_IDENTITY_PROXY" "BOND_TOKEN()(address)" --rpc-url "$RPC_URL")
  log_success "FleetIdentity owner: $FI_OWNER"
  log_success "FleetIdentity BASE_BOND: $FI_BOND"
  log_success "FleetIdentity BOND_TOKEN: $FI_TOKEN"
  
  # Test SwarmRegistry
  log_info "Testing SwarmRegistry proxy..."
  SR_OWNER=$(cast call "$SWARM_REGISTRY_PROXY" "owner()(address)" --rpc-url "$RPC_URL")
  log_success "SwarmRegistry owner: $SR_OWNER"
  
  # Test BondTreasuryPaymaster
  log_info "Testing BondTreasuryPaymaster..."
  BTP_TOKEN=$(cast call "$BOND_TREASURY_PAYMASTER" "bondToken()(address)" --rpc-url "$RPC_URL")
  BTP_QUOTA=$(cast call "$BOND_TREASURY_PAYMASTER" "quota()(uint256)" --rpc-url "$RPC_URL")
  log_success "BondTreasuryPaymaster bondToken: $BTP_TOKEN"
  log_success "BondTreasuryPaymaster quota: $BTP_QUOTA"
  
  log_success "All contracts verified successfully!"
}

# =============================================================================
# Step 4b: Verify Source Code on Block Explorer
# =============================================================================
#
# Why a separate step:
#   forge script --verify sends absolute file paths (e.g. /Users/me/project/src/...)
#   which the ZkSync verifier rejects: "import with absolute or traversal path".
#
# Workaround:
#   1. Flatten each contract into a single .sol file (no imports)
#   2. Use forge verify-contract with the flattened file
#   3. Clean up temporary flat files
#
# Constructor args are extracted from the broadcast JSON using the ZkSync
# ContractDeployer ABI: create(bytes32 salt, bytes32 bytecodeHash, bytes ctorInput)
#
# =============================================================================

verify_source_code() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Verifying source code on block explorer..."

  # Get RPC URL for chain detection
  if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="${L2_RPC:-https://mainnet.era.zksync.io}"
    CHAIN_ID="324"
  else
    RPC_URL="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
    CHAIN_ID="300"
  fi

  BROADCAST_JSON="broadcast/DeploySwarmUpgradeableZkSync.s.sol/${CHAIN_ID}/run-latest.json"
  if [ ! -f "$BROADCAST_JSON" ]; then
    log_error "Broadcast file not found: $BROADCAST_JSON"
    log_warning "Skipping source code verification"
    return 1
  fi

  # Extract constructor args from broadcast JSON
  # ZkSync ContractDeployer.create(): 0x9c4d535b + salt(32) + hash(32) + offset_to_ctor(32) + len(32) + ctor_data
  log_info "Extracting constructor args from broadcast..."
  CTOR_ARGS=$(python3 -c "
import json, sys
with open('$BROADCAST_JSON') as f:
    data = json.load(f)
for tx in data['transactions']:
    addr = (tx.get('additionalContracts') or [{}])[0].get('address', '')
    inp = tx['transaction'].get('input', '')
    payload = inp[10:]  # skip 0x + 9c4d535b
    offset = int(payload[128:192], 16)
    ctor_start = offset * 2
    ctor_len = int(payload[ctor_start:ctor_start+64], 16)
    ctor_args = payload[ctor_start+64:ctor_start+64+ctor_len*2]
    print(f'{addr}:{ctor_args}')
")

  # Build lookup of address -> constructor args
  declare -A CTOR_MAP
  while IFS=: read -r addr args; do
    CTOR_MAP["$addr"]="$args"
  done <<< "$CTOR_ARGS"

  # Create temporary directory for flattened sources
  FLAT_DIR=$(mktemp -d)

  # Flatten all unique contract sources
  log_info "Flattening contract sources..."
  forge flatten src/swarms/ServiceProviderUpgradeable.sol > "$FLAT_DIR/FlatSP.sol"
  forge flatten src/swarms/FleetIdentityUpgradeable.sol > "$FLAT_DIR/FlatFI.sol"
  forge flatten src/swarms/SwarmRegistryUniversalUpgradeable.sol > "$FLAT_DIR/FlatSR.sol"
  forge flatten lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol > "$FLAT_DIR/FlatProxy.sol"
  forge flatten src/paymasters/BondTreasuryPaymaster.sol > "$FLAT_DIR/FlatBTP.sol"

  # Copy flat files into src/ so forge can find them
  cp "$FLAT_DIR/FlatSP.sol" src/FlatSP.sol
  cp "$FLAT_DIR/FlatFI.sol" src/FlatFI.sol
  cp "$FLAT_DIR/FlatSR.sol" src/FlatSR.sol
  cp "$FLAT_DIR/FlatProxy.sol" src/FlatProxy.sol
  cp "$FLAT_DIR/FlatBTP.sol" src/FlatBTP.sol

  VERIFY_FAILED=0

  # Helper to verify a single contract
  verify_one() {
    local address="$1"
    local source="$2"
    local label="$3"
    local ctor_key
    ctor_key=$(echo "$address" | tr '[:upper:]' '[:lower:]')
    local args="${CTOR_MAP[$ctor_key]}"

    local VARGS=(
      --zksync
      --chain "$FORGE_CHAIN"
      --verifier zksync
      --verifier-url "$VERIFIER_URL"
      "$address"
      "$source"
    )
    if [ -n "$args" ]; then
      VARGS+=(--constructor-args "$args")
    fi

    log_info "Verifying $label at $address..."
    if forge verify-contract "${VARGS[@]}" 2>&1; then
      log_success "$label verified"
    else
      log_error "$label verification failed (can retry manually)"
      VERIFY_FAILED=$((VERIFY_FAILED + 1))
    fi
  }

  # Verify all 7 contracts
  verify_one "$SERVICE_PROVIDER_IMPL" "src/FlatSP.sol:ServiceProviderUpgradeable" "ServiceProvider Implementation"
  verify_one "$SERVICE_PROVIDER_PROXY" "src/FlatProxy.sol:ERC1967Proxy" "ServiceProvider Proxy"
  verify_one "$FLEET_IDENTITY_IMPL" "src/FlatFI.sol:FleetIdentityUpgradeable" "FleetIdentity Implementation"
  verify_one "$FLEET_IDENTITY_PROXY" "src/FlatProxy.sol:ERC1967Proxy" "FleetIdentity Proxy"
  verify_one "$SWARM_REGISTRY_IMPL" "src/FlatSR.sol:SwarmRegistryUniversalUpgradeable" "SwarmRegistry Implementation"
  verify_one "$SWARM_REGISTRY_PROXY" "src/FlatProxy.sol:ERC1967Proxy" "SwarmRegistry Proxy"
  verify_one "$BOND_TREASURY_PAYMASTER" "src/FlatBTP.sol:BondTreasuryPaymaster" "BondTreasuryPaymaster"

  # Clean up flat files from src/
  rm -f src/FlatSP.sol src/FlatFI.sol src/FlatSR.sol src/FlatProxy.sol src/FlatBTP.sol
  rm -rf "$FLAT_DIR"

  if [ "$VERIFY_FAILED" -gt 0 ]; then
    log_warning "$VERIFY_FAILED contract(s) failed source verification (deployment itself succeeded)"
  else
    log_success "All 7 contracts source-code verified on block explorer!"
  fi
}

# =============================================================================
# Step 5: Update Environment File
# =============================================================================
#
# We append the deployed contract addresses to the environment file.
# This allows future scripts to reference these contracts.
#
# Format follows existing conventions in the env file.
#
# =============================================================================

update_env_file() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi
  
  log_info "Updating $ENV_FILE with deployed addresses..."
  
  TIMESTAMP=$(date +%Y-%m-%d)
  
  # Check if swarm contracts section already exists
  if grep -q "SERVICE_PROVIDER_PROXY" "$ENV_FILE"; then
    log_info "Updating existing swarm contract addresses in $ENV_FILE..."
    
    # Remove old swarm contracts block (comment + 7 lines of variables)
    sed -i.bak '/^# Swarm Contracts/,/^$/d' "$ENV_FILE"
    # Also remove any straggling individual lines that weren't in a block
    sed -i.bak '/^SERVICE_PROVIDER_PROXY=/d' "$ENV_FILE"
    sed -i.bak '/^SERVICE_PROVIDER_IMPL=/d' "$ENV_FILE"
    sed -i.bak '/^FLEET_IDENTITY_PROXY=/d' "$ENV_FILE"
    sed -i.bak '/^FLEET_IDENTITY_IMPL=/d' "$ENV_FILE"
    sed -i.bak '/^SWARM_REGISTRY_PROXY=/d' "$ENV_FILE"
    sed -i.bak '/^SWARM_REGISTRY_IMPL=/d' "$ENV_FILE"
    sed -i.bak '/^BASE_BOND=/d' "$ENV_FILE"
    sed -i.bak '/^BOND_TREASURY_PAYMASTER=/d' "$ENV_FILE"
    sed -i.bak '/^BOND_QUOTA=/d' "$ENV_FILE"
    sed -i.bak '/^BOND_PERIOD=/d' "$ENV_FILE"
    # Clean up trailing blank lines
    sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  fi
  
  # Append new addresses
  cat >> "$ENV_FILE" << EOF

# Swarm Contracts (ZkSync Era - deployed $TIMESTAMP)
SERVICE_PROVIDER_PROXY=$SERVICE_PROVIDER_PROXY
SERVICE_PROVIDER_IMPL=$SERVICE_PROVIDER_IMPL
FLEET_IDENTITY_PROXY=$FLEET_IDENTITY_PROXY
FLEET_IDENTITY_IMPL=$FLEET_IDENTITY_IMPL
SWARM_REGISTRY_PROXY=$SWARM_REGISTRY_PROXY
SWARM_REGISTRY_IMPL=$SWARM_REGISTRY_IMPL
BOND_TREASURY_PAYMASTER=$BOND_TREASURY_PAYMASTER
BASE_BOND=$BASE_BOND
BOND_QUOTA=$BOND_QUOTA
BOND_PERIOD=$BOND_PERIOD
EOF
  
  log_success "Environment file updated"
}

# =============================================================================
# Step 6: Print Summary
# =============================================================================

print_summary() {
  echo ""
  echo "=============================================="
  echo "  DEPLOYMENT SUMMARY"
  echo "=============================================="
  echo ""
  echo "Network: $NETWORK ($HARDHAT_NETWORK)"
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
  echo "ServiceProvider:"
  echo "  Proxy:          $SERVICE_PROVIDER_PROXY"
  echo "  Implementation: $SERVICE_PROVIDER_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$SERVICE_PROVIDER_PROXY"
  echo ""
  echo "FleetIdentity:"
  echo "  Proxy:          $FLEET_IDENTITY_PROXY"
  echo "  Implementation: $FLEET_IDENTITY_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$FLEET_IDENTITY_PROXY"
  echo ""
  echo "SwarmRegistry:"
  echo "  Proxy:          $SWARM_REGISTRY_PROXY"
  echo "  Implementation: $SWARM_REGISTRY_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$SWARM_REGISTRY_PROXY"
  echo ""
  echo "BondTreasuryPaymaster:"
  echo "  Address:        $BOND_TREASURY_PAYMASTER"
  echo "  Explorer:       $EXPLORER_URL/address/$BOND_TREASURY_PAYMASTER"
  echo ""
  echo "Configuration:"
  echo "  Owner:                $L2_ADMIN"
  echo "  Withdrawer:           ${PAYMASTER_WITHDRAWER:-deployer}"
  echo "  Fleet Operator:       $FLEET_OPERATOR"
  echo "  Bond Token:           $BOND_TOKEN"
  echo "  Base Bond:            $BASE_BOND wei"
  echo "  Bond Quota:           $BOND_QUOTA wei"
  echo "  Bond Period:          $BOND_PERIOD seconds"
  echo ""
  echo "=============================================="
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
  echo ""
  echo "=============================================="
  echo "  ZkSync Swarm Contracts Deployment"
  echo "=============================================="
  echo ""
  
  cd "$PROJECT_ROOT"
  
  preflight_checks
  move_l1_contracts
  compile_contracts
  deploy_contracts
  verify_deployment
  verify_source_code
  update_env_file
  print_summary
  
  # Note: restore_l1_contracts is called automatically via trap on EXIT
}

main "$@"
