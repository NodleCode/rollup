# EnvelopeApprovalPaymaster — Path-C gas sponsor

`src/paymasters/EnvelopeApprovalPaymaster.sol`

## Purpose

Sponsors gas in **two modes**, both funded from one ETH pool and bounded by the same per-tx cap + daily QuotaControl:

| Mode | Caller | Auth | What gets sponsored |
|---|---|---|---|
| **A — User approval** | regular user | EIP-712 grant signed off-chain by `operatorSigner` (single-use nonce, deadline) + selector + spender checks | `token.approve(envelopeVault, ...)` / `token.setApprovalForAll(envelopeVault, true)` for ERC-20 / 721 / 1155 — the user-side step in Path C |
| **B — Operator direct call** | operator EOA on the `isOperator` allowlist | target must be on the `isAllowedTarget` allowlist; no grant required | Anything the operator wants to call on an allowlisted target — typically `vault.makeCustomDeposit`, `vault.withdrawDeposit`, etc. |

Mode B is the "single point we top up" pattern: instead of funding the operator's hot wallet directly, fund the paymaster and let the operator submit txs gaslessly. Bounded daily spend (QuotaControl), bounded per-tx spend (`maxEthPerTx`), and rotation just means flipping `isOperator` on a new EOA — no balance migration.

## Deployment scope

- **Authorization model** — signed grants from the operator. No on-chain user whitelist; the backend gates per request.
- **No token allowlist** — the operator's grant is the only auth surface. Defense-in-depth comes from a hard per-tx ETH cap and a global daily quota.
- **Operator-driven UX** — the user never sees the EIP-712 grant; only the operator's backend does.

