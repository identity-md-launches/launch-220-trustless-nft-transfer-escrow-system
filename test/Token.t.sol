// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {NFTSwap} from "../src/NFTSwap.sol";

contract TokenTest is Test {
    Token internal token;

    function setUp() public {
        token = new Token();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Pairwise");
        assertEq(token.symbol(), "PAIR");
    }

    function testFuzz_transferConserves(uint96 raw) public {
        uint256 amount = bound(raw, 0, 1e27);
        token.transfer(address(7), amount);
        assertEq(token.balanceOf(address(7)), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(7)), 1e27);
        token.transfer(address(this), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndInfiniteApproval() public {
        token.approve(address(7), 100);
        vm.prank(address(7));
        token.transferFrom(address(this), address(8), 100);
        assertEq(token.allowance(address(this), address(7)), 0);
        assertEq(token.balanceOf(address(8)), 100);
        token.approve(address(7), type(uint256).max);
        vm.prank(address(7));
        token.transferFrom(address(this), address(8), 3);
        assertEq(token.allowance(address(this), address(7)), type(uint256).max);
    }

    function test_invalidTransfersAndApprovals() public {
        vm.expectRevert(Token.InvalidAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(Token.InvalidAddress.selector);
        token.approve(address(0), 1);
        vm.expectRevert(Token.InsufficientBalance.selector);
        token.transfer(address(7), 1e27 + 1);
        vm.expectRevert(Token.InsufficientAllowance.selector);
        token.transferFrom(address(7), address(8), 1);
    }

    function test_selfTransferDoesNotMint() public {
        token.transfer(address(this), 100);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_adminSelectorsCannotMintEvenForDeployer() public {
        bytes[5] memory data = [
            abi.encodeWithSignature("mint(address,uint256)", address(7), 1),
            abi.encodeWithSignature("mint(uint256)", 1),
            abi.encodeWithSignature("initialize(address)", address(7)),
            abi.encodeWithSignature("upgradeTo(address)", address(7)),
            abi.encodeWithSignature("transferOwnership(address)", address(7))
        ];
        for (uint256 i; i < data.length; ++i) {
            (bool ok,) = address(token).call(data[i]);
            assertFalse(ok);
            vm.prank(address(7));
            (ok,) = address(token).call(data[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(7)), 0);
    }

    function test_factoryConstructionSupplyAndRuntimeFloor() public {
        address factory = address(0xFAC);
        vm.startPrank(factory);
        Token launch = new Token();
        NFTSwap app = new NFTSwap();
        vm.stopPrank();
        assertEq(launch.balanceOf(factory), 1e27);
        assertEq(launch.totalSupply(), 1e27);
        checkRuntime(address(launch));
        checkRuntime(address(app));
    }

    function checkRuntime(address target) internal view {
        bytes memory runtime = target.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
