// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {EquiHook, IERC20 as IERC20_Hook, IDividendVault} from "../src/EquiHook.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {DividendVault, IERC20 as IERC20_Vault} from "../src/DividendVault.sol";

// Simple ERC20 for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock tokens
        MockERC20 token0 = new MockERC20("Wrapped ETH", "WETH");
        MockERC20 token1 = new MockERC20("USD Coin", "USDC");
        console.log("Token0 (WETH):", address(token0));
        console.log("Token1 (USDC):", address(token1));

        // 2. Deploy PoolManager
        PoolManager poolManager = new PoolManager(address(this));
        console.log("PoolManager:", address(poolManager));

        // 3. Deploy PoolSwapTest (swap router for testing)
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        console.log("PoolSwapTest (SwapRouter):", address(swapRouter));

        // 4. Deploy DividendVault (hook address set after EquiHook deploy)
        DividendVault vault = new DividendVault(
            IERC20_Vault(address(token1)), // USDC as reward token
            address(0) // placeholder
        );
        console.log("DividendVault:", address(vault));

        // 5. Deploy EquiHook
        // NOTE: For production, use CREATE2 with hook-miner to get correct address bits
        // For MVP demo, deploy directly and verify permissions
        EquiHook hook = new EquiHook(
            IPoolManager(address(poolManager)),
            IDividendVault(address(vault)),
            IERC20_Hook(address(token1))
        );
        vault.setHook(address(hook));
        console.log("EquiHook:", address(hook));

        // 6. Deploy ComplianceSBT
        ComplianceSBT sbt = new ComplianceSBT(
            "EquiHook KYC",
            "EHKYC",
            address(hook)
        );
        console.log("ComplianceSBT:", address(sbt));

        // 7. Sort tokens (v4 requires token0 < token1)
        address tokenA = address(token0);
        address tokenB = address(token1);
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // 8. Create pool with hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 3000, // 0.3% - will be overridden by hook's dynamic fee
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at price 1:1 (sqrtPriceX96 = 1.0 * 2^96)
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96
        poolManager.initialize(key, sqrtPriceX96);
        console.log("Pool initialized");

        // 9. Mint test tokens to deployer
        token0.mint(msg.sender, 1000e18);
        token1.mint(msg.sender, 1000000e6);
        console.log("Test tokens minted to deployer");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("PoolManager:", address(poolManager));
        console.log("EquiHook:", address(hook));
        console.log("ComplianceSBT:", address(sbt));
        console.log("DividendVault:", address(vault));
        console.log("SwapRouter:", address(swapRouter));
        console.log("Token0 (WETH):", address(token0));
        console.log("Token1 (USDC):", address(token1));
    }
}