Deployed on ZkSync Sepolia at [`0x842fe6fC8358c5eeBf5b7dA4E8546DB3d8ADA268`](https://sepolia.explorer.zksync.io/address/0x842fe6fC8358c5eeBf5b7dA4E8546DB3d8ADA268#contract).

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

// Mode A
address public operatorSigner;                  // admin-rotatable EIP-712 signer
mapping(bytes32 => bool) public isNonceUsed;    // single-use replay protection

// Mode B
mapping(address => bool) public isOperator;     // EOAs allowed to call any fn on a target
mapping(address => bool) public isAllowedTarget; // contracts an operator may call
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

## `validateAndPayForPaymasterTransaction` — gates per mode

The function branches on `isOperator[tx.from]`:

```text
if isOperator[tx.from]:
    Mode B
        - isAllowedTarget[tx.to]                    [TargetNotAllowed]
        - requiredETH ≤ maxEthPerTx                 [PerTxLimitExceeded]
        - paymaster.balance ≥ requiredETH            [InsufficientPaymasterBalance]
        - claimed + requiredETH ≤ quota              [QuotaControl.QuotaExceeded]
else:
    Mode A — gates listed below
```

### Mode A (user-side approval) gates

```text
A. msg.sender == BOOTLOADER_FORMAL_ADDRESS                 [AccessRestrictedToBootloader]
B. paymasterInput flow == IPaymasterFlow.general           [WrongFlow]
C. Grant:
    - paymasterInput length >= 4                           [InvalidPaymasterInput]
    - block.timestamp <= deadline                          [GrantExpired]
    - !isNonceUsed[nonce]                                  [NonceAlreadyUsed]
    - SignatureChecker.isValidSignatureNow(operatorSigner, grantDigest, signature)
                                                              [InvalidGrantSignature]
      (supports both EOA ECDSA sigs and EIP-1271 contract signers)
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
// Mode A — rotate the EIP-712 grant signer
function setOperatorSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE);

// Mode B — manage the operator EOA allowlist
function setOperator(address operator, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE);

// Mode B — manage the target-contract allowlist
function setAllowedTarget(address target, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE);

// Inherited from QuotaControl
function setQuota(uint256 newQuota) external onlyRole(DEFAULT_ADMIN_ROLE);
function setPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE);

// Inherited from BasePaymaster
function withdraw(address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE);
```

`setOperatorSigner(0)`, `setOperator(0, ...)`, and `setAllowedTarget(0, ...)` all revert with `ZeroAddress` — no silent disable.

### Operational seeding (post-deploy)

Mode B is dormant at deploy. To enable: admin calls `setAllowedTarget(envelopeVault, true)` and `setOperator(operatorEOA, true)`. Multiple operators / targets are allowed.

## Events / Errors

```solidity
// Mode A
event OperatorSignerUpdated(address indexed previousSigner, address indexed newSigner);
event ApprovalSponsored(address indexed user, address indexed token,
                        bytes32 indexed nonce, uint256 gasPaid);

// Mode B
event OperatorSet(address indexed operator, bool allowed);
event AllowedTargetSet(address indexed target, bool allowed);
event OperatorCallSponsored(address indexed operator, address indexed target, uint256 gasPaid);

// Validation reverts
error WrongFlow();
error GrantExpired();                  // Mode A
error NonceAlreadyUsed();              // Mode A
error InvalidGrantSignature();         // Mode A
error UnsupportedSelector();           // Mode A
error SpenderNotEnvelope();            // Mode A
error TargetNotAllowed();              // Mode B
error PerTxLimitExceeded();            // both modes
error InsufficientPaymasterBalance();  // both modes
error ZeroAddress();                   // admin functions + constructor
error Unused();                        // _validateAndPayGeneralFlow hook (never reached)
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

### Shared (both modes)

| Attack | Mitigation |
|---|---|
| Drain via one huge tx (e.g. huge `gasLimit`) | `requiredETH > maxEthPerTx` reverts |
| Drain via many normal-sized txs | `QuotaControl` daily cap (shared across both modes) |
| Withdraw paymaster ETH without permission | `WITHDRAWER_ROLE` gate on `withdraw` |
| zkSync `<address>.transfer` issue | All ETH outflow uses `.call{value:}("")` (EraVM-safe) |
| Bootloader impersonation | `_mustBeBootloader()` (msg.sender == `BOOTLOADER_FORMAL_ADDRESS`) |

### Mode A specific

| Attack | Mitigation |
|---|---|
| Anyone tries to use the paymaster without operator sign-off | `_verifyAndConsumeGrant` — must hold a valid signature from `operatorSigner` (via `SignatureChecker`, EOA or EIP-1271) |
| Replay a stale grant | `nonce` is single-use (`isNonceUsed`); also `deadline` |
| Use a grant signed for another user | `user` is part of the EIP-712 struct hash; sig won't verify if `tx.from` differs |
| Sponsor a transfer / mint / arbitrary state-change | Inner selector must be `approve` or `setApprovalForAll` |
| Approve attacker as spender | Inner first arg must equal `envelopeVault` |
| Operator-signer key compromise | Bounded by `maxEthPerTx` per tx AND quota per day. Admin rotates via `setOperatorSigner` |

### Mode B specific

| Attack | Mitigation |
|---|---|
| Random EOA tries to use the paymaster directly | `isOperator[tx.from]` check — only allowlisted EOAs enter Mode B; otherwise the call falls through to Mode A and fails on grant decode |
| Operator EOA calls a malicious contract | `isAllowedTarget[tx.to]` check — admin curates which contracts the operator may call |
| Operator-EOA key compromise | Same `maxEthPerTx` + quota bounds. Admin revokes via `setOperator(eoa, false)` (one tx, no balance migration) |
| Single operator becomes a bottleneck or single-point-of-failure | Allowlist multiple operator EOAs; rotate independently |

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

const PAYMASTER = "0x842fe6fC8358c5eeBf5b7dA4E8546DB3d8ADA268";
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
# vault address already wired in .env-test as ENVELOPE_VAULT
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

`test/paymasters/EnvelopeApprovalPaymaster.t.sol` — **27 tests**:

**Mode A (user approval) — 19 tests**
- **Happy paths**: sponsors `approve`, sponsors `setApprovalForAll`, sponsors on any token (no allowlist), accepts EIP-1271 contract signer
- **Reverts per gate**: not-bootloader, approval-based-flow, expired grant, reused nonce, wrong signer, wrong user in sig, unsupported selector, spender-not-envelope, per-tx limit, insufficient balance, exceeded quota (via dedicated tight-quota paymaster instance)
- **Period rollover**: `claimed` counter resets after `period` elapsed
- **Admin gates**: rotate operator signer; non-admin can't; withdraw; non-withdrawer can't

**Mode B (operator direct call) — 7 tests**
- Operator EOA on allowlist + allowlisted target → sponsored
- `TargetNotAllowed` when target isn't on the allowlist
- Non-operator caller falls through to Mode A grant flow
- `PerTxLimitExceeded` applies to Mode B too
- Mode A and Mode B contribute to the same `QuotaControl` counter
- Admin can revoke operators (`setOperator(eoa, false)`)
- Non-admin cannot manage operators or targets

**Mode independence verified**: a Mode B success and a Mode A success drain into the same ETH pool and the same `claimed` counter, asserted in `test_modeB_operatorContributesToSameQuotaAsModeA`.
