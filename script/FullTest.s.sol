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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IERC20Basic {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEquiHook {
    function isCompliant(address user) external view returns (bool);
    function setIdentityRelayer(address relayer, bool authorized) external;
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
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hook = vm.envAddress("HOOK_ADDRESS");
        address sbt = vm.envAddress("SBT_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address feeToken = vm.envAddress("FEE_TOKEN_ADDRESS");

        console.log("Demo user:", deployer);

        vm.startBroadcast(deployerKey);

        // Deploy liquidity helper
        PoolModifyLiquidityTest liqHelper = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        console.log("Liquidity helper:", address(liqHelper));
        IEquiHook(hook).setIdentityRelayer(address(liqHelper), true);
        IEquiHook(hook).setIdentityRelayer(swapRouter, true);
        console.log("Identity relayers authorized");

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

        // Step 1: Mint SBT for deployer
        console.log("=== Step 1: Mint SBT ===");
        bytes32 leaf = keccak256(abi.encodePacked(deployer));
        IComplianceSBT(sbt).setMerkleRoot(leaf);
        IComplianceSBT(sbt).mintWithProof(new bytes32[](0));
        console.log("SBT balance:", IComplianceSBT(sbt).balanceOf(deployer));
        console.log("Deployer compliant:", IEquiHook(hook).isCompliant(deployer));

        // Step 2: Approvals
        console.log("=== Step 2: Approvals ===");
        IERC20Basic(weth).approve(poolManager, type(uint256).max);
        IERC20Basic(usdc).approve(poolManager, type(uint256).max);
        IERC20Basic(weth).approve(address(liqHelper), type(uint256).max);
        IERC20Basic(usdc).approve(address(liqHelper), type(uint256).max);
        IERC20Basic(weth).approve(swapRouter, type(uint256).max);
        IERC20Basic(usdc).approve(swapRouter, type(uint256).max);
        console.log("Approved");

        // Step 3: Add liquidity (full range)
        console.log("=== Step 3: Add Liquidity ===");
        ModifyLiquidityParams memory liqParams =
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e6, salt: bytes32(0)});
        liqHelper.modifyLiquidity(key, liqParams, abi.encode(deployer));
        console.log("Liquidity added");
        console.log("PoolManager WETH:", IERC20Basic(weth).balanceOf(poolManager));
        console.log("PoolManager USDC:", IERC20Basic(usdc).balanceOf(poolManager));

        // Step 3.5: Mint more tokens to deployer for swap settlement
        MockERC20(weth).mint(deployer, 1000e18);
        MockERC20(usdc).mint(deployer, 1000000e6);

        // Step 4: Exact-input swap that outputs the configured feeToken.
        console.log("=== Step 4: Swap ===");
        Currency feeCurrency = Currency.wrap(feeToken);
        bool zeroForOne = key.currency1 == feeCurrency;
        require(zeroForOne || key.currency0 == feeCurrency, "feeToken not in pool");
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 vaultRewardsBefore = IDividendVault(vault).totalRewards();
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -10_000, sqrtPriceLimitX96: sqrtPriceLimitX96});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Swapping exact input for feeToken rewards...");
        console.log("zeroForOne:", zeroForOne);
        PoolSwapTest(swapRouter).swap(key, params, testSettings, abi.encode(deployer));
        console.log("Swap done!");

        // Step 5: Post-swap
        console.log("=== Step 5: Results ===");
        console.log("Deployer WETH:", IERC20Basic(weth).balanceOf(deployer));
        console.log("Deployer USDC:", IERC20Basic(usdc).balanceOf(deployer));
        uint256 vaultRewardsAfter = IDividendVault(vault).totalRewards();
        console.log("Vault rewards:", vaultRewardsAfter);
        require(vaultRewardsAfter > vaultRewardsBefore, "vault rewards not routed");

        vm.stopBroadcast();

        console.log("\n=== FULL E2E TEST PASSED ===");
        console.log("\n=== COPY/PASTE E2E ENV ===");
        console.log(string.concat("export DEMO_USER_ADDRESS=", vm.toString(deployer)));
    }
}
