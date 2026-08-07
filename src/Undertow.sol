// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from
    "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

/**
 * @title Undertow
 * @notice A Programmable Uniswap v4 launch hook that recaptures loss-versus-rebalancing (LVR) for
 *         the pool's own liquidity providers, oracle-free and keeper-free, while enforcing the
 *         mandatory Programmable 10 bps volume fee non-bypassably on one canonical pool.
 *
 * @dev  ECONOMIC THESIS.
 *       LVR (Milionis, Moallemi, Roughgarden, Zhang, arXiv:2208.06046) is the value passive LPs bleed
 *       to arbitrageurs who pick off stale AMM quotes after the off-chain price moves. The cumulative
 *       profit of the rebalancing arbitrageur equals cumulative LVR. LVR grows with volatility x time:
 *       the longer a pool sits untraded, the further the fair price drifts, the larger the next
 *       arbitrage. This hook prices that staleness back to the arbitrageur.
 *
 *       LVR-RECAPTURE MECHANISM (a dynamic LP fee — routed to LPs by the v4 core, NOT a custom curve).
 *       The canonical pool is a dynamic-fee pool. On every swap the hook returns an LP-fee override:
 *
 *           lpFee = BASE_LP_FEE + surcharge,   surcharge = min(MAX_SURCHARGE, PER_BLOCK * staleBlocks)
 *
 *       where `staleBlocks = block.number - lastMaterialBlock`. The first swap after a quiet gap — the
 *       arbitrage that realigns the pool to the true price — pays the highest LP fee; that fee is
 *       distributed to in-range LPs by the unmodified v4 fee-growth accounting. Ordinary intra-block
 *       flow that follows the corrected price pays only BASE_LP_FEE. No oracle, no external price, no
 *       keeper: staleness (elapsed blocks) is the manipulation-resistant LVR proxy.
 *
 *       ANTI-GAMING. Only a swap whose executed quote volume reaches {materialThreshold} resets the
 *       staleness clock. A dust "priming" swap therefore cannot disarm the surcharge for a following
 *       large arbitrage. A residual remains (an arbitrageur may split one large realigning trade so
 *       only the first material tranche is surcharged); this is disclosed in THREAT_MODEL.md and is
 *       bounded — the first material tranche is always surcharged on its own volume.
 *
 *       MANDATORY PROGRAMMABLE FEE (hundredths-of-a-bip; 1000 = 10 bps = 0.10%).
 *         selected total hook charge = 1000 (10 bps). effective = max(1000,1000) = 1000.
 *         platform = 1000 (exactly 10 bps) -> owner-only CLAIMABLE LIABILITY.
 *         project  = effective - 1000 = 0.  This model takes NO project fee; the LVR surcharge is an
 *                    LP fee (excluded from the split), never a hook-owned charge.
 *       The 10 bps is charged on the EXECUTED GROSS QUOTE-SIDE volume of the one canonical pool in all
 *       four swap quadrants, via quadrant-dependent return deltas (quote can be currency0 or currency1):
 *
 *         | quote asset | zeroForOne exactIn | zeroForOne exactOut | oneForZero exactIn | oneForZero exactOut |
 *         | currency0   | before             | after               | after              | before              |
 *         | currency1   | after              | before              | before             | after               |
 *
 *       Collect BEFORE when the quote is the swap's specified currency (basis = |amountSpecified|,
 *       known pre-swap); collect AFTER when the quote is unspecified (basis = the executed quote delta,
 *       never the requested amount — a partial fill is never over-charged). Every returned delta is
 *       backed by ERC-6909 claims taken from the PoolManager in the SAME unlock; the hook creates no
 *       unbacked delta and holds no user funds beyond the owner-claimable platform liability.
 *
 *       AUTHORITIES. The only privileged action is claiming the accrued platform liability, callable
 *       ONLY by the immutable Programmable owner {PROGRAMMABLE_OWNER}, to itself or a destination it
 *       selects per claim. There is no builder/project/admin path, no owner over the LVR surcharge, no
 *       pause, no upgrade, no arbitrary call, no sweep, and no way to touch LP or trader funds.
 */
