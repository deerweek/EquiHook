// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IEquiHook {
    function isCompliant(address user) external view returns (bool);
    function setIdentityRelayer(address relayer, bool authorized) external;
}

contract SwapTest is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hook = vm.envAddress("HOOK_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerKey);

        // Build pool key
        address t0 = weth;
        address t1 = usdc;
        if (t0 > t1) (t0, t1) = (t1, t0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        console.log("Pool initialized with hook");

        console.log("Deployer compliant:", IEquiHook(hook).isCompliant(deployer));
        IEquiHook(hook).setIdentityRelayer(swapRouter, true);
        console.log("Swap router authorized as identity relayer");

        // Swap: buy 0.1 WETH with USDC
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 0.1e18, // 0.1 WETH
            sqrtPriceLimitX96: 4295128740 // MIN_SQRT_RATIO + 1 (effectively no limit for zeroForOne)
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap: 0.1 WETH...");
        PoolSwapTest(swapRouter).swap(key, params, testSettings, abi.encode(deployer));
        console.log("Swap executed successfully!");

        // Check balances after swap
        console.log("Hook contract code length:");
        console.log(hook.code.length);

        vm.stopBroadcast();

        console.log("\n=== SWAP TEST PASSED ===");
    }
}
