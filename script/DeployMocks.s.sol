// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockQuoterV2.sol";
import "../src/mocks/MockSwapRouter.sol";

// Paste the three mock contracts inline or import them
// For simplicity this script assumes they're compiled separately

contract DeployMocks is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockERC20 tokens
        MockERC20 mockWeth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);

        // 2. Deploy MockQuoterV2
        MockQuoterV2 mockQuoter = new MockQuoterV2(address(mockWeth), address(mockUsdc));

        // 3. Deploy MockSwapRouter
        MockSwapRouter mockRouter = new MockSwapRouter(address(mockWeth), address(mockUsdc));

        // 4. Mint test tokens to deployer
        mockWeth.mint(deployer, 100 ether);       // 100 WETH (18 decimals)
        mockUsdc.mint(deployer, 100_000e6);    // 100,000 USDC (6 decimals)

        vm.stopBroadcast();

        console.log("=== Echo Protocol Mock Contracts (Sepolia) ===");
        console.log("MockWETH:        ", address(mockWeth));
        console.log("MockUSDC:        ", address(mockUsdc));
        console.log("MockQuoterV2:    ", address(mockQuoter));
        console.log("MockSwapRouter:  ", address(mockRouter));
        console.log("");
        console.log("=== .env values to update ===");
        console.log("MOCK_WETH=", address(mockWeth));
        console.log("MOCK_USDC=", address(mockUsdc));
        console.log("UNISWAP_V3_QUOTER=", address(mockQuoter));
        console.log("UNISWAP_V3_ROUTER=", address(mockRouter));
    }
}
