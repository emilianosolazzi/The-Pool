// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {ReservePricingMode} from "../src/DynamicFeeHookV2.sol";
import {VaultOwnerController, ILiquidityVaultV2OwnerOps} from "../src/VaultOwnerController.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

// We need the same MockReserveHook used by LiquidityVaultV2.t.sol so the vault
// can post a real offer through the controller. Re-declare a minimal copy
// here (Foundry can't easily import a contract from another test file).
contract _MockReserveHook {
    mapping(address => mapping(address => uint256)) public proceeds;
    mapping(address => mapping(address => uint256)) public escrow;
    address public lastSellCurrency;
    uint128 public lastSellAmount;
    bool public hasActiveOffer;

    function proceedsOwed(address vault_, Currency c) external view returns (uint256) {
        return proceeds[vault_][Currency.unwrap(c)];
    }

    function escrowedReserve(address vault_, Currency c) external view returns (uint256) {
        return escrow[vault_][Currency.unwrap(c)];
    }

    function offerActive(PoolKey calldata) external view returns (bool) {
        return hasActiveOffer;
    }

    function claimReserveProceeds(Currency c) external returns (uint256 a) {
        address ca = Currency.unwrap(c);
        a = proceeds[msg.sender][ca];
        if (a > 0) {
            proceeds[msg.sender][ca] = 0;
            IERC20(ca).transfer(msg.sender, a);
        }
    }

    function cancelReserveOffer(PoolKey calldata) external returns (uint128 returned) {
        if (!hasActiveOffer) revert("NO_OFFER");
        returned = lastSellAmount;
        if (returned > 0 && lastSellCurrency != address(0)) {
            escrow[msg.sender][lastSellCurrency] = 0;
            IERC20(lastSellCurrency).transfer(msg.sender, returned);
        }
        hasActiveOffer = false;
    }

    function createReserveOffer(
        PoolKey calldata,
        Currency sellCurrency,
        uint128 sellAmount,
        uint160,
        uint64
    ) external {
        lastSellCurrency = Currency.unwrap(sellCurrency);
        lastSellAmount = sellAmount;
        hasActiveOffer = true;
        IERC20(lastSellCurrency).transferFrom(msg.sender, address(this), sellAmount);
        escrow[msg.sender][lastSellCurrency] += sellAmount;
    }

    function createReserveOfferWithMode(
        PoolKey calldata,
        Currency sellCurrency,
        uint128 sellAmount,
        uint160,
        uint64,
        uint8
    ) external {
        lastSellCurrency = Currency.unwrap(sellCurrency);
        lastSellAmount = sellAmount;
        hasActiveOffer = true;
        IERC20(lastSellCurrency).transferFrom(msg.sender, address(this), sellAmount);
        escrow[msg.sender][lastSellCurrency] += sellAmount;
    }
}

