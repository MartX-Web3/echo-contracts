// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IIntentRegistry.sol";

/// @title  IntentRegistry
/// @notice Immutable calldata decoder for Echo Protocol MVP.
///         Registered at deploy time with exactly two Uniswap V3 selectors.
///         No owner, no setter, no upgradeability — the spec is the contract.
///
/// @dev    Uniswap V3 ISwapRouter.ExactInputSingleParams layout:
///         struct ExactInputSingleParams {
///             address tokenIn;        // offset 4   (32 bytes, address in last 20)
///             address tokenOut;       // offset 36
///             uint24  fee;            // offset 68
///             address recipient;      // offset 100
///             uint256 deadline;       // offset 132 (not needed)
///             uint256 amountIn;       // offset 164
///             uint256 amountOutMinimum; // offset 196 (not needed)
///             uint160 sqrtPriceLimitX96; // offset 228 (not needed)
///         }
///
///         Uniswap V3 ISwapRouter.ExactOutputSingleParams layout:
///         struct ExactOutputSingleParams {
///             address tokenIn;        // offset 4
///             address tokenOut;       // offset 36
///             uint24  fee;            // offset 68
///             address recipient;      // offset 100
///             uint256 deadline;       // offset 132 (not needed)
///             uint256 amountOut;      // offset 164 (not needed)
///             uint256 amountInMaximum; // offset 196  ← amountIn for policy check
///             uint160 sqrtPriceLimitX96; // offset 228 (not needed)
///         }
///
///         Note: ABI encoding pads every type to 32 bytes. Addresses occupy
///         the last 20 bytes of a 32-byte slot (zero-padded on the left).
///         We use abi.decode with fixed offsets by slicing the calldata.

contract IntentRegistry is IIntentRegistry {

    // ── Selectors ──────────────────────────────────────────────────────────

    bytes4 public constant EXACT_INPUT_SINGLE  = bytes4(0x414bf389);
    bytes4 public constant EXACT_OUTPUT_SINGLE = bytes4(0x4aa4a4fa);

    // ── Offsets (byte positions from start of calldata, after 4-byte selector) ──
    // All struct fields are ABI-encoded as 32-byte slots.

    // ExactInputSingle:  tokenIn@4, tokenOut@36, recipient@100, amountIn@164
    uint16 private constant EIS_TOKEN_IN   = 4;
    uint16 private constant EIS_TOKEN_OUT  = 36;
    uint16 private constant EIS_RECIPIENT  = 100;
    uint16 private constant EIS_AMOUNT_IN  = 164;

    // ExactOutputSingle: tokenIn@4, tokenOut@36, recipient@100, amountInMaximum@196
    uint16 private constant EOS_TOKEN_IN   = 4;
    uint16 private constant EOS_TOKEN_OUT  = 36;
    uint16 private constant EOS_RECIPIENT  = 100;
    uint16 private constant EOS_AMOUNT_IN  = 196;  // amountInMaximum used as policy cap

    // Minimum calldata lengths (4 selector + params)
    // ExactInputSingle:  4 + 8 * 32 = 260 bytes
    // ExactOutputSingle: 4 + 8 * 32 = 260 bytes
    uint256 private constant MIN_CALLDATA_LEN = 260;

    // ── Custom errors ──────────────────────────────────────────────────────

    error UnknownSelector(bytes4 selector);
    error CalldataTooShort(uint256 length, uint256 minimum);

    // ── IIntentRegistry ───────────────────────────────────────────────────

    /// @inheritdoc IIntentRegistry
    function decode(bytes calldata data) external pure returns (
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) {
        if (data.length < MIN_CALLDATA_LEN) {
            revert CalldataTooShort(data.length, MIN_CALLDATA_LEN);
        }

        bytes4 sel = bytes4(data[:4]);

        if (sel == EXACT_INPUT_SINGLE) {
            tokenIn   = _decodeAddress(data, EIS_TOKEN_IN);
            tokenOut  = _decodeAddress(data, EIS_TOKEN_OUT);
            recipient = _decodeAddress(data, EIS_RECIPIENT);
            amountIn  = _decodeUint256(data, EIS_AMOUNT_IN);
            return (tokenIn, tokenOut, amountIn, recipient);
        }

        if (sel == EXACT_OUTPUT_SINGLE) {
            tokenIn   = _decodeAddress(data, EOS_TOKEN_IN);
            tokenOut  = _decodeAddress(data, EOS_TOKEN_OUT);
            recipient = _decodeAddress(data, EOS_RECIPIENT);
            amountIn  = _decodeUint256(data, EOS_AMOUNT_IN);
            return (tokenIn, tokenOut, amountIn, recipient);
        }

        revert UnknownSelector(sel);
    }

    /// @inheritdoc IIntentRegistry
    function getSpec(bytes4 selector) external pure returns (IntentSpec memory spec) {
        if (selector == EXACT_INPUT_SINGLE) {
            return IntentSpec({
                selector:        EXACT_INPUT_SINGLE,
                name:            "Uniswap V3 exactInputSingle",
                tokenInOffset:   EIS_TOKEN_IN,
                tokenOutOffset:  EIS_TOKEN_OUT,
                amountInOffset:  EIS_AMOUNT_IN,
                recipientOffset: EIS_RECIPIENT,
                exists:          true
            });
        }
        if (selector == EXACT_OUTPUT_SINGLE) {
            return IntentSpec({
                selector:        EXACT_OUTPUT_SINGLE,
                name:            "Uniswap V3 exactOutputSingle",
                tokenInOffset:   EOS_TOKEN_IN,
                tokenOutOffset:  EOS_TOKEN_OUT,
                amountInOffset:  EOS_AMOUNT_IN,
                recipientOffset: EOS_RECIPIENT,
                exists:          true
            });
        }
        revert UnknownSelector(selector);
    }

    /// @inheritdoc IIntentRegistry
    function isRegistered(bytes4 selector) external pure returns (bool) {
        return selector == EXACT_INPUT_SINGLE || selector == EXACT_OUTPUT_SINGLE;
    }

    /// @inheritdoc IIntentRegistry
    function registeredSelectors() external pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = EXACT_INPUT_SINGLE;
        selectors[1] = EXACT_OUTPUT_SINGLE;
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Decode a 20-byte address from a 32-byte ABI-encoded slot at `offset`.
    ///      ABI encoding pads addresses to 32 bytes (12 zero bytes on the left).
    ///      We take bytes [offset+12 .. offset+32].
    function _decodeAddress(bytes calldata data, uint16 offset) private pure returns (address) {
        // Bounds already checked by MIN_CALLDATA_LEN — safe to slice
        return address(bytes20(data[offset + 12 : offset + 32]));
    }

    /// @dev Decode a uint256 from a 32-byte ABI-encoded slot at `offset`.
    function _decodeUint256(bytes calldata data, uint16 offset) private pure returns (uint256) {
        return uint256(bytes32(data[offset : offset + 32]));
    }
}
