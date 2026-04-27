// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DynamicFeeHook} from "../../src/archive-v1/DynamicFeeHook.sol";
import {FeeDistributor} from "../../src/FeeDistributor.sol";
import {LiquidityVault} from "../../src/archive-v1/LiquidityVault.sol";
import {BootstrapRewards} from "../../src/BootstrapRewards.sol";
import {HookMiner} from "../../test/utils/HookMiner.sol";

/// @notice Clean full redeploy: distributor, vault, NEW hook (owner = EOA),
///         bootstrap, fresh pool. The new hook fixes the Ownable(msg.sender)
///         CREATE2 ownership-lock bug.
contract RedeployAll is Script {
    uint64  internal constant EPOCH_LENGTH       = 30 days;
    uint32  internal constant EPOCH_COUNT        = 6;
    uint64  internal constant DWELL              = 7 days;
    uint64  internal constant CLAIM_WINDOW       = 90 days;
    uint64  internal constant FINALIZATION_DELAY = 7 days;
    uint16  internal constant BONUS_BPS          = 5_000;
    uint256 internal constant PER_EPOCH_CAP_ASSET  = 10_000e6;
    uint256 internal constant PER_WALLET_CAP_ASSET = 25_000e6;
    uint256 internal constant GLOBAL_CAP_ASSET     = 100_000e6;

    struct Inputs {
        address poolManager;
        address posManager;
        address token0;
        address token1;
        address assetToken;
        address treasury;
        address permit2;
        address sender;
        uint24  poolFee;
        int24   tickSpacing;
        int24   initTick;
        uint64  programStart;
    }

    struct Predicted {
        address distributor;
        address vault;
        address hook;
        bytes32 salt;
        uint160 sqrtPriceX96;
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        i.poolManager = vm.envAddress("POOL_MANAGER");
        i.posManager  = vm.envAddress("POS_MANAGER");
        i.token0      = vm.envAddress("TOKEN0");
        i.token1      = vm.envAddress("TOKEN1");
        i.assetToken  = vm.envAddress("ASSET_TOKEN");
        i.treasury    = vm.envAddress("TREASURY");
        i.permit2     = vm.envAddress("PERMIT2");
        i.sender      = vm.envAddress("SENDER");

        i.poolFee     = uint24(vm.envOr("REDEPLOY_POOL_FEE",     uint256(500)));
        i.tickSpacing = int24 (vm.envOr("REDEPLOY_TICK_SPACING", int256(60)));
        i.initTick    = int24 (vm.envOr("REDEPLOY_INIT_TICK",    int256(-198060)));
        i.programStart = uint64(vm.envOr("REDEPLOY_PROGRAM_START", uint256(block.timestamp)));

        require(i.token0 < i.token1, "TOKEN0 must sort below TOKEN1");
        require(
            i.assetToken == i.token0 || i.assetToken == i.token1,
            "ASSET_TOKEN must equal TOKEN0 or TOKEN1"
        );
        require(i.initTick % i.tickSpacing == 0, "INIT_TICK not multiple of TICK_SPACING");
    }

    function _predict(Inputs memory i) internal view returns (Predicted memory p) {
        uint256 nonce = vm.getNonce(i.sender);
        p.distributor  = vm.computeCreateAddress(i.sender, nonce);
        p.vault        = vm.computeCreateAddress(i.sender, nonce + 1);
        p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(i.initTick);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (p.hook, p.salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(DynamicFeeHook).creationCode,
            abi.encode(i.poolManager, p.distributor, i.sender)
        );
    }

    function _logInputs(Inputs memory i, Predicted memory p) internal pure {
        console2.log("=== Inputs ===");
        console2.log("sender (EOA)  :", i.sender);
        console2.log("PoolManager   :", i.poolManager);
        console2.log("PosManager    :", i.posManager);
        console2.log("token0        :", i.token0);
        console2.log("token1        :", i.token1);
        console2.log("assetToken    :", i.assetToken);
        console2.log("treasury (EOA):", i.treasury);
        console2.log("permit2       :", i.permit2);
        console2.log("poolFee       :", uint256(i.poolFee));
        console2.log("tickSpacing   :", int256(i.tickSpacing));
        console2.log("initTick      :", int256(i.initTick));
        console2.log("sqrtPriceX96  :", uint256(p.sqrtPriceX96));
        console2.log("programStart  :", uint256(i.programStart));
        console2.log("=== Predicted addresses ===");
        console2.log("FeeDistributor:", p.distributor);
        console2.log("LiquidityVault:", p.vault);
        console2.log("DynamicFeeHook:", p.hook);
    }

    function _bootstrapConfig(address vaultAddr, address asset, address treasury, uint64 programStart)
        internal
        pure
        returns (BootstrapRewards.Config memory cfg)
    {
        cfg = BootstrapRewards.Config({
            vault: IERC20(vaultAddr),
            payoutAsset: IERC20(asset),
            realTreasury: treasury,
            programStart: programStart,
            epochLength: EPOCH_LENGTH,
            epochCount: EPOCH_COUNT,
            dwellPeriod: DWELL,
            claimWindow: CLAIM_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            bonusShareBps: BONUS_BPS,
            perEpochCap: PER_EPOCH_CAP_ASSET,
            perWalletShareCap: PER_WALLET_CAP_ASSET,
            globalShareCap: GLOBAL_CAP_ASSET
        });
    }

    function run() external {
        Inputs memory i = _loadInputs();
        Predicted memory p = _predict(i);
        _logInputs(i, p);

        IPoolManager pm = IPoolManager(i.poolManager);

        vm.startBroadcast();

        // 1. FeeDistributor — hook addr known a priori from salt mining
        FeeDistributor distributor = new FeeDistributor(pm, i.treasury, p.hook);
        require(address(distributor) == p.distributor, "Distributor address drift");

        // 2. LiquidityVault
        LiquidityVault vault = new LiquidityVault(
            IERC20(i.assetToken),
            pm,
            IPositionManager(i.posManager),
            "DeFi Hook LP Vault",
            "dHOOK-LPV",
            i.permit2
        );
        require(address(vault) == p.vault, "Vault address drift");

        // 3. DynamicFeeHook with explicit owner = EOA (NOT CREATE2 factory)
        DynamicFeeHook hook = new DynamicFeeHook{salt: p.salt}(pm, address(distributor), i.sender);
        require(address(hook) == p.hook, "Hook address mismatch -- salt stale");
        require(hook.owner() == i.sender, "Hook owner mismatch -- ownership-lock guard");

        // 4. BootstrapRewards
        BootstrapRewards bootstrap =
            new BootstrapRewards(_bootstrapConfig(address(vault), i.assetToken, i.treasury, i.programStart));

        // 5. Wire bootstrap as the distributor's treasury
        distributor.setTreasury(address(bootstrap));

        // 6. Initialize the new pool
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(i.token0),
            currency1:   Currency.wrap(i.token1),
            fee:         i.poolFee,
            tickSpacing: i.tickSpacing,
            hooks:       IHooks(address(hook))
        });
        pm.initialize(key, p.sqrtPriceX96);

        // 7. Pin pool key on distributor + vault (one-shot, never repointable)
        distributor.setPoolKey(key);
        vault.setPoolKey(key);

        vm.stopBroadcast();

        // ── Final guards ─────────────────────────────────────────────────
        require(distributor.hook() == address(hook), "distributor.hook != hook");
        require(distributor.treasury() == address(bootstrap), "distributor.treasury != bootstrap");
        require(address(hook.feeDistributor()) == address(distributor), "hook.feeDistributor != distributor");

        console2.log("FeeDistributor  :", address(distributor));
        console2.log("LiquidityVault  :", address(vault));
        console2.log("DynamicFeeHook  :", address(hook));
        console2.log("BootstrapRewards:", address(bootstrap));
        console2.log("=== Done. Paste into web/lib/deployments.ts ===");
        console2.log("hook        =", address(hook));
        console2.log("vault       =", address(vault));
        console2.log("distributor =", address(distributor));
        console2.log("bootstrap   =", address(bootstrap));
        console2.log("tickSpacing =", int256(i.tickSpacing));
        console2.log("poolFee     =", uint256(i.poolFee));
    }
}
