// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {VaultLens} from "../src/VaultLens.sol";

interface IHookView {
    function registeredVault(PoolId pid) external view returns (address);
}

/// @notice Read-only post-broadcast verification. Reads VAULT_ADDRESS and
///         LENS_ADDRESS from env and prints the six required checks.
contract VerifyResumeDeploy is Script {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address lensAddr  = vm.envAddress("LENS_ADDRESS");
        address hookAddr  = vm.envAddress("HOOK_V2");

        LiquidityVaultV2 vault = LiquidityVaultV2(payable(vaultAddr));
        VaultLens lens = VaultLens(lensAddr);

        console2.log("=== Post-deploy verification ===");
        console2.log("Vault:", vaultAddr);
        console2.log("Lens :", lensAddr);

        // 1. vault.poolKey()
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = vault.poolKey();
        console2.log("[1] poolKey.currency0  :", Currency.unwrap(c0));
        console2.log("[1] poolKey.currency1  :", Currency.unwrap(c1));
        console2.log("[1] poolKey.fee        :", uint256(fee));
        console2.log("[1] poolKey.tickSpacing:", int256(tickSpacing));
        console2.log("[1] poolKey.hooks      :", address(hooks));
        require(Currency.unwrap(c0) != address(0) && Currency.unwrap(c1) != address(0), "poolKey unset");

        // 2. vault.reserveHook()
        address rh = vault.reserveHook();
        console2.log("[2] reserveHook        :", rh);
        require(rh == hookAddr, "reserveHook mismatch");
        require(rh == address(hooks), "reserveHook != poolKey.hooks");

        // 3. vault.navReferenceSqrtPriceX96()
        uint160 navRef = vault.navReferenceSqrtPriceX96();
        console2.log("[3] navReferenceSqrtPx96:", uint256(navRef));
        require(navRef != 0, "navReference zero");

        // 4. hook.registeredVault[poolId] == vault
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks
        });
        address registered = IHookView(hookAddr).registeredVault(key.toId());
        console2.log("[4] hook.registeredVault:", registered);
        require(registered == vaultAddr, "hook.registeredVault mismatch");

        // 5. VaultLens.vaultStatus(vault)
        VaultLens.VaultStatus st = lens.vaultStatus(vaultAddr);
        console2.log("[5] vaultStatus enum  :", uint256(st));
        require(st != VaultLens.VaultStatus.UNCONFIGURED, "still UNCONFIGURED");

        // 6. VaultLens.getVaultStats(vault)
        (uint256 tvl, uint256 sharePrice, uint256 depositors, uint256 liqDeployed, uint256 yieldColl, ) =
            lens.getVaultStats(vaultAddr);
        console2.log("[6] tvl       :", tvl);
        console2.log("[6] sharePrice:", sharePrice);
        console2.log("[6] depositors:", depositors);
        console2.log("[6] liqDeplyed:", liqDeployed);
        console2.log("[6] yieldColl :", yieldColl);

        console2.log("=== ALL POST-DEPLOY CHECKS PASSED ===");
    }
}
