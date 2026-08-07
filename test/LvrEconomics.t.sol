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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Undertow} from "../src/Undertow.sol";

/// @dev Proves the LVR-recapture thesis: a staler pool charges the realigning swap a higher LP fee,
///      so its own in-range LPs earn strictly more from the same trade.
contract LvrEconomicsTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    Undertow internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    uint256 internal constant MATERIAL = 1e15;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        bytes memory args = abi.encode(manager, currency0, MATERIAL);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(Undertow).creationCode, args);
        hook = new Undertow{salt: salt}(manager, currency0, MATERIAL);
        require(address(hook) == addr, "addr");
        (poolKey, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        // Deep, wide position so test swaps stay well inside range (no price-limit artifacts).
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 500 ether, salt: bytes32(0)}),
            ""
        );
    }

    function _swap(bool zeroForOne, uint256 amt) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_stalerPool_paysLpsMore() public {
        uint256 amt = 0.05 ether;

        // Fresh (near-zero staleness): the clock is at the init block; roll +1 so staleBlocks = 1.
        vm.roll(block.number + 1);
        (uint256 g0Before,) = manager.getFeeGrowthGlobals(poolId);
        _swap(true, amt); // zeroForOne, resets clock to current block; LP fee on currency0
        (uint256 g0AfterLow,) = manager.getFeeGrowthGlobals(poolId);
        uint256 lowStaleFeeGrowth = g0AfterLow - g0Before;

        // Restore price toward 1:1 (charges fee on currency1, not currency0 -> g0 stays comparable).
        _swap(false, amt);

        // Stale pool: 40 quiet blocks -> the realigning swap pays a much higher LP fee.
        vm.roll(block.number + 40);
        (uint256 g0Before2,) = manager.getFeeGrowthGlobals(poolId);
        _swap(true, amt); // same size, same direction, same currency0 fee basis
        (uint256 g0After2,) = manager.getFeeGrowthGlobals(poolId);
        uint256 highStaleFeeGrowth = g0After2 - g0Before2;

        // Same trade size, but the staler pool's LPs earn strictly more (LVR recaptured to LPs).
        assertGt(highStaleFeeGrowth, lowStaleFeeGrowth, "staler pool must pay LPs more");
    }
}
