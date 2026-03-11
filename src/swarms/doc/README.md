# Swarm System — Documentation

BLE tag registry enabling decentralized device discovery using cryptographic membership proofs.

## Contents

| Document                                                     | Description                                                                                                                 |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| [spec/swarm-specification.md](spec/swarm-specification.md)   | Full technical specification (data model, registration, economics, operations, lifecycle, discovery, maintenance, upgrades) |
| [spec/swarm-specification.pdf](spec/swarm-specification.pdf) | PDF build of the specification with rendered diagrams                                                                       |
| [upgradeable-contracts.md](upgradeable-contracts.md)         | Operational guide — TypeScript/ethers.js integration, Cast CLI, upgrade & rollback procedures                               |
| [iso3166-2/](iso3166-2/)                                     | Per-country administrative-area mapping tables (ISO 3166-2 → `adminIndex`)                                                  |

## Building the PDF

```bash
cd spec && bash build.sh
```

Requires `@mermaid-js/mermaid-cli` and `md-to-pdf` (install via `npm i` from repo root).
