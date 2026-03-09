#!/bin/bash
# =============================================================================
# deploy_swarm_contracts_l1.sh
#
# Automated deployment script for Swarm contracts (ServiceProvider, FleetIdentity,
# SwarmRegistryL1) to Ethereum L1.
#
# OVERVIEW:
# ---------
# This script deploys the upgradeable Swarm contracts to Ethereum L1 using Foundry.
# Unlike ZkSync deployments, we use Forge here because:
#   1. Forge is stable and well-tested for L1 deployments
#   2. SwarmRegistryL1 uses SSTORE2 (EXTCODECOPY) which works on L1
#   3. No need for special compiler or Hardhat plugins
#
# L1 vs ZKSYNC:
# -------------
# - L1: Uses SwarmRegistryL1Upgradeable with SSTORE2 for storage proofs
# - ZkSync: Uses SwarmRegistryUniversalUpgradeable (no SSTORE2)
# 
# SSTORE2 relies on EXTCODECOPY opcode which is NOT supported on ZkSync Era.
# For ZkSync deployments, use deploy_swarm_contracts_zksync.sh instead.
#
# CONTRACT ARCHITECTURE:
# ----------------------
# - ServiceProviderUpgradeable: Registry for service providers (no dependencies)
# - FleetIdentityUpgradeable: NFT-based fleet identity with bonding (depends on ERC20 bond token)
# - SwarmRegistryL1Upgradeable: Main registry with SSTORE2 (depends on ServiceProvider & FleetIdentity)
#
# USAGE:
# ------
#   # For testnet (dry run - simulation only):
#   ./ops/deploy_swarm_contracts_l1.sh testnet
#
#   # For testnet (actual deployment):
#   ./ops/deploy_swarm_contracts_l1.sh testnet --broadcast
#
#   # For mainnet (actual deployment):
#   ./ops/deploy_swarm_contracts_l1.sh mainnet --broadcast
#
# REQUIRED ENVIRONMENT VARIABLES:
# -------------------------------
# The script loads from .env-test (testnet) or .env-prod (mainnet):
#   - DEPLOYER_PRIVATE_KEY: Private key with ETH for gas
#   - BOND_TOKEN: Address of the ERC20 bond token (NODL)
#   - BASE_BOND: Bond amount in wei (e.g., 100000000000000000000 for 100 NODL)
#   - OWNER: (optional) Contract owner address, defaults to deployer
#   - L1_RPC: RPC URL for L1 (Sepolia or Mainnet)
#   - ETHERSCAN_API_KEY: For contract verification
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
    CHAIN_ID="11155111"  # Sepolia
    EXPLORER_URL="https://sepolia.etherscan.io"
    VERIFIER_URL="https://api-sepolia.etherscan.io/api"
    ;;
  mainnet)
    ENV_FILE=".env-prod"
    CHAIN_ID="1"  # Ethereum Mainnet
    EXPLORER_URL="https://etherscan.io"
    VERIFIER_URL="https://api.etherscan.io/api"
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
    log_error "forge not found. Please install foundry."
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

  if [ -z "$BOND_TOKEN" ] && [ -z "$NODL" ]; then
    log_error "BOND_TOKEN or NODL not set in $ENV_FILE"
    exit 1
  fi

  if [ -z "$L1_RPC" ]; then
    log_error "L1_RPC not set in $ENV_FILE"
    exit 1
  fi

  # Set defaults
  export BOND_TOKEN="${BOND_TOKEN:-$NODL}"
  export BASE_BOND="${BASE_BOND:-100000000000000000000}"  # 100 NODL default

  log_success "Pre-flight checks passed"
}

# =============================================================================
# Step 1: Build Contracts
# =============================================================================
#
# Standard Forge build - no special flags needed for L1.
# All contracts including SwarmRegistryL1 (with SSTORE2) compile normally.
#
# =============================================================================

build_contracts() {
  log_info "Building contracts with Forge..."
  
  forge build
  
  log_success "Build complete"
}

# =============================================================================
# Step 2: Deploy Contracts
# =============================================================================
#
# Uses Forge script to deploy all contracts in the correct order:
#   1. ServiceProviderUpgradeable
#   2. FleetIdentityUpgradeable  
#   3. SwarmRegistryL1Upgradeable
#
# =============================================================================

