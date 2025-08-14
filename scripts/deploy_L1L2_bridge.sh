#!/usr/bin/env bash
# Orchestrates the complete deployment of NODL bridge system on L1 and L2
#
# Prerequisites:
# - .env file with required environment variables (NODL_ADMIN, NODL_MINTER, L2_BRIDGE_OWNER, etc.)
# - ETHERSCAN_API_KEY environment variable for contract verification
# - foundry and zkforge installed
# - Private key available for interactive signing (-i flag)
#
# Usage: ./scripts/deploy_L1L2_bridge.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${BLUE}==== STEP $1: $2 ====${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Function to extract contract address from forge output
extract_address() {
    local log_file="$1"
    local contract_name="$2"
    grep "Deployed $contract_name at" "$log_file" | grep -o "0x[a-fA-F0-9]\{40\}" | tail -1
}

# Function to update .env file
update_env() {
    local key="$1"
    local value="$2"
    
    if grep -q "^$key=" .env; then
        # Update existing line (cross-platform sed)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^$key=.*/$key=$value/" .env
        else
            sed -i "s/^$key=.*/$key=$value/" .env
        fi
    else
        # Add new line
        echo "$key=$value" >> .env
    fi
    print_info "Updated .env: $key=$value"
}

# Function to verify L1 contract
verify_l1_contract() {
    local address="$1"
    local contract_path="$2"
    local contract_name="$3"
    local constructor_args="${4:-}"
    
    print_info "Verifying L1 contract $contract_name at $address..."
    
    # First attempt without API key (sometimes required)
    print_info "Attempting verification without API key..."
    if forge verify-contract --chain-id $L1_CHAIN_ID "$address" "$contract_path:$contract_name" $constructor_args 2>/dev/null; then
        print_success "Verification successful without API key"
    fi
    
    # Second attempt with API key
    print_info "Attempting verification with API key..."
    if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
        if forge verify-contract --chain-id $L1_CHAIN_ID "$address" "$contract_path:$contract_name" --etherscan-api-key "$ETHERSCAN_API_KEY" $constructor_args; then
            print_success "Verification successful with API key"
        else
            print_warning "Verification failed, but continuing deployment"
        fi
    else
        print_warning "ETHERSCAN_API_KEY not set, skipping verification"
    fi
}

# Function to verify L2 contract
verify_l2_contract() {
    local address="$1"
    local contract_path="$2"
    local contract_name="$3"
    local constructor_args="$4"
    
    print_info "Verifying L2 contract $contract_name at $address..."
    
    if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
        if forge verify-contract --zksync --chain "$L2_CHAIN_NAME" "$address" "$contract_path:$contract_name" \
            --verifier zksync --verifier-url "$L2_VERIFIER_URL" \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --constructor-args "$constructor_args"; then
            print_success "L2 contract verification successful"
        else
            print_warning "L2 verification failed, but continuing deployment"
        fi
    else
        print_warning "ETHERSCAN_API_KEY not set, skipping L2 verification"
    fi
}

