#!/usr/bin/env python3
"""
verify_zksync_contracts.py — Full source-code verification for ZkSync Era contracts.

PROBLEM:
  `forge verify-contract --zksync` and `forge script --verify` both fail to achieve
  full verification on the ZkSync explorer because:
    1. forge script --verify sends ABSOLUTE source paths → verifier rejects them.
    2. forge verify-contract sends standard JSON with OpenZeppelin's relative "../"
       imports → verifier rejects "import with absolute or traversal path".
    3. Using flattened files works around the import issue but changes the source
       path in the metadata hash → "partially verified" (metadata mismatch).

SOLUTION:
  This script generates standard JSON via `forge verify-contract --show-standard-json-input`,
  then rewrites all "../" relative imports in the source content to their resolved
  absolute-within-project paths (e.g., "../../utils/Foo.sol" → "lib/openzeppelin-contracts/
  contracts/utils/Foo.sol"). This preserves the original source file keys (and thus the
  metadata hash) while eliminating traversal paths that the verifier rejects.

  For contracts compiled with `bytecode_hash = "none"` in foundry.toml (added 2026-04-10),
  the metadata hash is omitted from bytecode entirely, so this script achieves FULL
  verification. For older contracts compiled without that setting, this achieves the
  best possible result (partial — metadata mismatch is cosmetic only).

USAGE:
  # Verify a single contract (no constructor args):
  python3 ops/verify_zksync_contracts.py \\
    --address 0x1234...  \\
    --contract src/swarms/FleetIdentityUpgradeable.sol:FleetIdentityUpgradeable \\
    --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification

  # Verify with constructor args:
  python3 ops/verify_zksync_contracts.py \\
    --address 0x1234...  \\
    --contract lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \\
    --constructor-args 0xabcdef... \\
    --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification

  # Verify all contracts from a broadcast JSON (batch mode):
  python3 ops/verify_zksync_contracts.py \\
    --broadcast broadcast/DeploySwarmUpgradeableZkSync.s.sol/324/run-latest.json \\
    --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification

  # Use --compiler-version and --zksolc-version to override defaults:
  python3 ops/verify_zksync_contracts.py ... --compiler-version 0.8.26 --zksolc-version v1.5.15

REQUIREMENTS:
  - Python 3.8+
  - forge (foundry-zksync) on PATH
  - No pip dependencies (stdlib only)
"""

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_SOLC = "0.8.26"
DEFAULT_ZKSOLC = "v1.5.15"

MAINNET_VERIFIER = (
    "https://zksync2-mainnet-explorer.zksync.io/contract_verification"
)
TESTNET_VERIFIER = (
    "https://explorer.sepolia.era.zksync.dev/contract_verification"
)

# Map from Solidity script contract name → source path used in verification.
# Used by --broadcast mode to map broadcast JSON entries to verifiable contracts.
# Extend this when adding new contract types to the deploy script.
CONTRACT_SOURCE_MAP = {
    "ServiceProviderUpgradeable": "src/swarms/ServiceProviderUpgradeable.sol:ServiceProviderUpgradeable",
    "FleetIdentityUpgradeable": "src/swarms/FleetIdentityUpgradeable.sol:FleetIdentityUpgradeable",
    "SwarmRegistryUniversalUpgradeable": "src/swarms/SwarmRegistryUniversalUpgradeable.sol:SwarmRegistryUniversalUpgradeable",
    "ERC1967Proxy": "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
    "BondTreasuryPaymaster": "src/paymasters/BondTreasuryPaymaster.sol:BondTreasuryPaymaster",
}


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------
def resolve_import(current_file: str, import_path: str) -> str:
    """Resolve a relative import like ../../utils/Foo.sol to an absolute project path."""
    if not import_path.startswith("."):
        return import_path
    current_dir = posixpath.dirname(current_file)
    return posixpath.normpath(posixpath.join(current_dir, import_path))


