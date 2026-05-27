// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EquiHook, IERC20 as IERC20_Hook, IDividendVault} from "../src/EquiHook.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {DividendVault, IERC20 as IERC20_Vault} from "../src/DividendVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract SingleDeployHookFactory {
    function deploy(IPoolManager poolManager, IDividendVault vault, IERC20_Hook feeToken, address owner, uint256 salt)
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
        uint256 salt,
        IPoolManager poolManager,
        IDividendVault vault,
        IERC20_Hook feeToken,
        address owner
    ) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(EquiHook).creationCode, abi.encode(poolManager, vault, feeToken, owner)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address feeTokenAddress = vm.envAddress("FEE_TOKEN_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DividendVault (hook address will be set after EquiHook deploy)
        DividendVault vault = new DividendVault(
            IERC20_Vault(feeTokenAddress),
            address(0) // placeholder, update after hook deploy
        );
        console.log("DividendVault deployed at:", address(vault));

        // 2. Deploy EquiHook at an address with the required v4 hook permission bits
        SingleDeployHookFactory factory = new SingleDeployHookFactory();
        uint160 requiredFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        uint256 salt = 0;
        address hookAddr = address(0);
        for (uint256 s = 0; s < 500000; s++) {
            address predicted = factory.computeAddress(
                s, IPoolManager(poolManager), IDividendVault(address(vault)), IERC20_Hook(feeTokenAddress), deployer
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == requiredFlags) {
                salt = s;
                hookAddr = predicted;
                break;
            }
        }
        require(hookAddr != address(0), "No valid hook address found");

        EquiHook hook = EquiHook(
            factory.deploy(
                IPoolManager(poolManager), IDividendVault(address(vault)), IERC20_Hook(feeTokenAddress), deployer, salt
            )
        );
        require(address(hook) == hookAddr, "Address mismatch");
        vault.setHook(address(hook));
        console.log("EquiHook deployed at:", address(hook));
        console.log("Hook salt:", salt);

        // 3. Deploy ComplianceSBT
        ComplianceSBT sbt = new ComplianceSBT("EquiHook KYC", "EHKYC", address(hook));
        hook.setComplianceIssuer(address(sbt));
        console.log("ComplianceSBT deployed at:", address(sbt));

        vm.stopBroadcast();
    }
}
