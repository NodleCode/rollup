#!/bin/bash
# =============================================================================
# deploy_envelope_zksync.sh
#
# Deploys EnvelopeLinks and EnvelopePaymaster to ZkSync Era via Hardhat.
#
# WHY HARDHAT (not Forge):
#   The ZkSync source verifier requires compiling without viaIR. Hardhat with
#   zksolc v1.5.1 produces verifiable artifacts. The Forge toolchain (zksolc
#   v1.5.15) supports viaIR but the verifier crashes on complex viaIR contracts.
#
# USAGE:
#   # Deploy to mainnet:
#   ./ops/deploy_envelope_zksync.sh mainnet
#
#   # Deploy to testnet:
#   ./ops/deploy_envelope_zksync.sh testnet
#
#   # Re-run only verification (deploy already succeeded):
#   ./ops/deploy_envelope_zksync.sh mainnet --verify-only \
#     --vault 0xff735c70f33ca4eF1768F527B5f230b76A61A89b \
#     --paymaster 0x5396e4F349D863C0AD577bd9E752293524460C36
#
#   # Deploy + fund paymaster:
#   ./ops/deploy_envelope_zksync.sh mainnet --fund 0.01
#
# REQUIRED ENVIRONMENT (loaded from .env-prod or .env-test):
#   - DEPLOYER_PRIVATE_KEY
#   - ENVELOPE_MFA_AUTHORIZER
#   - ENVELOPE_FEE_TOKEN (or NODL as fallback)
#   - ENVELOPE_OWNER (defaults to L2_ADMIN)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# Parse Arguments
# =============================================================================

NETWORK="${1:-testnet}"
shift || true

VERIFY_ONLY=false
FUND_AMOUNT=""
VAULT_ADDR=""
PAYMASTER_ADDR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=true; shift ;;
    --vault) VAULT_ADDR="$2"; shift 2 ;;
    --paymaster) PAYMASTER_ADDR="$2"; shift 2 ;;
    --fund) FUND_AMOUNT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# =============================================================================
# Network Configuration
# =============================================================================

case "$NETWORK" in
  testnet)
    ENV_FILE=".env-test"
    HH_NETWORK="zkSyncSepoliaTestnet"
    DEFAULT_RPC="https://rpc.ankr.com/zksync_era_sepolia"
    VERIFIER_URL="https://explorer.sepolia.era.zksync.dev/contract_verification"
    ;;
  mainnet)
    ENV_FILE=".env-prod"
    HH_NETWORK="zkSyncMainnet"
    DEFAULT_RPC="https://mainnet.era.zksync.io"
    VERIFIER_URL="https://zksync2-mainnet-explorer.zksync.io/contract_verification"
    ;;
  *)
    echo "Error: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
    exit 1
    ;;
esac

# =============================================================================
# Colors & Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Pre-flight
# =============================================================================

cd "$PROJECT_ROOT"

log_info "Loading environment from $ENV_FILE"
if [ ! -f "$ENV_FILE" ]; then
  log_error "Environment file '$ENV_FILE' not found."
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Validate
if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  log_error "DEPLOYER_PRIVATE_KEY not set in $ENV_FILE"
  exit 1
fi
if [ -z "${ENVELOPE_MFA_AUTHORIZER:-}" ]; then
  log_error "ENVELOPE_MFA_AUTHORIZER not set in $ENV_FILE"
  exit 1
fi

RPC_URL="${L2_RPC:-$DEFAULT_RPC}"
VERIFIER_URL="${L2_VERIFIER_URL:-$VERIFIER_URL}"
OWNER="${ENVELOPE_OWNER:-$L2_ADMIN}"
FEE_TOKEN="${ENVELOPE_FEE_TOKEN:-$NODL}"

DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL" --ether)

log_info "Network:    $NETWORK ($HH_NETWORK)"
log_info "RPC:        $RPC_URL"
log_info "Deployer:   $DEPLOYER_ADDRESS ($BALANCE ETH)"
log_info "Owner:      $OWNER"
log_info "MFA:        $ENVELOPE_MFA_AUTHORIZER"
log_info "Fee Token:  $FEE_TOKEN"
echo ""

# =============================================================================
# Deploy (via Hardhat)
# =============================================================================

if [ "$VERIFY_ONLY" = true ]; then
  log_info "Skipping deployment (--verify-only)"
  if [ -z "$VAULT_ADDR" ] || [ -z "$PAYMASTER_ADDR" ]; then
    log_error "--verify-only requires --vault and --paymaster addresses"
    exit 1
  fi
