// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EquiHook} from "../src/EquiHook.sol";
import {DividendVault} from "../src/DividendVault.sol";

interface IComplianceSBTState {
    function balanceOf(address owner) external view returns (uint256);
}

interface IERC20State {
    function balanceOf(address account) external view returns (uint256);
}

contract VerifyE2EState is Script {
    function run() external view {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address sbtAddress = vm.envAddress("SBT_ADDRESS");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address feeTokenAddress = vm.envAddress("FEE_TOKEN_ADDRESS");
        address demoUser = vm.envAddress("DEMO_USER_ADDRESS");

        EquiHook hook = EquiHook(hookAddress);
        DividendVault vault = DividendVault(vaultAddress);
        IComplianceSBTState sbt = IComplianceSBTState(sbtAddress);
        IERC20State feeToken = IERC20State(feeTokenAddress);

        uint256 sbtBalance = sbt.balanceOf(demoUser);
        uint128 userLiquidity = hook.userLiquidity(demoUser);
        uint256 totalRewards = vault.totalRewards();
        uint256 earned = vault.earned(demoUser);
        uint256 vaultBalance = feeToken.balanceOf(vaultAddress);

        require(sbtBalance > 0, "demo user has no SBT");
        require(hook.isCompliant(demoUser), "demo user not compliant");
        require(vault.isRewardParticipant(demoUser), "demo user not reward participant");
        require(userLiquidity > 0, "demo user has no hook-tracked liquidity");
        require(totalRewards > 0, "vault has no rewards");
        require(earned > 0, "demo user has no earned rewards");
        require(vaultBalance >= totalRewards, "vault reward token balance too low");

        console.log("=== EquiHook E2E State Verified ===");
        console.log("Demo user:", demoUser);
        console.log("SBT balance:", sbtBalance);
        console.log("Hook compliant:", hook.isCompliant(demoUser));
        console.log("Hook-tracked liquidity:", userLiquidity);
        console.log("Vault totalRewards:", totalRewards);
        console.log("Demo user earned:", earned);
        console.log("Vault reward token balance:", vaultBalance);
    }
}
