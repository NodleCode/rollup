# Stats Queries

### 1. Get Wallets by Time (e.g., Monthly New Wallets)

Use this query to retrieve new wallets created within a specific time range.

```graphql
{
  wallets (filter: {
    timestamp: {
      greaterThanOrEqualTo: START,  // Replace START with the beginning timestamp
      lessThanOrEqualTo: END        // Replace END with the ending timestamp
    }
  }) {
    nodes {
      id          // Unique identifier of the wallet
      timestamp   // Timestamp when the wallet was created
    }
    totalCount    // Total number of wallets within the time period
  }
}
```

### 2. Get Transfers by Time (e.g., Monthly Transfers)

Use this query to count ERC-20 transfers within a specified time range.

```graphql
{
  eRC20Transfers(filter: {
    timestamp: {
      greaterThanOrEqualTo: START,  // Replace START with the beginning timestamp
      lessThanOrEqualTo: END        // Replace END with the ending timestamp
    }
  }) {
    totalCount    // Total number of ERC-20 transfers within the time period
  }
}
```

### 3. Get Accounts by Time (e.g., Holders)

Use this query to count the number of accounts holding a balance greater than 0 within a specific time range.

```graphql
{
  accounts (filter: {
    timestamp: {
      greaterThanOrEqualTo: START,  // Replace START with the beginning timestamp
      lessThanOrEqualTo: END        // Replace END with the ending timestamp
    }
    balance: {
      greaterThan: 0  // Filters only accounts with a balance greater than 0
    }
  }) {
    totalCount    // Total number of accounts (holders) within the time period
  }
}
```