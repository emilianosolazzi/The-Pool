// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {VaultOwnerController} from "../src/VaultOwnerController.sol";

/// @notice Deploys VaultOwnerController for an already-deployed LiquidityVaultV2.
///
/// @dev    Required env:
///           VAULT          existing LiquidityVaultV2 address
///           SAFE           Safe/multisig (becomes controller owner)
///
///         After this script:
///           1. Current vault owner must call:
///                vault.transferOwnership(controller)
///           2. Anyone (or the Safe) calls:
///                controller.acceptVaultOwnership()
///           3. Safe calls:
///                controller.setReserveKeeper(hotKeeperEOA, true)
///           4. Update keeper service env:
///                KEEPER_WRITE_TARGET=<controller address>
///                (VAULT stays the same; reads keep using it.)
///
///         The hook is NOT touched. The pool is NOT touched. The vault is
///         NOT redeployed. registeredVault[poolId] continues to point at
///         the existing vault, which still calls the hook in its own name.
contract DeployController is Script {
    function run() external returns (VaultOwnerController controller) {
        address vault = vm.envAddress("VAULT");
        address safe = vm.envAddress("SAFE");

        require(vault != address(0), "VAULT_ZERO");
        require(safe != address(0), "SAFE_ZERO");

        vm.startBroadcast();
        controller = new VaultOwnerController(vault, safe);
        vm.stopBroadcast();

        console2.log("VaultOwnerController:", address(controller));
        console2.log("vault:               ", vault);
        console2.log("owner (safe):        ", safe);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1) From current vault owner:");
        console2.log("     vault.transferOwnership(controller)");
        console2.log("  2) controller.acceptVaultOwnership()");
        console2.log("  3) From safe: controller.setReserveKeeper(hotKeeper, true)");
        console2.log("  4) Set keeper service env: KEEPER_WRITE_TARGET=controller");
    }
}
