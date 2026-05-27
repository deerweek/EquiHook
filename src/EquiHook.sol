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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// Inline IERC20 interface (solmate ERC20 is abstract, not interface)
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDividendVault {
    function addRewards(uint256 amount) external;
    function syncCompliance(address user) external;
}

contract EquiHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;
    IDividendVault public vault;
    IERC20 public feeToken;
    address public owner;
    address public complianceIssuer;

    mapping(address => bool) public isCompliant;
    mapping(address => uint256) public complianceSince; // timestamp of SBT mint
    mapping(address => bool) public authorizedIdentityRelayer;

    // Identity-weighted pricing tiers
    uint24 public constant TIER0_FEE = 20000; // 2.0% — no SBT (deterrent)
    uint24 public constant TIER1_FEE = 3000; // 0.3% — SBT holder (base)
    uint24 public constant TIER2_FEE = 1500; // 0.15% — long-term holder (discount)
    uint256 public constant TIER2_THRESHOLD = 30 days; // hold duration for Tier 2
    uint256 public constant SIZE_THRESHOLD_BPS = 200; // 2% — swap size threshold
    uint256 public constant SIZE_SCALING_FACTOR = 10; // fee increase per BPS over threshold

    // LP position identity lock
    mapping(address => uint128) public userLiquidity; // SBT-bound LP ledger

    event ComplianceIssuerUpdated(address indexed issuer);
    event IdentityRelayerUpdated(address indexed relayer, bool authorized);
    event ComplianceRegistered(address indexed user, uint256 since);
    event ComplianceCleared(address indexed user);
    event LiquidityLocked(address indexed user, uint128 liquidityDelta, uint128 totalLiquidity);
    event LiquidityUnlocked(address indexed user, uint128 liquidityDelta, uint128 remainingLiquidity);
    event IdentityFeeOverride(address indexed sender, PoolId indexed poolId, uint24 fee, uint256 swapSizeBps);
    event HookRewardRouted(PoolId indexed poolId, Currency indexed currency, address indexed vault, uint256 amount);
    event HookRewardSkipped(
        PoolId indexed poolId, Currency indexed currency, Currency indexed expectedCurrency, uint256 amount
    );

    error NotPoolManager();
    error NotCompliant();
    error LPNotVerified();
    error NotOwner();
    error NotComplianceAuthority();
    error UnauthorizedIdentityRelayer();

    constructor(IPoolManager _poolManager, IDividendVault _vault, IERC20 _feeToken, address _owner) {
        poolManager = _poolManager;
        vault = _vault;
        feeToken = _feeToken;
        owner = _owner;

        // Validate hook permissions - this verifies the address has correct permission bits
        IHooks(this)
            .validateHookPermissions(
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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyComplianceAuthority() {
        if (msg.sender != owner && msg.sender != complianceIssuer) revert NotComplianceAuthority();
        _;
    }

    // Compliance management
    function setComplianceIssuer(address issuer) external onlyOwner {
        complianceIssuer = issuer;
        emit ComplianceIssuerUpdated(issuer);
    }

    function setIdentityRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedIdentityRelayer[relayer] = authorized;
        emit IdentityRelayerUpdated(relayer, authorized);
    }

    function registerCompliance(address user) external onlyComplianceAuthority {
        isCompliant[user] = true;
        if (complianceSince[user] == 0) complianceSince[user] = block.timestamp;
        vault.syncCompliance(user);
        emit ComplianceRegistered(user, complianceSince[user]);
    }

    function clearCompliance(address user) external onlyComplianceAuthority {
        isCompliant[user] = false;
        vault.syncCompliance(user);
        emit ComplianceCleared(user);
    }

    // Hook callbacks - all return their selector
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        address identity = _resolveIdentity(sender, hookData);

        // LP position identity lock: require SBT, track liquidity in hook's ledger
        if (!isCompliant[identity]) revert LPNotVerified();
        userLiquidity[identity] = userLiquidity[identity] + uint128(uint256(params.liquidityDelta));
        emit LiquidityLocked(identity, uint128(uint256(params.liquidityDelta)), userLiquidity[identity]);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        address identity = _resolveIdentity(sender, hookData);

        // Identity-weighted pricing: fee depends on WHO is trading, not just HOW MUCH
        uint24 fee = _identityFee(identity);

        // Overlay: size-based dynamic scaling on top of identity tier
        uint128 swapAmount = params.amountSpecified < 0
            ? uint128(uint256(-params.amountSpecified))
            : uint128(uint256(params.amountSpecified));
        uint256 liquidity = StateLibrary.getLiquidity(poolManager, key.toId());
        uint256 ratioBps;
        if (liquidity > 0) {
            ratioBps = (uint256(swapAmount) * 10000) / liquidity;
            if (ratioBps > SIZE_THRESHOLD_BPS) {
                uint256 sizePenalty = (ratioBps - SIZE_THRESHOLD_BPS) * SIZE_SCALING_FACTOR;
                uint256 scaledFee = uint256(fee) + sizePenalty;
                fee = scaledFee > TIER0_FEE ? TIER0_FEE : _toUint24(scaledFee);
            }
        }

        emit IdentityFeeOverride(identity, key.toId(), fee, ratioBps);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        // Fee is taken from the unspecified token (same as FeeTakingHook pattern).
        // For exact input (amountSpecified < 0): unspecified = output token
        // For exact output (amountSpecified > 0): unspecified = input token
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 hookFee = uint256(SafeCast.toUint128(swapAmount)) / 20; // 5% of output
        if (hookFee > 0) {
            Currency expectedCurrency = Currency.wrap(address(feeToken));
            if (!(feeCurrency == expectedCurrency)) {
                emit HookRewardSkipped(key.toId(), feeCurrency, expectedCurrency, hookFee);
                return (IHooks.afterSwap.selector, 0);
            }

            // take() sends tokens from pool to vault and creates -hookFee delta for this hook.
            // Returning +hookFee cancels that delta so NonzeroDeltaCount stays 0.
            poolManager.take(feeCurrency, address(vault), hookFee);
            vault.addRewards(hookFee);
            emit HookRewardRouted(key.toId(), feeCurrency, address(vault), hookFee);
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

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        address identity = _resolveIdentity(sender, hookData);

        // LP identity lock: can only remove liquidity you personally added
        if (params.liquidityDelta >= 0) return IHooks.beforeRemoveLiquidity.selector;
        uint128 requested = uint128(uint256(-params.liquidityDelta));
        if (requested > userLiquidity[identity]) revert LPNotVerified();
        userLiquidity[identity] -= requested;
        emit LiquidityUnlocked(identity, requested, userLiquidity[identity]);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    function _identityFee(address user) internal view returns (uint24) {
        if (!isCompliant[user]) return TIER0_FEE; // 2.0% — unverified
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - complianceSince[user] >= TIER2_THRESHOLD) return TIER2_FEE; // 0.15% — long-term
        return TIER1_FEE; // 0.3% — standard SBT holder
    }

    function _toUint24(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) revert SafeCast.SafeCastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(value);
    }

    function _resolveIdentity(address sender, bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 0) return sender;
        address identity = abi.decode(hookData, (address));
        if (identity == sender || authorizedIdentityRelayer[sender]) return identity;
        revert UnauthorizedIdentityRelayer();
    }
}
