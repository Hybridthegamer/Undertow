// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Undertow} from "../src/Undertow.sol";

/// @dev The four named safety cases from the review checklist, adapted to Undertow's design
///      (the LVR rebate is a native dynamic LP fee, so there is no rebate pot to drain).
contract UndertowSafetyTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    Undertow internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    uint256 internal quoteId;

    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    address internal constant ATTACKER = address(0xA11CE);
    uint256 internal constant MATERIAL = 1e15;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        bytes memory args = abi.encode(manager, currency0, MATERIAL);
        (address addr, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(Undertow).creationCode, args);
        hook = new Undertow{salt: salt}(manager, currency0, MATERIAL);
        require(address(hook) == addr, "addr");
        // Initialize the canonical dynamic-fee pool but DO NOT add liquidity here;
        // each test controls its own liquidity state.
        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        quoteId = uint256(uint160(Currency.unwrap(currency0)));
        vm.roll(block.number + 1);
    }

    function _addDeep() internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 500 ether, salt: bytes32(0)}),
            ""
        );
    }

    function _swap(address who, bool zeroForOne, int256 amountSpecified) internal returns (bool ok) {
        vm.prank(who);
        try swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (BalanceDelta) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _fundAndApprove(address who) internal {
        deal(Currency.unwrap(currency0), who, 1e24);
        deal(Currency.unwrap(currency1), who, 1e24);
        vm.startPrank(who);
        IERC20Min(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Min(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // 1. Reentrancy — the hook's callbacks are gated to the PoolManager, and it never calls
    //    untrusted code (the LVR rebate is a native LP fee, not a pot pay-out), so there is no
    //    reentrant path. Prove the authorization boundary that closes it.
    // -------------------------------------------------------------------------------------------
    function test_reentrancy_callbacksRejectNonPoolManager() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        // Direct calls from a non-PoolManager caller (an attacker mid-reentry) must revert.
        vm.startPrank(ATTACKER);
        vm.expectRevert();
        IHooks(address(hook)).beforeSwap(ATTACKER, poolKey, p, "");
        vm.expectRevert();
        IHooks(address(hook)).afterSwap(ATTACKER, poolKey, p, BalanceDelta.wrap(0), "");
        vm.expectRevert();
        IHooks(address(hook)).afterInitialize(ATTACKER, poolKey, SQRT_PRICE_1_1, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // 2. Zero-liquidity — with no in-range liquidity a swap cannot execute; the hook must not
    //    accrue a phantom fee or corrupt its accounting (no donation-to-zero-LPs revert exists
    //    here because the rebate is a native LP fee, not a pot pay-out).
    // -------------------------------------------------------------------------------------------
    function test_zeroLiquidity_noPhantomFeeNoCorruption() public {
        // no _addDeep(): the pool has zero liquidity. An after-quadrant swap (quote is the
        // UNSPECIFIED currency) charges on the EXECUTED quote output, which is zero when nothing
        // can fill -> no phantom fee, and the hook stays solvent.
        _swap(address(this), false, -1e15); // oneForZero exact-input: quote(currency0) unspecified
        assertEq(hook.programmableFeeOwed(poolId), 0, "no phantom fee on the executed-output basis");
        assertEq(manager.balanceOf(address(hook), quoteId), 0, "solvency: hook holds nothing");
        // the hook state is uncorrupted: the pool is still bound and its clock is sane
        assertTrue(hook.bound(poolId), "pool binding intact");
        assertLe(hook.lastMaterialBlock(poolId), block.number, "clock uncorrupted");
    }

    // -------------------------------------------------------------------------------------------
    // 3. Self-arb drain — an attacker hammering the pool with swaps can never drain the hook's
    //    claims or make it insolvent; the accrued owner liability is always fully backed and only
    //    ever grows, and the attacker can never claim it.
    // -------------------------------------------------------------------------------------------
    function test_selfArbDrain_hookNeverDrainable() public {
        _addDeep();
        _fundAndApprove(ATTACKER);
        uint256 lastOwed;
        for (uint256 i; i < 24; i++) {
            vm.roll(block.number + (i % 5));
            _swap(ATTACKER, i % 2 == 0, -int256(0.05 ether));
            uint256 owed = hook.programmableFeeOwed(poolId);
            // SOLVENCY: claims held always exactly back the liability
            assertEq(manager.balanceOf(address(hook), quoteId), owed, "drain: solvency violated");
            // liability only ever grows (never leaks to the attacker)
            assertGe(owed, lastOwed, "drain: liability decreased");
            lastOwed = owed;
        }
        // the attacker cannot claim the accrued liability
        vm.prank(ATTACKER);
        vm.expectRevert(Undertow.NotProgrammableOwner.selector);
        hook.claimProgrammableFee(poolKey, ATTACKER);
    }

    // -------------------------------------------------------------------------------------------
    // 4. Double-fee — the 10 bps is charged exactly once per swap (in the before OR the after
    //    quadrant, never both). Prove the accrual equals a single 10 bps of quote volume.
    // -------------------------------------------------------------------------------------------
    function test_noDoubleFee_chargedExactlyOnce() public {
        _addDeep();
        uint256 amtIn = 1 ether; // zeroForOne exact-input: quote is the specified currency -> BEFORE quadrant only
        uint256 before = hook.programmableFeeOwed(poolId);
        _swap(address(this), true, -int256(amtIn));
        uint256 charged = hook.programmableFeeOwed(poolId) - before;
        uint256 single = (amtIn * 1000 + 1_000_000 - 1) / 1_000_000; // ceil(0.10%)
        assertEq(charged, single, "fee must be a single 10 bps, not doubled");
        // and the whole liability is still exactly backed
        assertEq(manager.balanceOf(address(hook), quoteId), hook.programmableFeeOwed(poolId), "solvency");
    }
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
}