main() {
    print_info "Starting NODL Bridge deployment orchestration..."
    echo
    
    if [ ! -f .env ]; then
        print_error ".env file not found!"
        exit 1
    fi
    
    source .env
    
    L1_RPC="${L1_RPC:?Please set L1_RPC in .env}"
    L2_RPC="${L2_RPC:?Please set L2_RPC in .env}"
    L2_VERIFIER_URL="${L2_VERIFIER_URL:?Please set L2_VERIFIER_URL in .env}"
    
    # Check required environment variables
    required_vars=("NODL_ADMIN" "NODL_MINTER" "L2_BRIDGE_OWNER" "L1_MAILBOX" "L1_BRIDGE_OWNER" "L1_CHAIN_ID" "L2_CHAIN_NAME")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            print_error "Required environment variable $var is not set!"
            exit 1
        fi
    done
    
    # Create logs directory
    mkdir -p logs
    
    # =================================================================
    # STEP 0: Deploy L2 NODL Token
    # =================================================================
    print_step "0" "Deploy L2 NODL Token"
    
    if [ -n "${NODL:-}" ] && [ "$NODL" != "" ]; then
        print_info "NODL already set to: $NODL"
        print_info "Skipping L2 NODL deployment"
        NODL_ADDR="$NODL"
    else
        LOG_FILE="logs/deploy_l2_nodl.log"
        print_info "Deploying L2 NODL token..."
        print_info "Admin: $NODL_ADMIN"
        print_info "Minter: $NODL_MINTER"
        
        if forge script script/DeployL2Nodl.s.sol --zksync --rpc-url "$L2_RPC" --zk-optimizer -i 1 --broadcast | tee "$LOG_FILE"; then
            NODL_ADDR=$(extract_address "$LOG_FILE" "NODL")
            if [ -n "$NODL_ADDR" ]; then
                update_env "NODL" "$NODL_ADDR"
                print_success "L2 NODL deployed at: $NODL_ADDR"
            else
                print_error "Failed to extract L2 NODL address from deployment"
                exit 1
            fi
        else
            print_error "L2 NODL deployment failed"
            exit 1
        fi
    fi
    
    # =================================================================
    # STEP 0.1: Verify L2 NODL Token
    # =================================================================
    print_step "0.1" "Verify L2 NODL Token"
    
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$NODL_ADMIN")
    verify_l2_contract "$NODL_ADDR" "src/NODL.sol" "NODL" "$CONSTRUCTOR_ARGS"
    
    # Re-source .env to get updated NODL
    source .env
    
    # =================================================================
    # STEP 1: Deploy L1 NODL Token
    # =================================================================
    print_step "1" "Deploy L1 NODL Token"
    
    if [ -n "${L1_NODL:-}" ] && [ "$L1_NODL" != "" ]; then
        print_info "L1_NODL already set to: $L1_NODL"
        print_info "Skipping L1 NODL deployment"
        L1_NODL_ADDR="$L1_NODL"
    else
        LOG_FILE="logs/deploy_l1_nodl.log"
        print_info "Deploying L1 NODL token..."
        print_info "Admin: $NODL_ADMIN"
        print_info "Minter: $NODL_MINTER"
        
        if forge script script/DeployL1NODL.s.sol -i 1 --broadcast --rpc-url "$L1_RPC" | tee "$LOG_FILE"; then
            L1_NODL_ADDR=$(extract_address "$LOG_FILE" "L1Nodl")
            if [ -n "$L1_NODL_ADDR" ]; then
                update_env "L1_NODL" "$L1_NODL_ADDR"
                print_success "L1 NODL deployed at: $L1_NODL_ADDR"
            else
                print_error "Failed to extract L1 NODL address from deployment"
                exit 1
            fi
        else
            print_error "L1 NODL deployment failed"
            exit 1
        fi
    fi
    
    # =================================================================
    # STEP 2: Verify L1 NODL Token
    # =================================================================
    print_step "2" "Verify L1 NODL Token"
    
    verify_l1_contract "$L1_NODL_ADDR" "src/L1NODL.sol" "L1NODL"
    
    # =================================================================
    # STEP 3: Deploy L2 Bridge
    # =================================================================
    print_step "3" "Deploy L2 Bridge"
    
    if [ -n "${L2_BRIDGE:-}" ] && [ "$L2_BRIDGE" != "" ]; then
        print_info "L2_BRIDGE already set to: $L2_BRIDGE"
        print_info "Skipping L2 Bridge deployment"
        L2_BRIDGE_ADDR="$L2_BRIDGE"
    else
        LOG_FILE="logs/deploy_l2_bridge.log"
        print_info "Deploying L2 Bridge..."
        print_info "Owner: $L2_BRIDGE_OWNER"
        print_info "NODL Token: $NODL"
        
        if forge script script/DeployL2Bridge.s.sol --zksync --rpc-url "$L2_RPC" --zk-optimizer -i 1 --broadcast | tee "$LOG_FILE"; then
            L2_BRIDGE_ADDR=$(extract_address "$LOG_FILE" "L2Bridge")
            if [ -n "$L2_BRIDGE_ADDR" ]; then
                update_env "L2_BRIDGE" "$L2_BRIDGE_ADDR"
                print_success "L2 Bridge deployed at: $L2_BRIDGE_ADDR"
                
                # Check if minting permission was granted during deployment
                if grep -q "Granted MINTER_ROLE" "$LOG_FILE"; then
                    print_success "MINTER_ROLE granted to L2 Bridge during deployment"
                else
                    print_warning "MINTER_ROLE granting may have failed, but continuing deployment"
                fi
            else
                print_error "Failed to extract L2 Bridge address from deployment"
                exit 1
            fi
        else
            print_error "L2 Bridge deployment failed"
            exit 1
        fi
    fi
    
    # =================================================================
    # STEP 4: Verify L2 Bridge
    # =================================================================
    print_step "4" "Verify L2 Bridge"
    
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "$L2_BRIDGE_OWNER" "$NODL")
    verify_l2_contract "$L2_BRIDGE_ADDR" "src/bridge/L2Bridge.sol" "L2Bridge" "$CONSTRUCTOR_ARGS"
    
    # Re-source .env to get updated L2_BRIDGE
    source .env
    
    # =================================================================
    # STEP 5: Deploy L1 Bridge
    # =================================================================
    print_step "5" "Deploy L1 Bridge"
    
    if [ -n "${L1_BRIDGE:-}" ] && [ "$L1_BRIDGE" != "" ]; then
        print_info "L1_BRIDGE already set to: $L1_BRIDGE"
        print_info "Skipping L1 Bridge deployment"
        L1_BRIDGE_ADDR="$L1_BRIDGE"
    else
        LOG_FILE="logs/deploy_l1_bridge.log"
        print_info "Deploying L1 Bridge..."
        print_info "Owner: $L1_BRIDGE_OWNER"
        print_info "Mailbox: $L1_MAILBOX"
        print_info "L1 Token: $L1_NODL_ADDR"
        print_info "L2 Bridge: $L2_BRIDGE_ADDR"
        
        if forge script script/DeployL1Bridge.s.sol -i 1 --broadcast --rpc-url "$L1_RPC" | tee "$LOG_FILE"; then
            L1_BRIDGE_ADDR=$(extract_address "$LOG_FILE" "L1Bridge")
            if [ -n "$L1_BRIDGE_ADDR" ]; then
                update_env "L1_BRIDGE" "$L1_BRIDGE_ADDR"
                print_success "L1 Bridge deployed at: $L1_BRIDGE_ADDR"
            else
                print_error "Failed to extract L1 Bridge address from deployment"
                exit 1
            fi
        else
            print_error "L1 Bridge deployment failed"
            exit 1
        fi
    fi
    
    # =================================================================
    # STEP 6: Verify L1 Bridge
    # =================================================================
    print_step "6" "Verify L1 Bridge"
    
    verify_l1_contract "$L1_BRIDGE_ADDR" "src/bridge/L1Bridge.sol" "L1Bridge"
    
    # =================================================================
    # STEP 7: Initialize L2 Bridge
    # =================================================================
    print_step "7" "Initialize L2 Bridge"
    
    print_info "Initializing L2 Bridge with L1 Bridge address..."
    print_info "L2 Bridge: $L2_BRIDGE_ADDR"
    print_info "L1 Bridge: $L1_BRIDGE_ADDR"
    
    if cast send -i "$L2_BRIDGE_ADDR" "initialize(address)" "$L1_BRIDGE_ADDR" --rpc-url "$L2_RPC"; then
        print_success "L2 Bridge initialized successfully"
    else
        print_error "L2 Bridge initialization failed"
        exit 1
    fi
    
    # =================================================================
    # DEPLOYMENT SUMMARY
    # =================================================================
    echo
    print_info "=== DEPLOYMENT SUMMARY ==="
    echo -e "${GREEN}✅ L1 NODL Token:${NC} $L1_NODL_ADDR"
    echo -e "${GREEN}✅ L2 Bridge:${NC}     $L2_BRIDGE_ADDR"
    echo -e "${GREEN}✅ L1 Bridge:${NC}     $L1_BRIDGE_ADDR"
    echo
    print_info "All contracts deployed and initialized successfully!"
    print_info "Updated .env file with new contract addresses."
    echo
    print_info "Next steps:"
    echo "  1. Fund the L1 NODL token contract if needed"
    echo "  2. Test bridge functionality with small amounts"
    echo "  3. Use the get_l2_to_l1_msg_proof.sh script to finalize withdrawals"
    echo
}

# Run main function
main "$@"
