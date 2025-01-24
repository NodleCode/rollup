// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BaseContentSign} from "../../src/contentsign/BaseContentSign.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PaymentMiddleware} from "../../src/contentsign/PaymentMiddleware.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockWhitelist is ERC721 {
    constructor() ERC721("Mock Whitelist", "MWL") {}

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}

contract MockContentSign is BaseContentSign {
    constructor() BaseContentSign("Mock", "MOCK") {}

    function _userIsWhitelisted(address) internal pure override returns (bool) {
        return true;
    }
}

contract PaymentMiddlewareTest is Test {
    PaymentMiddleware private middleware;
    MockContentSign private target;
    MockWhitelist private whitelist;
    MockToken private feeToken;

    address internal admin = vm.addr(1);
    address internal alice = vm.addr(2);
    address internal bob = vm.addr(3);

    uint256 internal constant FEE_AMOUNT = 100 ether;

    error UserNotWhitelisted(address user);

    event Minted(address indexed minter, uint256 clickId);

    function setUp() public {
        target = new MockContentSign();
        whitelist = new MockWhitelist();
        feeToken = new MockToken();

        middleware = new PaymentMiddleware(target, whitelist, feeToken, FEE_AMOUNT, admin);

        // Setup test state
        feeToken.mint(alice, 1000 ether);
        whitelist.mint(alice, 1);

        vm.prank(alice);
        feeToken.approve(address(middleware), type(uint256).max);
    }

    function test_initialization() public view {
        assertEq(address(middleware.target()), address(target));
        assertEq(address(middleware.whitelist()), address(whitelist));
        assertEq(address(middleware.feeToken()), address(feeToken));
        assertEq(middleware.feeAmount(), FEE_AMOUNT);
        assertEq(middleware.owner(), admin);
        assertEq(whitelist.balanceOf(alice), 1);
    }

    function test_safeMint_succeeds() public {
        vm.prank(alice);

        vm.expectEmit(true, true, true, true);
        emit Minted(alice, 0);

        middleware.safeMint(alice, "test-uri");

        assertEq(target.ownerOf(0), alice);
        assertEq(target.tokenURI(0), "test-uri");
        assertEq(feeToken.balanceOf(address(middleware)), FEE_AMOUNT);
    }

    function test_safeMint_failsIfNotWhitelisted() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(UserNotWhitelisted.selector, bob));
        middleware.safeMint(bob, "test-uri");
    }

    function test_safeMint_failsIfInsufficientAllowance() public {
        vm.startPrank(alice);
        feeToken.approve(address(middleware), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(middleware), 0, FEE_AMOUNT)
        );
        middleware.safeMint(alice, "test-uri");
        vm.stopPrank();
    }

    function test_safeMint_failsIfInsufficientBalance() public {
        vm.startPrank(alice);
        feeToken.transfer(bob, feeToken.balanceOf(alice));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, FEE_AMOUNT));
        middleware.safeMint(alice, "test-uri");
        vm.stopPrank();
    }

    function test_withdraw() public {
        // First mint to collect some fees
        vm.prank(alice);
        middleware.safeMint(alice, "test-uri");

        uint256 initialBalance = feeToken.balanceOf(admin);

        vm.prank(admin);
        middleware.withdraw(feeToken);

        assertEq(feeToken.balanceOf(admin), initialBalance + FEE_AMOUNT);
        assertEq(feeToken.balanceOf(address(middleware)), 0);
    }

    function test_withdraw_failsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        middleware.withdraw(feeToken);
    }

    function test_withdraw_anyToken() public {
        // Setup a different token
        MockToken otherToken = new MockToken();
        otherToken.mint(address(middleware), 1000 ether);

        uint256 initialBalance = otherToken.balanceOf(admin);

        vm.prank(admin);
        middleware.withdraw(otherToken);

        assertEq(otherToken.balanceOf(admin), initialBalance + 1000 ether);
        assertEq(otherToken.balanceOf(address(middleware)), 0);
    }

    function test_setFeeAmount() public {
        uint256 newFee = 200 ether;

        vm.prank(admin);
        middleware.setFeeAmount(newFee);

        assertEq(middleware.feeAmount(), newFee);
    }

    function test_setFeeAmount_failsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        middleware.setFeeAmount(200 ether);
    }

    function test_setTarget() public {
        MockContentSign newTarget = new MockContentSign();

        vm.prank(admin);
        middleware.setTarget(newTarget);

        assertEq(address(middleware.target()), address(newTarget));
    }

    function test_setTarget_failsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        middleware.setTarget(target);
    }

    function test_setWhitelist() public {
        MockWhitelist newWhitelist = new MockWhitelist();

        vm.prank(admin);
        middleware.setWhitelist(newWhitelist);

        assertEq(address(middleware.whitelist()), address(newWhitelist));
    }

    function test_setWhitelist_failsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        middleware.setWhitelist(whitelist);
    }

    function test_setFeeToken() public {
        MockToken newToken = new MockToken();

        vm.prank(admin);
        middleware.setFeeToken(newToken);

        assertEq(address(middleware.feeToken()), address(newToken));
    }

    function test_setFeeToken_failsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        middleware.setFeeToken(feeToken);
    }
}
