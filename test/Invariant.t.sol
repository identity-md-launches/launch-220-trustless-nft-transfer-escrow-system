// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NFTSwap} from "../src/NFTSwap.sol";
import {Mock721, Mock20} from "./mocks/Assets.sol";

contract SwapHandler is Test {
    NFTSwap public swap;
    Mock721 public nft;
    Mock20 public coin;
    address public constant MAKER = address(0xA11CE);
    address public constant TAKER = address(0xB0B);
    uint256 public filled;
    mapping(uint256 => uint256) public offerForNFT;

    constructor(NFTSwap s, Mock721 n, Mock20 c) {
        swap = s;
        nft = n;
        coin = c;
        for (uint256 i; i < 8; ++i) {
            nft.mint(MAKER, i);
        }
        coin.mint(TAKER, 1_000_000);
        vm.prank(MAKER);
        nft.setApprovalForAll(address(swap), true);
        vm.prank(TAKER);
        coin.approve(address(swap), type(uint256).max);
    }

    function terms(uint256 tokenId)
        public
        view
        returns (NFTSwap.Asset[] memory offered, NFTSwap.Asset[] memory requested)
    {
        offered = new NFTSwap.Asset[](1);
        requested = new NFTSwap.Asset[](1);
        offered[0] = NFTSwap.Asset(NFTSwap.Kind.ERC721, address(nft), tokenId, 1);
        requested[0] = NFTSwap.Asset(NFTSwap.Kind.ERC20, address(coin), 0, 100);
    }

    function create(uint256 seed) external {
        uint256 tokenId = seed % 8;
        if (nft.ownerOf(tokenId) != MAKER) return;
        (NFTSwap.Asset[] memory offered, NFTSwap.Asset[] memory requested) = terms(tokenId);
        vm.prank(MAKER);
        offerForNFT[tokenId] = swap.createOffer(TAKER, offered, requested);
    }

    function fill(uint256 seed) external {
        uint256 tokenId = seed % 8;
        uint256 id = offerForNFT[tokenId];
        (, uint64 expiry, NFTSwap.Status status,,) = swap.offers(id);
        if (status != NFTSwap.Status.Open || block.timestamp >= expiry) return;
        (NFTSwap.Asset[] memory offered, NFTSwap.Asset[] memory requested) = terms(tokenId);
        vm.prank(TAKER);
        swap.fillOffer(id, offered, requested);
        ++filled;
    }

    function cancel(uint256 seed) external {
        uint256 tokenId = seed % 8;
        uint256 id = offerForNFT[tokenId];
        (,, NFTSwap.Status status,,) = swap.offers(id);
        if (status != NFTSwap.Status.Open) return;
        (NFTSwap.Asset[] memory offered, NFTSwap.Asset[] memory requested) = terms(tokenId);
        vm.prank(MAKER);
        swap.cancelOffer(id, offered, requested);
    }

    function elapse(uint16 seconds_) external {
        vm.warp(block.timestamp + seconds_);
    }

    function unauthorized(uint256 seed) external {
        uint256 tokenId = seed % 8;
        (NFTSwap.Asset[] memory offered, NFTSwap.Asset[] memory requested) = terms(tokenId);
        vm.prank(address(0xBAD));
        (bool ok,) = address(swap).call(abi.encodeCall(swap.fillOffer, (offerForNFT[tokenId], offered, requested)));
        require(!ok, "outsider settled");
    }
}

contract SwapInvariantTest is StdInvariant, Test {
    NFTSwap internal swap;
    Mock721 internal nft;
    Mock20 internal coin;
    SwapHandler internal handler;

    function setUp() public {
        swap = new NFTSwap();
        nft = new Mock721();
        coin = new Mock20();
        handler = new SwapHandler(swap, nft, coin);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.fill.selector;
        selectors[2] = handler.cancel.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.unauthorized.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_paymentConservationAndNoStrandedCurrency() public view {
        assertEq(coin.balanceOf(handler.MAKER()) + coin.balanceOf(handler.TAKER()), 1_000_000);
        assertEq(coin.balanceOf(handler.MAKER()), handler.filled() * 100);
        assertEq(coin.balanceOf(address(swap)), 0);
        assertEq(address(swap).balance, 0);
    }

    function invariant_custodyMatchesOfferState() public view {
        for (uint256 i; i < 8; ++i) {
            uint256 id = handler.offerForNFT(i);
            (,, NFTSwap.Status status,,) = swap.offers(id);
            address expected = status == NFTSwap.Status.Open
                ? address(swap)
                : status == NFTSwap.Status.Filled ? handler.TAKER() : handler.MAKER();
            assertEq(nft.ownerOf(i), expected);
        }
    }

    function afterInvariant() public {
        for (uint256 i; i < 8; ++i) {
            handler.cancel(i);
        }
        for (uint256 i; i < 8; ++i) {
            assertTrue(nft.ownerOf(i) != address(swap), "refund stranded");
        }
    }
}
