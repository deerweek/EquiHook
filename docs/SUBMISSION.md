# EquiHook — Hackathon Submission

## Overview

EquiHook is a Uniswap v4 Hook-based RWA infrastructure on X Layer testnet. It records KYC compliance via Soulbound Tokens (SBTs), applies identity-weighted dynamic fees through a real v4 dynamic-fee pool, resolves end-user identity through authorized hookData relayers instead of trusting router addresses, locks LP positions to verified identities, and routes excess fees to a DividendVault as synthetic dividends for compliant users.

## Core Features

1. **KYC Compliance via SBT** — Merkle-proof-based Soulbound Token minting; only the SBT contract or owner can update compliance state
2. **Identity-Weighted Dynamic Pricing** — v4 fee override on a dynamic-fee pool: 2.0% (no SBT), 0.3% (SBT holder), 0.15% (30+ day holder)
3. **Authorized Identity Relayers** — approved router/helper contracts pass the real trader or LP in `hookData`; unapproved contracts cannot spoof another user's KYC identity
4. **LP Position Identity Lock** — Liquidity providers must hold SBT; LP positions are tracked in hook's internal ledger
5. **FeeToken-Safe Dividends** — 5% of feeToken-denominated swap output routed to DividendVault, distributed pro-rata to compliant users without late-joiner backdating; non-reward-token fee paths emit a skip event instead of corrupting reward accounting
6. **On-Chain Observability** — events expose compliance syncs, fee overrides, liquidity locks, and reward routing for demo verification

## Rubric Fit

- **Innovation** — EquiHook turns a v4 pool into an identity-aware RWA market primitive: the same hook controls compliance state, per-user dynamic swap fees, LP eligibility, and fee-funded reward distribution.
- **Potential Market Value** — The design supports a realistic compliant-asset venue on X Layer: verified traders receive better execution, long-term compliant users receive discounts, LP access can be permissioned, and protocol fees can fund rewards for compliant holders.
- **Completion** — The project includes CREATE2-mined hook permission bits, real `DYNAMIC_FEE_FLAG`/`OVERRIDE_FEE_FLAG` v4 fee semantics, authorized identity relayer controls, local PoolManager E2E tests that trigger add liquidity + swap + reward routing, X Layer demo transactions, and scripts ready for final redeploy.

## Demo Deployment (X Layer Testnet, Chain ID 1952)

The addresses below are the final X Layer testnet deployment used for the on-chain evidence. The pool is initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, demo routers are authorized as identity relayers, and the hook returns `OVERRIDE_FEE_FLAG | tierFee` from `beforeSwap`, so identity pricing is applied by the v4 swap engine itself.

