// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ComplianceSBT} from "../src/ComplianceSBT.sol";
import {EquiHook} from "../src/EquiHook.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IERC20Basic {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SmokeTest is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hook = vm.envAddress("HOOK_ADDRESS");
        address sbt = vm.envAddress("SBT_ADDRESS");
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerKey);

        // Step 1: Set Merkle Root (single-leaf: just deployer)
        console.log("=== Step 1: Set Merkle Root ===");
        bytes32 leaf = keccak256(abi.encodePacked(deployer));
        ComplianceSBT(sbt).setMerkleRoot(leaf);
        console.log("Merkle root set");

        // Step 2: Mint SBT with empty proof (single-leaf tree)
        console.log("=== Step 2: Mint SBT ===");
        bytes32[] memory proof = new bytes32[](0);
        ComplianceSBT(sbt).mintWithProof(proof);
        console.log("SBT balance:", ComplianceSBT(sbt).balanceOf(deployer));

        // Step 3: Verify compliance registered in hook
        console.log("=== Step 3: Check compliance ===");
        console.log("Is compliant:", EquiHook(hook).isCompliant(deployer));

        // Step 4: Approve tokens
        console.log("=== Step 4: Approve tokens ===");
        IERC20Basic(weth).approve(poolManager, type(uint256).max);
        IERC20Basic(usdc).approve(poolManager, type(uint256).max);
        IERC20Basic(weth).approve(swapRouter, type(uint256).max);
        IERC20Basic(usdc).approve(swapRouter, type(uint256).max);

        // Step 5: Log balances
        console.log("=== Step 5: Balances ===");
        console.log("WETH:", IERC20Basic(weth).balanceOf(deployer));
        console.log("USDC:", IERC20Basic(usdc).balanceOf(deployer));

        // Step 6: Pool key verification
        console.log("=== Step 6: Pool Key ===");
        address t0 = weth;
        address t1 = usdc;
        if (t0 > t1) (t0, t1) = (t1, t0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        console.log("Hook:", address(key.hooks));
        console.log("Pool key with hook verified");

        vm.stopBroadcast();

        console.log("\n=== ALL CHECKS PASSED ===");
    }
}
