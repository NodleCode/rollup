#!/usr/bin/env python3
"""
verify_hardhat_zksync.py — Source-code verification for Hardhat-compiled ZkSync contracts.

PROBLEM:
  The @matterlabs/hardhat-zksync-verify plugin has a bug (HH700: artifact not found
  for @openzeppelin/contracts-hardhat-zksync-upgradable) that prevents automatic
  verification. Manual submission via the ZkSync verification API works, but requires
  filtering the standard JSON to only include sources in the contract's dependency
  graph — otherwise unrelated compilation errors (e.g., Grants.sol) cause the
  verifier to reject the submission.

SOLUTION:
  This script reads Hardhat's build-info JSON (artifacts-zk/build-info/*.json),
  performs a BFS from the target contract to find all transitive imports, builds a
  filtered standard JSON input, and submits it to the ZkSync verification API.

USAGE:
  # Verify a single contract:
  python3 ops/verify_hardhat_zksync.py \\
    --address 0xff735c70f33ca4eF1768F527B5f230b76A61A89b \\
    --contract src/envelope/EnvelopeLinks.sol:EnvelopeLinks \\
    --constructor-args "$(cast abi-encode 'constructor(address,address,address)' 0xAddr1 0xAddr2 0xAddr3)"

  # Verify multiple contracts:
  python3 ops/verify_hardhat_zksync.py \\
    --address 0xABC... --contract src/A.sol:A --constructor-args 0x... \\
    --address 0xDEF... --contract src/B.sol:B --constructor-args 0x...

  # Override compiler versions (defaults from build-info):
  python3 ops/verify_hardhat_zksync.py ... --zksolc-version v1.5.1 --solc-version 0.8.26

  # Specify verifier URL (defaults to mainnet):
  python3 ops/verify_hardhat_zksync.py ... --verifier-url https://explorer.sepolia.era.zksync.dev/contract_verification

REQUIREMENTS:
  - Python 3.8+
  - Hardhat must have been compiled with `npx hardhat compile` first
  - No pip dependencies (stdlib only)
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import deque
from pathlib import Path

# Default verifier URLs
MAINNET_VERIFIER = "https://zksync2-mainnet-explorer.zksync.io/contract_verification"
TESTNET_VERIFIER = "https://explorer.sepolia.era.zksync.dev/contract_verification"


def find_build_info(project_root: str) -> str:
    """Find the most recent build-info JSON file."""
    build_info_dir = os.path.join(project_root, "artifacts-zk", "build-info")
    if not os.path.isdir(build_info_dir):
        print(f"ERROR: Build info directory not found: {build_info_dir}", file=sys.stderr)
        print("Run 'npx hardhat compile' first.", file=sys.stderr)
        sys.exit(1)

    json_files = sorted(
        Path(build_info_dir).glob("*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not json_files:
        print(f"ERROR: No JSON files in {build_info_dir}", file=sys.stderr)
        sys.exit(1)

    return str(json_files[0])


def load_build_info(path: str) -> dict:
    """Load and parse a build-info JSON file."""
    print(f"Loading build-info: {os.path.basename(path)}")
    with open(path) as f:
        return json.load(f)


def find_transitive_imports(sources: dict, entry_file: str) -> set:
    """
    BFS from entry_file to find all transitive imports.

    Uses re.DOTALL to handle multi-line import statements like:
        import {
            IPaymaster,
            ExecutionResult
        } from "lib/era-contracts/...";
    """
    needed = set()
    queue = deque([entry_file])

    while queue:
        src_path = queue.popleft()
        if src_path in needed:
            continue
        needed.add(src_path)

        content = sources.get(src_path, {}).get("content", "")
        # Match import paths from both single-line and multi-line imports
        imports = re.findall(r'import\s+[^;]*?["\']([^"\']+)["\']', content, re.DOTALL)

        for imp in imports:
            # Try the import path directly (Hardhat stores @openzeppelin/... paths as-is)
            if imp in sources and imp not in needed:
                queue.append(imp)
            else:
                # Try relative resolution
                base = os.path.dirname(src_path)
                resolved = os.path.normpath(os.path.join(base, imp))
                if resolved in sources and resolved not in needed:
                    queue.append(resolved)

    return needed


def build_filtered_input(build_info: dict, source_file: str) -> dict:
    """Build a filtered standard JSON input with only the needed sources."""
    sources = build_info["input"]["sources"]

    if source_file not in sources:
        print(f"ERROR: Source file '{source_file}' not found in build-info.", file=sys.stderr)
        print(f"Available sources containing similar name:", file=sys.stderr)
        basename = os.path.basename(source_file)
        for k in sorted(sources.keys()):
            if basename in k:
                print(f"  {k}", file=sys.stderr)
        sys.exit(1)

    needed = find_transitive_imports(sources, source_file)
    print(f"  Found {len(needed)} source files in dependency graph")

    return {
        "language": build_info["input"]["language"],
        "sources": {k: v for k, v in sources.items() if k in needed},
        "settings": build_info["input"]["settings"],
    }


def extract_compiler_versions(build_info: dict) -> tuple:
    """Extract zksolc and solc versions from build-info."""
    # solcVersion in Hardhat build-info is like "zkVM-0.8.26-1.0.1"
    solc_version_raw = build_info.get("solcVersion", "")
    # Extract the solc semver (e.g., "0.8.26" from "zkVM-0.8.26-1.0.1")
    match = re.search(r"(\d+\.\d+\.\d+)", solc_version_raw)
    solc_version = match.group(1) if match else "0.8.26"

    # zksolc version from settings or default
    zksolc_version = build_info.get("zksolcVersion")
    if not zksolc_version:
        # Try to find it in the output compiler metadata
        settings = build_info.get("input", {}).get("settings", {})
        zksolc_version = "v1.5.1"  # Hardhat default

    if not zksolc_version.startswith("v"):
        zksolc_version = f"v{zksolc_version}"

    return zksolc_version, solc_version


def submit_verification(
    verifier_url: str,
    address: str,
    contract_name: str,
    source_code: dict,
    constructor_args: str,
    zksolc_version: str,
    solc_version: str,
) -> int:
    """Submit a verification request to the ZkSync API. Returns the verification ID."""
    payload = {
        "contractAddress": address,
        "sourceCode": source_code,
        "codeFormat": "solidity-standard-json-input",
        "contractName": contract_name,
        "compilerZksolcVersion": zksolc_version,
        "compilerSolcVersion": solc_version,
        "constructorArguments": constructor_args,
        "optimizationUsed": True,
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        verifier_url,
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        resp = urllib.request.urlopen(req)
        verification_id = int(resp.read().decode().strip())
        return verification_id
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()[:500]
        print(f"  ERROR: HTTP {e.code}", file=sys.stderr)
        print(f"  Response: {error_body}", file=sys.stderr)
        sys.exit(1)


def poll_verification(verifier_url: str, verification_id: int, timeout: int = 120) -> str:
    """Poll for verification result. Returns 'successful', 'failed', or raises on timeout."""
    url = f"{verifier_url}/{verification_id}"
    start = time.time()

    while time.time() - start < timeout:
        time.sleep(5)
        try:
            resp = urllib.request.urlopen(url)
            result = json.loads(resp.read().decode())
            status = result.get("status", "")

            if status == "successful":
                return "successful"
            elif status == "failed":
                error = result.get("error", "unknown")
                errors = result.get("compilationErrors", [])
                print(f"  FAILED: {error}", file=sys.stderr)
                for err in errors[:3]:
                    # Trim long error messages
                    print(f"    {err[:200]}", file=sys.stderr)
                return "failed"
            # else: still in progress
            print(f"  Status: {status} (waiting...)")
        except urllib.error.HTTPError:
            pass

    print(f"  TIMEOUT after {timeout}s", file=sys.stderr)
    return "timeout"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Verify Hardhat-compiled contracts on ZkSync Era"
    )
    parser.add_argument(
        "--address",
        action="append",
        required=True,
        help="Contract address to verify (can be repeated for multiple contracts)",
    )
    parser.add_argument(
        "--contract",
        action="append",
        required=True,
        help="Contract identifier as 'path:Name' (can be repeated, matches --address order)",
    )
    parser.add_argument(
        "--constructor-args",
        action="append",
        default=[],
        help="ABI-encoded constructor args with 0x prefix (can be repeated, matches --address order)",
    )
    parser.add_argument(
        "--verifier-url",
        default=MAINNET_VERIFIER,
        help=f"ZkSync verifier API URL (default: {MAINNET_VERIFIER})",
    )
    parser.add_argument(
        "--zksolc-version",
        default=None,
        help="Override zksolc version (default: auto-detect from build-info)",
    )
    parser.add_argument(
        "--solc-version",
        default=None,
        help="Override solc version (default: auto-detect from build-info)",
    )
    parser.add_argument(
        "--build-info",
        default=None,
        help="Path to build-info JSON (default: most recent in artifacts-zk/build-info/)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Timeout in seconds for polling verification status (default: 120)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Validate matching counts
    if len(args.address) != len(args.contract):
        print("ERROR: --address and --contract must be specified the same number of times", file=sys.stderr)
        sys.exit(1)

    # Pad constructor-args with empty strings if fewer provided
    constructor_args_list = args.constructor_args + ["0x"] * (len(args.address) - len(args.constructor_args))

    # Find project root (script is in ops/)
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(project_root)

    # Load build info
    build_info_path = args.build_info or find_build_info(project_root)
    build_info = load_build_info(build_info_path)

    # Determine compiler versions
    zksolc_version, solc_version = extract_compiler_versions(build_info)
    if args.zksolc_version:
        zksolc_version = args.zksolc_version
    if args.solc_version:
        solc_version = args.solc_version

    print(f"Compiler: zksolc {zksolc_version}, solc {solc_version}")
    print(f"Verifier: {args.verifier_url}")
    print()

    # Process each contract
    results = []
    for i, (address, contract, ctor_args) in enumerate(
        zip(args.address, args.contract, constructor_args_list)
    ):
        source_file, contract_name = contract.split(":")
        print(f"[{i+1}/{len(args.address)}] Verifying {contract_name} at {address}")
        print(f"  Source: {source_file}")
        print(f"  Constructor args: {ctor_args[:20]}{'...' if len(ctor_args) > 20 else ''}")

        # Build filtered standard JSON
        filtered_input = build_filtered_input(build_info, source_file)

        # Ensure constructor args have 0x prefix
        if not ctor_args.startswith("0x"):
            ctor_args = "0x" + ctor_args

        # Submit
        print(f"  Submitting to verifier...")
        verification_id = submit_verification(
            args.verifier_url,
            address,
            contract,
            filtered_input,
            ctor_args,
            zksolc_version,
            solc_version,
        )
        print(f"  Verification ID: {verification_id}")

        # Poll for result
        status = poll_verification(args.verifier_url, verification_id, args.timeout)
        results.append((contract_name, address, verification_id, status))

        if status == "successful":
            print(f"  ✓ VERIFIED")
        else:
            print(f"  ✗ {status.upper()}")
        print()

    # Summary
    print("=" * 60)
    print("VERIFICATION SUMMARY")
    print("=" * 60)
    all_ok = True
    for name, addr, vid, status in results:
        icon = "✓" if status == "successful" else "✗"
        print(f"  {icon} {name}: {addr} (ID: {vid}, {status})")
        if status != "successful":
            all_ok = False
    print()

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