deploy_contracts() {
  log_info "Deploying contracts to L1 ($NETWORK)..."
  
  FORGE_ARGS=(
    "script"
    "script/DeploySwarmUpgradeable.s.sol:DeploySwarmUpgradeableL1"
    "--rpc-url" "$L1_RPC"
    "--chain-id" "$CHAIN_ID"
  )
  
  if [ "$BROADCAST" = "--broadcast" ]; then
    FORGE_ARGS+=("--broadcast")
    
    # Add verification if API key is available
    if [ -n "$ETHERSCAN_API_KEY" ]; then
      FORGE_ARGS+=("--verify" "--verifier-url" "$VERIFIER_URL")
    fi
  else
    log_warning "DRY RUN MODE - Add '--broadcast' to actually deploy"
    log_info "Would deploy with:"
    log_info "  BOND_TOKEN: $BOND_TOKEN"
    log_info "  BASE_BOND: $BASE_BOND"
    log_info "  OWNER: ${OWNER:-deployer}"
    log_info "  RPC: $L1_RPC"
  fi
  
  # Run the deployment
  forge "${FORGE_ARGS[@]}" 2>&1 | tee /tmp/deploy-output-$$.txt
  
  if [ "$BROADCAST" = "--broadcast" ]; then
    # Extract deployed addresses from output
    SERVICE_PROVIDER_PROXY=$(grep "ServiceProvider Proxy:" /tmp/deploy-output-$$.txt | awk '{print $NF}')
    SERVICE_PROVIDER_IMPL=$(grep "ServiceProvider Implementation:" /tmp/deploy-output-$$.txt | grep -v "Proxy" | awk '{print $NF}')
    FLEET_IDENTITY_PROXY=$(grep "FleetIdentity Proxy:" /tmp/deploy-output-$$.txt | awk '{print $NF}')
    FLEET_IDENTITY_IMPL=$(grep "FleetIdentity Implementation:" /tmp/deploy-output-$$.txt | grep -v "Proxy" | awk '{print $NF}')
    SWARM_REGISTRY_PROXY=$(grep "SwarmRegistry Proxy:" /tmp/deploy-output-$$.txt | awk '{print $NF}')
    SWARM_REGISTRY_IMPL=$(grep "SwarmRegistry Implementation:" /tmp/deploy-output-$$.txt | grep -v "Proxy" | awk '{print $NF}')
    
    # Validate we got addresses
    if [ -z "$SERVICE_PROVIDER_PROXY" ] || [ -z "$FLEET_IDENTITY_PROXY" ] || [ -z "$SWARM_REGISTRY_PROXY" ]; then
      log_warning "Could not extract all addresses from output"
      log_info "Check /tmp/deploy-output-$$.txt for details"
    else
      log_success "Deployment complete!"
    fi
  fi
  
  rm -f /tmp/deploy-output-$$.txt
}

# =============================================================================
# Step 3: Verify Deployment
# =============================================================================

verify_deployment() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi
  
  if [ -z "$SERVICE_PROVIDER_PROXY" ]; then
    log_warning "Skipping verification - addresses not extracted"
    return 0
  fi
  
  log_info "Verifying deployment..."
  
  # Test ServiceProvider
  log_info "Testing ServiceProvider proxy..."
  SP_OWNER=$(cast call "$SERVICE_PROVIDER_PROXY" "owner()(address)" --rpc-url "$L1_RPC")
  log_success "ServiceProvider owner: $SP_OWNER"
  
  # Test FleetIdentity
  log_info "Testing FleetIdentity proxy..."
  FI_OWNER=$(cast call "$FLEET_IDENTITY_PROXY" "owner()(address)" --rpc-url "$L1_RPC")
  FI_BOND=$(cast call "$FLEET_IDENTITY_PROXY" "BASE_BOND()(uint256)" --rpc-url "$L1_RPC")
  FI_TOKEN=$(cast call "$FLEET_IDENTITY_PROXY" "BOND_TOKEN()(address)" --rpc-url "$L1_RPC")
  log_success "FleetIdentity owner: $FI_OWNER"
  log_success "FleetIdentity BASE_BOND: $FI_BOND"
  log_success "FleetIdentity BOND_TOKEN: $FI_TOKEN"
  
  # Test SwarmRegistry
  log_info "Testing SwarmRegistry proxy..."
  SR_OWNER=$(cast call "$SWARM_REGISTRY_PROXY" "owner()(address)" --rpc-url "$L1_RPC")
  log_success "SwarmRegistry owner: $SR_OWNER"
  
  log_success "All contracts verified successfully!"
}

