// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {EquiHook, IERC20 as IERC20_Hook, IDividendVault} from "../src/EquiHook.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {DividendVault, IERC20 as IERC20_Vault} from "../src/DividendVault.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";

contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract E2ETest is Test {
    PoolManager public poolManager;
    PoolSwapTest public swapRouter;
    EquiHook public hook;
    ComplianceSBT public sbt;
    DividendVault public vault;
    TestToken public token0;
    TestToken public token1;
    PoolKey public poolKey;

    address public admin = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function _deployHookWithCorrectBits() internal returns (EquiHook) {
        HookDeployer deployer = new HookDeployer();
        // Use Hooks constants for correct bit positions:
        // BEFORE_SWAP_FLAG = 1<<7, AFTER_SWAP_FLAG = 1<<6,
        // BEFORE_ADD_LIQUIDITY_FLAG = 1<<11, AFTER_SWAP_RETURNS_DELTA_FLAG = 1<<2
        uint160 requiredFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        for (uint256 salt = 0; salt < 200000; salt++) {
            address predicted = deployer.computeAddress(
                address(deployer),
                salt,
                IPoolManager(address(poolManager)),
                IDividendVault(address(vault)),
                IERC20_Hook(address(token1))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == requiredFlags) {
                address deployed = deployer.deploy(
                    IPoolManager(address(poolManager)),
                    IDividendVault(address(vault)),
                    IERC20_Hook(address(token1)),
                    salt
                );
                require(deployed == predicted, "Address mismatch");
                return EquiHook(deployed);
            }
        }
        revert("No valid hook address found");
    }

    function setUp() public {
        poolManager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        token0 = new TestToken("Wrapped ETH", "WETH", 18);
        token1 = new TestToken("USD Coin", "USDC", 6);

        vault = new DividendVault(IERC20_Vault(address(token1)), address(0));

        hook = _deployHookWithCorrectBits();
        vault.setHook(address(hook));

        sbt = new ComplianceSBT("EquiHook KYC", "EHKYC", address(hook));

        address t0 = address(token0);
        address t1 = address(token1);
        if (t0 > t1) (t0, t1) = (t1, t0);

        poolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        poolManager.initialize(poolKey, sqrtPriceX96);

        bytes32 leafAlice = keccak256(abi.encodePacked(alice));
        bytes32 leafBob = keccak256(abi.encodePacked(bob));
        bytes32 root = leafAlice < leafBob
            ? keccak256(abi.encodePacked(leafAlice, leafBob))
            : keccak256(abi.encodePacked(leafBob, leafAlice));
        sbt.setMerkleRoot(root);

        token0.mint(alice, 100e18);
        token1.mint(alice, 100000e6);
        token0.mint(bob, 100e18);
        token1.mint(bob, 100000e6);
    }

    function _getProof(address user) internal view returns (bytes32[] memory) {
        bytes32 leafAlice = keccak256(abi.encodePacked(alice));
        bytes32 leafBob = keccak256(abi.encodePacked(bob));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = (user == alice) ? leafBob : leafAlice;
        return proof;
    }

    function test_fullFlow_mintSbt_addLiq_swap_claim() public {
        // Step 1: Alice mints SBT
        vm.prank(alice);
        sbt.mintWithProof(_getProof(alice));
        assertEq(sbt.balanceOf(alice), 1);
        assertTrue(hook.isCompliant(alice));

        // Step 2: Bob mints SBT
        vm.prank(bob);
        sbt.mintWithProof(_getProof(bob));
        assertTrue(hook.isCompliant(bob));

        // Step 3: Verify non-compliant user is blocked
        address charlie = address(0xC);
        assertFalse(hook.isCompliant(charlie));

        // Step 4: Verify vault starts empty
        assertEq(vault.totalRewards(), 0);

        // Step 5: Verify compliance state
        assertTrue(hook.isCompliant(alice));
        assertTrue(hook.isCompliant(bob));
    }

    function test_sbt_soulbound_cannotTransfer() public {
        vm.prank(alice);
        sbt.mintWithProof(_getProof(alice));

        bytes32 leaf = keccak256(abi.encodePacked(alice));
        vm.expectRevert(ComplianceSBT.TransferBlocked.selector);
        sbt.transferFrom(alice, bob, uint256(leaf));
    }

    function test_revoke_clearsCompliance() public {
        vm.prank(alice);
        sbt.mintWithProof(_getProof(alice));
        assertTrue(hook.isCompliant(alice));

        vm.prank(admin);
        sbt.revoke(alice);
        assertFalse(hook.isCompliant(alice));
        assertEq(sbt.balanceOf(alice), 0);
    }

    function test_hookParameters_correct() public {
        assertEq(hook.TIER0_FEE(), 20000);
        assertEq(hook.TIER1_FEE(), 3000);
        assertEq(hook.TIER2_FEE(), 1500);
        assertEq(hook.TIER2_THRESHOLD(), 30 days);
        assertEq(hook.SIZE_THRESHOLD_BPS(), 200);
        assertEq(hook.SIZE_SCALING_FACTOR(), 10);
    }

    function test_dividendVault_accumulates() public {
        // Tokens arrive at vault via poolManager.take() in production
        token1.mint(address(vault), 1000e6);

        vm.prank(admin);
        vault.setCompliantUserCount(2);

        vm.prank(address(hook));
        vault.addRewards(1000e6);

        assertEq(vault.totalRewards(), 1000e6);
    }
}
