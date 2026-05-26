// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {MerkleProofLib} from "solmate/src/utils/MerkleProofLib.sol";

interface IEquiHook {
    function registerCompliance(address user) external;
    function clearCompliance(address user) external;
}

contract ComplianceSBT is ERC721 {
    bytes32 public merkleRoot;
    address public admin;
    IEquiHook public hook;

    error NotAdmin();
    error AlreadyMinted();
    error InvalidProof();
    error TransferBlocked();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _hook
    ) ERC721(name, symbol) {
        admin = msg.sender;
        hook = IEquiHook(_hook);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyAdmin {
        merkleRoot = _merkleRoot;
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mintWithProof(bytes32[] calldata proof) external {
        if (_balanceOf[msg.sender] > 0) revert AlreadyMinted();
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProofLib.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        _mint(msg.sender, uint256(leaf));
        hook.registerCompliance(msg.sender);
    }

    function revoke(address user) external onlyAdmin {
        if (balanceOf(user) == 0) return;
        uint256 tokenId = uint256(keccak256(abi.encodePacked(user)));
        _burn(tokenId);
        hook.clearCompliance(user);
    }

    // Soulbound: block all transfers
    function transferFrom(address, address, uint256) public pure override {
        revert TransferBlocked();
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert TransferBlocked();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert TransferBlocked();
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == 0x80ac58cd; // ERC721 only
    }
}