else
  log_info "Compiling with Hardhat (zksolc v1.5.1, no viaIR)..."
  npx hardhat compile --force 2>&1 | grep -E "^(Successfully|Error)" || true
  echo ""

  log_info "Deploying to $NETWORK..."
  # Hardhat deploy-zksync runs the script and prints deployed addresses
  DEPLOY_OUTPUT=$(HARDHAT_NETWORK="$HH_NETWORK" npx hardhat deploy-zksync \
    --script DeployEnvelope.ts --network "$HH_NETWORK" 2>&1)

  echo "$DEPLOY_OUTPUT"
  echo ""

  # Extract addresses from output
  VAULT_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -oP 'EnvelopeLinks deployed at \K0x[a-fA-F0-9]+')
  PAYMASTER_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -oP 'EnvelopePaymaster deployed at \K0x[a-fA-F0-9]+')

  if [ -z "$VAULT_ADDR" ]; then
    log_error "Could not extract EnvelopeLinks address from deploy output"
    exit 1
  fi

  log_success "EnvelopeLinks:     $VAULT_ADDR"
  log_success "EnvelopePaymaster: $PAYMASTER_ADDR"
  echo ""
fi

# =============================================================================
# Verify (via filtered standard JSON API submission)
# =============================================================================

log_info "Verifying contracts on ZkSync explorer..."

# Build constructor args
VAULT_CTOR=$(cast abi-encode "constructor(address,address,address)" \
  "$ENVELOPE_MFA_AUTHORIZER" "$OWNER" "$FEE_TOKEN")
PAYMASTER_CTOR=$(cast abi-encode "constructor(address,address,address)" \
  "${ENVELOPE_PAYMASTER_ADMIN:-$OWNER}" "${ENVELOPE_PAYMASTER_WITHDRAWER:-$OWNER}" "$VAULT_ADDR")

VERIFY_ARGS=(
  "--address" "$VAULT_ADDR"
  "--contract" "src/envelope/EnvelopeLinks.sol:EnvelopeLinks"
  "--constructor-args" "$VAULT_CTOR"
  "--address" "$PAYMASTER_ADDR"
  "--contract" "src/paymasters/EnvelopePaymaster.sol:EnvelopePaymaster"
  "--constructor-args" "$PAYMASTER_CTOR"
  "--verifier-url" "$VERIFIER_URL"
)

python3 ops/verify_hardhat_zksync.py "${VERIFY_ARGS[@]}"

# =============================================================================
# Validate
# =============================================================================

echo ""
log_info "Validating on-chain state..."

MFA=$(cast call "$VAULT_ADDR" "mfaAuthorizer()(address)" --rpc-url "$RPC_URL")
log_info "  mfaAuthorizer(): $MFA"

OWN=$(cast call "$VAULT_ADDR" "owner()(address)" --rpc-url "$RPC_URL")
log_info "  owner(): $OWN"

FT=$(cast call "$VAULT_ADDR" "feeToken()(address)" --rpc-url "$RPC_URL")
log_info "  feeToken(): $FT"

PM_VAULT=$(cast call "$PAYMASTER_ADDR" "envelopeLinks()(address)" --rpc-url "$RPC_URL")
log_info "  paymaster.envelopeLinks(): $PM_VAULT"

log_success "Validation passed"

# =============================================================================
# Fund Paymaster (optional)
# =============================================================================

if [ -n "$FUND_AMOUNT" ]; then
  log_info "Funding paymaster with $FUND_AMOUNT ETH..."
  cast send "$PAYMASTER_ADDR" \
    --value "${FUND_AMOUNT}ether" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"
  PM_BAL=$(cast balance "$PAYMASTER_ADDR" --rpc-url "$RPC_URL" --ether)
  log_success "Paymaster balance: $PM_BAL ETH"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "============================================================"
echo "  ENVELOPE DEPLOYMENT COMPLETE ($NETWORK)"
echo "============================================================"
echo "  EnvelopeLinks:     $VAULT_ADDR"
echo "  EnvelopePaymaster: $PAYMASTER_ADDR"
echo ""
echo "  Update $ENV_FILE:"
echo "    ENVELOPE_VAULT=$VAULT_ADDR"
echo "    ENVELOPE_PAYMASTER=$PAYMASTER_ADDR"
echo "============================================================"
