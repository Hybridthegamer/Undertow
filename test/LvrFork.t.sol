// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Undertow} from "../src/Undertow.sol";

/// @dev Rehearses the hook against the REAL mainnet Uniswap v4 PoolManager. Runs only when
///      MAINNET_RPC_URL is set; otherwise it is skipped (never reported as executed).
contract LvrForkTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_LIMIT = 4295128740;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    Undertow internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    Currency internal quote;
    uint256 internal quoteId;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        manager = IPoolManager(MAINNET_POOL_MANAGER);
        // Confirm we are bound to the real deployed core (has code).
        assertGt(MAINNET_POOL_MANAGER.code.length, 0, "PoolManager not deployed on this fork");

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        quote = Currency.wrap(t0);
        quoteId = uint256(uint160(t0));

        MockERC20(t0).mint(address(this), 1e27);
        MockERC20(t1).mint(address(this), 1e27);
        MockERC20(t0).approve(address(swapRouter), type(uint256).max);
        MockERC20(t1).approve(address(swapRouter), type(uint256).max);
        MockERC20(t0).approve(address(lpRouter), type(uint256).max);
        MockERC20(t1).approve(address(lpRouter), type(uint256).max);

        bytes memory args = abi.encode(manager, quote, uint256(1e15));
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(Undertow).creationCode, args);
        hook = new Undertow{salt: salt}(manager, quote, 1e15);
        require(address(hook) == addr, "addr");

        poolKey = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ""
        );
    }

    function test_fork_platformFeeAndSolvency() public {
        if (address(manager) == address(0)) {
            vm.skip(true);
            return;
        }
        vm.roll(block.number + 5);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 owed = hook.programmableFeeOwed(poolId);
        assertEq(owed, 1 ether / 1000, "10 bps of quote input on the real PoolManager");
        assertEq(manager.balanceOf(address(hook), quoteId), owed, "solvency on mainnet fork");
    }
}