def fix_traversal_imports(std_json: dict) -> int:
    """Rewrite ../  imports in source content to resolved absolute paths.

    Returns the number of import lines rewritten.
    """
    source_keys = set(std_json["sources"].keys())
    changed = 0
    pattern = re.compile(r'(import\s+.*?["\'])(\.\./[^"\']+)(["\'].*)')

    for src_key in list(std_json["sources"].keys()):
        content = std_json["sources"][src_key]["content"]
        lines = content.split("\n")
        new_lines = []
        for line in lines:
            m = pattern.match(line)
            if m:
                prefix, rel_path, suffix = m.groups()
                abs_path = resolve_import(src_key, rel_path)
                if abs_path in source_keys:
                    new_lines.append(prefix + abs_path + suffix)
                    changed += 1
                    continue
            new_lines.append(line)
        std_json["sources"][src_key]["content"] = "\n".join(new_lines)

    return changed


def generate_standard_json(
    address: str,
    contract: str,
    constructor_args: str,
    solc_version: str,
    project_root: str,
) -> dict:
    """Run forge verify-contract --show-standard-json-input and return parsed JSON."""
    cmd = [
        "forge",
        "verify-contract",
        "--zksync",
        "--verifier",
        "zksync",
        "--show-standard-json-input",
        "--compiler-version",
        solc_version,
    ]
    if constructor_args and constructor_args != "0x":
        cmd.extend(["--constructor-args", constructor_args])
    cmd.extend([address, contract])

    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=project_root
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"forge verify-contract --show-standard-json-input failed:\n{result.stderr}"
        )
    return json.loads(result.stdout)


def submit_verification(
    verifier_url: str,
    address: str,
    contract: str,
    std_json: dict,
    constructor_args: str,
    solc_version: str,
    zksolc_version: str,
) -> str:
    """POST to ZkSync verification API. Returns verification ID."""
    payload = {
        "contractAddress": address,
        "sourceCode": std_json,
        "codeFormat": "solidity-standard-json-input",
        "contractName": contract,
        "compilerZksolcVersion": zksolc_version,
        "compilerSolcVersion": solc_version,
        "optimizationUsed": True,
        "constructorArguments": constructor_args if constructor_args else "0x",
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        verifier_url, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read().decode().strip()
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"Verification API returned {e.code}: {body}")


def check_verification_status(verifier_url: str, vid: str) -> str:
    """Poll verification status. Returns 'successful', 'failed', or 'in_progress'."""
    url = f"{verifier_url}/{vid}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())
        return data.get("status", "unknown")


def verify_one(
    address: str,
    contract: str,
    constructor_args: str,
    verifier_url: str,
    solc_version: str,
    zksolc_version: str,
    project_root: str,
    label: str = "",
) -> bool:
    """Verify a single contract. Returns True on success."""
    display = label or contract.split(":")[-1]
    print(f"  [{display}] {address}")

    # Step 1: Generate standard JSON
    print(f"    Generating standard JSON input...", end=" ", flush=True)
    std_json = generate_standard_json(
        address, contract, constructor_args, solc_version, project_root
    )
    fixes = fix_traversal_imports(std_json)
    print(f"done (rewrote {fixes} imports)")

    # Step 2: Submit
    print(f"    Submitting to verifier...", end=" ", flush=True)
    vid = submit_verification(
        verifier_url,
        address,
        contract,
        std_json,
        constructor_args,
        solc_version,
        zksolc_version,
    )
    print(f"ID: {vid}")

    # Step 3: Poll for result
    for attempt in range(12):
        time.sleep(5)
        status = check_verification_status(verifier_url, vid)
        if status == "successful":
            print(f"    ✓ Verified")
            return True
        elif status == "failed":
            print(f"    ✗ Verification failed")
            return False
        print(f"    ... {status} (attempt {attempt + 1})", flush=True)

    print(f"    ✗ Timed out waiting for verification")
    return False


