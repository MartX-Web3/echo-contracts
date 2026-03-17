// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IntentRegistry.sol";
import "../src/interfaces/IIntentRegistry.sol";

/// @notice Tests for IntentRegistry.
///         Covers correct decoding, revert cases, and fuzz testing.
contract IntentRegistryTest is Test {

    IntentRegistry public registry;

    // Uniswap V3 SwapRouter on Sepolia
    address constant UNI_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // Test tokens
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    bytes4 constant EXACT_INPUT_SINGLE  = bytes4(0x414bf389);
    bytes4 constant EXACT_OUTPUT_SINGLE = bytes4(0x4aa4a4fa);

    function setUp() public {
        registry = new IntentRegistry();
    }

    // ── isRegistered ──────────────────────────────────────────────────────

    function test_isRegistered_exactInputSingle() public view {
        assertTrue(registry.isRegistered(EXACT_INPUT_SINGLE));
    }

    function test_isRegistered_exactOutputSingle() public view {
        assertTrue(registry.isRegistered(EXACT_OUTPUT_SINGLE));
    }

    function test_isRegistered_unknown() public view {
        assertFalse(registry.isRegistered(bytes4(0xdeadbeef)));
        assertFalse(registry.isRegistered(bytes4(0)));
    }

    // ── registeredSelectors ───────────────────────────────────────────────

    function test_registeredSelectors() public view {
        bytes4[] memory sels = registry.registeredSelectors();
        assertEq(sels.length, 2);
        assertEq(sels[0], EXACT_INPUT_SINGLE);
        assertEq(sels[1], EXACT_OUTPUT_SINGLE);
    }

    // ── getSpec ───────────────────────────────────────────────────────────

    function test_getSpec_exactInputSingle() public view {
        IIntentRegistry.IntentSpec memory spec = registry.getSpec(EXACT_INPUT_SINGLE);
        assertEq(spec.selector, EXACT_INPUT_SINGLE);
        assertEq(spec.name, "Uniswap V3 exactInputSingle");
        assertEq(spec.tokenInOffset,   4);
        assertEq(spec.tokenOutOffset,  36);
        assertEq(spec.amountInOffset,  164);
        assertEq(spec.recipientOffset, 100);
        assertTrue(spec.exists);
    }

    function test_getSpec_exactOutputSingle() public view {
        IIntentRegistry.IntentSpec memory spec = registry.getSpec(EXACT_OUTPUT_SINGLE);
        assertEq(spec.selector, EXACT_OUTPUT_SINGLE);
        assertEq(spec.name, "Uniswap V3 exactOutputSingle");
        assertEq(spec.tokenInOffset,   4);
        assertEq(spec.tokenOutOffset,  36);
        assertEq(spec.amountInOffset,  196);
        assertEq(spec.recipientOffset, 100);
        assertTrue(spec.exists);
    }

    function test_getSpec_unknown_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IntentRegistry.UnknownSelector.selector, bytes4(0xdeadbeef))
        );
        registry.getSpec(bytes4(0xdeadbeef));
    }

    // ── decode: exactInputSingle ──────────────────────────────────────────

    function _buildExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        address recipient,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            EXACT_INPUT_SINGLE,
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountIn,
            amountOutMinimum,
            sqrtPriceLimitX96
        );
    }

    function _buildExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        address recipient,
        uint256 deadline,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            EXACT_OUTPUT_SINGLE,
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountOut,
            amountInMaximum,
            sqrtPriceLimitX96
        );
    }

    function test_decode_exactInputSingle_basic() public view {
        address myRecipient = makeAddr("recipient");
        bytes memory data = _buildExactInputSingle(
            USDC, WETH, 3000, myRecipient, block.timestamp, 100e6, 0, 0
        );

        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);

        assertEq(tIn,  USDC);
        assertEq(tOut, WETH);
        assertEq(amt,  100e6);
        assertEq(rec,  myRecipient);
    }

    function test_decode_exactInputSingle_large_amount() public view {
        address myRecipient = makeAddr("recipient");
        uint256 largeAmount = 1_000_000e6; // 1M USDC
        bytes memory data = _buildExactInputSingle(
            USDC, WETH, 500, myRecipient, block.timestamp + 1000, largeAmount, 0, 0
        );

        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);

        assertEq(tIn,  USDC);
        assertEq(tOut, WETH);
        assertEq(amt,  largeAmount);
        assertEq(rec,  myRecipient);
    }

    function test_decode_exactInputSingle_different_fee_tiers() public view {
        // 100, 500, 3000, 10000 are the standard Uniswap V3 fee tiers
        // Fee tier should not affect decoded fields
        address rec = makeAddr("r");
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint i = 0; i < fees.length; i++) {
            bytes memory data = _buildExactInputSingle(
                USDC, WETH, fees[i], rec, block.timestamp, 50e6, 0, 0
            );
            (address tIn, address tOut, uint256 amt, address r) = registry.decode(data);
            assertEq(tIn,  USDC);
            assertEq(tOut, WETH);
            assertEq(amt,  50e6);
            assertEq(r,    rec);
        }
    }

    // ── decode: exactOutputSingle ──────────────────────────────────────────

    function test_decode_exactOutputSingle_basic() public view {
        address myRecipient = makeAddr("recipient");
        // amountOut = 1 WETH, amountInMaximum = 3000 USDC
        bytes memory data = _buildExactOutputSingle(
            USDC, WETH, 3000, myRecipient, block.timestamp, 1e18, 3000e6, 0
        );

        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);

        assertEq(tIn,  USDC);
        assertEq(tOut, WETH);
        assertEq(amt,  3000e6);   // amountInMaximum is the policy cap
        assertEq(rec,  myRecipient);
    }

    function test_decode_exactOutputSingle_amountInMaximum_used() public view {
        // Verify that for exactOutputSingle, amountInMaximum (offset 196) is returned
        // not amountOut (offset 164)
        address rec = makeAddr("rec");
        uint256 amountOut       = 1e18;    // 1 WETH output
        uint256 amountInMaximum = 5000e6;  // 5000 USDC maximum input

        bytes memory data = _buildExactOutputSingle(
            USDC, WETH, 3000, rec, block.timestamp, amountOut, amountInMaximum, 0
        );

        (, , uint256 amt, ) = registry.decode(data);

        // Must be amountInMaximum, not amountOut
        assertEq(amt, amountInMaximum);
        assertNotEq(amt, amountOut);
    }

    // ── decode: revert cases ──────────────────────────────────────────────

    function test_decode_unknown_selector_reverts() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xdeadbeef),
            USDC, WETH, uint24(3000), makeAddr("r"),
            block.timestamp, 100e6, 0, 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(IntentRegistry.UnknownSelector.selector, bytes4(0xdeadbeef))
        );
        registry.decode(data);
    }

    function test_decode_calldata_too_short_reverts() public {
        // Only 10 bytes — way too short
        bytes memory data = abi.encodePacked(EXACT_INPUT_SINGLE, bytes(new bytes(6)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentRegistry.CalldataTooShort.selector,
                uint256(10),
                uint256(260)
            )
        );
        registry.decode(data);
    }

    function test_decode_empty_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentRegistry.CalldataTooShort.selector,
                uint256(0),
                uint256(260)
            )
        );
        registry.decode(new bytes(0));
    }

    function test_decode_exactly_259_bytes_reverts() public {
        // One byte short of minimum
        bytes memory data = new bytes(259);
        bytes4 sel = EXACT_INPUT_SINGLE;
        data[0] = sel[0]; data[1] = sel[1]; data[2] = sel[2]; data[3] = sel[3];

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentRegistry.CalldataTooShort.selector,
                uint256(259),
                uint256(260)
            )
        );
        registry.decode(data);
    }

    function test_decode_exactly_260_bytes_does_not_revert() public view {
        // Minimum valid length — should not revert on length check
        // (may produce zero-address results, which is fine for this test)
        bytes memory data = new bytes(260);
        bytes4 sel = EXACT_INPUT_SINGLE;
        data[0] = sel[0]; data[1] = sel[1]; data[2] = sel[2]; data[3] = sel[3];

        // Should not revert — zero addresses returned
        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);
        assertEq(tIn,  address(0));
        assertEq(tOut, address(0));
        assertEq(amt,  0);
        assertEq(rec,  address(0));
    }

    // ── Fuzz: correctness with arbitrary valid inputs ──────────────────────

    function testFuzz_decode_exactInputSingle(
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn
    ) public view {
        bytes memory data = _buildExactInputSingle(
            tokenIn, tokenOut, 3000, recipient, block.timestamp, amountIn, 0, 0
        );

        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);

        assertEq(tIn,  tokenIn);
        assertEq(tOut, tokenOut);
        assertEq(amt,  amountIn);
        assertEq(rec,  recipient);
    }

    function testFuzz_decode_exactOutputSingle(
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountInMaximum
    ) public view {
        bytes memory data = _buildExactOutputSingle(
            tokenIn, tokenOut, 3000, recipient, block.timestamp, 1e18, amountInMaximum, 0
        );

        (address tIn, address tOut, uint256 amt, address rec) = registry.decode(data);

        assertEq(tIn,  tokenIn);
        assertEq(tOut, tokenOut);
        assertEq(amt,  amountInMaximum);
        assertEq(rec,  recipient);
    }

    // ── Fuzz: unknown selectors always revert ──────────────────────────────

    function testFuzz_decode_unknownSelector_alwaysReverts(bytes4 sel) public {
        vm.assume(sel != EXACT_INPUT_SINGLE && sel != EXACT_OUTPUT_SINGLE);

        // Build minimum valid calldata with unknown selector
        bytes memory data = new bytes(260);
        data[0] = sel[0]; data[1] = sel[1]; data[2] = sel[2]; data[3] = sel[3];

        vm.expectRevert(
            abi.encodeWithSelector(IntentRegistry.UnknownSelector.selector, sel)
        );
        registry.decode(data);
    }

    // ── Immutability: no setter exists ────────────────────────────────────

    function test_noSetterFunction() public view {
        // Verify the contract has no way to add new selectors
        // This is enforced by the absence of any state variables and
        // the use of pure functions throughout.
        // All functions are `pure` (no storage reads/writes).
        // Compile-time guarantee — this test documents the intent.
        assertTrue(registry.isRegistered(EXACT_INPUT_SINGLE));
        assertTrue(registry.isRegistered(EXACT_OUTPUT_SINGLE));
        assertFalse(registry.isRegistered(bytes4(0x12345678)));
        // No way to change this — no owner, no setter
    }

    // ── Security: recipient cannot be faked by data manipulation ──────────

    function test_decode_recipient_at_correct_offset() public view {
        // Place different address values at different offsets to ensure
        // we're reading recipient from offset 100, not from another field
        address decoy1    = makeAddr("decoy1");    // will be at tokenIn offset (4)
        address decoy2    = makeAddr("decoy2");    // will be at tokenOut offset (36)
        address realRecip = makeAddr("realRecip"); // will be at recipient offset (100)

        bytes memory data = _buildExactInputSingle(
            decoy1,    // tokenIn  at offset 4
            decoy2,    // tokenOut at offset 36
            3000,
            realRecip, // recipient at offset 100
            block.timestamp,
            100e6,
            0,
            0
        );

        (address tIn, address tOut, , address rec) = registry.decode(data);

        assertEq(tIn,  decoy1);
        assertEq(tOut, decoy2);
        assertEq(rec,  realRecip); // must be realRecip, not decoy1 or decoy2
        assertNotEq(rec, decoy1);
        assertNotEq(rec, decoy2);
    }
}
