// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EquiHook, IERC20, IDividendVault} from "../../src/EquiHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract HookDeployer {
    function deploy(IPoolManager poolManager, IDividendVault vault, IERC20 feeToken, address owner, uint256 salt)
        external
        returns (address)
    {
        bytes memory bytecode =
            abi.encodePacked(type(EquiHook).creationCode, abi.encode(poolManager, vault, feeToken, owner));
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
        return addr;
    }

    function computeAddress(
        address deployer,
        uint256 salt,
        IPoolManager poolManager,
        IDividendVault vault,
        IERC20 feeToken,
        address owner
    ) external pure returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(EquiHook).creationCode, abi.encode(poolManager, vault, feeToken, owner)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}