contract Undertow is BaseHook {
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    // ----------------------------------------------------------------------------------------------
    //                                            Constants
    // ----------------------------------------------------------------------------------------------

    /// @notice Immutable Programmable fee owner. The sole claimant of the platform liability.
    address public constant PROGRAMMABLE_OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;

    /// @dev Fee denominator: hundredths-of-a-bip in 100%. 1_000_000 = 100%.
    uint256 internal constant FEE_DENOM = 1_000_000;

    /// @dev Platform rate: exactly 10 bps, the fixed Programmable slice.
    uint256 internal constant PLATFORM_RATE = 1000;

    /// @notice Base LP fee applied to ordinary flow, in hundredths-of-a-bip. 3000 = 0.30%.
    uint24 public constant BASE_LP_FEE = 3000;

    /// @notice Maximum LVR surcharge added on top of the base LP fee, in hundredths-of-a-bip. 50000 = 5.00%.
    uint24 public constant MAX_SURCHARGE = 50_000;

    /// @notice LVR surcharge accrued per stale block, in hundredths-of-a-bip. 500 = 5 bps/block.
    uint24 public constant SURCHARGE_PER_BLOCK = 500;

    /// @notice Hard ceiling on the total LP fee override (BASE_LP_FEE + MAX_SURCHARGE = 5.30%).
    ///         Always far below the v4 core maximum (100%).
    uint24 public constant MAX_LP_FEE = BASE_LP_FEE + MAX_SURCHARGE;

    // ----------------------------------------------------------------------------------------------
    //                                        Immutable config
    // ----------------------------------------------------------------------------------------------

    /// @notice The canonical pool's quote asset (the Programmable fee basis). Bound at construction.
    Currency public immutable quoteCurrency;

    /// @notice Minimum executed quote volume that resets the staleness clock. Blocks dust priming.
    uint256 public immutable materialThreshold;

    // ----------------------------------------------------------------------------------------------
    //                                            Storage
    // ----------------------------------------------------------------------------------------------

    /// @notice Owner-claimable platform liability (10 bps), scoped by PoolId. Denominated in {quoteCurrency}.
    ///         No cross-pool netting: each pool's liability is independent.
    mapping(PoolId => uint256) public programmableFeeOwed;

    /// @notice The last block in which a swap of at least {materialThreshold} quote volume executed.
    mapping(PoolId => uint256) public lastMaterialBlock;

    /// @notice Whether a pool has been bound to this hook (one-shot canonical binding).
    mapping(PoolId => bool) public bound;

    // ----------------------------------------------------------------------------------------------
    //                                             Events
    // ----------------------------------------------------------------------------------------------

    /// @notice Emitted when the canonical pool is bound at initialization.
    event PoolBound(PoolId indexed poolId, Currency quote);

    /// @notice Emitted on every swap with the LVR surcharge applied to LPs (hundredths-of-a-bip).
    event LvrSurcharge(PoolId indexed poolId, uint256 staleBlocks, uint24 surcharge, uint24 lpFee);

    /// @notice Emitted when the mandatory 10 bps platform fee accrues to the owner liability.
    event ProgrammableFeeCollected(PoolId indexed poolId, Currency indexed quote, uint256 platform);

    /// @notice Emitted when the owner claims the accrued platform liability.
    event ProgrammableFeeClaimed(PoolId indexed poolId, Currency indexed quote, address indexed to, uint256 amount);

    // ----------------------------------------------------------------------------------------------
    //                                             Errors
    // ----------------------------------------------------------------------------------------------

    error NotDynamicFee();
    error NotQuotePool();
    error AlreadyBound();
    error NotProgrammableOwner();
    error ZeroClaimDestination();

    constructor(IPoolManager _poolManager, Currency _quoteCurrency, uint256 _materialThreshold)
        BaseHook(_poolManager)
    {
        quoteCurrency = _quoteCurrency;
        materialThreshold = _materialThreshold;
    }

    // ----------------------------------------------------------------------------------------------
    //                                           Permissions
    // ----------------------------------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ----------------------------------------------------------------------------------------------
    //                                         Initialization
    // ----------------------------------------------------------------------------------------------

    /// @dev One-shot canonical binding: the pool must be dynamic-fee and must contain the quote asset.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(quoteCurrency)
                && Currency.unwrap(key.currency1) != Currency.unwrap(quoteCurrency)
        ) revert NotQuotePool();
        PoolId id = key.toId();
        if (bound[id]) revert AlreadyBound();
        bound[id] = true;
        lastMaterialBlock[id] = block.number;
        emit PoolBound(id, quoteCurrency);
        return IHooks.afterInitialize.selector;
    }

    // ----------------------------------------------------------------------------------------------
    //                                             Swaps
    // ----------------------------------------------------------------------------------------------

    /// @dev Sets the LVR-recapture LP fee override, and collects the 10 bps platform fee in the
    ///      BEFORE quadrant (when the quote is this swap's specified currency).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();

        // --- LVR surcharge as a dynamic LP fee (routed to in-range LPs by the core) ---
        uint24 lpFeeOverride = _lvrLpFeeOverride(id) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // --- Mandatory 10 bps: BEFORE quadrant iff the quote is the specified currency ---
        // quote is specified when (quote is currency0) == (specified token is token0)
        if ((key.currency0 == quoteCurrency) != ((params.amountSpecified < 0) == params.zeroForOne)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
        }

        uint256 specifiedAbs =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 platform = _ceilFee(specifiedAbs);
        _collect(id, platform);

        // Positive specified delta -> hook is credited `platform` of the (quote) specified currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(platform.toInt128(), int128(0)), lpFeeOverride);
    }

    /// @dev Collects the 10 bps platform fee in the AFTER quadrant (quote unspecified), and updates
    ///      the staleness clock when the executed quote volume is material.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        bool quoteIs0 = key.currency0 == quoteCurrency;

        int128 quoteDelta = quoteIs0 ? delta.amount0() : delta.amount1();
        uint256 quoteExecuted = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : uint256(uint128(quoteDelta));

        // AFTER quadrant iff the quote is the UNSPECIFIED currency of this swap.
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool quoteIsUnspecified = quoteIs0 != specifiedTokenIs0;

        int128 feeDelta = 0;
        if (quoteIsUnspecified && quoteExecuted != 0) {
            uint256 platform = _ceilFee(quoteExecuted);
            _collect(id, platform);
            feeDelta = platform.toInt128(); // positive -> charged to the swapper on the unspecified (quote) side
        }

        // Reset the staleness clock only for material swaps (dust priming cannot disarm the surcharge).
        if (quoteExecuted >= materialThreshold) {
            lastMaterialBlock[id] = block.number;
        }

        return (IHooks.afterSwap.selector, feeDelta);
    }

    // ----------------------------------------------------------------------------------------------
    //                                           Fee claims
    // ----------------------------------------------------------------------------------------------

    /// @notice Claim the accrued 10 bps platform liability for `key`'s pool to `to`.
    /// @dev Callable ONLY by the immutable Programmable owner. The claim is paid as ERC-6909 quote
    ///      claims transferred to `to`, redeemable at the PoolManager. No other party can claim,
    ///      redirect, or reduce this liability.
    function claimProgrammableFee(PoolKey calldata key, address to) external returns (uint256 amount) {
        if (msg.sender != PROGRAMMABLE_OWNER) revert NotProgrammableOwner();
        if (to == address(0)) revert ZeroClaimDestination();
        PoolId id = key.toId();
        amount = programmableFeeOwed[id];
        if (amount == 0) return 0;
        programmableFeeOwed[id] = 0;
        // Transfer the hook's ERC-6909 quote claims to the destination (owner redeems at PoolManager).
        poolManager.transfer(to, quoteCurrency.toId(), amount);
        emit ProgrammableFeeClaimed(id, quoteCurrency, to, amount);
    }

    // ----------------------------------------------------------------------------------------------
    //                                            Internals
    // ----------------------------------------------------------------------------------------------

    /// @dev The LVR-recapture LP fee (base + staleness surcharge), in hundredths-of-a-bip, without
    ///      the override flag. Hard-bounded to [BASE_LP_FEE, MAX_LP_FEE].
    function _lvrLpFeeOverride(PoolId id) internal returns (uint24 lpFee) {
        uint256 last = lastMaterialBlock[id];
        uint256 staleBlocks = block.number > last ? block.number - last : 0;
        uint256 rawSurcharge = staleBlocks * SURCHARGE_PER_BLOCK;
        uint24 surcharge = rawSurcharge >= MAX_SURCHARGE ? MAX_SURCHARGE : uint24(rawSurcharge);
        lpFee = BASE_LP_FEE + surcharge; // <= MAX_LP_FEE, far below the core maximum
        emit LvrSurcharge(id, staleBlocks, surcharge, lpFee);
    }

    /// @dev 10 bps of `grossQuote`, rounded up so the platform is never under-collected.
    function _ceilFee(uint256 grossQuote) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(grossQuote, PLATFORM_RATE, FEE_DENOM);
    }

    /// @dev Take `amount` of the quote as ERC-6909 claims to the hook and record the owner liability.
    function _collect(PoolId id, uint256 amount) internal {
        if (amount == 0) return;
        quoteCurrency.take(poolManager, address(this), amount, true);
        programmableFeeOwed[id] += amount;
        emit ProgrammableFeeCollected(id, quoteCurrency, amount);
    }
}
