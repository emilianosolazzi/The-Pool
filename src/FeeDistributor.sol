// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract FeeDistributor is Ownable2Step, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    error InvalidDistributionCurrency(address currency);

    uint256 public constant SHARE_DENOMINATOR = 100;
    /// @notice Hard ceiling on the treasury cut (50% of distributions).
    uint256 public constant MAX_TREASURY_SHARE = 50;

    /// @notice Mutable treasury share (default 20 / 100). LP share = SHARE_DENOMINATOR - treasuryShare.
    uint256 public treasuryShare = 20;

    /// @notice Backwards-compatible read of LP share.
    function lpShare() external view returns (uint256) {
        return SHARE_DENOMINATOR - treasuryShare;
    }

    IPoolManager public immutable poolManager;
    address public hook;
    address public treasury;
    PoolKey public poolKey;

    bool private _poolKeySet;
    uint256 public totalDistributed;
    uint256 public totalToTreasury;
    uint256 public totalToLPs;
    uint256 public distributionCount;

    event FeeDistributed(address indexed currency, uint256 total, uint256 treasury, uint256 lp, uint256 id);
    event FeeDistributionRetried(address indexed currency, uint256 amount, address indexed caller);
    event UndistributedSwept(address indexed currency, address indexed to, uint256 amount);
    event PoolKeySet(bytes32 indexed poolId);
    event HookUpdated(address indexed old, address indexed newHook);
    event TreasuryUpdated(address indexed old, address indexed newTreasury);
    event TreasuryShareUpdated(uint256 oldShare, uint256 newShare);

    constructor(IPoolManager _poolManager, address _treasury, address _hook) Ownable(msg.sender) {
        require(_treasury != address(0), "ZERO_ADDRESS");
        poolManager = _poolManager;
        treasury = _treasury;
        hook = _hook;
    }

    function distribute(Currency currency, uint256 amount) external nonReentrant {
        require(msg.sender == hook, "ONLY_HOOK");
        _distribute(currency, amount);
    }

    /// @notice Re-run distribution accounting against a balance physically
    ///         present in this contract. Intended for the post-`FeeDistributionFailed`
    ///         recovery path on the hook side: tokens already arrived here but
    ///         the original `distribute()` reverted (e.g. a transient pool issue,
    ///         missing pool key at the time, etc.). Owner re-tries once the
    ///         underlying cause is cleared. Strict balance check prevents
    ///         double-counting.
    function retryDistribute(Currency currency, uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 bal = IERC20Like(Currency.unwrap(currency)).balanceOf(address(this));
        require(bal >= amount, "INSUFFICIENT_BALANCE");
        emit FeeDistributionRetried(Currency.unwrap(currency), amount, msg.sender);
        _distribute(currency, amount);
    }

    /// @notice Last-resort owner escape hatch. Moves stuck pool-currency
    ///         tokens out of the distributor — used only when re-distributing
    ///         is not feasible (e.g. pool key was migrated, donate target
    ///         unreachable). Restricted to pool-key currencies so the function
    ///         cannot exfiltrate unrelated assets.
    function sweepUndistributed(Currency currency, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        address currencyAddr = Currency.unwrap(currency);
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        if (currencyAddr != Currency.unwrap(poolKey.currency0) && currencyAddr != Currency.unwrap(poolKey.currency1)) {
            revert InvalidDistributionCurrency(currencyAddr);
        }
        currency.transfer(to, amount);
        emit UndistributedSwept(currencyAddr, to, amount);
    }

    function _distribute(Currency currency, uint256 amount) internal {
        require(_poolKeySet, "POOL_KEY_NOT_SET");
        require(amount > 0, "ZERO_AMOUNT");
        address currencyAddr = Currency.unwrap(currency);
        if (currencyAddr != Currency.unwrap(poolKey.currency0) && currencyAddr != Currency.unwrap(poolKey.currency1)) {
            revert InvalidDistributionCurrency(currencyAddr);
        }

        uint256 treasuryAmount = (amount * treasuryShare) / SHARE_DENOMINATOR;
        uint256 lpAmount = amount - treasuryAmount;

        currency.transfer(treasury, treasuryAmount);
        totalToTreasury += treasuryAmount;

        bool isToken0 = (currency == poolKey.currency0);
        uint256 amount0 = isToken0 ? lpAmount : 0;
        uint256 amount1 = isToken0 ? 0 : lpAmount;

        poolManager.sync(currency);
        currency.transfer(address(poolManager), lpAmount);
        poolManager.settle();
        poolManager.donate(poolKey, amount0, amount1, "");

        totalToLPs += lpAmount;
        distributionCount++;
        totalDistributed += amount;

        emit FeeDistributed(Currency.unwrap(currency), amount, treasuryAmount, lpAmount, distributionCount);
    }

    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        require(!_poolKeySet, "ALREADY_SET");
        poolKey = _poolKey;
        _poolKeySet = true;
        emit PoolKeySet(PoolId.unwrap(_poolKey.toId()));
    }

    function setHook(address _newHook) external onlyOwner {
        require(_newHook != address(0), "ZERO_ADDRESS");
        address oldHook = hook;
        hook = _newHook;
        emit HookUpdated(oldHook, _newHook);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "ZERO_ADDRESS");
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    /// @notice Owner-adjustable treasury share (out of `SHARE_DENOMINATOR`).
    /// @dev    Hard-capped at `MAX_TREASURY_SHARE` (50). LP share is the
    ///         complement; lowering treasuryShare increases LP share, never
    ///         the other way around past the cap.
    function setTreasuryShare(uint256 _newShare) external onlyOwner {
        require(_newShare <= MAX_TREASURY_SHARE, "SHARE_TOO_HIGH");
        emit TreasuryShareUpdated(treasuryShare, _newShare);
        treasuryShare = _newShare;
    }

    function getLPYieldSummary()
        external
        view
        returns (uint256 lpBonusRate, uint256 totalLPBonusPaid, uint256 totalTreasuryPaid, uint256 distributions)
    {
        return (SHARE_DENOMINATOR - treasuryShare, totalToLPs, totalToTreasury, distributionCount);
    }
}
