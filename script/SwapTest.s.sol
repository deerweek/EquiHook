// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IEquiHook {
    function registerCompliance(address user) external;
    function isCompliant(address user) external view returns (bool);
}

contract SwapTest is Script {
    address public constant HOOK = 0x3a6be95CeF62b582871009d4337BB35668e788c0;
    address public constant POOL_MANAGER = 0x5C8c9f0fA540e287e12A152DC0E2EbF4Ac5564F2;
    address public constant SWAP_ROUTER = 0x5e8D9db6Dcf7942820Fb22d1Ed164135974501DE;
    address public constant WETH = 0x2058A09CBe22262971f06b04e1D726BBD9272773;
    address public constant USDC = 0x9B09E000C32B503E97A3BA7d7F874B5A6CDf4A81;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Build pool key
        address t0 = WETH;
        address t1 = USDC;
        if (t0 > t1) (t0, t1) = (t1, t0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        console.log("Pool initialized with hook");

        // Register SwapRouter as compliant (hook checks sender = SwapRouter)
        console.log("Registering SwapRouter as compliant...");
        IEquiHook(HOOK).registerCompliance(SWAP_ROUTER);
        console.log("SwapRouter compliant:", IEquiHook(HOOK).isCompliant(SWAP_ROUTER));

        // Swap: buy 0.1 WETH with USDC
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 0.1e18, // 0.1 WETH
            sqrtPriceLimitX96: 4295128740 // MIN_SQRT_RATIO + 1 (effectively no limit for zeroForOne)
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        console.log("Executing swap: 0.1 WETH...");
        PoolSwapTest(SWAP_ROUTER).swap(key, params, testSettings, new bytes(0));
        console.log("Swap executed successfully!");

        // Check balances after swap
        console.log("Hook contract code length:");
        console.log(address(HOOK).code.length);

        vm.stopBroadcast();

        console.log("\n=== SWAP TEST PASSED ===");
    }
}
