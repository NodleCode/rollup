# EnvelopeVault — link-based asset vault

`src/peanut/V4/PeanutV4.4.sol`

## Purpose

A non-custodial vault that lets a sender deposit ETH / ERC-20 / ERC-721 / ERC-1155 assets against an arbitrary `pubKey20` (last 20 bytes of an ECDSA public key). Anyone holding the matching **private key** can later claim the asset to any recipient address by producing a signature. Optionally a deposit can be:

- **Recipient-bound** — only a pre-named recipient address can claim
- **MFA-gated** — claim also requires a second signature from an admin-configured `MFA_AUTHORIZER`
- **Sender-reclaimable** — sender can reclaim after a configurable delay if the link is never used

This is the vendored upstream contract from `peanutprotocol/peanut-contracts@main` with security hardening + ZkSync alignment patches applied during vendoring.

## Constructor

```solidity
constructor(address _ecoAddress, address _mfaAuthorizer)
```

| Param | Purpose | `address(0)` means |
|---|---|---|
| `_ecoAddress` | Rebasing ECO-like ERC-20 token to gate from regular ERC-20 deposits (forces it through `contractType==4`) | no token gating |
| `_mfaAuthorizer` | EOA whose ECDSA signatures unlock `withdrawMFADeposit` | MFA disabled — any deposit flagged `withMFA=true` is unrecoverable |

Both stored `immutable`. The MFA authorizer was promoted from a hardcoded constant in upstream to per-deploy config during vendoring.

The constructor also computes and stores `DOMAIN_SEPARATOR` for the gasless-reclaim EIP-712 signature flow.

## Storage

```solidity
struct Deposit {
    address pubKey20;          // 20 bytes  — claim signature must recover to this
    uint256 amount;            // 32 bytes  — asset amount (or 1 for ERC-721)
    address tokenAddress;      // 20 bytes  — 0x0 for ETH
    uint8   contractType;      //  1 byte   — 0=ETH 1=ERC20 2=ERC721 3=ERC1155 4=L2ECO
    bool    claimed;           //  1 byte
    bool    requiresMFA;       //  1 byte
    uint40  timestamp;         //  5 bytes  — deposit time
    uint256 tokenId;           // 32 bytes  — 0 for ERC-20
    address senderAddress;     // 20 bytes  — who owns reclaim rights
    address recipient;         // 20 bytes  — if non-zero, only this address can claim
    uint40  reclaimableAfter;  //  5 bytes  — sender reclaim earliest (for recipient-bound only)
} // 6 slots, packed

Deposit[] public deposits;       // index = depositIndex
address public ecoAddress;       // immutable
address public immutable MFA_AUTHORIZER;
bytes32 public DOMAIN_SEPARATOR; // set at construction; not immutable for clarity
```

## Constants

| Name | Value | Purpose |
|---|---|---|
| `PEANUT_SALT` | `keccak256("Konrad makes tokens go woosh tadam")` | Domain-tags every link signature; prevents the same signature being reused on a different Peanut deployment |
| `ANYONE_WITHDRAWAL_MODE` | `bytes32(0)` | Default mode — anyone holding the private key can withdraw on behalf of an arbitrary recipient |
| `RECIPIENT_WITHDRAWAL_MODE` | `keccak256("only recipient")` | Used for `withdrawDepositAsRecipient` — only the recipient address signs |
| `GASLESS_RECLAIM_TYPEHASH` | `keccak256("GaslessReclaim(uint256 depositIndex)")` | EIP-712 type for sender's gasless reclaim |

## Deposit functions

All deposit functions are `payable` (ETH path uses `msg.value`) and `nonReentrant`. They route through internal `_pullTokensViaApproval` / `_pullTokensVia3009Encoded` for asset transfer, then `_storeDeposit` for state update.

