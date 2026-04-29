// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ReservePricingMode} from "./DynamicFeeHookV2.sol";

/// @notice Minimal owner-side surface of LiquidityVaultV2 needed by the
///         controller. Mirrors the vault function signatures verbatim so
///         keeper TS can keep using identical calldata layouts.
interface ILiquidityVaultV2OwnerOps {
    function acceptOwnership() external;

    function offerReserveToHookWithMode(
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry,
        ReservePricingMode mode
    ) external;

    function rebalanceOfferWithMode(
        Currency sellCurrency,
        uint128 newSellAmount,
        uint160 newSqrtPriceX96,
        uint64 expiry,
        ReservePricingMode mode
    ) external;

    function cancelReserveOffer(Currency sellCurrency) external returns (uint128);

    function collectReserveProceeds(Currency currency) external returns (uint256);
}

/// @title  VaultOwnerController
/// @notice Owner-of-vault wrapper. The Safe/multisig owns the controller.
///         The controller owns the vault. A whitelist of hot keepers can
///         call ONLY the reserve-management functions on the vault. All
///         other owner-only operations on the vault (setPoolKey, rebalance,
///         setReserveHook, pause, etc.) flow through the typed escape
///         hatch `executeVaultOwnerCall`, which is `onlyOwner`.
///
/// @dev    Why this exists:
///         - DynamicFeeHookV2.registerVault is one-shot per PoolId. Once a
///           vault is registered for a pool, it cannot be replaced without
///           redeploying the hook (which would change the hook address and
///           force a new pool anyway). So adding a "reserve keeper" role
///           by deploying a V3 vault is not viable while keeping the same
///           pool/hook.
///         - Solution: keep the existing vault. Move its owner from the
///           deployer EOA to this controller. The Safe owns the controller.
///           The controller forwards a narrow set of reserve calls from a
///           whitelisted hot keeper EOA, leaving the Safe as the sole
///           authority for everything else.
///
///         The hook still sees the vault as the registered counterparty
///         because the vault itself remains the `msg.sender` to the hook
///         on every reserve call. The controller never calls the hook.
contract VaultOwnerController is Ownable2Step, ReentrancyGuard {
    ILiquidityVaultV2OwnerOps public immutable vault;

    /// @notice Whitelisted hot keepers permitted to invoke the typed
    ///         reserve operations. Owner-managed.
    mapping(address => bool) public reserveKeepers;

    event ReserveKeeperSet(address indexed keeper, bool allowed);
    event VaultOwnershipAccepted(address indexed vault);
    event VaultCallExecuted(bytes4 indexed selector, bytes data, bytes result);
    /// @notice Emitted on every typed reserve-path forward so off-chain
    ///         consumers can audit keeper activity at the controller layer
    ///         (vault emits its own events too).
    event ReserveKeeperCallExecuted(
        address indexed caller,
        bytes4 indexed selector,
        Currency indexed currency
    );

    error NotKeeperOrOwner();
    error ZeroAddress();
    error VaultCallFailed(bytes returnData);
    error UseTypedReservePath();

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && !reserveKeepers[msg.sender]) {
            revert NotKeeperOrOwner();
        }
        _;
    }

    constructor(address _vault, address initialOwner) Ownable(initialOwner) {
        if (_vault == address(0) || initialOwner == address(0)) revert ZeroAddress();
        vault = ILiquidityVaultV2OwnerOps(_vault);
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    /// @notice Whitelist or revoke a hot keeper.
    function setReserveKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        reserveKeepers[keeper] = allowed;
        emit ReserveKeeperSet(keeper, allowed);
    }

    /// @notice Complete the two-step ownership transfer of the vault to this
    ///         controller. The current vault owner must have already called
    ///         `vault.transferOwnership(address(this))`. Permissionless: it
    ///         can only succeed if the prior owner already nominated us, so
    ///         leaving this open avoids a stuck state if the Safe key is
    ///         being rotated. Emits a clear event for off-chain auditing.
    function acceptVaultOwnership() external nonReentrant {
        vault.acceptOwnership();
        emit VaultOwnershipAccepted(address(vault));
    }

    // -----------------------------------------------------------------
    // Hot-keeper allowed reserve operations
    // -----------------------------------------------------------------

    /// @notice Forward to vault.offerReserveToHookWithMode.
    function offerReserveToHookWithMode(
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry,
        ReservePricingMode mode
    ) external onlyKeeperOrOwner nonReentrant {
        vault.offerReserveToHookWithMode(sellCurrency, sellAmount, vaultSqrtPriceX96, expiry, mode);
        emit ReserveKeeperCallExecuted(msg.sender, this.offerReserveToHookWithMode.selector, sellCurrency);
    }

    /// @notice Forward to vault.rebalanceOfferWithMode.
    function rebalanceOfferWithMode(
        Currency sellCurrency,
        uint128 newSellAmount,
        uint160 newSqrtPriceX96,
        uint64 expiry,
        ReservePricingMode mode
    ) external onlyKeeperOrOwner nonReentrant {
        vault.rebalanceOfferWithMode(sellCurrency, newSellAmount, newSqrtPriceX96, expiry, mode);
        emit ReserveKeeperCallExecuted(msg.sender, this.rebalanceOfferWithMode.selector, sellCurrency);
    }

    /// @notice Forward to vault.cancelReserveOffer.
    function cancelReserveOffer(Currency sellCurrency)
        external
        onlyKeeperOrOwner
        nonReentrant
        returns (uint128 returned)
    {
        returned = vault.cancelReserveOffer(sellCurrency);
        emit ReserveKeeperCallExecuted(msg.sender, this.cancelReserveOffer.selector, sellCurrency);
    }

    /// @notice Forward to vault.collectReserveProceeds. The vault function is
    ///         already permissionless, but exposing it here keeps the keeper's
    ///         write target uniform and emits controller-level accounting.
    function collectReserveProceeds(Currency currency)
        external
        onlyKeeperOrOwner
        nonReentrant
        returns (uint256 amount)
    {
        amount = vault.collectReserveProceeds(currency);
        emit ReserveKeeperCallExecuted(msg.sender, this.collectReserveProceeds.selector, currency);
    }

    // -----------------------------------------------------------------
    // Owner escape hatch (Safe-only)
    // -----------------------------------------------------------------

    /// @notice Forward an arbitrary owner-only call to the vault. Used by the
    ///         Safe for setPoolKey, rebalance, setReserveHook, setInitialTicks,
    ///         setMaxNavDeviationBps, refreshNavReference, setBootstrapRewards,
    ///         setZapRouter, transferOwnership, pause, unpause, etc.
    /// @dev    Reverts if the caller tries to invoke a reserve op via raw
    ///         calldata. The typed paths above must be used so that
    ///         controller-level events fire on every reserve action and the
    ///         on-chain audit trail stays uniform.
    function executeVaultOwnerCall(bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        bytes4 sel = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        if (
            sel == ILiquidityVaultV2OwnerOps.offerReserveToHookWithMode.selector
                || sel == ILiquidityVaultV2OwnerOps.rebalanceOfferWithMode.selector
                || sel == ILiquidityVaultV2OwnerOps.cancelReserveOffer.selector
                || sel == ILiquidityVaultV2OwnerOps.collectReserveProceeds.selector
        ) {
            revert UseTypedReservePath();
        }

        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) revert VaultCallFailed(ret);
        emit VaultCallExecuted(sel, data, ret);
        return ret;
    }
}
