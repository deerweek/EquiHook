// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEquiHookVault {
    function isCompliant(address user) external view returns (bool);
}

contract DividendVault {
    IERC20 public rewardToken;
    IEquiHookVault public hook;

    uint256 public totalRewards;
    uint256 public rewardPerTokenStored;
    uint256 public compliantUserCount;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public claimable;
    mapping(address => bool) public isRewardParticipant;

    address public owner;

    error NotOwner();
    error NotHook();
    error NothingToClaim();
    error TransferFailed();

    event RewardsAdded(uint256 amount, uint256 rewardPerTokenStored);
    event ComplianceSynced(address indexed user, bool active, uint256 compliantUserCount);
    event RewardsClaimed(address indexed user, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != address(hook)) revert NotHook();
        _;
    }

    constructor(IERC20 _rewardToken, address _hook) {
        rewardToken = _rewardToken;
        hook = IEquiHookVault(_hook);
        owner = msg.sender;
    }

    function addRewards(uint256 amount) external onlyHook {
        // Tokens are already at the vault via poolManager.take() — no transfer needed.
        totalRewards += amount;
        if (compliantUserCount > 0) {
            rewardPerTokenStored += (amount * 1e18) / compliantUserCount;
        }
        emit RewardsAdded(amount, rewardPerTokenStored);
    }

    function syncCompliance(address user) external onlyHook {
        bool compliant = hook.isCompliant(user);
        bool active = isRewardParticipant[user];

        if (compliant && !active) {
            isRewardParticipant[user] = true;
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
            compliantUserCount += 1;
        } else if (!compliant && active) {
            claimable[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
            isRewardParticipant[user] = false;
            compliantUserCount -= 1;
        }
        emit ComplianceSynced(user, isRewardParticipant[user], compliantUserCount);
    }

    function setHook(address _hook) external onlyOwner {
        hook = IEquiHookVault(_hook);
    }

    function claim() external {
        uint256 owed = earned(msg.sender);
        if (owed == 0) revert NothingToClaim();

        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        claimable[msg.sender] = 0;
        if (!rewardToken.transfer(msg.sender, owed)) revert TransferFailed();
        emit RewardsClaimed(msg.sender, owed);
    }

    function earned(address user) public view returns (uint256) {
        uint256 accrued = claimable[user];
        if (isRewardParticipant[user]) {
            accrued += (rewardPerTokenStored - userRewardPerTokenPaid[user]) / 1e18;
        }
        return accrued;
    }
}
