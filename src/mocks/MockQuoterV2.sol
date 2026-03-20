// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockQuoterV2
/// @notice Returns deterministic quotes at a fixed rate for testing.
///         Rate: 1 WETH (1e18) = 2000 USDC (2000e6)
///         i.e. 1e18 tokenIn (WETH) -> 2000e6 tokenOut (USDC)
///              1e6  tokenIn (USDC) -> 5e14   tokenOut (WETH)  (1/2000)
contract MockQuoterV2 {

    /// @dev price of WETH in USDC, scaled 1e6
    uint256 public constant WETH_PRICE_USDC = 2000e6; // $2000 per ETH

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24  fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;      // desired output
        uint24  fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Quote for exactInput — how much tokenOut given amountIn
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32  initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        amountOut = _getAmountOut(params.tokenIn, params.tokenOut, params.amountIn);
        sqrtPriceX96After       = 0;
        initializedTicksCrossed = 1;
        gasEstimate             = 150_000;
    }

    /// @notice Quote for exactOutput — how much tokenIn needed to get amountOut
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        view
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32  initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        amountIn = _getAmountIn(params.tokenIn, params.tokenOut, params.amount);
        sqrtPriceX96After       = 0;
        initializedTicksCrossed = 1;
        gasEstimate             = 150_000;
    }

    // ── Internal pricing ─────────────────────────────────────────────────────

    /// @dev Returns amountOut given amountIn, using fixed WETH/USDC rate
    function _getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        internal view returns (uint256)
    {
        if (_isWeth(tokenIn) && _isUsdc(tokenOut)) {
            // WETH -> USDC: amountIn (1e18) * 2000e6 / 1e18
            return amountIn * WETH_PRICE_USDC / 1e18;
        } else if (_isUsdc(tokenIn) && _isWeth(tokenOut)) {
            // USDC -> WETH: amountIn (1e6) * 1e18 / 2000e6
            return amountIn * 1e18 / WETH_PRICE_USDC;
        }
        // Unknown pair — return 1:1
        return amountIn;
    }

    /// @dev Returns amountIn needed to get amountOut
    function _getAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
        internal view returns (uint256)
    {
        if (_isWeth(tokenIn) && _isUsdc(tokenOut)) {
            // Need X WETH to get amountOut USDC: X = amountOut * 1e18 / 2000e6
            return amountOut * 1e18 / WETH_PRICE_USDC;
        } else if (_isUsdc(tokenIn) && _isWeth(tokenOut)) {
            // Need X USDC to get amountOut WETH: X = amountOut * 2000e6 / 1e18
            return amountOut * WETH_PRICE_USDC / 1e18;
        }
        return amountOut;
    }

    // Simple address type checks (not hardcoded addresses — works with any deployment)
    // We distinguish by decimals-convention: WETH = 18 decimals hint via amount scale
    // For mock purposes we use a storage mapping set at deploy
    // Actually for simplicity: owner sets token addresses

    address public weth;
    address public usdc;
    address public owner;

    constructor(address _weth, address _usdc) {
        weth  = _weth;
        usdc  = _usdc;
        owner = msg.sender;
    }

    function setTokens(address _weth, address _usdc) external {
        require(msg.sender == owner, "only owner");
        weth = _weth;
        usdc = _usdc;
    }

    function _isWeth(address token) internal view returns (bool) {
        return token == weth;
    }

    function _isUsdc(address token) internal view returns (bool) {
        return token == usdc;
    }
}
