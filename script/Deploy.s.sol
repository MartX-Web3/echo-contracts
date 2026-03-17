// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/EchoAccountFactory.sol";

/// @notice Deploy all Echo Protocol contracts to Sepolia in the correct order.
///
///         Deployment order (dependency graph):
///           PolicyRegistry    ← no deps
///           IntentRegistry    ← no deps (parallel)
///               ↓
///           EchoPolicyValidator ← needs registry + intentRegistry
///               ↓
///           EchoAccountFactory  ← needs registry + validator + OZ addresses
///               ↓
///           registry.setValidator(validator)  ← wire up
///           registry.setFactory(factory)      ← wire up
///           registry.createTemplate(...)×3    ← seed official templates
///
///         Required environment variables (.env):
///           DEPLOYER_PRIVATE_KEY     — Echo team deployer wallet
///           SEPOLIA_RPC_URL          — Alchemy/Infura Sepolia endpoint
///           ETHERSCAN_API_KEY        — for verification
///           ENTRY_POINT_V07          — 0x0000000071727De22E5E9d8BAf0edAc6f37da032
///           OZ_ACCOUNT_IMPL          — pre-deployed OZ AccountERC7579 implementation
///           OZ_BOOTSTRAP             — pre-deployed OZ ERC7579Bootstrap
///
///         Run:
///           forge script script/Deploy.s.sol \
///             --rpc-url $SEPOLIA_RPC_URL \
///             --broadcast \
///             --verify \
///             -vvvv
contract Deploy is Script {

    // ── Sepolia constants ──────────────────────────────────────────────────

    // ERC-4337 EntryPoint v0.7 (canonical, same on all chains)
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Token addresses on Sepolia (for template defaults — informational only)
    // Actual limits are set per-instance by users, not in templates.

    // ── State ──────────────────────────────────────────────────────────────

    PolicyRegistry      registry;
    IntentRegistry      intentReg;
    EchoPolicyValidator validator;
    EchoAccountFactory  factory;

    // ── run ────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address ozAccountImpl = vm.envAddress("OZ_ACCOUNT_IMPL");
        address ozBootstrap   = vm.envAddress("OZ_BOOTSTRAP");

        console.log("Deployer:         ", deployer);
        console.log("OZ Account Impl:  ", ozAccountImpl);
        console.log("OZ Bootstrap:     ", ozBootstrap);
        console.log("EntryPoint:       ", ENTRY_POINT);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. PolicyRegistry ──────────────────────────────────────────────
        registry = new PolicyRegistry(deployer);
        console.log("PolicyRegistry:        ", address(registry));

        // ── 2. IntentRegistry ──────────────────────────────────────────────
        intentReg = new IntentRegistry();
        console.log("IntentRegistry:        ", address(intentReg));

        // ── 3. EchoPolicyValidator ─────────────────────────────────────────
        validator = new EchoPolicyValidator(address(registry), address(intentReg));
        console.log("EchoPolicyValidator:   ", address(validator));

        // ── 4. EchoAccountFactory ──────────────────────────────────────────
        factory = new EchoAccountFactory(
            address(registry),
            address(validator),
            ozAccountImpl,
            ozBootstrap,
            ENTRY_POINT
        );
        console.log("EchoAccountFactory:    ", address(factory));

        // ── 5. Wire up ─────────────────────────────────────────────────────
        registry.setValidator(address(validator));
        console.log("setValidator: done");

        registry.setFactory(address(factory));
        console.log("setFactory: done");

        // ── 6. Create official templates ───────────────────────────────────
        uint256 DAY = 86400;

        bytes32 conservativeId = registry.createTemplate(
            "Conservative",
            50e6,            // maxPerOp:          50 USDC
            200e6,           // maxPerDay:         200 USDC
            20e6,            // explorationBudget:  20 USDC
            5e6,             // explorationPerTx:    5 USDC
            400e6,           // globalMaxPerDay:   400 USDC
            2000e6,          // globalTotalBudget: 2,000 USDC
            uint64(90 * DAY) // expiry:            90 days
        );
        console.log("Template Conservative: ");
        console.logBytes32(conservativeId);

        bytes32 standardId = registry.createTemplate(
            "Standard",
            100e6,            // maxPerOp:          100 USDC
            500e6,            // maxPerDay:         500 USDC
            50e6,             // explorationBudget:  50 USDC
            10e6,             // explorationPerTx:   10 USDC
            1000e6,           // globalMaxPerDay:  1,000 USDC
            5000e6,           // globalTotalBudget: 5,000 USDC
            uint64(90 * DAY)
        );
        console.log("Template Standard:     ");
        console.logBytes32(standardId);

        bytes32 activeId = registry.createTemplate(
            "Active",
            500e6,             // maxPerOp:           500 USDC
            2000e6,            // maxPerDay:         2,000 USDC
            100e6,             // explorationBudget:   100 USDC
            25e6,              // explorationPerTx:     25 USDC
            4000e6,            // globalMaxPerDay:   4,000 USDC
            20000e6,           // globalTotalBudget: 20,000 USDC
            uint64(90 * DAY)
        );
        console.log("Template Active:       ");
        console.logBytes32(activeId);

        vm.stopBroadcast();

        // ── 7. Print summary ───────────────────────────────────────────────
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("PolicyRegistry:       ", address(registry));
        console.log("IntentRegistry:       ", address(intentReg));
        console.log("EchoPolicyValidator:  ", address(validator));
        console.log("EchoAccountFactory:   ", address(factory));
        console.log("");
        console.log("Templates:");
        console.log("  Conservative: "); console.logBytes32(conservativeId);
        console.log("  Standard:     "); console.logBytes32(standardId);
        console.log("  Active:       "); console.logBytes32(activeId);
        console.log("");
        console.log("Copy these into src/contracts/addresses.ts in echo-gateway");
        console.log("Copy template IDs into echo-sdk/src/addresses.ts");
    }
}
