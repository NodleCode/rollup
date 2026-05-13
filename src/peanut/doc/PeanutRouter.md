# PeanutV4Router — cross-chain peanut withdrawal via Squid

`src/peanut/V4/PeanutRouter.sol`

## Purpose

Wraps a Peanut withdrawal with a Squid (Axelar) bridge call so a recipient can claim a peanut link on chain X and receive the value on chain Y in a single transaction. Without this contract the recipient would have to first claim peanut on X, then manually bridge.

**Not deployed on Sepolia.** Deploy if/when you wire a Squid integration.

## Constructor

```solidity
constructor(address _squidAddress) Ownable(msg.sender)
```

| Param | Purpose |
|---|---|
| `_squidAddress` | Target Squid router on this chain. All bridge calls go to it |

Inherits `Ownable2Step` (OZ v5) so ownership transfer happens in two transactions:
1. Current owner: `transferOwnership(newOwner)` → sets pending owner
2. New owner: `acceptOwnership()` → confirms

Initial owner is `msg.sender`. Use `transferOwnership` + `acceptOwnership` to move ownership to a multisig.

## Storage

```solidity
address public squidAddress;  // mutable (no setter exposed — set at deploy)
```

Plus inherited `Ownable2Step`: `_owner`, `_pendingOwner`.

## External

### `withdrawAndBridge`

```solidity
function withdrawAndBridge(
    address _peanutAddress,
    uint256 _depositIndex,
    bytes calldata _withdrawalSignature,
    uint256 _squidFee,
    uint256 _peanutFee,
    bytes calldata _squidData,
    bytes calldata _routingSignature
) public payable
```

Full flow:

1. **Validate `_routingSignature` first** (EIP-191 v0x00) — signed by the deposit's `pubKey20` over `(routerAddress, chainId, peanutAddress, depositIndex, squidAddress, squidFee, peanutFee, squidData)`. This pins the relayer to the exact fees + bridge calldata the link-owner agreed to. Front-running with a different fee structure reverts with `WRONG ROUTING SIGNER`.
2. `msg.value == _squidFee` (`msg.value MUST BE THE SQUID FEE`).
3. `deposit.contractType ∈ {0, 1}` — ETH or ERC-20 only. ERC-721 / ERC-1155 can't be bridged this way (`X-CHAIN CLAIMS WORK ONLY FOR ETH AND ERC20 TOKENS`).
4. `_peanutFee < deposit.amount` (`TOO HIGH FEE`).
5. Call `peanut.withdrawDepositAsRecipient(_depositIndex, address(this), _withdrawalSignature)`. The vault transfers the asset to this router.
6. Compute `amountToBridge = deposit.amount - _peanutFee`. For ERC-20: `safeIncreaseAllowance(squidAddress, amountToBridge)`. For ETH: `ethAmountToSquid += amountToBridge`.
7. `(bool ok,) = payable(squidAddress).call{value: ethAmountToSquid}(_squidData);` — forwards the bridge call. Reverts on failure.

The router retains `_peanutFee` as collectible revenue.

### `withdrawFees`

```solidity
function withdrawFees(address token, address to, uint256 amount) public onlyOwner
```

Owner-gated. For ETH: `payable(to).call{value: amount}("")`. For ERC-20: `SafeERC20.safeTransfer` (so USDT and other non-bool-returning tokens work).

### `receive() external payable {}`

Allows the router to receive ETH from the vault during a `withdrawAndBridge` ETH path.

## Signature scheme

The routing signature uses **EIP-191 version 0x00** (a personal-sign variant). The digest:

```solidity
keccak256(abi.encodePacked(
    bytes2(0x1900),
    address(this),       // verifying contract
    block.chainid,
    _peanutAddress,
    _depositIndex,
    squidAddress,
    _squidFee,
    _peanutFee,
    _squidData
))
```

The link owner signs this off-chain. `ECDSA.recover(digest, _routingSignature)` must equal `deposit.pubKey20`. This signature is **separate** from the withdrawal signature, which proves the link owner consents to the bridge (different digest, different purpose — withdrawal authorizes pulling from the vault, routing authorizes the bridge parameters).

## Threat model

| Attack | Mitigation |
|---|---|
| Relayer charges higher peanut fee than user agreed | `_routingSignature` verifies over the EXACT `_peanutFee`. Any change → different digest → wrong signer revert |
| Relayer pays lower squid fee than required by Axelar (tx stuck) | `msg.value == _squidFee` check + `_squidFee` is in the routing sig |
| Relayer modifies `_squidData` to redirect to a different destination chain / token | `_squidData` is in the routing sig digest |
| Front-runner submits the same tx with stolen sig | Idempotent for the relayer fee perspective; peanut withdrawal is single-use so the second attempt reverts inside `peanut.withdrawDepositAsRecipient` (deposit already claimed) |
| Stuck cross-chain tx (gas-price spike on destination) | Out of scope — Axelar fee adjustment is the recovery; this contract does not implement expiry |

## Vendoring patches

| | Patch |
|---|---|
| Import target | `./PeanutV4.2.sol` → `./PeanutV4.4.sol` |
| OZ v5 | `Ownable` constructor takes explicit `Ownable(msg.sender)` |
| Hardening (S2) | `IERC20.transfer` → `SafeERC20.safeTransfer` in `withdrawFees` (USDT-compatible) |
| Hardening (M2) | `Ownable` → `Ownable2Step` (handoff requires explicit acceptance) |
| Modern | Named imports |
| Modern | Pragma pinned to `0.8.26` |

## Test coverage

`test/peanut/PeanutRouter.t.sol` — 4 tests including:

- happy path: withdraw + bridge for ETH (256-run fuzz)
- happy path: withdraw + bridge for ERC-20 (256-run fuzz, validates fee paths)
- owner-only `withdrawFees` (asserts `Ownable.OwnableUnauthorizedAccount` for non-owner)
- relayer cannot tamper with fees / squidData (all `WRONG ROUTING SIGNER` reverts)

## Deploy

Not deployed on Sepolia. To deploy:

```bash
PEANUT_DEPLOY_ROUTER=true \
PEANUT_SQUID_ADDRESS=0x...                      # required
PEANUT_ROUTER_OWNER=0x...                       # optional; defaults to deployer
yarn hardhat deploy-zksync \
  --script DeployPeanut.ts \
  --network zkSyncSepoliaTestnet
```

After deploy, if `PEANUT_ROUTER_OWNER` ≠ deployer, the new owner must call `acceptOwnership()` from their own key.
