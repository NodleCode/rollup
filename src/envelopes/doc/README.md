# Envelopes — Documentation

Bearer-link asset transfer: a sender wraps ETH, ERC-20, ERC-721, or ERC-1155 assets in an on-chain envelope, gets a shareable URL, and anyone holding the URL can claim the contents through the app. Front-run-safe by construction (claim signature commits to the claimer's address).

## Contents

| Document                                                             | Description                                                                                                                          |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| [spec/envelopes-specification.md](spec/envelopes-specification.md)   | Full technical specification (architecture, roles, interfaces, flows, storage, security, testing, ops)                                |
| [integration-guide.md](integration-guide.md)                          | Operational runbook — TypeScript/ethers.js integration, Cast CLI, sender + app + recipient flows, admin operations, bug-fix rollout  |
