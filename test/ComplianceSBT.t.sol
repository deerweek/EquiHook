// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {IEquiHook} from "../src/ComplianceSBT.sol";

contract MockHook is IEquiHook {
    mapping(address => bool) public registered;

    function registerCompliance(address user) external {
        registered[user] = true;
    }

    function clearCompliance(address user) external {
        registered[user] = false;
    }
}

contract ComplianceSBTTest is Test {
    ComplianceSBT public sbt;
    MockHook public mockHook;

    address public admin = address(this);
    address public user1 = address(0xA1);
    address public user2 = address(0xA2);
    address public user3 = address(0xA3); // not in merkle tree

    bytes32 public leaf1;
    bytes32 public leaf2;
    bytes32 public merkleRoot;

    function setUp() public {
        mockHook = new MockHook();
        sbt = new ComplianceSBT("EquiKYC", "KYC", address(mockHook));

        // Build merkle tree for user1 and user2
        leaf1 = keccak256(abi.encodePacked(user1));
        leaf2 = keccak256(abi.encodePacked(user2));

        // Sort leaves for consistent hashing (solmate MerkleProofLib sorts by value)
        bytes32 node;
        if (leaf1 < leaf2) {
            node = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            node = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        merkleRoot = node;
        sbt.setMerkleRoot(merkleRoot);
    }

    // =========================================================================
    //                            mintWithProof
    // =========================================================================

    function test_mintWithProof_success() public {
        // proof for user1: leaf2 is the sibling
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(user1);
        sbt.mintWithProof(proof);

        // Token should be minted
        assertEq(sbt.balanceOf(user1), 1);
        assertEq(sbt.ownerOf(uint256(leaf1)), user1);

        // Hook should have registered compliance
        assertTrue(mockHook.registered(user1));
    }

    function test_mintWithProof_success_user2() public {
        // proof for user2: leaf1 is the sibling
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        vm.prank(user2);
        sbt.mintWithProof(proof);

        assertEq(sbt.balanceOf(user2), 1);
        assertEq(sbt.ownerOf(uint256(leaf2)), user2);
        assertTrue(mockHook.registered(user2));
    }

    function test_mintWithProof_invalidProof_reverts() public {
        // Use wrong sibling (leaf1 for user1 should use leaf2)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1; // wrong sibling for user1

        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.InvalidProof.selector);
        sbt.mintWithProof(proof);
    }

    function test_mintWithProof_emptyProof_reverts() public {
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.InvalidProof.selector);
        sbt.mintWithProof(proof);
    }

    function test_mintWithProof_userNotInTree_reverts() public {
        // user3 is not in the merkle tree
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        vm.prank(user3);
        vm.expectRevert(ComplianceSBT.InvalidProof.selector);
        sbt.mintWithProof(proof);
    }

    function test_mintWithProof_alreadyMinted_reverts() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        // First mint succeeds
        vm.prank(user1);
        sbt.mintWithProof(proof);

        // Second mint reverts
        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.AlreadyMinted.selector);
        sbt.mintWithProof(proof);
    }

    // =========================================================================
    //                            Transfer blocked
    // =========================================================================

    function test_transferFrom_blocked() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(user1);
        sbt.mintWithProof(proof);

        uint256 tokenId = uint256(leaf1);

        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.TransferBlocked.selector);
        sbt.transferFrom(user1, user2, tokenId);
    }

    function test_safeTransferFrom_blocked() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(user1);
        sbt.mintWithProof(proof);

        uint256 tokenId = uint256(leaf1);

        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.TransferBlocked.selector);
        sbt.safeTransferFrom(user1, user2, tokenId);
    }

    function test_safeTransferFromWithData_blocked() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(user1);
        sbt.mintWithProof(proof);

        uint256 tokenId = uint256(leaf1);

        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.TransferBlocked.selector);
        sbt.safeTransferFrom(user1, user2, tokenId, "");
    }

    // =========================================================================
    //                              revoke
    // =========================================================================

    function test_revoke_success() public {
        // Mint first
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(user1);
        sbt.mintWithProof(proof);
        assertTrue(mockHook.registered(user1));
        assertEq(sbt.balanceOf(user1), 1);

        // Revoke
        sbt.revoke(user1);

        // Token burned, compliance cleared
        assertEq(sbt.balanceOf(user1), 0);
        assertFalse(mockHook.registered(user1));
    }

    function test_revoke_nonMintedUser_doesNotRevert() public {
        // Revoking a user who never minted should return silently
        sbt.revoke(user3);
        assertFalse(mockHook.registered(user3));
    }

    function test_revoke_nonAdmin_reverts() public {
        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.NotAdmin.selector);
        sbt.revoke(user2);
    }

    // =========================================================================
    //                          setMerkleRoot
    // =========================================================================

    function test_setMerkleRoot_success() public {
        bytes32 newRoot = keccak256(abi.encodePacked("new root"));
        sbt.setMerkleRoot(newRoot);
        assertEq(sbt.merkleRoot(), newRoot);
    }

    function test_setMerkleRoot_nonAdmin_reverts() public {
        vm.prank(user1);
        vm.expectRevert(ComplianceSBT.NotAdmin.selector);
        sbt.setMerkleRoot(bytes32(0));
    }

    // =========================================================================
    //                          supportsInterface
    // =========================================================================

    function test_supportsInterface_ERC721() public {
        assertTrue(sbt.supportsInterface(0x80ac58cd));
    }

    function test_supportsInterface_ERC165() public {
        // After our override, ERC165 is not supported
        assertFalse(sbt.supportsInterface(0x01ffc9a7));
    }
}
