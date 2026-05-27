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
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

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
    using SafeCast for uint256;

    IPoolManager public immutable poolManager;
    IDividendVault public vault;
    IERC20 public feeToken;

    mapping(address => bool) public isCompliant;
    mapping(address => uint256) public complianceSince; // timestamp of SBT mint

    // Identity-weighted pricing tiers
    uint256 public constant TIER0_FEE = 20000;  // 2.0% — no SBT (deterrent)
    uint256 public constant TIER1_FEE = 3000;   // 0.3% — SBT holder (base)
    uint256 public constant TIER2_FEE = 1500;   // 0.15% — long-term holder (discount)
    uint256 public constant TIER2_THRESHOLD = 30 days; // hold duration for Tier 2
    uint256 public constant SIZE_THRESHOLD_BPS = 200; // 2% — swap size threshold
    uint256 public constant SIZE_SCALING_FACTOR = 10; // fee increase per BPS over threshold

    // LP position identity lock
    mapping(address => uint128) public userLiquidity; // SBT-bound LP ledger

    error NotPoolManager();
    error NotCompliant();
    error LPNotVerified();

    constructor(
        IPoolManager _poolManager,
        IDividendVault _vault,
        IERC20 _feeToken
    ) {
        poolManager = _poolManager;
        vault = _vault;
        feeToken = _feeToken;

        // Validate hook permissions - this verifies the address has correct permission bits
        IHooks(this).validateHookPermissions(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // Compliance management
    function registerCompliance(address user) external {
        isCompliant[user] = true;
        if (complianceSince[user] == 0) complianceSince[user] = block.timestamp;
    }

    function clearCompliance(address user) external {
        isCompliant[user] = false;
    }

    // Hook callbacks - all return their selector
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        // LP position identity lock: require SBT, track liquidity in hook's ledger
        if (!isCompliant[sender]) revert LPNotVerified();
        userLiquidity[sender] = userLiquidity[sender] + uint128(uint256(params.liquidityDelta));
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        // Identity-weighted pricing: fee depends on WHO is trading, not just HOW MUCH
        uint24 fee = _identityFee(sender);

        // Overlay: size-based dynamic scaling on top of identity tier
        uint128 swapAmount = params.amountSpecified < 0
            ? uint128(uint256(-params.amountSpecified))
            : uint128(uint256(params.amountSpecified));
        uint256 liquidity = StateLibrary.getLiquidity(poolManager, key.toId());
        if (liquidity > 0) {
            uint256 ratioBps = (uint256(swapAmount) * 10000) / liquidity;
            if (ratioBps > SIZE_THRESHOLD_BPS) {
                uint256 sizePenalty = (ratioBps - SIZE_THRESHOLD_BPS) * SIZE_SCALING_FACTOR;
                fee = uint256(fee) + sizePenalty > TIER0_FEE ? uint24(TIER0_FEE) : fee + uint24(sizePenalty);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        // Fee is taken from the unspecified token (same as FeeTakingHook pattern).
        // For exact input (amountSpecified < 0): unspecified = output token
        // For exact output (amountSpecified > 0): unspecified = input token
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) = specifiedTokenIs0
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 hookFee = uint256(uint128(swapAmount)) / 20; // 5% of output
        if (hookFee > 0) {
            // take() sends tokens from pool to vault and creates -hookFee delta for this hook.
            // Returning +hookFee cancels that delta so NonzeroDeltaCount stays 0.
            poolManager.take(feeCurrency, address(vault), hookFee);
            vault.addRewards(hookFee);
            return (IHooks.afterSwap.selector, hookFee.toInt128());
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

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        external override returns (bytes4) {
        // LP identity lock: can only remove liquidity you personally added
        if (params.liquidityDelta >= 0) return IHooks.beforeRemoveLiquidity.selector;
        uint128 requested = uint128(uint256(-params.liquidityDelta));
        if (requested > userLiquidity[sender]) revert LPNotVerified();
        userLiquidity[sender] -= requested;
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

    function _identityFee(address user) internal view returns (uint24) {
        if (!isCompliant[user]) return uint24(TIER0_FEE);           // 2.0% — unverified
        if (block.timestamp - complianceSince[user] >= TIER2_THRESHOLD) return uint24(TIER2_FEE); // 0.15% — long-term
        return uint24(TIER1_FEE);                                    // 0.3% — standard SBT holder
    }
}
