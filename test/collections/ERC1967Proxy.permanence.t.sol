// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UserCollection721} from "../../src/collections/UserCollection721.sol";

/// @notice Bytecode-permanence proof for canonical OZ ERC1967Proxy.
///         Codifies design §3.5.2 (1): no SELFDESTRUCT, no caller-controlled
///         delegatecall. Defense-in-depth audit gate.
contract ERC1967ProxyPermanenceTest is Test {
    /// @dev Deploy a real ERC1967Proxy and read its runtime bytecode.
    ///      Empty initData skips the constructor delegatecall — we just want
    ///      the deployed runtime, not a working instance.
    function _runtime() internal returns (bytes memory) {
        // Use any non-zero implementation; the runtime is the same regardless.
        ERC1967Proxy p = new ERC1967Proxy(address(this), "");
        return address(p).code;
    }

    function test_runtimeContainsNoSelfdestruct() public {
        bytes memory code = _runtime();
        require(code.length > 0, "no runtime");

        for (uint256 i = 0; i < code.length; ) {
            uint8 op = uint8(code[i]);

            // PUSH1..PUSH32 — skip the immediate bytes (op 0x60..0x7f).
            if (op >= 0x60 && op <= 0x7f) {
                uint256 imm = uint256(op) - 0x5f;
                i += 1 + imm;
                continue;
            }

            // SELFDESTRUCT (0xff) is the EVM mnemonic; canonical OZ
            // ERC1967Proxy must not contain it.
            assertTrue(op != 0xff, "ERC1967Proxy contains SELFDESTRUCT");

            i += 1;
        }
    }

    function test_proxyImplementationDelegatecallTargetIsConstructorFixed() public {
        // The only delegatecall in ERC1967Proxy's runtime targets _implementation()
        // which reads from the EIP-1967 slot. The slot is written exclusively by
        // ERC1967Utils.upgradeToAndCall (called only from the proxy's own
        // constructor since the impl does not inherit UUPSUpgradeable). Back the
        // proxy with the real shipped implementation so this exercises the
        // deployed system: deploy, assert the EIP-1967 slot equals that impl,
        // then attempt a real upgrade call and assert the slot cannot change.
        address impl = address(new UserCollection721());
        ERC1967Proxy p = new ERC1967Proxy(impl, "");

        bytes32 IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 stored = vm.load(address(p), IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), impl, "EIP-1967 slot mismatch");

        // A real (state-changing) call — a staticcall could never write the
        // slot regardless of the proxy's behavior, so it would prove nothing.
        // Against an upgradeable proxy this call would succeed and rewrite the
        // slot; here it must revert (the impl exposes no upgradeToAndCall
        // selector) and leave the slot untouched.
        bytes memory upgradeCall = abi.encodeWithSelector(
            0x4f1ef286, address(0xdeadbeef), bytes("")
        );
        (bool ok, ) = address(p).call(upgradeCall);
        assertFalse(ok, "upgradeToAndCall unexpectedly succeeded");
        bytes32 storedAfter = vm.load(address(p), IMPL_SLOT);
        assertEq(stored, storedAfter, "EIP-1967 slot was mutated");
    }
}
