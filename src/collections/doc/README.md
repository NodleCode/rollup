# User Collections — Documentation

Operator-triggered NFT collection factory: users pay in fiat off-chain, a trusted backend deploys a fully-isolated per-collection `ERC1967Proxy` (ERC-721 or ERC-1155) on the user's behalf.

## Contents

| Document                                                                         | Description                                                                                            |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [spec/user-collections-specification.md](spec/user-collections-specification.md) | Full technical specification (architecture, roles, interfaces, flows, storage, security, testing, ops) |
| [spec/design-and-implementation.md](spec/design-and-implementation.md)           | Design rationale & as-built implementation (ERC1967Proxy architecture, permanence proof, address pre-derivation, deploy/verify, upgrades) |
