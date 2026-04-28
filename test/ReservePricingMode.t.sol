// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {DynamicFeeHookV2, ReservePricingMode} from "../src/DynamicFeeHookV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Pricing-mode coverage for the reserve-offer system.
///         PRICE_IMPROVEMENT: vault quotes BETTER than pool for the swapper.
///         VAULT_SPREAD:      vault quotes WORSE than pool, vault earns spread.
///
///         Gate orientations (verified by these tests):
///           PRICE_IMPROVEMENT, sellingCurrency1 (zeroForOne): poolSqrtP <= vaultSqrtP
///           PRICE_IMPROVEMENT, sellingCurrency0 (oneForZero): poolSqrtP >= vaultSqrtP
///           VAULT_SPREAD,      sellingCurrency1 (zeroForOne): poolSqrtP >= vaultSqrtP
///           VAULT_SPREAD,      sellingCurrency0 (oneForZero): poolSqrtP <= vaultSqrtP
contract ReservePricingModeTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHookV2 public hook;
    FeeDistributor public distributor;
    PoolKey public poolKey;
    address public treasury;
    address public vaultEOA = makeAddr("vaultEOA");

    // sqrtPriceX96 = 2^96 = SQRT_PRICE_1_1 -> price 1:1.
    uint160 internal constant SQRT_BELOW = uint160((uint256(1) << 96) - (uint256(1) << 90)); // ~1.5% below 1:1
    uint160 internal constant SQRT_ABOVE = uint160((uint256(1) << 96) + (uint256(1) << 90)); // ~1.5% above 1:1

    function setUp() public {
        treasury = makeAddr("treasury");

        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        distributor = new FeeDistributor(manager, treasury, address(0));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHookV2).creationCode,
            abi.encode(address(manager), address(distributor), address(this))
        );
        hook = new DynamicFeeHookV2{salt: salt}(manager, address(distributor), address(this));
        require(address(hook) == hookAddr, "hook addr mismatch");
        distributor.setHook(address(hook));

        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1);
        distributor.setPoolKey(poolKey);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );

        hook.registerVault(poolKey, vaultEOA);

        // Fund vault with both tokens for the symmetric tests.
        MockERC20(Currency.unwrap(currency0)).mint(vaultEOA, 100 ether);
        MockERC20(Currency.unwrap(currency1)).mint(vaultEOA, 100 ether);
        vm.startPrank(vaultEOA);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // PRICE_IMPROVEMENT mode (default) — backward-compat
    // -----------------------------------------------------------------

    /// @dev Existing-behaviour reproduction: pool=1:1, vault=1:1, sells token1
    ///      via zeroForOne. poolSqrtP <= vaultSqrtP -> fills.
    function test_priceImprovement_currency1_fills() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency1, 0.5e18, SQRT_PRICE_1_1, 0, ReservePricingMode.PRICE_IMPROVEMENT
        );

        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);

        assertEq(hook.totalReserveFills(), fillsBefore + 1, "PI mode filled at equal price");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), 0.5e18);
    }

    /// @dev PI mode, sells token1, but pool is HIGHER than vault.
    ///      Gate fails (poolSqrtP > vaultSqrtP) -> no fill, AMM only.
    function test_priceImprovement_currency1_skipsWhenPoolAbove() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency1, 0.5e18, SQRT_BELOW, 0, ReservePricingMode.PRICE_IMPROVEMENT
        );

        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, true, -int256(0.1 ether), ZERO_BYTES);
        assertEq(hook.totalReserveFills(), fillsBefore, "PI mode skipped: AMM is better");
    }

    // -----------------------------------------------------------------
    // VAULT_SPREAD mode — vault earns spread
    // -----------------------------------------------------------------

    /// @dev VAULT_SPREAD, sells token1 (zeroForOne).
    ///      Vault prices BELOW pool (vaultSqrtP < poolSqrtP) -> gate passes.
    ///      Vault gives less token1 per token0 than pool -> vault earns spread.
    function test_vaultSpread_currency1_fillsAndEarnsSpread() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency1, 0.5e18, SQRT_BELOW, 0, ReservePricingMode.VAULT_SPREAD
        );

        uint256 fillsBefore = hook.totalReserveFills();
        uint256 escrowBefore = hook.escrowedReserve(vaultEOA, currency1);
        uint256 proceedsBefore = hook.proceedsOwed(vaultEOA, currency0);

        swap(poolKey, true, -int256(0.1 ether), ZERO_BYTES);

        assertEq(hook.totalReserveFills(), fillsBefore + 1, "VAULT_SPREAD filled when pool >= vault");
        // Inventory consumed (some), proceeds (in currency0) accrued.
        uint256 escrowAfter = hook.escrowedReserve(vaultEOA, currency1);
        uint256 proceedsAfter = hook.proceedsOwed(vaultEOA, currency0);
        assertLt(escrowAfter, escrowBefore, "vault inventory drained");
        assertGt(proceedsAfter, proceedsBefore, "vault accrued token0 proceeds");

        // Spread check: at vaultSqrtP < SQRT_PRICE_1_1, vault gives strictly less
        // token1 per token0 than 1:1. So token0_taken > token1_given.
        uint256 token1Given = escrowBefore - escrowAfter;
        uint256 token0Taken = proceedsAfter - proceedsBefore;
        assertGt(token0Taken, token1Given, "vault earns spread (received more than gave at 1:1 baseline)");
    }

    /// @dev VAULT_SPREAD, sells token1, vault price ABOVE pool.
    ///      Gate (poolSqrtP >= vaultSqrtP) fails -> swap routes 100% to AMM.
    function test_vaultSpread_currency1_skipsWhenPoolBelow() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency1, 0.5e18, SQRT_ABOVE, 0, ReservePricingMode.VAULT_SPREAD
        );

        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, true, -int256(0.1 ether), ZERO_BYTES);
        assertEq(hook.totalReserveFills(), fillsBefore, "VAULT_SPREAD skipped: pool < vault");
    }

    /// @dev VAULT_SPREAD, sells token0 (oneForZero).
    ///      Vault prices ABOVE pool (vaultSqrtP > poolSqrtP) -> gate
    ///      poolSqrtP <= vaultSqrtP passes -> fills.
    function test_vaultSpread_currency0_fillsAndEarnsSpread() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency0, 0.5e18, SQRT_ABOVE, 0, ReservePricingMode.VAULT_SPREAD
        );

        uint256 fillsBefore = hook.totalReserveFills();
        uint256 escrowBefore = hook.escrowedReserve(vaultEOA, currency0);
        uint256 proceedsBefore = hook.proceedsOwed(vaultEOA, currency1);

        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES); // oneForZero

        assertEq(hook.totalReserveFills(), fillsBefore + 1, "VAULT_SPREAD selling token0 fills");
        uint256 escrowAfter = hook.escrowedReserve(vaultEOA, currency0);
        uint256 proceedsAfter = hook.proceedsOwed(vaultEOA, currency1);
        assertLt(escrowAfter, escrowBefore);
        assertGt(proceedsAfter, proceedsBefore);

        // At vaultSqrtP > SQRT_PRICE_1_1 (i.e. token0 priced higher), vault
        // gives less token0 per token1 received than 1:1. So token1_taken > token0_given.
        uint256 token0Given = escrowBefore - escrowAfter;
        uint256 token1Taken = proceedsAfter - proceedsBefore;
        assertGt(token1Taken, token0Given, "vault earns spread on currency0 sale");
    }

    /// @dev VAULT_SPREAD, sells token0, vault price BELOW pool.
    ///      Gate (poolSqrtP <= vaultSqrtP) fails -> AMM only.
    function test_vaultSpread_currency0_skipsWhenPoolAbove() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency0, 0.5e18, SQRT_BELOW, 0, ReservePricingMode.VAULT_SPREAD
        );

        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES);
        assertEq(hook.totalReserveFills(), fillsBefore, "VAULT_SPREAD currency0 skipped: pool > vault");
    }

    // -----------------------------------------------------------------
    // PRICE_IMPROVEMENT, sells token0 — symmetric coverage
    // -----------------------------------------------------------------

    /// @dev PI mode selling token0: gate poolSqrtP >= vaultSqrtP.
    ///      Vault below pool -> swapper gets MORE token0 per token1 than AMM.
    function test_priceImprovement_currency0_fills() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency0, 0.5e18, SQRT_BELOW, 0, ReservePricingMode.PRICE_IMPROVEMENT
        );
        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES);
        assertEq(hook.totalReserveFills(), fillsBefore + 1, "PI mode currency0 fills");
    }

    /// @dev PI mode selling token0 with vault above pool -> gate fails.
    function test_priceImprovement_currency0_skipsWhenPoolBelow() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency0, 0.5e18, SQRT_ABOVE, 0, ReservePricingMode.PRICE_IMPROVEMENT
        );
        uint256 fillsBefore = hook.totalReserveFills();
        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES);
        assertEq(hook.totalReserveFills(), fillsBefore, "PI mode currency0 skipped");
    }

    // -----------------------------------------------------------------
    // Backward compat: createReserveOffer (no mode arg) defaults to PI
    // -----------------------------------------------------------------

    function test_legacyCreate_defaultsToPriceImprovement() public {
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 0.5e18, SQRT_PRICE_1_1, 0);
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertEq(uint8(o.pricingMode), uint8(ReservePricingMode.PRICE_IMPROVEMENT));
    }

    /// @dev Mode persists in struct after create-with-mode.
    function test_modeStoredInOffer() public {
        vm.prank(vaultEOA);
        hook.createReserveOfferWithMode(
            poolKey, currency1, 0.5e18, SQRT_BELOW, 0, ReservePricingMode.VAULT_SPREAD
        );
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertEq(uint8(o.pricingMode), uint8(ReservePricingMode.VAULT_SPREAD));
    }
}