contract VaultOwnerControllerTest is Test {
    LiquidityVaultV2 public vault;
    VaultOwnerController public controller;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockPoolManager public mockManager;
    MockPositionManager public mockPosMgr;
    _MockReserveHook public hookMock;

    address public safe = makeAddr("safe");
    address public keeper = makeAddr("keeper");
    address public outsider = makeAddr("outsider");

    PoolKey public poolKey;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        mockManager = new MockPoolManager();
        mockPosMgr = new MockPositionManager();
        hookMock = new _MockReserveHook();

        vault = new LiquidityVaultV2(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "LP Vault V2",
            "LPV2",
            address(0),
            address(0) // zapRouter unused for these tests
        );

        address lo = address(weth) < address(usdc) ? address(weth) : address(usdc);
        address hi = address(weth) < address(usdc) ? address(usdc) : address(weth);
        poolKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(hookMock))
        });

        mockManager.setSlot0(TickMath.getSqrtPriceAtTick(-198900), -198900);
        vault.setPoolKey(poolKey);
        vault.setReserveHook(address(hookMock));

        // Deploy controller, owned by the Safe.
        controller = new VaultOwnerController(address(vault), safe);

        // Two-step transfer: deployer (this) hands vault ownership to controller.
        vault.transferOwnership(address(controller));
        controller.acceptVaultOwnership();
        assertEq(vault.owner(), address(controller), "vault owner != controller");

        vm.prank(safe);
        controller.setReserveKeeper(keeper, true);
    }

    // -----------------------------------------------------------------
    // Deployment / ownership
    // -----------------------------------------------------------------

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(VaultOwnerController.ZeroAddress.selector);
        new VaultOwnerController(address(0), safe);
    }

    function test_constructor_revertsOnZeroOwner() public {
        // Ownable's own zero check fires before our ZeroAddress check.
        vm.expectRevert();
        new VaultOwnerController(address(vault), address(0));
    }

    function test_acceptVaultOwnership_isPermissionless() public {
        // Build a fresh vault + controller; have outsider complete the accept.
        LiquidityVaultV2 v2 = new LiquidityVaultV2(
            usdc,
            IPoolManager(address(mockManager)),
            IPositionManager(address(mockPosMgr)),
            "V",
            "V",
            address(0),
            address(0)
        );
        VaultOwnerController c2 = new VaultOwnerController(address(v2), safe);
        v2.transferOwnership(address(c2));

        vm.prank(outsider);
        c2.acceptVaultOwnership();
        assertEq(v2.owner(), address(c2));
    }

    // -----------------------------------------------------------------
    // Keeper allowlist
    // -----------------------------------------------------------------

    function test_setReserveKeeper_onlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        controller.setReserveKeeper(outsider, true);
    }

    function test_setReserveKeeper_revertsOnZero() public {
        vm.prank(safe);
        vm.expectRevert(VaultOwnerController.ZeroAddress.selector);
        controller.setReserveKeeper(address(0), true);
    }

    function test_setReserveKeeper_canRevoke() public {
        vm.prank(safe);
        controller.setReserveKeeper(keeper, false);
        assertFalse(controller.reserveKeepers(keeper));
    }

    // -----------------------------------------------------------------
    // Reserve ops authorization
    // -----------------------------------------------------------------

    function _seedVaultWithSellInventory(uint128 amt) internal {
        // Deposit `amt` of WETH into the vault so it can post a reserve offer.
        weth.mint(address(vault), amt);
    }

    function test_offer_byKeeper_succeeds() public {
        uint128 amt = 1 ether;
        _seedVaultWithSellInventory(amt);

        vm.prank(keeper);
        controller.offerReserveToHookWithMode(
            Currency.wrap(address(weth)),
            amt,
            uint160(1 << 96),
            0,
            ReservePricingMode.VAULT_SPREAD
        );
        assertTrue(hookMock.hasActiveOffer());
        assertEq(hookMock.lastSellCurrency(), address(weth));
        assertEq(uint256(hookMock.lastSellAmount()), uint256(amt));
    }

    function test_offer_bySafe_succeeds() public {
        uint128 amt = 0.5 ether;
        _seedVaultWithSellInventory(amt);

        vm.prank(safe);
        controller.offerReserveToHookWithMode(
            Currency.wrap(address(weth)),
            amt,
            uint160(1 << 96),
            0,
            ReservePricingMode.PRICE_IMPROVEMENT
        );
        assertTrue(hookMock.hasActiveOffer());
    }

    function test_offer_byOutsider_reverts() public {
        _seedVaultWithSellInventory(1 ether);
        vm.prank(outsider);
        vm.expectRevert(VaultOwnerController.NotKeeperOrOwner.selector);
        controller.offerReserveToHookWithMode(
            Currency.wrap(address(weth)),
            1 ether,
            uint160(1 << 96),
            0,
            ReservePricingMode.VAULT_SPREAD
        );
    }

    function test_cancel_byKeeper_succeeds() public {
        uint128 amt = 1 ether;
        _seedVaultWithSellInventory(amt);
        vm.prank(keeper);
        controller.offerReserveToHookWithMode(
            Currency.wrap(address(weth)), amt, uint160(1 << 96), 0, ReservePricingMode.VAULT_SPREAD
        );
        vm.prank(keeper);
        uint128 returned = controller.cancelReserveOffer(Currency.wrap(address(weth)));
        assertEq(uint256(returned), uint256(amt));
        assertFalse(hookMock.hasActiveOffer());
    }

    function test_cancel_byOutsider_reverts() public {
        vm.prank(outsider);
        vm.expectRevert(VaultOwnerController.NotKeeperOrOwner.selector);
        controller.cancelReserveOffer(Currency.wrap(address(weth)));
    }

    // After ownership move, vault.offerReserveToHookWithMode called directly
    // by the keeper (not via controller) MUST revert because the keeper is
    // not the vault owner anymore. Controller is the only authorised path.
    function test_directVaultCall_byKeeper_reverts() public {
        _seedVaultWithSellInventory(1 ether);
        vm.prank(keeper);
        vm.expectRevert(); // Ownable: caller is not the owner
        vault.offerReserveToHookWithMode(
            Currency.wrap(address(weth)), 1 ether, uint160(1 << 96), 0, ReservePricingMode.VAULT_SPREAD
        );
    }

    // -----------------------------------------------------------------
    // Escape hatch
    // -----------------------------------------------------------------

    function test_executeVaultOwnerCall_denyListsReserveSelectors() public {
        // Try to forward a reserve op via raw calldata. Must revert.
        bytes memory data = abi.encodeCall(
            ILiquidityVaultV2OwnerOps.cancelReserveOffer, (Currency.wrap(address(weth)))
        );
        vm.prank(safe);
        vm.expectRevert(VaultOwnerController.UseTypedReservePath.selector);
        controller.executeVaultOwnerCall(data);

        bytes memory data2 = abi.encodeCall(
            ILiquidityVaultV2OwnerOps.offerReserveToHookWithMode,
            (Currency.wrap(address(weth)), uint128(1), uint160(1 << 96), uint64(0), ReservePricingMode.VAULT_SPREAD)
        );
        vm.prank(safe);
        vm.expectRevert(VaultOwnerController.UseTypedReservePath.selector);
        controller.executeVaultOwnerCall(data2);
    }

    function test_executeVaultOwnerCall_forwardsPause() public {
        bytes memory data = abi.encodeWithSignature("pause()");
        vm.prank(safe);
        controller.executeVaultOwnerCall(data);
        assertTrue(vault.paused());
    }

    function test_executeVaultOwnerCall_forwardsSetMaxNavDeviationBps() public {
        bytes memory data = abi.encodeWithSignature("setMaxNavDeviationBps(uint256)", uint256(250));
        vm.prank(safe);
        controller.executeVaultOwnerCall(data);
        assertEq(vault.maxNavDeviationBps(), 250);
    }

    function test_executeVaultOwnerCall_onlyOwner() public {
        bytes memory data = abi.encodeWithSignature("pause()");
        vm.prank(outsider);
        vm.expectRevert();
        controller.executeVaultOwnerCall(data);
    }

    function test_executeVaultOwnerCall_bubblesRevert() public {
        // setMaxNavDeviationBps with > MAX_NAV_DEVIATION_CAP must revert.
        // VaultCallFailed carries a bytes payload, so match by selector via
        // partial-match `expectPartialRevert`.
        bytes memory data = abi.encodeWithSignature("setMaxNavDeviationBps(uint256)", uint256(10_000));
        vm.prank(safe);
        vm.expectPartialRevert(VaultOwnerController.VaultCallFailed.selector);
        controller.executeVaultOwnerCall(data);
    }

    // -----------------------------------------------------------------
    // Safe can transfer vault ownership back out (full escape)
    // -----------------------------------------------------------------

    function test_executeVaultOwnerCall_canTransferVaultOwnershipBack() public {
        address newOwner = makeAddr("newOwner");
        bytes memory data = abi.encodeWithSignature("transferOwnership(address)", newOwner);
        vm.prank(safe);
        controller.executeVaultOwnerCall(data);
        assertEq(vault.pendingOwner(), newOwner);
    }
}