| Function | Use case |
|---|---|
| `makeDeposit(token, contractType, amount, tokenId, pubKey20)` | Simplest — depositor is `msg.sender`, no MFA, no recipient bind |
| `makeMFADeposit(...)` | Same shape, but `withMFA=true` |
| `makeSelflessDeposit(..., onBehalfOf)` | Deposit credited to `onBehalfOf` (reclaim rights go to them, not msg.sender) — used by batcher |
| `makeSelflessMFADeposit(..., onBehalfOf)` | Selfless + MFA |
| `makeCustomDeposit(token, contractType, amount, tokenId, pubKey20, onBehalfOf, withMFA, recipient, reclaimableAfter, isGasless3009, args3009)` | All knobs exposed — the canonical entry point |
| `makeDepositWithAuthorization(token, from, amount, pubKey20, nonce, validAfter, validBefore, v, r, s)` | EIP-3009 path for USDC-style tokens — no pre-approval needed |

The minimalistic deposit functions (`makeDeposit`, `makeMFADeposit`, `makeSelflessDeposit`, `makeSelflessMFADeposit`) are marked `@deprecated` upstream but kept for ABI compatibility; new integrations should call `makeCustomDeposit`.

### `_storeDeposit` invariant — dual-zero rejection

A deposit with both `pubKey20 == 0` AND `recipient == 0` has **no withdrawal authority** — `_withdrawDeposit` would accept any caller without a valid signature. The hardening patch added at vendor time enforces:

```solidity
require(_pubKey20 != address(0) || _recipient != address(0), "DEPOSIT MUST HAVE AUTH");
```

so the dual-zero footgun is impossible.

## Withdraw functions

| Function | Caller | Auth |
|---|---|---|
| `withdrawDeposit(index, recipient, signature)` | anyone | `signature` (recovers to `pubKey20`) signed over `keccak256(PEANUT_SALT, chainid, address(this), index, recipient, ANYONE_WITHDRAWAL_MODE)` |
| `withdrawMFADeposit(index, recipient, signature, MFASignature)` | anyone | Both above signature AND a signature from `MFA_AUTHORIZER` over `keccak256(PEANUT_SALT, chainid, address(this), index, recipient)` |
| `withdrawDepositAsRecipient(index, recipient, signature)` | `recipient` only (msg.sender) | `signature` signed with `RECIPIENT_WITHDRAWAL_MODE` instead of `ANYONE_WITHDRAWAL_MODE` |
| `withdrawDepositSender(index)` | original sender | none beyond `msg.sender == _deposit.senderAddress`; for recipient-bound deposits also requires `block.timestamp > reclaimableAfter` |
| `withdrawDepositSenderGasless(reclaim, signer, signature)` | anyone | EIP-712 signature from `signer` (must equal `senderAddress`) over `GaslessReclaim(depositIndex)` |

All withdraws set `claimed = true` BEFORE the asset transfer (CEI). `nonReentrant` adds belt-and-suspenders.

## Asset paths

`contractType` determines how assets flow:

| Code | Asset | Deposit | Withdraw |
|---|---|---|---|
| 0 | ETH | `msg.value` | `recipient.call{value: amount}("")` |
| 1 | ERC-20 | `SafeERC20.safeTransferFrom(msg.sender, this, amount)` | `SafeERC20.safeTransfer(recipient, amount)` |
| 2 | ERC-721 | `safeTransferFrom(msg.sender, this, tokenId, "Internal transfer")` | `safeTransferFrom(this, recipient, tokenId)` |
| 3 | ERC-1155 | `safeTransferFrom(msg.sender, this, tokenId, amount, "Internal transfer")` | `safeTransferFrom(this, recipient, tokenId, amount, "")` |
| 4 | L2ECO (rebasing) | `SafeERC20.safeTransferFrom`; stored amount multiplied by `linearInflationMultiplier()` for inflation-invariance | inverse: `amount / linearInflationMultiplier()`, then `SafeERC20.safeTransfer` |

