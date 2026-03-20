// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMockToken {
    function transferFrom(address, address, uint256) external returns (bool);
    function mint(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title MockSwapRouter
/// @notice Simulates Uniswap V3 SwapRouter02 for Echo Protocol testing.
///         On exactInputSingle:  pulls tokenIn from sender, mints tokenOut to recipient.
///         On exactOutputSingle: mints tokenOut to recipient, pulls tokenIn from sender.
///         Fixed rate: 1 WETH = 2000 USDC.
contract MockSwapRouter {

    uint256 public constant WETH_PRICE_USDC = 2000e6;

    address public weth;
    address public usdc;
    address public owner;

    event Swap(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _weth, address _usdc) {
        weth  = _weth;
        usdc  = _usdc;
        owner = msg.sender;
    }

    // ── exactInputSingle ──────────────────────────────────────────────────────

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps exact amountIn of tokenIn for as much tokenOut as possible.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        amountOut = _getAmountOut(params.tokenIn, params.tokenOut, params.amountIn);
        require(amountOut >= params.amountOutMinimum, "MockRouter: slippage");

        // Pull tokenIn from caller
        IMockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Mint tokenOut to recipient
        IMockToken(params.tokenOut).mint(params.recipient, amountOut);

        emit Swap(params.tokenIn, params.tokenOut, params.recipient, params.amountIn, amountOut);
    }

    // ── exactOutputSingle ─────────────────────────────────────────────────────

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little tokenIn as possible to receive exact amountOut of tokenOut.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn)
    {
        amountIn = _getAmountIn(params.tokenIn, params.tokenOut, params.amountOut);
        require(amountIn <= params.amountInMaximum, "MockRouter: amountInMaximum exceeded");

        // Pull tokenIn from caller
        IMockToken(params.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Mint tokenOut to recipient
        IMockToken(params.tokenOut).mint(params.recipient, params.amountOut);

        emit Swap(params.tokenIn, params.tokenOut, params.recipient, amountIn, params.amountOut);
    }

    // ── Pricing ───────────────────────────────────────────────────────────────

    function _getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        internal view returns (uint256)
    {
        if (tokenIn == weth && tokenOut == usdc) {
            return amountIn * WETH_PRICE_USDC / 1e18;
        } else if (tokenIn == usdc && tokenOut == weth) {
            return amountIn * 1e18 / WETH_PRICE_USDC;
        }
        return amountIn;
    }

    function _getAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
        internal view returns (uint256)
    {
        if (tokenIn == weth && tokenOut == usdc) {
            return amountOut * 1e18 / WETH_PRICE_USDC;
        } else if (tokenIn == usdc && tokenOut == weth) {
            return amountOut * WETH_PRICE_USDC / 1e18;
        }
        return amountOut;
    }

    function setTokens(address _weth, address _usdc) external {
        require(msg.sender == owner, "only owner");
        weth = _weth;
        usdc = _usdc;
    }
}
