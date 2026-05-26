// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EquiHook, IERC20 as IERC20_Hook, IDividendVault} from "../src/EquiHook.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {DividendVault, IERC20 as IERC20_Vault} from "../src/DividendVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address feeTokenAddress = vm.envAddress("FEE_TOKEN_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DividendVault (hook address will be set after EquiHook deploy)
        DividendVault vault = new DividendVault(
            IERC20_Vault(feeTokenAddress),
            address(0) // placeholder, update after hook deploy
        );
        console.log("DividendVault deployed at:", address(vault));

        // 2. Deploy EquiHook
        EquiHook hook = new EquiHook(
            IPoolManager(poolManager),
            IDividendVault(address(vault)),
            IERC20_Hook(feeTokenAddress)
        );
        console.log("EquiHook deployed at:", address(hook));

        // 3. Deploy ComplianceSBT
        ComplianceSBT sbt = new ComplianceSBT(
            "EquiHook KYC",
            "EHKYC",
            address(hook)
        );
        console.log("ComplianceSBT deployed at:", address(sbt));

        vm.stopBroadcast();
    }
}