# =============================================================================
# Step 4: Update Environment File
# =============================================================================

update_env_file() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi
  
  if [ -z "$SERVICE_PROVIDER_PROXY" ]; then
    return 0
  fi
  
  log_info "Updating $ENV_FILE with deployed addresses..."
  
  TIMESTAMP=$(date +%Y-%m-%d)
  
  # Check if swarm contracts section already exists
  if grep -q "SERVICE_PROVIDER_L1_PROXY" "$ENV_FILE"; then
    log_warning "L1 Swarm contract addresses already exist in $ENV_FILE"
    log_warning "Please manually update the addresses:"
    echo ""
    echo "SERVICE_PROVIDER_L1_PROXY=$SERVICE_PROVIDER_PROXY"
    echo "SERVICE_PROVIDER_L1_IMPL=$SERVICE_PROVIDER_IMPL"
    echo "FLEET_IDENTITY_L1_PROXY=$FLEET_IDENTITY_PROXY"
    echo "FLEET_IDENTITY_L1_IMPL=$FLEET_IDENTITY_IMPL"
    echo "SWARM_REGISTRY_L1_PROXY=$SWARM_REGISTRY_PROXY"
    echo "SWARM_REGISTRY_L1_IMPL=$SWARM_REGISTRY_IMPL"
    return 0
  fi
  
  # Append new addresses
  cat >> "$ENV_FILE" << EOF

# Swarm Contracts L1 (Ethereum - deployed $TIMESTAMP)
SERVICE_PROVIDER_L1_PROXY=$SERVICE_PROVIDER_PROXY
SERVICE_PROVIDER_L1_IMPL=$SERVICE_PROVIDER_IMPL
FLEET_IDENTITY_L1_PROXY=$FLEET_IDENTITY_PROXY
FLEET_IDENTITY_L1_IMPL=$FLEET_IDENTITY_IMPL
SWARM_REGISTRY_L1_PROXY=$SWARM_REGISTRY_PROXY
SWARM_REGISTRY_L1_IMPL=$SWARM_REGISTRY_IMPL
EOF
  
  log_success "Environment file updated"
}

# =============================================================================
# Step 5: Print Summary
# =============================================================================

print_summary() {
  echo ""
  echo "=============================================="
  echo "  DEPLOYMENT SUMMARY (L1)"
  echo "=============================================="
  echo ""
  echo "Network: $NETWORK (Chain ID: $CHAIN_ID)"
  echo "Explorer: $EXPLORER_URL"
  echo ""
  
  if [ "$BROADCAST" != "--broadcast" ]; then
    echo "Mode: DRY RUN (no contracts deployed)"
    echo ""
    echo "To deploy for real, run:"
    echo "  $0 $NETWORK --broadcast"
    return 0
  fi
  
  if [ -z "$SERVICE_PROVIDER_PROXY" ]; then
    echo "Check deployment output for contract addresses."
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
  echo "SwarmRegistryL1:"
  echo "  Proxy:          $SWARM_REGISTRY_PROXY"
  echo "  Implementation: $SWARM_REGISTRY_IMPL"
  echo "  Explorer:       $EXPLORER_URL/address/$SWARM_REGISTRY_PROXY"
  echo ""
  echo "Configuration:"
  echo "  Owner:      ${OWNER:-deployer}"
  echo "  Bond Token: $BOND_TOKEN"
  echo "  Base Bond:  $BASE_BOND wei"
  echo ""
  echo "=============================================="
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
  echo ""
  echo "=============================================="
  echo "  Ethereum L1 Swarm Contracts Deployment"
  echo "=============================================="
  echo ""
  
  cd "$PROJECT_ROOT"
  
  preflight_checks
  build_contracts
  deploy_contracts
  verify_deployment
  update_env_file
  print_summary
}

main "$@"
