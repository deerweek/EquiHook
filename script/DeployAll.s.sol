// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {EquiHook, IERC20 as IERC20_Hook, IDividendVault} from "../src/EquiHook.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {DividendVault, IERC20 as IERC20_Vault} from "../src/DividendVault.sol";

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

contract HookFactory {
    function deploy(
        IPoolManager poolManager,
        IDividendVault vault,
        IERC20_Hook feeToken,
        uint256 salt
    ) external returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(EquiHook).creationCode,
            abi.encode(poolManager, vault, feeToken)
        );
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
        return addr;
    }

    function computeAddress(
        uint256 salt,
        IPoolManager poolManager,
        IDividendVault vault,
        IERC20_Hook feeToken
    ) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(EquiHook).creationCode,
            abi.encode(poolManager, vault, feeToken)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock tokens
        MockERC20 token0 = new MockERC20("Wrapped ETH", "WETH");
        MockERC20 token1 = new MockERC20("USD Coin", "USDC");
        console.log("Token0 (WETH):", address(token0));
        console.log("Token1 (USDC):", address(token1));

        // 2. Deploy PoolManager
        PoolManager poolManager = new PoolManager(deployer);
        console.log("PoolManager:", address(poolManager));

        // 3. Deploy PoolSwapTest (swap router)
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        console.log("SwapRouter:", address(swapRouter));

        // 4. Deploy DividendVault
        DividendVault vault = new DividendVault(IERC20_Vault(address(token1)), address(0));
        console.log("DividendVault:", address(vault));

        // 5. Deploy HookFactory and mine salt for CREATE2
        HookFactory factory = new HookFactory();
        uint160 requiredFlags = (1 << 7) | (1 << 6) | (1 << 11);
        uint256 salt = 0;
        address hookAddr = address(0);
        for (uint256 s = 0; s < 500000; s++) {
            address predicted = factory.computeAddress(
                s,
                IPoolManager(address(poolManager)),
                IDividendVault(address(vault)),
                IERC20_Hook(address(token1))
            );
            if (uint160(predicted) & 0x3FFF == requiredFlags) {
                salt = s;
                hookAddr = predicted;
                break;
            }
        }
        require(hookAddr != address(0), "No valid hook address found");
        console.log("Hook salt:", salt);
        console.log("Hook address:", hookAddr);

        // Deploy hook via factory
        EquiHook hook = EquiHook(factory.deploy(
            IPoolManager(address(poolManager)),
            IDividendVault(address(vault)),
            IERC20_Hook(address(token1)),
            salt
        ));
        require(address(hook) == hookAddr, "Address mismatch");
        vault.setHook(address(hook));
        console.log("EquiHook deployed:", address(hook));

        // 6. Deploy ComplianceSBT
        ComplianceSBT sbt = new ComplianceSBT("EquiHook KYC", "EHKYC", address(hook));
        console.log("ComplianceSBT:", address(sbt));

        // 7. Sort tokens
        address tokenA = address(token0);
        address tokenB = address(token1);
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // 8. Create pool with hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        poolManager.initialize(key, sqrtPriceX96);
        console.log("Pool initialized");

        // 9. Mint test tokens
        token0.mint(deployer, 1000e18);
        token1.mint(deployer, 1000000e6);
        console.log("Test tokens minted to deployer");

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("PoolManager:", address(poolManager));
        console.log("EquiHook:", address(hook));
        console.log("ComplianceSBT:", address(sbt));
        console.log("DividendVault:", address(vault));
        console.log("SwapRouter:", address(swapRouter));
        console.log("Token0 (WETH):", address(token0));
        console.log("Token1 (USDC):", address(token1));
    }
}
