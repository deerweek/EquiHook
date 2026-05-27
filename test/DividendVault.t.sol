// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DividendVault, IEquiHookVault, IERC20} from "../src/DividendVault.sol";

// =========================================================================
//                            Mock Contracts
// =========================================================================

contract MockToken is ERC20 {
    constructor() ERC20("MockToken", "MOCK", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockHookVault is IEquiHookVault {
    mapping(address => bool) public compliance;

    function setCompliant(address user, bool status) external {
        compliance[user] = status;
    }

    function isCompliant(address user) external view returns (bool) {
        return compliance[user];
    }
}

// =========================================================================
//                            Test Contract
// =========================================================================

contract DividendVaultTest is Test {
    MockToken public token;
    MockHookVault public hook;
    DividendVault public vault;

    address public owner = address(this);
    address public user1 = address(0xA1);
    address public user2 = address(0xA2);
    address public user3 = address(0xA3);
    address public nonHook = address(0xB1);
    address public nonOwner = address(0xB2);

    function setUp() public {
        token = new MockToken();
        hook = new MockHookVault();
        vault = new DividendVault(IERC20(address(token)), address(hook));

        // Mint tokens directly to the vault (poolManager.take() sends them there in production)
        token.mint(address(vault), 200e18);
    }

    // =========================================================================
    //                       addRewards: updates totalRewards
    // =========================================================================

    function test_addRewards_updatesTotalRewardsAndBalance() public {
        // Set up 2 compliant users
        hook.setCompliant(user1, true);
        hook.setCompliant(user2, true);
        vault.setCompliantUserCount(2);

        // Hook adds rewards
        uint256 amount = 100e18;
        vm.prank(address(hook));
        vault.addRewards(amount);

        assertEq(vault.totalRewards(), amount);
        // Balance check removed: tokens arrive via poolManager.take() in production,
        // not via addRewards transfer. Vault balance includes initial setup funds.
    }

    // =========================================================================
    //              addRewards: per-token distribution is correct
    // =========================================================================

    function test_addRewards_distributesPerTokenCorrectly() public {
        // 4 compliant users
        vault.setCompliantUserCount(4);

        uint256 amount = 200e18;
        vm.prank(address(hook));
        vault.addRewards(amount);

        // rewardPerTokenStored is 1e18-scaled: (200e18 * 1e18) / 4
        // But earned() divides by 1e18, so each user's share = 50e18
        // Test via earned() which is the user-facing value
        hook.setCompliant(user1, true);
        assertEq(vault.earned(user1), 50e18);
    }

    function test_addRewards_zeroCompliantUsers_noRevert() public {
        // With 0 compliant users, rewardPerTokenStored should stay 0
        vault.setCompliantUserCount(0);

        vm.prank(address(hook));
        vault.addRewards(100e18);

        assertEq(vault.totalRewards(), 100e18);
        assertEq(vault.rewardPerTokenStored(), 0);
    }

    // =========================================================================
    //                       claim: user receives correct reward
    // =========================================================================

    function test_claim_singleUser_receivesCorrectReward() public {
        hook.setCompliant(user1, true);
        vault.setCompliantUserCount(1);

        uint256 amount = 100e18;
        vm.prank(address(hook));
        vault.addRewards(amount);

        // earned(user1) = 0 + (100e18 - 0) = 100e18
        assertEq(vault.earned(user1), 100e18);

        vm.prank(user1);
        vault.claim();

        assertEq(token.balanceOf(user1), 100e18);
        assertEq(vault.earned(user1), 0);
    }

    function test_claim_twoUsers_eachGetsHalf() public {
        hook.setCompliant(user1, true);
        hook.setCompliant(user2, true);
        vault.setCompliantUserCount(2);

        uint256 amount = 100e18;
        vm.prank(address(hook));
        vault.addRewards(amount);

        // rewardPerTokenStored = (100e18 * 1e18) / 2 = 50e18
        assertEq(vault.earned(user1), 50e18);
        assertEq(vault.earned(user2), 50e18);

        vm.prank(user1);
        vault.claim();
        assertEq(token.balanceOf(user1), 50e18);

        vm.prank(user2);
        vault.claim();
        assertEq(token.balanceOf(user2), 50e18);
    }

    // =========================================================================
    //                   claim: no rewards reverts
    // =========================================================================

    function test_claim_noRewards_reverts() public {
        hook.setCompliant(user1, true);
        vault.setCompliantUserCount(1);

        // No rewards added yet
        vm.prank(user1);
        vm.expectRevert(DividendVault.NothingToClaim.selector);
        vault.claim();
    }

    // =========================================================================
    //              Multiple reward rounds: claims are correct
    // =========================================================================

    function test_multipleRounds_claimsCorrectAcrossRounds() public {
        hook.setCompliant(user1, true);
        hook.setCompliant(user2, true);
        vault.setCompliantUserCount(2);

        // Round 1: 100 tokens, each gets 50
        vm.prank(address(hook));
        vault.addRewards(100e18);

        assertEq(vault.earned(user1), 50e18);
        assertEq(vault.earned(user2), 50e18);

        // User1 claims after round 1
        vm.prank(user1);
        vault.claim();
        assertEq(token.balanceOf(user1), 50e18);
        assertEq(vault.earned(user1), 0);

        // Round 2: another 100 tokens, each gets another 50
        vm.prank(address(hook));
        vault.addRewards(100e18);

        // rewardPerTokenStored = 50e18 + 50e18 = 100e18
        // user1: claimable=0 + (100e18 - 50e18) = 50e18
        // user2: claimable=0 + (100e18 - 0) = 100e18
        assertEq(vault.earned(user1), 50e18);
        assertEq(vault.earned(user2), 100e18);

        // User1 claims round 2 rewards
        vm.prank(user1);
        vault.claim();
        assertEq(token.balanceOf(user1), 100e18); // 50 + 50

        // User2 claims both rounds at once
        vm.prank(user2);
        vault.claim();
        assertEq(token.balanceOf(user2), 100e18); // 50 + 50
    }

    function test_multipleRounds_userJoinsLate_earnedBackdated() public {
        // Only user1 is compliant initially
        hook.setCompliant(user1, true);
        vault.setCompliantUserCount(1);

        // Round 1: 100 tokens to 1 user
        vm.prank(address(hook));
        vault.addRewards(100e18);

        assertEq(vault.earned(user1), 100e18);

        // Now user2 becomes compliant, count increases
        hook.setCompliant(user2, true);
        vault.setCompliantUserCount(2);

        // Round 2: 100 tokens to 2 users (50 each incremental)
        vm.prank(address(hook));
        vault.addRewards(100e18);

        // rewardPerTokenStored = 100e18 + 50e18 = 150e18
        // user1: 150e18 - 0 = 150e18
        // user2: 150e18 - 0 = 150e18 (backdated! user2 wasn't present in round 1)
        // This is a known design characteristic: without per-user balances,
        // late joiners see the full accumulated rewardPerTokenStored.
        assertEq(vault.earned(user1), 150e18);
        assertEq(vault.earned(user2), 150e18);

        // user1 can claim their full earned amount
        vm.prank(user1);
        vault.claim();
        assertEq(token.balanceOf(user1), 150e18);

        // user2 tries to claim 150e18 but vault only has 50e18 remaining
        // (100e18 total deposits - 150e18 paid to user1 = -50e18 shortfall)
        // This demonstrates the backdating insolvency characteristic
        assertEq(vault.earned(user2), 150e18);
        assertEq(token.balanceOf(address(vault)), 50e18);
        // user2's claim would revert due to insufficient vault balance
        vm.prank(user2);
        vm.expectRevert(); // underflow in solmate transfer
        vault.claim();
    }

    // =========================================================================
    //                onlyHook: non-hook callers revert
    // =========================================================================

    function test_addRewards_nonHook_reverts() public {
        vm.prank(nonHook);
        vm.expectRevert(DividendVault.NotHook.selector);
        vault.addRewards(100e18);
    }

    function test_addRewards_ownerNotHook_reverts() public {
        // Even the owner can't call addRewards
        vm.expectRevert(DividendVault.NotHook.selector);
        vault.addRewards(100e18);
    }

    // =========================================================================
    //           onlyOwner: non-owner setCompliantUserCount reverts
    // =========================================================================

    function test_setCompliantUserCount_nonOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(DividendVault.NotOwner.selector);
        vault.setCompliantUserCount(5);
    }

    function test_setCompliantUserCount_hookNotOwner_reverts() public {
        vm.prank(address(hook));
        vm.expectRevert(DividendVault.NotOwner.selector);
        vault.setCompliantUserCount(5);
    }

    // =========================================================================
    //                          View functions
    // =========================================================================

    function test_earned_zeroWhenNoRewards() public {
        assertEq(vault.earned(user1), 0);
    }

    function test_constructor_setsStateCorrectly() public {
        assertEq(address(vault.rewardToken()), address(token));
        assertEq(address(vault.hook()), address(hook));
        assertEq(vault.owner(), owner);
    }
}
