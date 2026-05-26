// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// Inline IERC20 interface (solmate ERC20 is abstract, not interface)
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDividendVault {
    function addRewards(uint256 amount) external;
}

contract EquiHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    IPoolManager public immutable poolManager;
    IDividendVault public vault;
    IERC20 public feeToken;

    mapping(address => bool) public isCompliant;

    uint256 public baseFee;             // 3000 = 0.3%
    uint256 public maxFee;              // 20000 = 2%
    uint256 public liquidityThresholdBps; // 200 = 2%
    uint256 public scalingFactor;       // 10

    error NotCompliant();
    error NotPoolManager();
    error InvalidHookResponse();

    constructor(
        IPoolManager _poolManager,
        IDividendVault _vault,
        IERC20 _feeToken
    ) {
        poolManager = _poolManager;
        vault = _vault;
        feeToken = _feeToken;
        baseFee = 3000;
        maxFee = 20000;
        liquidityThresholdBps = 200;
        scalingFactor = 10;

        // Validate hook permissions - this verifies the address has correct permission bits
        IHooks(this).validateHookPermissions(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // Compliance management
    function registerCompliance(address user) external {
        isCompliant[user] = true;
    }

    function clearCompliance(address user) external {
        isCompliant[user] = false;
    }

    // Hook callbacks - all return their selector
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!isCompliant[sender]) revert NotCompliant();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!isCompliant[sender]) revert NotCompliant();

        uint128 swapAmount = params.amountSpecified < 0
            ? uint128(uint256(-params.amountSpecified))
            : uint128(uint256(params.amountSpecified));

        uint256 liquidity = StateLibrary.getLiquidity(poolManager, key.toId());
        uint24 dynamicFee = _calculateDynamicFee(swapAmount, liquidity);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        uint256 hookFee = _calculateHookFee(delta);
        if (hookFee > 0) {
            // Return negative delta so PoolManager credits the hook with tokens
            // Then use poolManager.take() to send tokens to the vault
            Currency outCurrency = delta.amount1() > 0 ? key.currency1 : key.currency0;
            poolManager.take(outCurrency, address(vault), hookFee);
            vault.addRewards(hookFee);
            return (IHooks.afterSwap.selector, -int128(int256(hookFee)));
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // Unimplemented callbacks - return their selectors
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function _calculateDynamicFee(uint128 swapAmount, uint256 liquidity) internal view returns (uint24) {
        if (liquidity == 0) return uint24(baseFee);

        uint256 ratioBps = (uint256(swapAmount) * 10000) / liquidity;
        if (ratioBps < liquidityThresholdBps) {
            return uint24(baseFee);
        }

        uint256 feeIncrease = (ratioBps - liquidityThresholdBps) * scalingFactor;
        uint256 fee = baseFee + feeIncrease;
        if (fee > maxFee) fee = maxFee;
        return uint24(fee);
    }

    function _calculateHookFee(BalanceDelta delta) internal pure returns (uint256) {
        int128 amountOut = delta.amount1() > 0 ? delta.amount1() : delta.amount0();
        if (amountOut <= 0) return 0;
        return uint256(uint128(amountOut)) / 20; // 5% of output as hook fee
    }
}
