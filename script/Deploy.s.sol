// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/EchoAccount.sol";
import "../src/EchoAccountFactory.sol";

/// @notice Deploy all Echo Protocol contracts to Sepolia.
///
///         Deployment order:
///           PolicyRegistry         ← no deps
///           IntentRegistry         ← no deps
///           EchoPolicyValidator    ← needs registry + intentRegistry
///           EchoAccount (impl)     ← logic contract only, never initialized directly
///           EchoAccountFactory     ← needs registry + validator + implementation
///           registry.setValidator()
///           registry.setFactory()
///           registry.createTemplate() × 3
///
///         Required .env:
///           DEPLOYER_PRIVATE_KEY
///           SEPOLIA_RPC_URL
///           ETHERSCAN_API_KEY
///
///         Run:
///           forge script script/Deploy.s.sol \
///             --rpc-url $SEPOLIA_RPC_URL \
///             --broadcast \
///             --verify \
///             -vvvv
contract Deploy is Script {

    uint256 constant DAY = 86400;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. PolicyRegistry
        PolicyRegistry registry = new PolicyRegistry(deployer);
        console.log("PolicyRegistry:      ", address(registry));

        // 2. IntentRegistry
        IntentRegistry intentReg = new IntentRegistry();
        console.log("IntentRegistry:      ", address(intentReg));

        // 3. EchoPolicyValidator
        EchoPolicyValidator validator = new EchoPolicyValidator(
            address(registry),
            address(intentReg)
        );
        console.log("EchoPolicyValidator: ", address(validator));

        // 4. EchoAccount implementation (logic only — _disableInitializers in constructor)
        EchoAccount accountImpl = new EchoAccount();
        console.log("EchoAccount impl:    ", address(accountImpl));

        // 5. EchoAccountFactory
        EchoAccountFactory factory = new EchoAccountFactory(
            address(registry),
            address(validator),
            address(accountImpl)
        );
        console.log("EchoAccountFactory:  ", address(factory));

        // 6. Wire up
        registry.setValidator(address(validator));
        registry.setFactory(address(factory));
        console.log("setValidator + setFactory: done");

        // 7. Official templates
        bytes32 conservativeId = registry.createTemplate(
            "Conservative",
            50e6, 200e6, 20e6, 5e6, 400e6, 2000e6, uint64(90 * DAY)
        );
        bytes32 standardId = registry.createTemplate(
            "Standard",
            100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(90 * DAY)
        );
        bytes32 activeId = registry.createTemplate(
            "Active",
            500e6, 2000e6, 100e6, 25e6, 4000e6, 20000e6, uint64(90 * DAY)
        );

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("PolicyRegistry:      ", address(registry));
        console.log("IntentRegistry:      ", address(intentReg));
        console.log("EchoPolicyValidator: ", address(validator));
        console.log("EchoAccount impl:    ", address(accountImpl));
        console.log("EchoAccountFactory:  ", address(factory));
        console.log("");
        console.log("Templates:");
        console.log("  Conservative:"); console.logBytes32(conservativeId);
        console.log("  Standard:    "); console.logBytes32(standardId);
        console.log("  Active:      "); console.logBytes32(activeId);
    }
}
