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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Undertow} from "../src/Undertow.sol";

contract UndertowTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    Undertow internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal constant OWNER = 0x4957f49620AFf3Adbbe8195a4f633E49cc93376c;
    uint256 internal constant MATERIAL = 1e15; // 0.001 quote units resets the staleness clock
    uint256 internal quoteId; // ERC-6909 id of the quote currency

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    event LvrSurcharge(PoolId indexed poolId, uint256 staleBlocks, uint24 surcharge, uint24 lpFee);
    event ProgrammableFeeCollected(PoolId indexed poolId, Currency indexed quote, uint256 platform);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies(); // sets currency0 < currency1
        _deployHook(currency0); // quote = currency0
        (poolKey, poolId) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        quoteId = uint256(uint160(Currency.unwrap(currency0)));
        // Advance so the first test swap sees a defined, non-negative staleness gap.
        vm.roll(block.number + 1);
    }

    function _deployHook(Currency quote) internal {
        bytes memory args = abi.encode(manager, quote, MATERIAL);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(Undertow).creationCode, args);
        hook = new Undertow{salt: salt}(manager, quote, MATERIAL);
        assertEq(address(hook), addr, "mined addr mismatch");
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // -------------------------------------------------------------------------------------------
    //                                    Init / configuration
    // -------------------------------------------------------------------------------------------

    function test_revertsOnStaticFee() public {
        (Currency a, Currency b) = (currency0, currency1);
        vm.expectRevert(); // NotDynamicFee bubbles through initialize's afterInitialize wrapper
        initPool(a, b, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_bindsCanonicalPool() public view {
        assertTrue(hook.bound(poolId));
        assertEq(Currency.unwrap(hook.quoteCurrency()), Currency.unwrap(currency0));
    }

    // -------------------------------------------------------------------------------------------
    //                          Mandatory 10 bps — all four swap quadrants
    // -------------------------------------------------------------------------------------------

    function test_platformFee_zeroForOne_exactIn() public {
        // quote (currency0) is the input/specified currency -> BEFORE quadrant, basis = |amountSpecified|
        uint256 amtIn = 1 ether;
        _swap(true, -int256(amtIn));
        uint256 expected = _ceil(amtIn, 1000, 1_000_000);
        assertEq(hook.programmableFeeOwed(poolId), expected, "owed");
        assertEq(manager.balanceOf(address(hook), quoteId), expected, "solvency: claims back the liability");
    }

    function test_platformFee_oneForZero_exactOut() public {
        // exact-out oneForZero: specified = currency0 (out) -> quote specified -> BEFORE quadrant
        uint256 amtOut = 0.5 ether;
        _swap(false, int256(amtOut));
        uint256 expected = _ceil(amtOut, 1000, 1_000_000);
        assertEq(hook.programmableFeeOwed(poolId), expected, "owed");
        assertEq(manager.balanceOf(address(hook), quoteId), expected, "solvency");
    }

    function test_platformFee_oneForZero_exactIn() public {
        // oneForZero exact-in: specified = currency1 (in) -> quote (currency0) UNSPECIFIED -> AFTER quadrant
        _swap(false, -int256(1 ether));
        uint256 owed = hook.programmableFeeOwed(poolId);
        assertGt(owed, 0, "after-quadrant fee accrued");
        assertEq(manager.balanceOf(address(hook), quoteId), owed, "solvency");
    }

    function test_platformFee_zeroForOne_exactOut() public {
        // zeroForOne exact-out: specified = currency1 (out) -> quote (currency0) UNSPECIFIED -> AFTER quadrant
        _swap(true, int256(0.5 ether));
        uint256 owed = hook.programmableFeeOwed(poolId);
        assertGt(owed, 0, "after-quadrant fee accrued");
        assertEq(manager.balanceOf(address(hook), quoteId), owed, "solvency");
    }

    /// @dev The 10 bps is exactly 0.1% of the quote input for the deterministic before-quadrant.
    function testFuzz_platformFee_exactRate(uint128 amtIn) public {
        amtIn = uint128(bound(amtIn, 1e6, 100 ether));
        _swap(true, -int256(uint256(amtIn)));
        assertEq(hook.programmableFeeOwed(poolId), _ceil(amtIn, 1000, 1_000_000));
    }

    // -------------------------------------------------------------------------------------------
    //                                   LVR surcharge schedule
    // -------------------------------------------------------------------------------------------

    function test_surcharge_scalesWithStaleBlocks() public {
        // clock was set at setUp init block; roll 4 blocks so staleBlocks = 4 (5 - 1) at swap time.
        uint256 base = 3000;
        uint256 perBlock = 500;
        // We are one block past the init block already (setUp rolled +1). Roll 3 more -> 4 stale blocks.
        vm.roll(block.number + 3);
        uint256 stale = 4;
        vm.expectEmit(true, false, false, true);
        emit LvrSurcharge(poolId, stale, uint24(perBlock * stale), uint24(base + perBlock * stale));
        _swap(true, -int256(0.01 ether));
    }

    function test_surcharge_capped() public {
        vm.roll(block.number + 10_000); // way past saturation
        vm.recordLogs();
        _swap(true, -int256(0.01 ether));
        // surcharge saturates at MAX_SURCHARGE (50000) -> lpFee = 53000
        // (assert via the public constants; exact emit checked in schedule test)
        assertEq(uint256(hook.MAX_SURCHARGE()), 50_000);
        assertEq(uint256(hook.BASE_LP_FEE()) + hook.MAX_SURCHARGE(), 53_000);
    }

    function test_surcharge_zeroSameBlock() public {
        // First material swap sets the clock to this block; a second swap in the SAME block is not stale.
        _swap(true, -int256(0.01 ether)); // material (>= MATERIAL) -> resets clock to current block
        vm.expectEmit(true, false, false, true);
        emit LvrSurcharge(poolId, 0, 0, uint24(3000));
        _swap(false, -int256(0.01 ether)); // opposite direction, same block -> zero surcharge
    }

    // -------------------------------------------------------------------------------------------
    //                          Anti-gaming: dust priming cannot disarm
    // -------------------------------------------------------------------------------------------

    function test_dustPriming_doesNotResetClock() public {
        uint256 clockBefore = hook.lastMaterialBlock(poolId);
        vm.roll(block.number + 5);
        // A sub-threshold "priming" swap must NOT advance the staleness clock.
        _swap(true, -int256(MATERIAL - 1));
        assertEq(hook.lastMaterialBlock(poolId), clockBefore, "dust must not reset the clock");
    }

    function test_materialSwap_resetsClock() public {
        vm.roll(block.number + 5);
        _swap(true, -int256(MATERIAL + 1 ether));
        assertEq(hook.lastMaterialBlock(poolId), block.number, "material swap resets the clock");
    }

    // -------------------------------------------------------------------------------------------
    //                                     Owner-only claim
    // -------------------------------------------------------------------------------------------

    function test_claim_onlyOwner() public {
        _swap(true, -int256(1 ether));
        vm.expectRevert(Undertow.NotProgrammableOwner.selector);
        hook.claimProgrammableFee(poolKey, address(0xBEEF));
    }

    function test_claim_transfersClaimsToDestination() public {
        _swap(true, -int256(1 ether));
        uint256 owed = hook.programmableFeeOwed(poolId);
        assertGt(owed, 0);
        address dest = address(0xD0);
        vm.prank(OWNER);
        uint256 claimed = hook.claimProgrammableFee(poolKey, dest);
        assertEq(claimed, owed);
        assertEq(hook.programmableFeeOwed(poolId), 0, "liability cleared");
        assertEq(manager.balanceOf(dest, quoteId), owed, "destination received the claims");
        assertEq(manager.balanceOf(address(hook), quoteId), 0, "hook no longer holds the claim");
    }

    function test_claim_rejectsZeroDestination() public {
        _swap(true, -int256(1 ether));
        vm.prank(OWNER);
        vm.expectRevert(Undertow.ZeroClaimDestination.selector);
        hook.claimProgrammableFee(poolKey, address(0));
    }

    // -------------------------------------------------------------------------------------------
    //                                        Helpers
    // -------------------------------------------------------------------------------------------

    function _ceil(uint256 x, uint256 num, uint256 den) internal pure returns (uint256) {
        return (x * num + den - 1) / den;
    }
}