| Contract | Address |
|----------|---------|
| EquiHook | [`0x0f88692065F92f45B686bf6F616dfE0F32A20AC4`](https://www.oklink.com/xlayer/address/0x0f88692065F92f45B686bf6F616dfE0F32A20AC4) |
| ComplianceSBT | [`0xd4d285154F10C3037997aBDfbDf609C8656dbeD5`](https://www.oklink.com/xlayer/address/0xd4d285154F10C3037997aBDfbDf609C8656dbeD5) |
| DividendVault | [`0x70d5b1C728840f98EC682F660E8515439Bb142fF`](https://www.oklink.com/xlayer/address/0x70d5b1C728840f98EC682F660E8515439Bb142fF) |
| PoolManager | [`0xc8c1CA142f518e5E864B1326fB1742E46C47F46A`](https://www.oklink.com/xlayer/address/0xc8c1CA142f518e5E864B1326fB1742E46C47F46A) |
| SwapRouter | [`0x0670dD30ee2C7b2a5b7276Ad4Cdca91991aeE0CF`](https://www.oklink.com/xlayer/address/0x0670dD30ee2C7b2a5b7276Ad4Cdca91991aeE0CF) |
| WETH (MockERC20) | [`0x17619c650cBb8aa9AA475226384a4f26F6308926`](https://www.oklink.com/xlayer/address/0x17619c650cBb8aa9AA475226384a4f26F6308926) |
| USDC / FeeToken (MockERC20) | [`0x62bdB96b2E8733bfDB358cEf75e558dA6129c74E`](https://www.oklink.com/xlayer/address/0x62bdB96b2E8733bfDB358cEf75e558dA6129c74E) |

## On-Chain Evidence: Full E2E Swap with Hook

The FullTest script executed a complete swap lifecycle on-chain on the final deployment, proving all hook behaviors are triggered by real transactions. Approved identity relayers carry the real user identity through `hookData`, while unapproved contracts cannot spoof identities.

### Transaction Flow (15 transactions, all successful)

| Step | TX Hash | Description |
|------|---------|-------------|
| Deploy PoolModifyLiquidityTest | [`0xe113590a...`](https://www.oklink.com/xlayer/tx/0xe113590a3112fd2804ef628a7f8047d5accfc2e84e7c6879d46a88446bd40cac) | Deploy liquidity helper |
| setIdentityRelayer(liqHelper) | [`0xe48fa7a5...`](https://www.oklink.com/xlayer/tx/0xe48fa7a512b01be22e6b490ea6f5aa8c799edb678cd47da3d2ed5319998cacc8) | Authorize helper to carry `hookData` identity |
| setIdentityRelayer(SwapRouter) | [`0xf0daf7d5...`](https://www.oklink.com/xlayer/tx/0xf0daf7d5380f602f92958a5896d8bde2b8b8eb373563bfe9b20cdcd17f16112d) | Authorize swap router to carry `hookData` identity |
| setMerkleRoot | [`0x3ace6888...`](https://www.oklink.com/xlayer/tx/0x3ace6888d15f4c01ddab3f19e88ca3f10337a593d158a222e7ab398bdf0114ab) | Set Merkle root for deployer |
| mintWithProof | [`0x45e7571a...`](https://www.oklink.com/xlayer/tx/0x45e7571ab399dfdc5aacc36b48cd6ce1f4cea5e0f5fec797d02754a09bfa9c0c) | Mint SBT, register compliance |
| Approvals (x6) | [`0xf2282333...`](https://www.oklink.com/xlayer/tx/0xf2282333633df4c6830f7922ec38d3ef8fb8442a9b950f08ed058241761f2f55) et al. | Approve tokens |
| addLiquidity | [`0xd96a989d...`](https://www.oklink.com/xlayer/tx/0xd96a989ddcac05aea276e4d3ba6a21480772abca70a28f0d37eeeafd03411c3e) | Add liquidity, triggering LP identity lock |
| mint extra tokens | [`0x512fa660...`](https://www.oklink.com/xlayer/tx/0x512fa660649f2fbeaf2ecb736dff4a8a8a5858d6d1dc061fad6b3c6642051f41) | Mint tokens for swap settlement |
| **SWAP** | [`0x9a7bdb08...`](https://www.oklink.com/xlayer/tx/0x9a7bdb08ab000dd6bb478ea35d38e19f6385285ed3c132d3193ebc9324642a27) | **Exact-input swap to feeToken — hook triggers and routes rewards** |

### What the Swap Proves

The swap transaction triggers all hook behaviors:

1. **`beforeSwap`** — Resolves the real trader identity, checks compliance (`isCompliant[identity] = true`), calculates identity-weighted fee (3000 base fee for Tier 1 SBT holder), returns `OVERRIDE_FEE_FLAG | lpFee`
2. **`afterSwap`** — Calculates 5% hook fee on feeToken output, calls `poolManager.take()` to route 493 USDC raw units to DividendVault, calls `vault.addRewards(493)`, returns `+493` to cancel delta
3. **`beforeAddLiquidity`** — Enforces LP identity lock: requires SBT, tracks liquidity in hook's internal ledger
4. **Vault accumulated** — `totalRewards = 493` (verified on-chain)

### Verified On-Chain State

```
SBT balance(deployer) = 1
isCompliant(deployer) = true
Pool active liquidity = 1000000
Hook-tracked liquidity(deployer) = 1000000
Vault totalRewards = 493
Demo user earned = 493
Vault reward token balance = 493
TIER0_FEE = 20000 (2.0% — no SBT deterrent)
TIER1_FEE = 3000 (0.3% — SBT holder base)
TIER2_FEE = 1500 (0.15% — 30+ day holder discount)
```

## Deployment Transactions

| Contract | TX Hash |
|----------|---------|
| WETH (MockERC20) | [`0x9a3212d0...`](https://www.oklink.com/xlayer/tx/0x9a3212d07d4f81480f569846e7f88b2e24ac9f95fd904c8f29bf39d21ace180a) |
| USDC (MockERC20) | [`0x22ab228f...`](https://www.oklink.com/xlayer/tx/0x22ab228f03348ed2a96d06caf1bf07eba33fd2343c37ca87d5e21f1bfa79782d) |
| PoolManager | [`0x71bc7ea0...`](https://www.oklink.com/xlayer/tx/0x71bc7ea0e8cba5873822416a3e2b8cf3761ec0cfa85ca541c99ffa0685c8a508) |
| SwapRouter | [`0x860ef021...`](https://www.oklink.com/xlayer/tx/0x860ef021e908e00a462031e634d14cd24d8454fc1e7775fc6c65183455d162d0) |
| DividendVault | [`0xc478bf47...`](https://www.oklink.com/xlayer/tx/0xc478bf473ac59d2ba0c3bd2b3ea66c7d46d0055aaa620707ebad886fc910957d) |
| EquiHook (CREATE2) | [`0x3f4d35eb...`](https://www.oklink.com/xlayer/tx/0x3f4d35eb89d0a59a1617bcf3fddbfa12c74875e692d64e323d2f4df62c4d1ef3) |
| ComplianceSBT | [`0x266da00f...`](https://www.oklink.com/xlayer/tx/0x266da00f59765b0d7b706a6186a5e4e2a4d0fb81e085b300cf0c1893ad9dbc95) |
| Pool Initialize | [`0x0514cc3e...`](https://www.oklink.com/xlayer/tx/0x0514cc3e61fb715cd1f36d8f57b19489e31f5ab22417cb6542b53330c15c19e0) |

## Test Results

```
66 tests passed, 0 failed, 0 skipped

ComplianceSBT: 17/17 passed
DividendVault: 14/14 passed
EquiHook:      23/23 passed
E2E:           12/12 passed
```

## Architecture

```
User (with SBT) → PoolManager.swap() → EquiHook.beforeSwap()
                                         ├─ Resolve identity from sender or authorized hookData relayer
                                         ├─ Check isCompliant[identity]
                                         ├─ _identityFee(): 3-tier pricing
                                         │   ├─ Tier 0: 2.0% (no SBT)
                                         │   ├─ Tier 1: 0.3% (new SBT)
                                         │   └─ Tier 2: 0.15% (30+ days)
                                         └─ Size-based overlay (if swap > 2% of liquidity)
                                         └─ Return OVERRIDE_FEE_FLAG | tierFee
                                      → EquiHook.afterSwap()
                                         ├─ Calculate 5% hook fee on unspecified token
                                         ├─ If fee currency == feeToken: poolManager.take() → DividendVault
                                         ├─ vault.addRewards(fee)
                                         └─ If fee currency != feeToken: emit HookRewardSkipped
                                      → EquiHook.beforeAddLiquidity()
                                         ├─ Resolve LP identity from sender or authorized hookData relayer
                                         ├─ Require isCompliant[identity]
                                         └─ Track userLiquidity[identity]
                                      → EquiHook.beforeRemoveLiquidity()
                                         └─ Verify requested <= userLiquidity[identity]
                                      → DividendVault.syncCompliance()
                                         └─ Snapshot rewardPerToken at join/revoke time
                                      → DividendVault.claim()
                                         └─ Pro-rata distribution to eligible compliant users
```

## Hook Permission Bits

The hook address is CREATE2-mined to encode these permission bits in the low 14 bits:

| Permission | Bit | Value |
|-----------|-----|-------|
| beforeSwap | 1<<7 | 128 |
| afterSwap | 1<<6 | 64 |
| beforeAddLiquidity | 1<<11 | 2048 |
| beforeRemoveLiquidity | 1<<9 | 512 |
| afterSwapReturnDelta | 1<<2 | 4 |

Required flags: `0x0AC4` (beforeSwap + afterSwap + beforeAddLiquidity + beforeRemoveLiquidity + afterSwapReturnDelta)

## Key Design Decisions

1. **Identity-Weighted Pricing** — Fee depends on WHO is trading, not just HOW MUCH. 3-tier structure incentivizes KYC compliance and long-term participation.
2. **LP Position Identity Lock** — `beforeAddLiquidity` requires SBT and tracks liquidity in hook's ledger. `beforeRemoveLiquidity` enforces that you can only remove what you personally added. Prevents anonymous LP positions.
3. **FeeTakingHook pattern** — Hook uses `poolManager.take()` to extract fees, then returns `+hookFee` from `afterSwap` to cancel the delta. This ensures `NonzeroDeltaCount = 0` after the swap.
4. **Unspecified token fee** — Fee is taken from the unspecified token (output for exact-input, input for exact-output), matching the Uniswap v4 FeeTakingHook pattern.
5. **FeeToken-safe reward accumulator with snapshots** — `rewardPerTokenStored` tracks cumulative reward per compliant user; `syncCompliance(user)` snapshots users when they join or leave so new users cannot claim past rewards. The hook only routes configured `feeToken` rewards to the single-token vault and emits `HookRewardSkipped` for other swap directions.
6. **Soulbound SBT** — ERC721 with all transfer functions overridden to revert. KYC is non-transferable.
7. **Restricted compliance authority** — `registerCompliance` and `clearCompliance` are limited to the SBT issuer or owner, preventing arbitrary self-registration.
8. **Native v4 dynamic fee integration** — Pools are initialized with `DYNAMIC_FEE_FLAG`, and `beforeSwap` returns `OVERRIDE_FEE_FLAG | fee`, making identity pricing a real swap-time fee override.
9. **Authorized router-safe user binding** — `hookData` carries the real trader or LP identity only when the caller is the user or an owner-approved relayer, avoiding both router-address mispricing and identity spoofing.

## Build & Run

```bash
# Run all tests
forge test -v

# Deploy on X Layer testnet
PRIVATE_KEY=<key> forge script script/DeployAll.s.sol --tc DeployAll --rpc-url https://testrpc.xlayer.tech --broadcast

# Copy the export block printed by DeployAll before running the demo scripts
export HOOK_ADDRESS=<hook>
export SBT_ADDRESS=<sbt>
export VAULT_ADDRESS=<vault>
export POOL_MANAGER_ADDRESS=<poolManager>
export SWAP_ROUTER_ADDRESS=<router>
export WETH_ADDRESS=<weth>
export USDC_ADDRESS=<usdc>
export FEE_TOKEN_ADDRESS=<usdc>

# Run FullTest (SBT mint + liquidity + swap + verify vault rewards)
PRIVATE_KEY=<key> forge script script/FullTest.s.sol --tc FullTest --rpc-url https://testrpc.xlayer.tech --broadcast

# Copy the demo user printed by FullTest
export DEMO_USER_ADDRESS=<deployer>

# Verify final deployment wiring, dynamic-fee pool liquidity, and post-swap E2E state
forge script script/VerifySubmission.s.sol --tc VerifySubmission --rpc-url https://testrpc.xlayer.tech
```
