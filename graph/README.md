# Content Sign - The Graph

To support indexing data for the ERC721 - Content Sign from Nodle.

Please refer to: @openzeppelin/subgraphs

## Installation

As part of the monorepo, all installs are specially arranged to the root package.

## Usage

Use after all main installations.You do not need to run anything more

Major codebase are generated and edited, by running the following command or just `yarn bootstrap`

```
npx graph-compiler \
  --config config.json \
  --include node_modules/@openzeppelin/subgraphs/src/datasources \
  --export-schema \
  --export-subgraph
```

Fix the Contracts paths on the generated files `generated/*`, [*]

