// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface INFTReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract Mock721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    bool public noMove;
    bool public blocked;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7;
    }

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "minted");
        ownerOf[id] = to;
        ++balanceOf[to];
    }

    function setFailure(bool noMove_, bool blocked_) external {
        noMove = noMove_;
        blocked = blocked_;
    }

    function approve(address spender, uint256 id) external {
        require(msg.sender == ownerOf[id], "owner");
        getApproved[id] = spender;
    }

    function setApprovalForAll(address spender, bool approved) external {
        isApprovedForAll[msg.sender][spender] = approved;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(!blocked, "blocked");
        require(ownerOf[id] == from && to != address(0), "owner");
        require(msg.sender == from || getApproved[id] == msg.sender || isApprovedForAll[from][msg.sender], "approval");
        if (noMove) return;
        ownerOf[id] = to;
        --balanceOf[from];
        ++balanceOf[to];
        delete getApproved[id];
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            require(INFTReceiver(to).onERC721Received(msg.sender, from, id, "") == 0x150b7a02, "receiver");
        }
    }
}

contract Mock20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public mode; // 0 normal, 1 false, 2 no return, 3 recipient fee, 4 sender fee, 5 bonus, 6 malformed.
    address public callback;
    bytes public callbackData;
    bool public callbackRejected;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (mode == 1) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount + (mode == 4 ? 1 : 0);
        balanceOf[to] += mode == 3 ? amount - 1 : mode == 5 ? amount + 1 : amount;
        if (callback != address(0)) {
            (bool ok, bytes memory reason) = callback.call(callbackData);
            callbackRejected = !ok && bytes4(reason) == bytes4(keccak256("Reentrancy()"));
        }
        if (mode == 2) {
            assembly { return(0, 0) }
        }
        if (mode == 6) {
            assembly { return(0, 1) }
        }
        return true;
    }
}
