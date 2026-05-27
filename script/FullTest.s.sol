// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Basic {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEquiHook {
    function registerCompliance(address user) external;
    function isCompliant(address user) external view returns (bool);
}

interface IDividendVault {
    function totalRewards() external view returns (uint256);
}

interface MockERC20 {
    function mint(address to, uint256 amount) external;
}

interface IComplianceSBT {
    function setMerkleRoot(bytes32 root) external;
    function mintWithProof(bytes32[] calldata proof) external;
    function balanceOf(address owner) external view returns (uint256);
}

contract FullTest is Script {
    address public constant HOOK = 0x319583D87Fab5f72a83f4467442679921944CAc4;
    address public constant SBT = 0xA583550fdD5364cdAE99a269d58De6b2292B2A4d;
    address public constant VAULT = 0xC1113d97179903548251921EA3382cb643C98A95;
    address public constant POOL_MANAGER = 0xcb3Cbd2E0e7457806A87539c92EAb7EA84BEc39f;
    address public constant SWAP_ROUTER = 0x71425c7e9aBcf2954f42596ebfBbA5dA4b1C1d05;
    address public constant WETH = 0x6e8FFa15E70045C04EB63226498A0AeA66053d8D;
    address public constant USDC = 0xFF396a2ca5d62412b00a595d813960178e5654bE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy liquidity helper
        PoolModifyLiquidityTest liqHelper = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        console.log("Liquidity helper:", address(liqHelper));

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

        // Step 1: Mint SBT for deployer
        console.log("=== Step 1: Mint SBT ===");
        bytes32 leaf = keccak256(abi.encodePacked(deployer));
        IComplianceSBT(SBT).setMerkleRoot(leaf);
        IComplianceSBT(SBT).mintWithProof(new bytes32[](0));
        console.log("SBT balance:", IComplianceSBT(SBT).balanceOf(deployer));
        console.log("Deployer compliant:", IEquiHook(HOOK).isCompliant(deployer));

        // Step 1.5: Register liquidity helper as compliant (it's the sender in beforeAddLiquidity)
        IEquiHook(HOOK).registerCompliance(address(liqHelper));
        console.log("Liquidity helper compliant:", IEquiHook(HOOK).isCompliant(address(liqHelper)));

        // Step 2: Approvals
        console.log("=== Step 2: Approvals ===");
        IERC20Basic(WETH).approve(POOL_MANAGER, type(uint256).max);
        IERC20Basic(USDC).approve(POOL_MANAGER, type(uint256).max);
        IERC20Basic(WETH).approve(address(liqHelper), type(uint256).max);
        IERC20Basic(USDC).approve(address(liqHelper), type(uint256).max);
        IERC20Basic(WETH).approve(SWAP_ROUTER, type(uint256).max);
        IERC20Basic(USDC).approve(SWAP_ROUTER, type(uint256).max);
        console.log("Approved");

        // Step 3: Add liquidity (full range)
        console.log("=== Step 3: Add Liquidity ===");
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: 1e6,
            salt: bytes32(0)
        });
        liqHelper.modifyLiquidity(key, liqParams, new bytes(0));
        console.log("Liquidity added");
        console.log("PoolManager WETH:", IERC20Basic(WETH).balanceOf(POOL_MANAGER));
        console.log("PoolManager USDC:", IERC20Basic(USDC).balanceOf(POOL_MANAGER));

        // Step 3.5: Mint more tokens to deployer for swap settlement
        MockERC20(WETH).mint(deployer, 1000e18);
        MockERC20(USDC).mint(deployer, 1000000e6);

        // Step 4: Swap (very small amount relative to liquidity)
        console.log("=== Step 4: Swap ===");
        // Register SwapRouter as compliant
        IEquiHook(HOOK).registerCompliance(SWAP_ROUTER);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 100,
            sqrtPriceLimitX96: 4295128740
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        console.log("Swapping 100 raw WETH...");
        PoolSwapTest(SWAP_ROUTER).swap(key, params, testSettings, new bytes(0));
        console.log("Swap done!");

        // Step 5: Post-swap
        console.log("=== Step 5: Results ===");
        console.log("Deployer WETH:", IERC20Basic(WETH).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20Basic(USDC).balanceOf(deployer));
        console.log("Vault rewards:", IDividendVault(VAULT).totalRewards());

        vm.stopBroadcast();

        console.log("\n=== FULL E2E TEST PASSED ===");
    }
}
