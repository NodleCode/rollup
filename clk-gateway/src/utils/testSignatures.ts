/**
 * Dynamic signature generation for testing
 * This file creates actual typed data signatures for test cases
 */

import { Wallet } from 'ethers'
import { buildTypedData } from '../helpers'

// Test wallets used for generating these signatures
export const TEST_WALLET_PRIVATE_KEY = '0x2f8664f7f93c06a56a46845a30788d1116b3950c14928b901c4d47da1b491928'
export const TEST_WALLET_2_PRIVATE_KEY = '0x3400ccf9abb2f0954749fdfe045c6709051b0cb397e05bff2f0d71f5fce3fc27'
export const testWallet = new Wallet(TEST_WALLET_PRIVATE_KEY)
export const testWallet2 = new Wallet(TEST_WALLET_2_PRIVATE_KEY)

/**
 * Create a typed data signature for handle validation
 */
export async function createValidationSignature(
    handle: string,
    ensName: string,
    owner: string,
    wallet: Wallet = testWallet
): Promise<string> {
    const typedData = buildTypedData({
        handle: handle.toLowerCase(),
        ensName,
        owner,
        action: 'validate_handle',
    }, {
        HandleValidation: [
            { name: 'handle', type: 'string' },
            { name: 'ensName', type: 'string' },
            { name: 'owner', type: 'address' },
            { name: 'action', type: 'string' },
        ],
    })

    // Remove EIP712Domain as the validation function expects
    const { EIP712Domain, ...messageTypes } = typedData.types

    return await wallet.signTypedData(
        typedData.domain,
        messageTypes,
        typedData.message
    )
}

/**
 * Create a typed data signature for handle confirmation
 */
export async function createConfirmationSignature(
    handle: string,
    txHash: string,
    owner: string,
    wallet: Wallet = testWallet
): Promise<string> {
    const typedData = buildTypedData({
        handle: handle.toLowerCase(),
        txHash,
        owner,
        action: 'confirm_handle',
    }, {
        HandleConfirmation: [
            { name: 'handle', type: 'string' },
            { name: 'txHash', type: 'string' },
            { name: 'owner', type: 'address' },
            { name: 'action', type: 'string' },
        ],
    })

    // Remove EIP712Domain as the validation function expects  
    const { EIP712Domain, ...messageTypes } = typedData.types

    return await wallet.signTypedData(
        typedData.domain,
        messageTypes,
        typedData.message
    )
}

export interface TestRequestData {
    handle: string
    ensName: string
    owner: string
    signature: string
    idempotencyKey?: string
    txHash?: string
}

/**
 * Create a test validate request with dynamic signature
 */
export async function createTestValidateRequest(
    handle: string = 'testhandle',
    useInvalidSignature: boolean = false,
    wallet: Wallet = testWallet
): Promise<TestRequestData> {
    const owner = wallet.address
    const ensName = 'test.eth'

    let signature: string
    if (useInvalidSignature) {
        // Create an invalid signature by using wrong data
        signature = '0x' + '1'.repeat(130) // Invalid signature format
    } else {
        signature = await createValidationSignature(handle, ensName, owner, wallet)
    }

    return {
        handle,
        ensName,
        owner,
        signature,
        idempotencyKey: `test-${Date.now()}-${Math.random()}`
    }
}

/**
 * Create a test confirm request with dynamic signature
 */
export async function createTestConfirmRequest(
    handle: string = 'testhandle',
    txHash: string = '0x1234567890123456789012345678901234567890123456789012345678901234',
    wallet: Wallet = testWallet
): Promise<TestRequestData> {
    const owner = wallet.address
    const signature = await createConfirmationSignature(handle, txHash, owner, wallet)

    return {
        handle,
        ensName: 'test.eth',
        owner,
        signature,
        txHash
    }
}
