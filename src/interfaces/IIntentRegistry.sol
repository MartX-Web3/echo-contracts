// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IIntentRegistry
/// @notice Interface for the Echo Intent Registry.
///         Maps function selectors to semantic parameter positions,
///         enabling EchoPolicyValidator to decode any registered
///         protocol calldata into (tokenIn, tokenOut, amountIn, recipient).
interface IIntentRegistry {

    // ── Structs ────────────────────────────────────────────────────────────

    /// @notice Describes how to extract semantic fields from a calldata payload.
    /// @dev    All offsets are byte positions measured from the start of calldata
    ///         (i.e. including the 4-byte selector prefix).
    ///         offset = 0 means the field is not present / not applicable.
    struct IntentSpec {
        bytes4  selector;
        string  name;               // human-readable, e.g. "Uniswap V3 exactInputSingle"
        uint16  tokenInOffset;      // byte offset of the tokenIn address field
        uint16  tokenOutOffset;     // byte offset of the tokenOut address field
        uint16  amountInOffset;     // byte offset of the amountIn uint256 field
        uint16  recipientOffset;    // byte offset of the recipient address field
        bool    exists;
    }

    // ── Events ─────────────────────────────────────────────────────────────

    // IntentRegistry is immutable — no events needed for MVP.
    // Fields are set at construction time and cannot be changed.

    // ── Functions ──────────────────────────────────────────────────────────

    /// @notice Decode calldata into semantic fields.
    /// @param  data  The full calldata including the 4-byte selector.
    /// @return tokenIn    Address of the input token.
    /// @return tokenOut   Address of the output token.
    /// @return amountIn   Amount of tokenIn being spent.
    /// @return recipient  Address that will receive the output tokens.
    /// @dev    Reverts with UnknownSelector if the selector is not registered.
    function decode(bytes calldata data) external pure returns (
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    );

    /// @notice Returns the IntentSpec for a given selector.
    /// @dev    Reverts with UnknownSelector if not registered.
    function getSpec(bytes4 selector) external pure returns (IntentSpec memory);

    /// @notice Returns true if the selector is registered.
    function isRegistered(bytes4 selector) external pure returns (bool);

    /// @notice Returns all registered selectors.
    function registeredSelectors() external pure returns (bytes4[] memory);
}
