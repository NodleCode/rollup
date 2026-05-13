# PeanutBatcherV4 — N-deposits-in-one-tx helper

`src/peanut/V4/PeanutBatcherV4.4.sol`

## Purpose

A stateless helper that lets a single tx create N peanut deposits at once. The batcher pulls tokens from `msg.sender` once, then loops calling the vault's `makeSelflessDeposit` / `makeCustomDeposit` / `makeSelflessMFADeposit` for each pubKey. Common use case: airdrops or per-recipient claim links.

Stateless by design — the `PeanutV4` reference is taken from the call argument each invocation, so the same batcher contract can fan out to multiple vault deployments. Also avoids EraVM pubdata cost on every batch call (`PeanutV4 public peanut` storage var was dropped during hardening).

## Constructor

```solidity
constructor() // no args
```

## Public entry points

| Function | Use case |
|---|---|
| `batchMakeDeposit(peanut, token, contractType, amount, tokenId, pubKeys20[])` | N deposits, all the same shape; returns array of deposit indexes |
| `batchMakeDepositNoReturn(peanut, token, contractType, amount, tokenId, pubKeys20[])` | Same as above but skips the return-array allocation (cheaper). Only meaningful for a single deposit, or for ETH-only with msg.value reused per call (legacy upstream shape) |
| `batchMakeDepositArbitrary(peanut, tokens[], contractTypes[], amounts[], tokenIds[], pubKeys20[], withMFAs[])` | Heterogeneous batch — each deposit has its own token/type/amount/id/pubkey/MFA flag |
| `batchMakeDepositRaffle(peanut, token, contractType, amounts[], pubKey20)` | Raffle: many deposits sharing the same `pubKey20`, each with its own amount. Withdraw order = order claimed. ETH and ERC-20 only |
| `batchMakeDepositRaffleMFA(...)` | Same as raffle, but all deposits are MFA-gated |

All call `peanut.makeSelflessDeposit(_, _, _, _, _, msg.sender)` (or its MFA / custom variants) under the hood — the **batcher caller** (`msg.sender`) becomes the `senderAddress` recorded in the vault, so they retain reclaim rights.

## ERC-721 batch — intentionally not supported

```solidity
} else if (_contractType == 2) {
    revert("ERC721 batch not implemented");
}
```

Each NFT has a unique `tokenId`, which doesn't fit the same-args-per-deposit shape of `batchMakeDeposit` / `batchMakeDepositArbitrary`. For multi-NFT airdrops, call `makeCustomDeposit` per token in your own client loop.

## Token pulls

| `contractType` | Path |
|---|---|
| 0 (ETH) | `msg.value == amount * pubKeys20.length` check; ETH is then forwarded per inner deposit |
| 1 (ERC-20) | `safeTransferFrom(msg.sender, address(this), totalAmount)`; one-time `forceApprove(peanut, MAX)` via `_setAllowanceIfZero` |
| 3 (ERC-1155) | `safeTransferFrom(msg.sender, address(this), tokenId, totalAmount, "")`; `setApprovalForAll(peanut, true)` |

The batcher holds the assets transiently between pull and the inner `makeSelflessDeposit` calls. Each inner call pulls from the batcher (whom it just approved) into the vault.

## `_setAllowanceIfZero`

```solidity
function _setAllowanceIfZero(address tokenAddress, address spender) internal {
    if (IERC20(tokenAddress).allowance(address(this), spender) == 0) {
        IERC20(tokenAddress).forceApprove(spender, type(uint256).max);
    }
}
```

Sets max allowance on first use, then no-ops. `forceApprove` (OZ v5) handles USDT-style non-bool-returning tokens; replaced upstream's `safeApprove` which was removed in OZ v5.

## Receiver hooks (S1 hardening)

Same self-only policy as the vault — direct ERC-721 / ERC-1155 transfers to the batcher revert with `"DIRECT TRANSFERS NOT ALLOWED"`. The legitimate path is the batcher itself initiating the inner `safeTransferFrom`, where the bootloader sees `operator == address(this)`.

## Storage

None. (`PeanutV4 public peanut` was removed during hardening — see ZkSync notes.)

## Events / errors

None of its own. Inner deposits emit `PeanutV4.DepositEvent`.

## Vendoring patches

| | Patch |
|---|---|
| OZ v5 | `safeApprove` → `forceApprove` |
| ZkSync (Z2) | Dropped `PeanutV4 public peanut` storage var; uses local per call |
| ZkSync (Z1) | Explicit `override(IERC165)` on `supportsInterface` |
| Hardening (S1) | Receivers revert on non-self operator |
| Modern | Named imports |
| Modern | Pragma pinned to `0.8.26` |
| Add | `_withMFAs.length` check in `batchMakeDepositArbitrary` (upstream was missing) |

## Test coverage

`test/peanut/PeanutBatcher.t.sol` — 13 tests:
- happy paths for ETH / ERC-20 / ERC-1155 batches
- ERC-721 batch reverts as designed (`test_RevertWhen_BatchERC721NotImplemented`)
- raffle (ETH + ERC-20)
- multiple batches in a row
- not-approved revert paths for all three asset types
