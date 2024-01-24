# Content Sign - The Graph

This project exists to support indexing data for the ERC721 - Content Sign from Nodle.

Please refer to: @openzeppelin/subgraphs

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [Contributing](#contributing)
- [License](#license)

## Installation

As part of the monorepo, all installs are specially arranged to the root package.

## Usage

Use after all main installations.

Major codebase are generated and edited, by running the following command or just `yarn generate`

```
npx graph-compiler \
  --config config.json \
  --include node_modules/@openzeppelin/subgraphs/src/datasources \
  --export-schema \
  --export-subgraph
```

