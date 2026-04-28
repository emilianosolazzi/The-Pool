// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";
import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {VaultLens} from "../src/VaultLens.sol";

/// @notice Resume deploy: FeeDistributor + HookV2 + ZapAdapter are already
///         on Arbitrum. This broadcasts only the remaining steps:
///           - Libraries (VaultMath, VaultLP)  — auto-deployed by `forge script`
///             when the linked vault constructor is broadcast; their addresses
///             are visible in the broadcast log.
///           - LiquidityVaultV2 (linked).
///           - VaultLens.
///           - Vault wiring (setPoolKey, rebalance to user-chosen band,
///             setReserveHook, refreshNavReference, optional setZapRouter,
///             treasury / fees / cap).
///           - hook.registerVault binding.
///
///         Env (matches DeployHookV2AndVault semantics):
///           FEE_DISTRIBUTOR  (already deployed)
///           HOOK_V2          (already deployed)
///           ZAP_ROUTER       (already deployed, e.g. SwapRouter02ZapAdapter)
///           POOL_MANAGER, POS_MANAGER, TOKEN0, TOKEN1, ASSET_TOKEN
///           PERMIT2, TREASURY (optional, defaults to msg.sender)
///           POOL_FEE, TICK_SPACING
///           V2_TICK_LOWER, V2_TICK_UPPER
///           PERFORMANCE_FEE_BPS (optional, default 400)
///           MAX_TVL (optional)
///           SET_ZAP_ROUTER_AFTER_DEPLOY (optional bool, default false — only
///             call setZapRouter if you want to override the constructor arg)
contract DeployVaultResume is Script {
    function run() external {
        address feeDistributor = vm.envAddress("FEE_DISTRIBUTOR");
        address hookAddr       = vm.envAddress("HOOK_V2");
        address zapRouter      = vm.envAddress("ZAP_ROUTER");

        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address posManagerAddr  = vm.envAddress("POS_MANAGER");
        address token0          = vm.envAddress("TOKEN0");
        address token1          = vm.envAddress("TOKEN1");
        address assetToken      = vm.envAddress("ASSET_TOKEN");
        address permit2         = vm.envAddress("PERMIT2");
        address treasury        = vm.envOr("TREASURY", msg.sender);

        uint24  poolFee     = uint24(vm.envUint("POOL_FEE"));
        int24   tickSpacing = int24(vm.envInt("TICK_SPACING"));
        int24   tickLower   = int24(vm.envInt("V2_TICK_LOWER"));
        int24   tickUpper   = int24(vm.envInt("V2_TICK_UPPER"));

        uint256 perfFeeBps = vm.envOr("PERFORMANCE_FEE_BPS", uint256(400));
        uint256 maxTVL     = vm.envOr("MAX_TVL", uint256(0));
        bool    overrideZapRouter = vm.envOr("SET_ZAP_ROUTER_AFTER_DEPLOY", false);

        require(token0 < token1, "TOKEN_ORDER");
        require(assetToken == token0 || assetToken == token1, "ASSET_NOT_IN_POOL");
        require(tickLower < tickUpper, "TICK_ORDER");
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, "TICK_SPACING");

        IPoolManager     poolManager = IPoolManager(poolManagerAddr);
        IPositionManager posManager  = IPositionManager(posManagerAddr);
        DynamicFeeHookV2 hook        = DynamicFeeHookV2(hookAddr);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         poolFee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(hookAddr)
        });

        console2.log("=== Resume deploy: pre-broadcast ===");
        console2.log("FeeDistributor   :", feeDistributor);
        console2.log("DynamicFeeHookV2 :", hookAddr);
        console2.log("ZapRouter        :", zapRouter);
        console2.log("Deployer         :", msg.sender);
        console2.log("Asset            :", assetToken);
        console2.log("Tick lower       :", int256(tickLower));
        console2.log("Tick upper       :", int256(tickUpper));
        console2.log("====================================");

        vm.startBroadcast();

        // 1. LiquidityVaultV2 (linked to VaultMath + VaultLP — forge auto-
        //    deploys libraries first; their addresses appear in broadcast log).
        LiquidityVaultV2 vault = new LiquidityVaultV2(
            IERC20(assetToken),
            poolManager,
            posManager,
            "The Pool Zap LP Vault V2.1",
            "pZAP-LPV21",
            permit2,
            zapRouter
        );

        // 2. Wire vault.
        vault.setPoolKey(key);
        // setInitialTicks before any LP exists; rebalance with minLiquidity=0
        // also works pre-deposit but does an extra _collectYield call that is a
        // no-op. Using setInitialTicks keeps intent explicit.
        if (tickLower != vault.tickLower() || tickUpper != vault.tickUpper()) {
            vault.setInitialTicks(tickLower, tickUpper);
        }
        vault.setReserveHook(hookAddr);
        if (overrideZapRouter) {
            vault.setZapRouter(zapRouter);
        }
        vault.refreshNavReference();
        if (treasury != msg.sender) vault.setTreasury(treasury);
        if (perfFeeBps > 0) vault.setPerformanceFeeBps(perfFeeBps);
        if (maxTVL > 0) vault.setMaxTVL(maxTVL);

        // 3. Hook ↔ vault binding (one-shot).
        hook.registerVault(key, address(vault));

        // 4. VaultLens.
        VaultLens lens = new VaultLens();

        vm.stopBroadcast();

        console2.log("=== Resume deploy: complete ===");
        console2.log("LiquidityVaultV2 :", address(vault));
        console2.log("VaultLens        :", address(lens));
        console2.log("(VaultMath / VaultLP addresses are in the broadcast log)");
        console2.log("================================");
    }
}
