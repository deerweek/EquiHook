// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EquiHook} from "../src/EquiHook.sol";
import {DividendVault} from "../src/DividendVault.sol";

interface ISubmissionSBTState {
    function balanceOf(address owner) external view returns (uint256);
}

interface ISubmissionERC20State {
    function balanceOf(address account) external view returns (uint256);
}

contract VerifySubmission is Script {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address sbtAddress = vm.envAddress("SBT_ADDRESS");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address feeTokenAddress = vm.envAddress("FEE_TOKEN_ADDRESS");
        address wethAddress = vm.envAddress("WETH_ADDRESS");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address demoUser = vm.envAddress("DEMO_USER_ADDRESS");

        EquiHook hook = EquiHook(hookAddress);
        DividendVault vault = DividendVault(vaultAddress);
        ISubmissionSBTState sbt = ISubmissionSBTState(sbtAddress);
        ISubmissionERC20State feeToken = ISubmissionERC20State(feeTokenAddress);
        IPoolManager poolManager = IPoolManager(poolManagerAddress);

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

        address token0 = wethAddress;
        address token1 = usdcAddress;
        if (token0 > token1) (token0, token1) = (token1, token0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 poolLiquidity = StateLibrary.getLiquidity(poolManager, poolId);

        require(sqrtPriceX96 > 0, "pool not initialized");
        require(lpFee == 0, "unexpected stored dynamic lp fee");
        require(poolLiquidity > 0, "pool has no active liquidity");

        require(hook.TIER0_FEE() == 20000, "bad tier0 fee");
        require(hook.TIER1_FEE() == 3000, "bad tier1 fee");
        require(hook.TIER2_FEE() == 1500, "bad tier2 fee");

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

        console.log("=== EquiHook Submission Verified ===");
        console.log("Hook:", hookAddress);
        console.log("ComplianceSBT:", sbtAddress);
        console.log("DividendVault:", vaultAddress);
        console.log("SwapRouter:", swapRouterAddress);
        console.log("PoolManager:", poolManagerAddress);
        console.log("FeeToken:", feeTokenAddress);
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Pool sqrtPriceX96:", sqrtPriceX96);
        console.log("Pool protocolFee:", protocolFee);
        console.log("Pool stored dynamic lpFee:", lpFee);
        console.log("Pool active liquidity:", poolLiquidity);
        console.log("Demo user:", demoUser);
        console.log("SBT balance:", sbtBalance);
        console.log("Hook compliant:", hook.isCompliant(demoUser));
        console.log("Hook-tracked liquidity:", userLiquidity);
        console.log("Vault totalRewards:", totalRewards);
        console.log("Demo user earned:", earned);
        console.log("Vault reward token balance:", vaultBalance);
    }
}