For ERC-20, the depositor must approve the vault first (Path C). The `EnvelopeApprovalPaymaster` exists to sponsor that approval tx.

## Receiver hooks (S1 hardening)

The vault implements `IERC721Receiver` + `IERC1155Receiver` because withdrawing NFTs goes through `safeTransferFrom` and the **recipient** may be a contract that needs the receiver-check; for the vault itself, the only legitimate calls to its own receiver hooks are when the vault itself is the operator (i.e. during withdraw). Direct deposits via `safeTransferFrom(user → vault, ...)` from outside this contract are explicitly rejected:

```solidity
require(_operator == address(this), "DIRECT TRANSFERS NOT ALLOWED");
```

This closes the upstream footgun where the hooks silently returned `bytes4(0)`, causing some tokens to accept the transfer and strand the asset in the vault.

## EIP-3009 path

For tokens that implement EIP-3009 (USDC and forks), the user signs `ReceiveWithAuthorization(...)` off-chain; the relayer submits to the vault via `makeDepositWithAuthorization` (or `makeCustomDeposit` with `_isGasless3009=true`). No pre-approval is needed — this is Path B.

The vault re-derives the nonce as `keccak256(pubKey20, _nonce)` before calling the token's `receiveWithAuthorization` — this binds the EIP-3009 signature to the specific link, preventing front-running where another link's owner steals the deposit.

## Events

```solidity
event DepositEvent(uint256 indexed _index, uint8 indexed _contractType,
                   uint256 _amount, address indexed _senderAddress);
event WithdrawEvent(uint256 indexed _index, uint8 indexed _contractType,
                    uint256 _amount, address indexed _recipientAddress);
event MessageEvent(string message); // emitted once at deploy ("Hello World, have a nutty day!")
```

## Views

```solidity
function getDepositCount() external view returns (uint256);
function getDeposit(uint256 _index) external view returns (Deposit memory);
function getAllDeposits() external view returns (Deposit[] memory);
function getAllDepositsForAddress(address _address) external view returns (Deposit[] memory);
function getSigner(bytes32 messageHash, bytes memory signature) public pure returns (address);
```

Note that `getAllDeposits` / `getAllDepositsForAddress` scale linearly with array length. Indexing services should listen to events instead.

## Vendoring patches applied at import

| | Patch |
|---|---|
| OZ v5 | `security/ReentrancyGuard.sol` → `utils/ReentrancyGuard.sol` |
| OZ v5 | `ECDSA.toEthSignedMessageHash` → `MessageHashUtils.toEthSignedMessageHash` |
| OZ v5 | `IL2ECO.transfer/transferFrom` → `SafeERC20.safeTransfer/safeTransferFrom` (cast IL2ECO → IERC20) |
| Hardening (S1) | `onERC{721,1155,1155Batch}Received` revert on non-self operator |
| Hardening (S3) | `MFA_AUTHORIZER` from `constant` to `immutable` constructor arg |
| Hardening (S4) | `_storeDeposit` rejects dual-zero pubKey20 + recipient |
| Bug fix | `_withdrawDeposit` L2ECO branch was sending to `senderAddress`; fixed to `_recipientAddress` |
| ZkSync | All raw IL2ECO calls switched to SafeERC20 |
| ZkSync | Explicit `override(IERC165)` on `supportsInterface` |
| Modern | Named imports throughout |
| Modern | Pragma pinned to `0.8.26` |

## Test coverage

| Suite | File |
|---|---|
| Vendored upstream tests | `test/peanut/EnvelopeVault.t.sol`, `Deposit.t.sol`, `SigWithdraw.t.sol`, `SenderWithdraw.t.sol`, `MFA.t.sol`, `RecipientBound.t.sol`, `Integration.t.sol`, `PeanutV4Gasless.t.sol` |
| Hardening (S1–S4 + T1–T4) | `test/peanut/PeanutHardening.t.sol` |

71 tests pass.
