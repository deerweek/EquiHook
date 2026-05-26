# EquiHook Design Spec

**Date:** 2026-05-26
**Status:** Approved for implementation
**Deadline:** 2026-05-28 23:59 UTC (hackathon submission)

## Overview

EquiHook is a Uniswap v4 Hook-based RWA infrastructure deployed on X Layer. It combines KYC-gated compliance via Soulbound Tokens with a dynamic fee mechanism that converts slippage into synthetic dividends for compliant token holders.

**Core value prop:** Every large trade that would normally extract value from LPs automatically redistributes as yield to long-term compliant holders.

## Architecture

### Contracts (3 total)

#### 1. ComplianceSBT.sol

Soulbound Token for KYC-gated pool access.

**Functions:**
- `setMerkleRoot(bytes32 root)` — Admin sets the KYC whitelist Merkle Root (one-time)
- `mintWithProof(bytes32[] calldata proof)` — User provides Merkle Proof, contract verifies `msg.sender` is in the whitelist, mints SBT, calls `EquiHook.registerCompliance(msg.sender)`
- `revoke(address user)` — Admin revokes a user's SBT and clears their compliance status in the Hook
- Override `transferFrom` / `safeTransferFrom` to revert (true soulbound)

**Design notes:**
- Each address can only mint once (check `balanceOf == 0` before mint)
- On revoke, call `EquiHook.clearCompliance(user)` to sync state
- Uses standard ERC721 with transfer disabled

#### 2. EquiHook.sol (Core Hook)

Main Uniswap v4 Hook contract.

**State:**
```solidity
mapping(address => bool) public isCompliant;
ISBT public sbt;
IDividendVault public vault;
uint256 public baseFee;        // e.g., 3000 (0.3%)
uint256 public maxFee;         // e.g., 20000 (2%)
uint256 public liquidityThresholdBps; // e.g., 200 (2% in basis points)
```

**Functions:**
- `registerCompliance(address user)` — idempotent, sets `isCompliant[user] = true`
- `clearCompliance(address user)` — sets `isCompliant[user] = false`
- `beforeSwap(PoolKey, SwapParams, ...) returns (BeforeSwapDelta, uint24 lpFeeOverride)`
  1. Check `isCompliant[msg.sender]` — revert if false
  2. Get pool liquidity via `poolManager.getLiquidity(key.toId())`
  3. Calculate `ratioBps = (swapAmount * 10000) / liquidity`
  4. If `ratioBps < liquidityThresholdBps`: return `lpFeeOverride = baseFee`
  5. Else: return `lpFeeOverride = min(baseFee + feeIncrease, maxFee)`
- `afterSwap(PoolKey, SwapParams, BalanceDelta, ...)`
  1. Calculate Hook Fee earned from this swap
  2. Transfer fee tokens to `DividendVault`
  3. Call `vault.addRewards(amount)`
- `beforeAddLiquidity(PoolKey, ...)`
  1. Check `isCompliant[msg.sender]` — revert if false

**Hook flags (encoded in address):**
- `beforeSwap` (0x40)
- `afterSwap` (0x80)
- `beforeAddLiquidity` (0x04)

**Security:**
- All callbacks have `onlyPoolManager` modifier
- Use `hook-miner` to find a deploy address with correct flag bits

#### 3. DividendVault.sol

Manages synthetic dividend accumulation and claims.

**State:**
```solidity
uint256 public totalRewards;
mapping(address => uint256) public claimable;
IHook public hook;
```

**Functions:**
- `addRewards(uint256 amount)` — Called by EquiHook after each swap, receives the pool's quote token (e.g., USDC) and increments `totalRewards`
- `claim()` — User claims their share of accumulated rewards
  - MVP logic: track a global `rewardPerToken` accumulator (similar to Synthetix StakingRewards)
  - On `addRewards`: `rewardPerToken += amount / totalCompliantUsers`
  - On `claim()`: user receives `rewardPerToken - userLastClaimed`, update `userLastClaimed`
  - Transfer quote tokens to `msg.sender`

## Dynamic Fee Calculation

```
ratioBps = (swapAmount * 10000) / poolLiquidity  // basis points

If ratioBps < liquidityThresholdBps:
  effectiveFee = baseFee
Else:
  feeIncrease = (ratioBps - liquidityThresholdBps) * scalingFactor
  effectiveFee = min(baseFee + feeIncrease, maxFee)

Where:
- baseFee = 3000 (0.3%)
- maxFee = 20000 (2%)
- liquidityThresholdBps = 200 (2%)
- scalingFactor = tunable, e.g., 10
```

The fee increase scales linearly with the swap-to-liquidity ratio. Large trades (whales, MEV) pay significantly more, and the excess flows to compliant holders as synthetic dividends.

## User Flow

```
Admin (one-time):
  ComplianceSBT.setMerkleRoot(merkleRoot)

User onboarding:
  1. User completes KYC externally (off-chain)
  2. Admin adds user address to Merkle tree
  3. User calls ComplianceSBT.mintWithProof(proof)
  4. SBT minted + EquiHook.registerCompliance(user) called

Trading:
  1. User initiates Swap on v4 Pool
  2. EquiHook.beforeSwap: check compliance + calculate dynamic fee
  3. Swap executes at dynamic fee rate
  4. EquiHook.afterSwap: transfer excess fee to DividendVault

Claiming:
  1. User calls DividendVault.claim()
  2. Receives synthetic dividend tokens
```

## Dependencies

- Uniswap v4-core (`@uniswap/v4-core`)
- Uniswap v4-periphery (`@uniswap/v4-periphery`)
- Foundry/Forge for build and test
- Solidity >= 0.8.24

## Target Network

- X Layer testnet (Chain ID 195) for development and testing
- X Layer mainnet (Chain ID 196) for final deployment if v4 is available
- Uniswap v4 not yet confirmed on X Layer — deploy Hook first, point to PoolManager when available

## MVP Success Criteria

All of the following must work end-to-end for the demo to count as success:

1. User self-mints ComplianceSBT via Merkle Proof (soulbound, non-transferable)
2. Only SBT holders can execute Swap and Add Liquidity (others get reverted)
3. `beforeSwap` implements dynamic fee based on swapAmount / poolLiquidity ratio
4. Swap fees partially flow to DividendVault as Hook Fee
5. Users can call `claim()` to withdraw their share from DividendVault
6. All contracts deployed on X Layer testnet with verifiable addresses:
   - Hook contract address
   - Pool address (created via official PoolManager)
7. All code compiles with no errors, core flow (`mint -> addLiq -> swap -> claim`) runs on testnet

## Out of Scope (MVP)

- Frontend UI (time constraint)
- Complex snapshot mechanism for dividend distribution
- Oracle-based price deviation for dynamic fees
- AI Agent integration (future enhancement)
- Self-deploying Uniswap v4 infrastructure

## Future Enhancements

- AI Agent for adaptive fee curves based on market conditions
- Oracle price deviation integration for more precise dynamic fees
- Snapshot-based pro-rata dividend distribution
- Frontend for seamless user onboarding and trading
- Multi-pool support for multiple RWA assets
