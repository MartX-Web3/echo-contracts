// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/modules/EchoDelegationModule.sol";
import "../src/EchoOnboarding.sol";

/// @notice Deploy Echo Protocol (EIP-7702 + ERC-4337 path) to Sepolia.
///
///         Deployment order:
///           PolicyRegistry
///           IntentRegistry
///           EchoPolicyValidator
///           EchoDelegationModule   ← users' EIP-7702 delegation target
///           EchoOnboarding         ← one-tx: register instance + bind EOA for 7702
///           registry.setValidator()
///           registry.setOnboarding(onboarding)
///           validator.setEip7702Onboarding(onboarding)
///           registry.createTemplate() × 3
///
///         No smart-account clone / factory: `UserOperation.sender` is the user EOA.
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

        PolicyRegistry registry = new PolicyRegistry(deployer);
        console.log("PolicyRegistry:      ", address(registry));

        IntentRegistry intentReg = new IntentRegistry();
        console.log("IntentRegistry:      ", address(intentReg));

        EchoPolicyValidator validator = new EchoPolicyValidator(
            address(registry),
            address(intentReg)
        );
        console.log("EchoPolicyValidator: ", address(validator));

        EchoDelegationModule delegation = new EchoDelegationModule(validator);
        console.log("EchoDelegationModule:", address(delegation));

        EchoOnboarding onboarding = new EchoOnboarding(registry, validator);
        console.log("EchoOnboarding:      ", address(onboarding));

        registry.setValidator(address(validator));
        registry.setOnboarding(address(onboarding));
        validator.setEip7702Onboarding(address(onboarding));
        console.log("setValidator + setOnboarding + setEip7702Onboarding: done");

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

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE (EIP-7702 path) ===");
        console.log("PolicyRegistry:      ", address(registry));
        console.log("IntentRegistry:      ", address(intentReg));
        console.log("EchoPolicyValidator: ", address(validator));
        console.log("EchoDelegationModule:", address(delegation));
        console.log("EchoOnboarding:      ", address(onboarding));
        console.log("");
        console.log("Configure gateway: DELEGATION_MODULE = delegation address above.");
        console.log("");
        console.log("Templates:");
        console.log("  Conservative:"); console.logBytes32(conservativeId);
        console.log("  Standard:    "); console.logBytes32(standardId);
        console.log("  Active:      "); console.logBytes32(activeId);
    }
}
