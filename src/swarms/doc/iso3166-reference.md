# ISO 3166 Reference

## Country Codes (ISO 3166-1 Numeric)

FleetIdentity uses ISO 3166-1 numeric codes (1-999) for country identification.

| Code | Country        |
| :--- | :------------- |
| 124  | Canada         |
| 250  | France         |
| 276  | Germany        |
| 392  | Japan          |
| 826  | United Kingdom |
| 840  | United States  |

## Admin Area Codes

Admin codes map ISO 3166-2 subdivisions to 1-indexed integers.

### Region Key Encoding

```
Country:    regionKey = countryCode
Admin Area: regionKey = (countryCode << 10) | adminCode
```

**Examples:**
| Location | Country | Admin | Region Key |
| :------- | ------: | ----: | ---------: |
| United States | 840 | — | 840 |
| US-California | 840 | 5 | 860,165 |
| Canada | 124 | — | 124 |
| CA-Alberta | 124 | 1 | 127,001 |

## Admin Area Mapping Files

The [iso3166-2/](iso3166-2/) directory contains per-country mappings.

### File Format

Filename: `{ISO_3166-1_numeric}-{Country_Name}.md`

| Admin Code | ISO 3166-2 | Name                  |
| ---------: | :--------- | :-------------------- |
|          1 | XX         | Full subdivision name |
|          2 | YY         | ...                   |

### Constraints

- Admin codes: 1-indexed integers
- Valid range: 1-255 (covers all real-world subdivisions)
- Code 0 is invalid (reverts with `InvalidAdminCode()`)

## United States (840)

Selected entries from [iso3166-2/840-United_States.md](iso3166-2/840-United_States.md):

| Admin | ISO 3166-2 | State      |
| ----: | :--------- | :--------- |
|     1 | AL         | Alabama    |
|     5 | CA         | California |
|    32 | NY         | New York   |
|    43 | TX         | Texas      |

## Usage

```solidity
// US-California
uint16 countryCode = 840;
uint8 adminCode = 5;
uint32 regionKey = fleetIdentity.makeAdminRegion(countryCode, adminCode);
// regionKey = (840 << 10) | 5 = 860165

// Register
fleetIdentity.registerFleetLocal(uuid, countryCode, adminCode, tier);
// tokenId = (860165 << 128) | uint128(uuid)
```

## Contract Functions

```solidity
// Build region key
uint32 region = fleetIdentity.makeAdminRegion(countryCode, adminCode);

// Active regions
uint16[] memory countries = fleetIdentity.getActiveCountries();
uint32[] memory adminAreas = fleetIdentity.getActiveAdminAreas();

// Extract from token
uint32 region = fleetIdentity.tokenRegion(tokenId);
// If region < 1024: country-level
// If region >= 1024: adminCode = region & 0x3FF, countryCode = region >> 10
```

## Data Source

Mappings based on ISO 3166-2 standard maintained by ISO and national statistical agencies.
