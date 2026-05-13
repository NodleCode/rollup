# EnvelopeApprovalPaymaster — Path-C gas sponsor

`src/paymasters/EnvelopeApprovalPaymaster.sol`

## Purpose

Sponsors gas for the user-side **approval txs** needed before a Peanut deposit can be made on a token that doesn't support EIP-2612 / EIP-3009. Specifically:

| Standard | Sponsored call |
|---|---|
| ERC-20 (no permit) | `token.approve(envelope, amount)` |
| ERC-721 | `token.approve(envelope, tokenId)` |
| ERC-1155 | `token.setApprovalForAll(envelope, true)` |

The user pays 0 ETH. The operator's backend gates **every** sponsored tx by issuing an EIP-712 grant signed off-chain. The paymaster verifies the grant on-chain before paying the bootloader.

## Deployment scope

- **Authorization model** — signed grants from the operator. No on-chain user whitelist; the backend gates per request.
- **No token allowlist** — the operator's grant is the only auth surface. Defense-in-depth comes from a hard per-tx ETH cap and a global daily quota.
- **Operator-driven UX** — the user never sees the EIP-712 grant; only the operator's backend does.

Deployed on ZkSync Sepolia at [`0xEE95bFF2240652e0f57aE3fcd57F87d85593c191`](https://sepolia.explorer.zksync.io/address/0xEE95bFF2240652e0f57aE3fcd57F87d85593c191#contract).

## Inheritance

```
EnvelopeApprovalPaymaster is BasePaymaster, QuotaControl
```

- `BasePaymaster` (`src/paymasters/BasePaymaster.sol`) — IPaymaster + bootloader gate + `WITHDRAWER_ROLE` + ETH `withdraw` / `receive` / `postTransaction` stub. Its `validateAndPayForPaymasterTransaction` is marked `virtual` and overridden here, because the paymaster needs full `Transaction` calldata (the base hook signature `(from, to, requiredETH)` hides `transaction.data` and `transaction.paymasterInput`).
- `QuotaControl` (`src/QuotaControl.sol`) — global wei-per-period cap, period auto-rolls.

## Constructor

```solidity
constructor(
    address admin,
    address withdrawer,
    address operatorSigner_,
    address envelope_,
    uint256 maxEthPerTx_,
    uint256 initialQuota,
    uint256 initialPeriod
)
```

| Param | Role / purpose |
|---|---|
| `admin` | `DEFAULT_ADMIN_ROLE` — can `setOperatorSigner` and `setQuota` / `setPeriod` |
| `withdrawer` | `WITHDRAWER_ROLE` — can `withdraw` ETH from the paymaster |
| `operatorSigner_` | EOA whose ECDSA grant signatures the paymaster accepts. Cannot be `address(0)` (constructor reverts `ZeroAddress`) |
| `envelope_` | Vault address — the **only** allowed `spender` / `operator` in sponsored approvals. Cannot be `address(0)` |
| `maxEthPerTx_` | Hard ceiling on `gasLimit * maxFeePerGas` per sponsored tx |
| `initialQuota` | Total wei sponsorable per period |
| `initialPeriod` | Period length in seconds (max 30 days per `QuotaControl`) |

The constructor also computes and stores the immutable `DOMAIN_SEPARATOR` for the EIP-712 grant.

## Storage

```solidity
bytes32 public immutable DOMAIN_SEPARATOR;
address public immutable envelopeVault;
uint256 public immutable maxEthPerTx;

address public operatorSigner;                 // admin-rotatable
mapping(bytes32 => bool) public isNonceUsed;   // single-use replay protection
```

Plus inherited:
- `QuotaControl`: `period`, `quota`, `quotaRenewalTimestamp`, `claimed`
- `BasePaymaster`/`AccessControl`: roles

## Constants

| | Value |
|---|---|
| `APPROVE_SEL` | `0x095ea7b3` — `approve(address,uint256)`; covers ERC-20 and ERC-721 |
| `SET_APPROVAL_FOR_ALL_SEL` | `0xa22cb465` — `setApprovalForAll(address,bool)`; covers ERC-721 and ERC-1155 |
| `EIP712_DOMAIN_TYPEHASH` | `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")` |
| `GRANT_TYPEHASH` | `keccak256("EnvelopeApprovalGrant(address user,uint256 deadline,bytes32 nonce)")` |

## EIP-712 grant

The operator signs this typed-data struct off-chain:

```ts
domain = {
  name: "EnvelopeApprovalPaymaster",
  version: "1",
  chainId,
  verifyingContract: <paymaster address>,
};

types = {
  EnvelopeApprovalGrant: [
    { name: "user",     type: "address" },
    { name: "deadline", type: "uint256" },
    { name: "nonce",    type: "bytes32" },
  ],
};

value = { user, deadline, nonce };
signature = await operatorWallet.signTypedData(domain, types, value);
```

The user attaches `abi.encode(deadline, nonce, signature)` inside the `general` paymaster flow:

```ts
const innerInput = AbiCoder.defaultAbiCoder().encode(
  ["uint256", "bytes32", "bytes"], [deadline, nonce, signature]
);
const paymasterParams = utils.getPaymasterParams(PAYMASTER, {
  type: "General", innerInput,
});
```

The user does NOT sign this grant — they just sign the outer ZkSync tx as usual. The grant proves to the paymaster that the **operator** authorized this tx.

## `validateAndPayForPaymasterTransaction` — the 5 gates

```text
A. msg.sender == BOOTLOADER_FORMAL_ADDRESS                 [AccessRestrictedToBootloader]
B. paymasterInput flow == IPaymasterFlow.general           [WrongFlow]
C. Grant:
    - paymasterInput length >= 4                           [InvalidPaymasterInput]
    - block.timestamp <= deadline                          [GrantExpired]
    - !isNonceUsed[nonce]                                  [NonceAlreadyUsed]
    - ECDSA.recover(grantDigest, signature) == operatorSigner  [InvalidGrantSignature]
D. Inner call:
    - data.length >= 36                                    [UnsupportedSelector]
    - selector ∈ {APPROVE_SEL, SET_APPROVAL_FOR_ALL_SEL}   [UnsupportedSelector]
    - first arg (spender/operator) == envelopeVault        [SpenderNotEnvelope]
E. Pay:
    - requiredETH (= gasLimit * maxFeePerGas) <= maxEthPerTx   [PerTxLimitExceeded]
    - paymaster.balance >= requiredETH                     [InsufficientPaymasterBalance]
    - claimed + requiredETH <= quota (period auto-rolls)   [QuotaControl.QuotaExceeded]
```

State writes during validation (allowed for paymasters under EraVM rules):
- `isNonceUsed[nonce] = true`
- `claimed += requiredETH` (with period rollover)

Then `BOOTLOADER_FORMAL_ADDRESS.call{value: requiredETH}("")` and emit `ApprovalSponsored(user, token, nonce, gasPaid)`.

The validation is split into four helper functions (`_requireGeneralFlow`, `_verifyAndConsumeGrant`, `_requireApprovalCallToEnvelope`, `_payBootloader`) so each scope has <16 locals — zksolc's legacy codegen otherwise hits stack-too-deep on the unified function and the block-explorer verification compile fails.

## Admin functions

```solidity
function setOperatorSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE);
function setQuota(uint256 newQuota) external onlyRole(DEFAULT_ADMIN_ROLE);  // inherited
function setPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE); // inherited
function withdraw(address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE); // inherited
```

`setOperatorSigner(0)` reverts with `ZeroAddress` — the paymaster cannot be silently disabled.

## Events / Errors

```solidity
event OperatorSignerUpdated(address indexed previousSigner, address indexed newSigner);
event ApprovalSponsored(address indexed user, address indexed token,
                        bytes32 indexed nonce, uint256 gasPaid);

error WrongFlow();
error GrantExpired();
error NonceAlreadyUsed();
error InvalidGrantSignature();
error UnsupportedSelector();
error SpenderNotEnvelope();
error PerTxLimitExceeded();
error InsufficientPaymasterBalance();
error ZeroAddress();
error Unused();           // _validateAndPayGeneralFlow hook (BasePaymaster requirement; never reached)
```

Plus inherited:

```solidity
error AccessRestrictedToBootloader();       // from BasePaymaster
error PaymasterFlowNotSupported();          // from BasePaymaster
error InvalidPaymasterInput(string message);
error FailedToWithdraw();
error QuotaExceeded();                      // from QuotaControl
error ZeroPeriod();
error TooLongPeriod();
```

## Threat model

| Attack | Mitigation |
|---|---|
| Anyone tries to use the paymaster without operator sign-off | `_verifyAndConsumeGrant` — must hold a valid signature from `operatorSigner` |
| Replay a stale grant | `nonce` is single-use (`isNonceUsed`); also `deadline` |
| Use a grant signed for another user | `user` is part of the EIP-712 struct hash; sig won't verify if `tx.from` differs |
| Sponsor a transfer / mint / arbitrary state-change | Inner selector must be `approve` or `setApprovalForAll` |
| Approve attacker as spender | Inner first arg must equal `envelopeVault` |
| Drain via one huge tx (e.g. huge `gasLimit`) | `requiredETH > maxEthPerTx` reverts |
| Drain via many normal-sized txs | `QuotaControl` daily cap |
| Operator-signer key compromise | Bounded by `maxEthPerTx` per tx AND quota per day. Admin rotates via `setOperatorSigner` |
| Withdraw paymaster ETH without permission | `WITHDRAWER_ROLE` gate on `withdraw` |
| zkSync `<address>.transfer` issue | All ETH outflow uses `.call{value:}("")` (EraVM-safe) |
| Bootloader impersonation | `_mustBeBootloader()` (msg.sender == `BOOTLOADER_FORMAL_ADDRESS`) |

## What was deliberately dropped (vs. earlier iterations)

| Feature | Why removed |
|---|---|
| Per-token allowlist + `ALLOWLIST_ADMIN_ROLE` | The operator already curates which tokens get grants (off-chain decision in the API). On-chain allowlist was operator-side ceremony. Per-tx ETH cap + quota gives equivalent worst-case bound under key compromise. |
| `TokenNotAllowed` error | (See above) |
| `Witnessed` events for token add/remove | (See above) |

## Backend signing code skeleton

```ts
import { Wallet } from "zksync-ethers";
import { ethers } from "ethers";
import { randomBytes, hexlify } from "ethers";

const PAYMASTER = "0xEE95bFF2240652e0f57aE3fcd57F87d85593c191";
const CHAIN_ID  = 300;
const operatorWallet = new Wallet(process.env.OPERATOR_PK!);

async function signGrant(user: string, ttlSec = 300) {
  const deadline = BigInt(Math.floor(Date.now() / 1000) + ttlSec);
  const nonce = hexlify(randomBytes(32));
  const signature = await operatorWallet.signTypedData(
    { name: "EnvelopeApprovalPaymaster", version: "1",
      chainId: CHAIN_ID, verifyingContract: PAYMASTER },
    { EnvelopeApprovalGrant: [
        { name: "user",     type: "address" },
        { name: "deadline", type: "uint256" },
        { name: "nonce",    type: "bytes32" },
    ]},
    { user, deadline, nonce },
  );
  return { deadline, nonce, signature };
}
```

## Deploy

```bash
# vault address already wired in .env-test as PEANUT_V4
ENVELOPE_PAYMASTER_FUNDING=2000000000000000     # 0.002 ETH; optional
yarn hardhat deploy-zksync \
  --script DeployEnvelopePaymaster.ts \
  --network zkSyncSepoliaTestnet
```

Optional env vars (defaults documented in the script header):
- `ENVELOPE_PAYMASTER_ADMIN`, `_WITHDRAWER`, `_OPERATOR_SIGNER`
- `ENVELOPE_PAYMASTER_MAX_ETH_PER_TX` (default 0.001 ETH)
- `ENVELOPE_PAYMASTER_QUOTA` (default 0.1 ETH)
- `ENVELOPE_PAYMASTER_PERIOD` (default 86400)
- `ENVELOPE_PAYMASTER_FUNDING` (default 0)

## Test coverage

`test/paymasters/EnvelopeApprovalPaymaster.t.sol` — 19 tests:
- **Happy paths**: sponsors `approve`, sponsors `setApprovalForAll`, sponsors approval on ANY token (no allowlist)
- **Reverts per gate**: not-bootloader, approval-based-flow, expired grant, reused nonce, wrong signer, wrong user in sig, unsupported selector, spender-not-envelope, per-tx limit, insufficient balance, exceeded quota (via dedicated tight-quota paymaster instance)
- **Period rollover**: claimed counter resets after `period` elapsed
- **Admin gates**: rotate operator signer; non-admin can't; withdraw; non-withdrawer can't
