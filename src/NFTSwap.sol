// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC721Asset {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20Asset {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A private-counterparty, exact-basket, atomic ERC-721/ERC-20 swap escrow.
/// @dev Authenticated Ethereum transactions supply the signatures. No relayer or off-chain orders.
/// Assets must implement honest, conventional token semantics; arbitrary token code is not trusted.
contract NFTSwap {
    enum Kind {
        ERC721,
        ERC20
    }

    enum Status {
        Missing,
        Open,
        Filled,
        Cancelled
    }

    struct Asset {
        Kind kind;
        address token;
        uint256 id; // ERC-20: zero; ERC-721: token ID, including zero.
        uint256 amount; // ERC-721: exactly one; ERC-20: positive minor units.
    }

    struct Offer {
        address maker;
        uint64 expiresAt;
        Status status;
        address taker;
        bytes32 termsHash;
    }

    uint256 public constant OFFER_LIFETIME = 30 minutes;
    uint256 public constant MAX_ASSETS = 16;
    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;
    uint256 private entered = 1;

    error Reentrancy();
    error InvalidCounterparty();
    error InvalidAsset();
    error InvalidBasketSize();
    error DuplicateAsset();
    error NotOpen();
    error NotMaker();
    error NotTaker();
    error Expired();
    error TermsMismatch();
    error WrongOwner();
    error TokenTransferFailed();
    error InexactPayment();

    // Full terms remain available in the receipt, while storage contains only their commitment.
    event OfferCreated(
        uint256 indexed offerId,
        address indexed maker,
        address indexed taker,
        uint64 expiresAt,
        bytes32 termsHash,
        Asset[] offered,
        Asset[] requested
    );
    event OfferFilled(uint256 indexed offerId);
    event OfferCancelled(uint256 indexed offerId);

    modifier nonReentrant() {
        if (entered != 1) revert Reentrancy();
        entered = 2;
        _;
        entered = 1;
    }

    /// @notice Locks 1–16 NFTs for one taker, requesting 1–16 ERC-20/ERC-721 assets.
    /// @dev Starts the deadline at block inclusion. Approve each offered NFT before calling.
    function createOffer(address taker, Asset[] calldata offered, Asset[] calldata requested)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (taker == address(0) || taker == msg.sender || taker == address(this)) {
            revert InvalidCounterparty();
        }
        _validate(offered, true);
        _validate(requested, false);
        for (uint256 i; i < offered.length; ++i) {
            for (uint256 j; j < requested.length; ++j) {
                if (_sameAsset(offered[i], requested[j])) revert DuplicateAsset();
            }
        }

        offerId = nextOfferId++;
        uint64 expiresAt = uint64(block.timestamp + OFFER_LIFETIME);
        bytes32 commitment = hashTerms(offered, requested);
        offers[offerId] = Offer(msg.sender, expiresAt, Status.Open, taker, commitment);

        for (uint256 i; i < offered.length; ++i) {
            // Pull only from the authenticated maker. No receiver callback is needed for custody.
            _moveNFT(offered[i], msg.sender, address(this), false);
        }
        emit OfferCreated(offerId, msg.sender, taker, expiresAt, commitment, offered, requested);
    }

    /// @notice Only the named taker can settle, before expiry, using the exact committed arrays.
    /// @dev Nonpayable: extra native currency is rejected. Order and all fields must match.
    function fillOffer(uint256 offerId, Asset[] calldata offered, Asset[] calldata requested) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.status != Status.Open) revert NotOpen();
        if (msg.sender != offer.taker) revert NotTaker();
        if (block.timestamp >= offer.expiresAt) revert Expired();
        if (hashTerms(offered, requested) != offer.termsHash) revert TermsMismatch();
        offer.status = Status.Filled;

        for (uint256 i; i < requested.length; ++i) {
            Asset calldata asset = requested[i];
            if (asset.kind == Kind.ERC721) {
                _moveNFT(asset, msg.sender, offer.maker, true);
            } else {
                _payExact(asset, msg.sender, offer.maker);
            }
        }
        for (uint256 i; i < offered.length; ++i) {
            _moveNFT(offered[i], address(this), msg.sender, true);
        }
        emit OfferFilled(offerId);
    }

    /// @notice Maker may cancel or reclaim after expiry. Refunds always return to the maker.
    /// @dev Plain transferFrom avoids a maker receiver hook blocking its own refund.
    function cancelOffer(uint256 offerId, Asset[] calldata offered, Asset[] calldata requested) external nonReentrant {
        Offer storage offer = offers[offerId];
        if (offer.status != Status.Open) revert NotOpen();
        if (msg.sender != offer.maker) revert NotMaker();
        if (hashTerms(offered, requested) != offer.termsHash) revert TermsMismatch();
        offer.status = Status.Cancelled;
        for (uint256 i; i < offered.length; ++i) {
            _moveNFT(offered[i], address(this), msg.sender, false);
        }
        emit OfferCancelled(offerId);
    }

    function hashTerms(Asset[] calldata offered, Asset[] calldata requested) public pure returns (bytes32) {
        return keccak256(abi.encode(offered, requested));
    }

    function _validate(Asset[] calldata assets, bool onlyNFTs) private view {
        if (assets.length == 0 || assets.length > MAX_ASSETS) revert InvalidBasketSize();
        for (uint256 i; i < assets.length; ++i) {
            Asset calldata asset = assets[i];
            if (asset.token.code.length == 0 || asset.token == address(this)) revert InvalidAsset();
            if (asset.kind == Kind.ERC721) {
                if (asset.amount != 1 || !IERC721Asset(asset.token).supportsInterface(0x80ac58cd)) {
                    revert InvalidAsset();
                }
            } else {
                if (onlyNFTs || asset.id != 0 || asset.amount == 0) revert InvalidAsset();
                // ERC-721 shares balanceOf/transferFrom selectors with ERC-20. A one-unit
                // "payment" could otherwise accidentally transfer NFT #1 instead of currency.
                (bool ok, bytes memory data) = asset.token.staticcall{gas: 30_000}(
                    abi.encodeCall(IERC721Asset.supportsInterface, (bytes4(0x80ac58cd)))
                );
                if (ok && data.length >= 32 && bytes32(data) == bytes32(uint256(1))) revert InvalidAsset();
            }
            for (uint256 j; j < i; ++j) {
                if (_sameAsset(asset, assets[j])) revert DuplicateAsset();
            }
        }
    }

    function _sameAsset(Asset calldata a, Asset calldata b) private pure returns (bool) {
        return a.kind == b.kind && a.token == b.token && a.id == b.id;
    }

    function _moveNFT(Asset calldata asset, address from, address to, bool safe) private {
        IERC721Asset nft = IERC721Asset(asset.token);
        if (nft.ownerOf(asset.id) != from) revert WrongOwner();
        if (safe) nft.safeTransferFrom(from, to, asset.id);
        else nft.transferFrom(from, to, asset.id);
        if (nft.ownerOf(asset.id) != to) revert WrongOwner();
    }

    function _payExact(Asset calldata asset, address from, address to) private {
        IERC20Asset token = IERC20Asset(asset.token);
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        (bool ok, bytes memory result) =
            asset.token.call(abi.encodeCall(IERC20Asset.transferFrom, (from, to, asset.amount)));
        // Conventional tokens returning no data are supported; false/malformed data are rejected.
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenTransferFailed();
        }
        uint256 afterFrom = token.balanceOf(from);
        uint256 afterTo = token.balanceOf(to);
        if (
            afterFrom > beforeFrom || beforeFrom - afterFrom != asset.amount || afterTo < beforeTo
                || afterTo - beforeTo != asset.amount
        ) revert InexactPayment();
    }
}
