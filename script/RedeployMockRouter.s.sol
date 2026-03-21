// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/MockSwapRouter.sol";

/// @notice Redeploy only MockSwapRouter (after adding deadline field to struct).
///         Reuses existing MockWETH and MockUSDC addresses.
contract RedeployMockRouter is Script {
    address constant MOCK_WETH = 0xF0527287E6B7570BdaaDe7629C47D60a3e0eF104;
    address constant MOCK_USDC = 0xBa9D46448e4142AC7a678678eFf6882D9197d716;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MockSwapRouter router = new MockSwapRouter(MOCK_WETH, MOCK_USDC);

        vm.stopBroadcast();

        console.log("New MockSwapRouter:", address(router));
        console.log("Update gateway .env: UNISWAP_V3_ROUTER=", address(router));
    }
}