# ---------------------------------------------------------------------------
# Broadcast mode: extract contracts + constructor args from forge broadcast
# ---------------------------------------------------------------------------
def parse_broadcast(broadcast_path: str) -> list:
    """Parse broadcast JSON and return list of (address, contract_name, ctor_args_hex)."""
    with open(broadcast_path) as f:
        data = json.load(f)

    results = []
    for tx in data["transactions"]:
        contract_name = tx.get("contractName", "")
        address = tx.get("contractAddress", "")
        if not address:
            additional = tx.get("additionalContracts") or []
            if additional:
                address = additional[0].get("address", "")
        if not address or not contract_name:
            continue

        # Extract constructor args from ZkSync ContractDeployer input
        inp = tx["transaction"].get("input", "")
        ctor_hex = "0x"
        if inp.startswith("0x9c4d535b"):
            payload = inp[10:]  # skip 0x + selector
            offset_hex = payload[128:192]
            offset = int(offset_hex, 16)
            ctor_start = offset * 2
            ctor_len = int(payload[ctor_start : ctor_start + 64], 16)
            if ctor_len > 0:
                ctor_hex = "0x" + payload[
                    ctor_start + 64 : ctor_start + 64 + ctor_len * 2
                ]

        source = CONTRACT_SOURCE_MAP.get(contract_name)
        if not source:
            print(
                f"  [WARNING] Unknown contract '{contract_name}' at {address} "
                f"— add it to CONTRACT_SOURCE_MAP in this script"
            )
            continue

        results.append((address, source, ctor_hex, contract_name))

    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Verify ZkSync Era contracts with full source-code matching.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # Single-contract mode
    parser.add_argument("--address", help="Contract address to verify")
    parser.add_argument(
        "--contract",
        help="Contract identifier (e.g., src/Foo.sol:Foo)",
    )
    parser.add_argument(
        "--constructor-args",
        default="0x",
        help="ABI-encoded constructor args (hex, 0x-prefixed). Default: 0x",
    )

    # Batch mode
    parser.add_argument(
        "--broadcast",
        help="Path to forge broadcast JSON for batch verification",
    )

    # Common options
    parser.add_argument(
        "--verifier-url",
        default=MAINNET_VERIFIER,
        help=f"ZkSync verification API URL. Default: mainnet",
    )
    parser.add_argument(
        "--compiler-version",
        default=DEFAULT_SOLC,
        help=f"Solc version (default: {DEFAULT_SOLC})",
    )
    parser.add_argument(
        "--zksolc-version",
        default=DEFAULT_ZKSOLC,
        help=f"zksolc version (default: {DEFAULT_ZKSOLC})",
    )
    parser.add_argument(
        "--project-root",
        default=None,
        help="Project root directory (default: auto-detect from git)",
    )

    args = parser.parse_args()

    # Determine project root
    project_root = args.project_root
    if not project_root:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            project_root = result.stdout.strip()
        else:
            project_root = os.getcwd()

    # Validate mode
    if not args.broadcast and not (args.address and args.contract):
        parser.error(
            "Either --broadcast or both --address and --contract are required"
        )

    print(f"ZkSync Contract Verification")
    print(f"  Verifier: {args.verifier_url}")
    print(f"  Solc: {args.compiler_version}  zksolc: {args.zksolc_version}")
    print(f"  Project: {project_root}")
    print()

    if args.broadcast:
        # Batch mode
        contracts = parse_broadcast(
            os.path.join(project_root, args.broadcast)
            if not os.path.isabs(args.broadcast)
            else args.broadcast
        )
        print(f"Found {len(contracts)} contracts in broadcast\n")

        success = 0
        failed = 0
        for address, source, ctor, name in contracts:
            try:
                ok = verify_one(
                    address=address,
                    contract=source,
                    constructor_args=ctor,
                    verifier_url=args.verifier_url,
                    solc_version=args.compiler_version,
                    zksolc_version=args.zksolc_version,
                    project_root=project_root,
                    label=name,
                )
                if ok:
                    success += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"    ✗ Error: {e}")
                failed += 1

        print(f"\n{'='*50}")
        print(f"Results: {success} verified, {failed} failed")
        sys.exit(1 if failed > 0 else 0)

    else:
        # Single contract mode
        try:
            ok = verify_one(
                address=args.address,
                contract=args.contract,
                constructor_args=args.constructor_args,
                verifier_url=args.verifier_url,
                solc_version=args.compiler_version,
                zksolc_version=args.zksolc_version,
                project_root=project_root,
            )
            sys.exit(0 if ok else 1)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
