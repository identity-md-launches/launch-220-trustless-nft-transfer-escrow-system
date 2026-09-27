// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NFTSwap} from "../src/NFTSwap.sol";
import {Mock721, Mock20} from "./mocks/Assets.sol";

contract Receiver {
    NFTSwap public swap;
    bool public reject;
    uint256 public blockedCalls;
    bytes[] private attacks;

    constructor(NFTSwap target) {
        swap = target;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function addAttack(bytes calldata data) external {
        attacks.push(data);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
        return result;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!reject, "reject");
        for (uint256 i; i < attacks.length; ++i) {
            (bool ok, bytes memory reason) = address(swap).call(attacks[i]);
            require(!ok && bytes4(reason) == NFTSwap.Reentrancy.selector, "unguarded callback");
            ++blockedCalls;
        }
        return 0x150b7a02;
    }
}

contract NFTSwapTest is Test {
    NFTSwap internal swap;
    Mock721 internal nft;
    Mock721 internal otherNFT;
    Mock20 internal coin;
    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal outsider = address(0xBAD);
    NFTSwap.Asset[] internal offered;
    NFTSwap.Asset[] internal requested;

    function setUp() public {
        vm.warp(10_000);
        swap = new NFTSwap();
        nft = new Mock721();
        otherNFT = new Mock721();
        coin = new Mock20();
        nft.mint(maker, 0);
        nft.mint(maker, 1);
        otherNFT.mint(taker, 77);
        coin.mint(taker, 1_000_000);
        vm.prank(maker);
        nft.setApprovalForAll(address(swap), true);
        vm.startPrank(taker);
        coin.approve(address(swap), type(uint256).max);
        otherNFT.setApprovalForAll(address(swap), true);
        vm.stopPrank();
        offered.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(nft), 0, 1));
        requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC20, address(coin), 0, 100));
    }

    function create() internal returns (uint256 id) {
        vm.prank(maker);
        id = swap.createOffer(taker, offered, requested);
    }

    function fill(uint256 id) internal {
        vm.prank(taker);
        swap.fillOffer(id, offered, requested);
    }

    function cancel(uint256 id) internal {
        vm.prank(maker);
        swap.cancelOffer(id, offered, requested);
    }

    function status(uint256 id) internal view returns (NFTSwap.Status s) {
        (,, s,,) = swap.offers(id);
    }

    function expectFillError(uint256 id, bytes4 error_) internal {
        vm.expectRevert(error_);
        vm.prank(taker);
        swap.fillOffer(id, offered, requested);
    }

    function test_escrowsThenSettlesExactERC20() public {
        uint256 id = create();
        assertEq(nft.ownerOf(0), address(swap));
        (address m, uint64 expiry, NFTSwap.Status s, address t, bytes32 hash) = swap.offers(id);
        assertEq(m, maker);
        assertEq(t, taker);
        assertEq(expiry, 11_800);
        assertEq(uint256(s), uint256(NFTSwap.Status.Open));
        assertEq(hash, swap.hashTerms(offered, requested));
        fill(id);
        assertEq(nft.ownerOf(0), taker);
        assertEq(coin.balanceOf(maker), 100);
        assertEq(coin.balanceOf(taker), 999_900);
        assertEq(coin.balanceOf(address(swap)), 0);
        assertEq(uint256(status(id)), uint256(NFTSwap.Status.Filled));
    }

    function test_mixedBasketAndSeveralNFTs() public {
        offered.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(nft), 1, 1));
        requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(otherNFT), 77, 1));
        fill(create());
        assertEq(nft.ownerOf(0), taker);
        assertEq(nft.ownerOf(1), taker);
        assertEq(otherNFT.ownerOf(77), maker);
        assertEq(coin.balanceOf(maker), 100);
    }

    function test_nftForNFT() public {
        requested[0] = NFTSwap.Asset(NFTSwap.Kind.ERC721, address(otherNFT), 77, 1);
        fill(create());
        assertEq(otherNFT.ownerOf(77), maker);
        assertEq(nft.ownerOf(0), taker);
    }

    function test_outsiderCannotFillCancelOrStealApprovedNFT() public {
        uint256 id = create();
        vm.startPrank(outsider);
        vm.expectRevert(NFTSwap.NotTaker.selector);
        swap.fillOffer(id, offered, requested);
        vm.expectRevert(NFTSwap.NotMaker.selector);
        swap.cancelOffer(id, offered, requested);
        offered[0].id = 1;
        vm.expectRevert(NFTSwap.WrongOwner.selector);
        swap.createOffer(taker, offered, requested);
        vm.stopPrank();
        assertEq(nft.ownerOf(0), address(swap));
        assertEq(nft.ownerOf(1), maker);
        assertEq(swap.nextOfferId(), 2);
    }

    function test_rejectsMissingAdditionalReorderedAndChangedTerms() public {
        requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(otherNFT), 77, 1));
        uint256 id = create();
        requested[0].amount = 99;
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        requested[0].amount = 100;
        NFTSwap.Asset memory saved = requested[1];
        requested.pop();
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        requested.push(saved);
        requested.push(saved);
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        requested.pop();
        requested[1] = requested[0];
        requested[0] = saved;
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        saved = requested[0];
        requested[0] = requested[1];
        requested[1] = saved;
        offered[0].id = 1;
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        offered[0].id = 0;
        requested[0].token = address(otherNFT);
        expectFillError(id, NFTSwap.TermsMismatch.selector);
        assertEq(coin.balanceOf(maker), 0);
        assertEq(nft.ownerOf(0), address(swap));
    }

    function test_deadlineExclusiveAndRefundAfterExpiry() public {
        uint256 id = create();
        vm.warp(11_800);
        expectFillError(id, NFTSwap.Expired.selector);
        assertEq(nft.ownerOf(0), address(swap));
        cancel(id);
        assertEq(nft.ownerOf(0), maker);
    }

    function test_canFillOneSecondBeforeExpiry() public {
        uint256 id = create();
        vm.warp(11_799);
        fill(id);
    }

    function test_lateMatchingTransactionNeverReactivates() public {
        uint256 id = create();
        vm.warp(100_000);
        expectFillError(id, NFTSwap.Expired.selector);
    }

    function test_cancelBeforeExpiryAndNoReplay() public {
        uint256 id = create();
        cancel(id);
        assertEq(nft.ownerOf(0), maker);
        expectFillError(id, NFTSwap.NotOpen.selector);
        vm.expectRevert(NFTSwap.NotOpen.selector);
        cancel(id);
    }

    function test_fillCannotReplayOrRefund() public {
        uint256 id = create();
        fill(id);
        expectFillError(id, NFTSwap.NotOpen.selector);
        vm.expectRevert(NFTSwap.NotOpen.selector);
        cancel(id);
    }

    function test_cancelCannotSubstituteCollateral() public {
        uint256 id = create();
        offered[0].id = 1;
        vm.expectRevert(NFTSwap.TermsMismatch.selector);
        cancel(id);
        assertEq(nft.ownerOf(0), address(swap));
    }

    function test_missingOffer() public {
        expectFillError(99, NFTSwap.NotOpen.selector);
    }

    function test_uniqueIdsAndIndependentOffers() public {
        uint256 first = create();
        offered[0].id = 1;
        uint256 second = create();
        assertEq(second, first + 1);
        cancel(second);
        offered[0].id = 0;
        fill(first);
        assertEq(nft.ownerOf(1), maker);
        assertEq(nft.ownerOf(0), taker);
    }

    function test_duplicateCollateralCannotBeEscrowedTwice() public {
        create();
        vm.expectRevert(NFTSwap.WrongOwner.selector);
        create();
    }

    function test_zeroSelfAndEscrowCounterpartyRejected() public {
        vm.startPrank(maker);
        vm.expectRevert(NFTSwap.InvalidCounterparty.selector);
        swap.createOffer(address(0), offered, requested);
        vm.expectRevert(NFTSwap.InvalidCounterparty.selector);
        swap.createOffer(maker, offered, requested);
        vm.expectRevert(NFTSwap.InvalidCounterparty.selector);
        swap.createOffer(address(swap), offered, requested);
        vm.stopPrank();
    }

    function test_invalidAssetFieldsAndEOA() public {
        offered[0].amount = 2;
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
        offered[0].amount = 1;
        requested[0].amount = 0;
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
        requested[0].amount = 100;
        requested[0].id = 1;
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
        requested[0].id = 0;
        requested[0].token = outsider;
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
        requested[0].token = address(coin);
        offered[0] = requested[0];
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
    }

    function test_emptyAndOversizeBaskets() public {
        requested.pop();
        vm.expectRevert(NFTSwap.InvalidBasketSize.selector);
        create();
        for (uint256 i; i < 17; ++i) {
            requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC20, address(coin), 0, i + 1));
        }
        vm.expectRevert(NFTSwap.InvalidBasketSize.selector);
        create();
        while (requested.length > 1) requested.pop();
        offered.pop();
        vm.expectRevert(NFTSwap.InvalidBasketSize.selector);
        create();
    }

    function test_rejectsERC721MasqueradingAsCurrency() public {
        // An honest ERC-721 has ERC-20's balanceOf and transferFrom selectors, with
        // an empty transfer return. It must not be interpreted as a fungible token.
        requested[0] = NFTSwap.Asset(NFTSwap.Kind.ERC20, address(otherNFT), 0, 1);
        otherNFT.mint(taker, 1);
        vm.expectRevert(NFTSwap.InvalidAsset.selector);
        create();
        assertEq(otherNFT.ownerOf(1), taker);
        assertEq(nft.ownerOf(0), maker);
    }

    function test_duplicateNFTERC20AndCrossBasketRejected() public {
        offered.push(offered[0]);
        vm.expectRevert(NFTSwap.DuplicateAsset.selector);
        create();
        offered.pop();
        requested.push(requested[0]);
        vm.expectRevert(NFTSwap.DuplicateAsset.selector);
        create();
        requested.pop();
        requested[0] = offered[0];
        vm.expectRevert(NFTSwap.DuplicateAsset.selector);
        create();
    }

    function test_failedApprovalAndFakeTransferRollbackCreation() public {
        vm.prank(maker);
        nft.setApprovalForAll(address(swap), false);
        vm.expectRevert("approval");
        create();
        assertEq(swap.nextOfferId(), 1);
        assertEq(nft.ownerOf(0), maker);
        vm.prank(maker);
        nft.setApprovalForAll(address(swap), true);
        nft.setFailure(true, false);
        vm.expectRevert(NFTSwap.WrongOwner.selector);
        create();
        assertEq(swap.nextOfferId(), 1);
    }

    function test_missingPaymentApprovalRollsBackAndCanRetry() public {
        uint256 id = create();
        vm.prank(taker);
        coin.approve(address(swap), 0);
        expectFillError(id, NFTSwap.TokenTransferFailed.selector);
        assertEq(uint256(status(id)), uint256(NFTSwap.Status.Open));
        assertEq(nft.ownerOf(0), address(swap));
        assertEq(coin.balanceOf(maker), 0);
        vm.prank(taker);
        coin.approve(address(swap), 100);
        fill(id);
    }

    function test_falseMalformedFeeBonusTokensRollback() public {
        uint256 id = create();
        for (uint8 mode = 1; mode <= 6; ++mode) {
            if (mode == 2) continue;
            coin.setMode(mode);
            expectFillError(
                id, mode == 1 || mode == 6 ? NFTSwap.TokenTransferFailed.selector : NFTSwap.InexactPayment.selector
            );
            assertEq(coin.balanceOf(taker), 1_000_000);
            assertEq(coin.balanceOf(maker), 0);
            assertEq(nft.ownerOf(0), address(swap));
        }
        coin.setMode(0);
        fill(id);
    }

    function test_noReturnERC20Supported() public {
        coin.setMode(2);
        fill(create());
        assertEq(coin.balanceOf(maker), 100);
    }

    function test_lateNFTTransferFailureRollsBackPaymentAndStatus() public {
        requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(otherNFT), 77, 1));
        uint256 id = create();
        nft.setFailure(false, true);
        vm.expectRevert("blocked");
        fill(id);
        assertEq(coin.balanceOf(maker), 0);
        assertEq(coin.balanceOf(taker), 1_000_000);
        assertEq(uint256(status(id)), uint256(NFTSwap.Status.Open));
        assertEq(otherNFT.ownerOf(77), taker);
        nft.setFailure(false, false);
        fill(id);
    }

    function test_nativeCurrencyAndDirectSafeDepositsRejected() public {
        uint256 id = create();
        vm.deal(taker, 1 ether);
        vm.prank(taker);
        (bool ok,) = address(swap).call{value: 1}(abi.encodeCall(swap.fillOffer, (id, offered, requested)));
        assertFalse(ok);
        assertEq(address(swap).balance, 0);
        vm.prank(maker);
        vm.expectRevert();
        nft.safeTransferFrom(maker, address(swap), 1);
        assertEq(nft.ownerOf(1), maker);
    }

    function test_erc20CallbackCannotReenter() public {
        uint256 id = create();
        coin.setCallback(address(swap), abi.encodeCall(swap.fillOffer, (id, offered, requested)));
        fill(id);
        assertTrue(coin.callbackRejected());
    }

    function test_receiverReentrancyAllEntryPointsBlocked() public {
        Receiver receiver = new Receiver(swap);
        taker = address(receiver);
        coin.mint(taker, 100);
        receiver.execute(address(coin), abi.encodeCall(coin.approve, (address(swap), 100)));
        uint256 id = create();
        receiver.addAttack(abi.encodeCall(swap.fillOffer, (id, offered, requested)));
        receiver.addAttack(abi.encodeCall(swap.cancelOffer, (id, offered, requested)));
        receiver.addAttack(abi.encodeCall(swap.createOffer, (maker, offered, requested)));
        receiver.execute(address(swap), abi.encodeCall(swap.fillOffer, (id, offered, requested)));
        assertEq(receiver.blockedCalls(), 3);
        assertEq(nft.ownerOf(0), taker);
    }

    function test_rejectingReceiverCannotBlockRefundOrOtherOffer() public {
        Receiver receiver = new Receiver(swap);
        receiver.setReject(true);
        address normalTaker = taker;
        taker = address(receiver);
        coin.mint(taker, 100);
        receiver.execute(address(coin), abi.encodeCall(coin.approve, (address(swap), 100)));
        uint256 id = create();
        vm.expectRevert("reject");
        receiver.execute(address(swap), abi.encodeCall(swap.fillOffer, (id, offered, requested)));
        assertEq(coin.balanceOf(maker), 0);
        cancel(id);
        assertEq(nft.ownerOf(0), maker);
        taker = normalTaker;
        fill(create());
    }

    function test_contractMakerCanRefundWithoutReceivingCallback() public {
        Receiver wallet = new Receiver(swap);
        wallet.setReject(true);
        nft.mint(address(wallet), 5);
        offered[0].id = 5;
        wallet.execute(address(nft), abi.encodeCall(nft.approve, (address(swap), 5)));
        bytes memory result =
            wallet.execute(address(swap), abi.encodeCall(swap.createOffer, (taker, offered, requested)));
        uint256 id = abi.decode(result, (uint256));
        wallet.execute(address(swap), abi.encodeCall(swap.cancelOffer, (id, offered, requested)));
        assertEq(nft.ownerOf(5), address(wallet));
    }

    function test_maximumBasketSettles() public {
        for (uint256 i = 1; i < 16; ++i) {
            if (i > 1) nft.mint(maker, i);
            offered.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(nft), i, 1));
            otherNFT.mint(taker, 100 + i);
            requested.push(NFTSwap.Asset(NFTSwap.Kind.ERC721, address(otherNFT), 100 + i, 1));
        }
        fill(create());
        for (uint256 i; i < 16; ++i) {
            assertEq(nft.ownerOf(i), taker);
        }
        for (uint256 i = 1; i < 16; ++i) {
            assertEq(otherNFT.ownerOf(100 + i), maker);
        }
    }

    function testFuzz_exactPaymentConservation(uint96 raw, uint16 delay) public {
        uint256 amount = bound(raw, 1, 1_000_000);
        requested[0].amount = amount;
        uint256 id = create();
        vm.warp(10_000 + bound(delay, 0, 1799));
        fill(id);
        assertEq(coin.balanceOf(maker), amount);
        assertEq(coin.balanceOf(maker) + coin.balanceOf(taker), 1_000_000);
        assertEq(coin.balanceOf(address(swap)), 0);
        assertEq(nft.ownerOf(0), taker);
    }
}
