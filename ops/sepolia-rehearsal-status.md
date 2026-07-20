# Sepolia Bridgehub rehearsal — PASSED

Date: 2026-07-17

## Deployed

| Contract | Address |
| --- | --- |
| New L2Bridge | `0xff735c70f33ca4eF1768F527B5f230b76A61A89b` |
| New L1Bridge | `0xd4676309609543A85ee6d18e8A9Ea385521D01a5` |
| LEGACY_BRIDGE (old L1) | `0xF8244F4Aa72D21b4511Cd7989221fF96E7D94B60` |
| BRIDGEHUB | `0x35A54c8C757806eB6820629bc82d90E056394C92` |
| L2_CHAIN_ID | `300` |

## Checklist

| Step | Result | Evidence |
| --- | --- | --- |
| Deposit → L2 mint | ✅ | L1 `0x143d61e548736bb26594f23dd6eabe4f93811c990e21a0bf5ede505fd478cd75` / L2 `0xc79f882950e1559730eeacdd32e4fd367ceb9ff3c917cd1b701a10ce4cff2663` |
| Withdraw → finalizeWithdrawal | ✅ | L2 `0x8e953c1c88e51424fd8f79abca5390e22d24b85b3a81d911726dbfb2aefd265f` → L1 `0xb8f8401cd17c070aebb5851ad055d9405d4c6b2b2d0e8dcaaaa9e8798dcc4de9` |
| Failed deposit → claimFailedDeposit | ✅ | Failed L2 `0x4ad1afbc54f6bbfa0cb7b17883faf93cdd18726a47d18cb0f9d8e2a954a5cea4` → claim L1 `0x76bd1b95fd9b97d541250fedbdef0d1525ee23c623d34f4b04c0d3bfbc888580` |
| Legacy replay blocked | ✅ | batch `21332` / idx `27` → `WithdrawalFinalizedOnLegacyBridge` |

See `ops/bridgehub-migration-cutover.md` for cutover sequencing updated from this rehearsal.
