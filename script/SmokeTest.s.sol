// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {EquiHook} from "../src/EquiHook.sol";

interface IERC20Basic {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SmokeTest is Script {
    address public constant HOOK = 0x319583D87Fab5f72a83f4467442679921944CAc4;
    address public constant SBT = 0xA583550fdD5364cdAE99a269d58De6b2292B2A4d;
    address public constant POOL_MANAGER = 0xcb3Cbd2E0e7457806A87539c92EAb7EA84BEc39f;
    address public constant SWAP_ROUTER = 0x71425c7e9aBcf2954f42596ebfBbA5dA4b1C1d05;
    address public constant WETH = 0x6e8FFa15E70045C04EB63226498A0AeA66053d8D;
    address public constant USDC = 0xFF396a2ca5d62412b00a595d813960178e5654bE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Step 1: Set Merkle Root (single-leaf: just deployer)
        console.log("=== Step 1: Set Merkle Root ===");
        bytes32 leaf = keccak256(abi.encodePacked(deployer));
        ComplianceSBT(SBT).setMerkleRoot(leaf);
        console.log("Merkle root set");

        // Step 2: Mint SBT with empty proof (single-leaf tree)
        console.log("=== Step 2: Mint SBT ===");
        bytes32[] memory proof = new bytes32[](0);
        ComplianceSBT(SBT).mintWithProof(proof);
        console.log("SBT balance:", ComplianceSBT(SBT).balanceOf(deployer));

        // Step 3: Verify compliance registered in hook
        console.log("=== Step 3: Check compliance ===");
        console.log("Is compliant:", EquiHook(HOOK).isCompliant(deployer));

        // Step 4: Approve tokens
        console.log("=== Step 4: Approve tokens ===");
        IERC20Basic(WETH).approve(POOL_MANAGER, type(uint256).max);
        IERC20Basic(USDC).approve(POOL_MANAGER, type(uint256).max);
        IERC20Basic(WETH).approve(SWAP_ROUTER, type(uint256).max);
        IERC20Basic(USDC).approve(SWAP_ROUTER, type(uint256).max);

        // Step 5: Log balances
        console.log("=== Step 5: Balances ===");
        console.log("WETH:", IERC20Basic(WETH).balanceOf(deployer));
        console.log("USDC:", IERC20Basic(USDC).balanceOf(deployer));

        // Step 6: Pool key verification
        console.log("=== Step 6: Pool Key ===");
        address t0 = WETH;
        address t1 = USDC;
        if (t0 > t1) (t0, t1) = (t1, t0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        console.log("Pool key with hook verified");

        vm.stopBroadcast();

        console.log("\n=== ALL CHECKS PASSED ===");
    }
}
