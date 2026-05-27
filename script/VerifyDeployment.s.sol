// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {EquiHook} from "../src/EquiHook.sol";
import {DividendVault} from "../src/DividendVault.sol";

contract VerifyDeployment is Script {
    function run() external view {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address sbtAddress = vm.envAddress("SBT_ADDRESS");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address feeTokenAddress = vm.envAddress("FEE_TOKEN_ADDRESS");

        EquiHook hook = EquiHook(hookAddress);
        DividendVault vault = DividendVault(vaultAddress);

        uint160 requiredFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        require(uint160(hookAddress) & Hooks.ALL_HOOK_MASK == requiredFlags, "bad hook permission bits");

        require(address(hook.poolManager()) == poolManagerAddress, "bad pool manager");
        require(address(hook.vault()) == vaultAddress, "bad hook vault");
        require(address(hook.feeToken()) == feeTokenAddress, "bad hook fee token");
        require(hook.complianceIssuer() == sbtAddress, "bad compliance issuer");
        require(hook.authorizedIdentityRelayer(swapRouterAddress), "swap router not authorized");

        require(address(vault.hook()) == hookAddress, "bad vault hook");
        require(address(vault.rewardToken()) == feeTokenAddress, "bad vault reward token");

        require(hook.TIER0_FEE() == 20000, "bad tier0 fee");
        require(hook.TIER1_FEE() == 3000, "bad tier1 fee");
        require(hook.TIER2_FEE() == 1500, "bad tier2 fee");

        console.log("=== EquiHook Deployment Verified ===");
        console.log("Hook:", hookAddress);
        console.log("ComplianceSBT:", sbtAddress);
        console.log("DividendVault:", vaultAddress);
        console.log("SwapRouter:", swapRouterAddress);
        console.log("PoolManager:", poolManagerAddress);
        console.log("FeeToken:", feeTokenAddress);
    }
}
