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

    address public owner;

    error NotOwner();
    error NotHook();
    error NothingToClaim();

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
        rewardToken.transferFrom(msg.sender, address(this), amount);
        totalRewards += amount;
        if (compliantUserCount > 0) {
            rewardPerTokenStored += (amount * 1e18) / compliantUserCount;
        }
    }

    function setCompliantUserCount(uint256 count) external onlyOwner {
        compliantUserCount = count;
    }

    function setHook(address _hook) external onlyOwner {
        hook = IEquiHookVault(_hook);
    }

    function claim() external {
        uint256 owed = earned(msg.sender);
        if (owed == 0) revert NothingToClaim();

        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        claimable[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
    }

    function earned(address user) public view returns (uint256) {
        return claimable[user] +
            (rewardPerTokenStored - userRewardPerTokenPaid[user]) / 1e18;
    }
}
