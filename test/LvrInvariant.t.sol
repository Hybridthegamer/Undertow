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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Undertow} from "../src/Undertow.sol";

/// @dev Drives random swaps (both directions, exact in/out) across random block gaps. Catches
///      expected price-limit reverts so `fail_on_revert = true` stays meaningful.
contract SwapHandler is Test {
    PoolSwapTest internal immutable swapRouter;
    PoolKey internal key;
    address internal immutable trader;

    uint160 internal constant MIN_LIMIT = 4295128740;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    constructor(PoolSwapTest _router, PoolKey memory _key, address _trader) {
        swapRouter = _router;
        key = _key;
        trader = _trader;
    }

    function swap(uint256 amtSeed, bool zeroForOne, bool exactIn, uint8 rollBy) external {
        vm.roll(block.number + (uint256(rollBy) % 50));
        int256 amt = int256(bound(amtSeed, 1e12, 5 ether));
        int256 amountSpecified = exactIn ? -amt : amt;
        vm.prank(trader);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_LIMIT : MAX_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }
}

contract LvrInvariantTest is Test, Deployers {
    Undertow internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    SwapHandler internal handler;
    uint256 internal quoteId;

    address internal constant TRADER = address(0x7ADE);
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
        quoteId = uint256(uint160(Currency.unwrap(currency0)));

        // Fund and approve the trader that the handler pranks.
        MockERC20(Currency.unwrap(currency0)).mint(TRADER, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(TRADER, 1e30);
        vm.startPrank(TRADER);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        handler = new SwapHandler(swapRouter, poolKey, TRADER);
        targetContract(address(handler));
    }

    /// @notice SOLVENCY: the accrued owner liability is always exactly backed by ERC-6909 quote claims
    ///         the hook holds. The hook can never owe more than it can pay.
    function invariant_platformLiabilityFullyBacked() public view {
        assertEq(manager.balanceOf(address(hook), quoteId), hook.programmableFeeOwed(poolId));
    }

    /// @notice The staleness clock never exceeds the current block.
    function invariant_clockNeverInFuture() public view {
        assertLe(hook.lastMaterialBlock(poolId), block.number);
    }
}
