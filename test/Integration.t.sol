// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/interfaces/IPolicyRegistry.sol";

/// @dev Minimal ERC-20 interface for balance checks.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC-7579 account interface.
interface IAccount {
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;
    function installModule(uint256 typeId, address module, bytes calldata initData) external;
}

/// @notice Integration tests for Echo Protocol — run against Sepolia fork.
///
///         These tests require:
///           SEPOLIA_RPC_URL in .env
///           forge test --fork-url $SEPOLIA_RPC_URL --match-contract Integration
///
///         They verify the full end-to-end flow:
///           Policy register → Module install (mock SA) → Swap validate
///
/// @dev    Since we cannot use the real OZ AccountERC7579 in the unit test
///         environment (requires forge install), Integration tests use a
///         MockOZAccount that faithfully replicates the relevant behaviour:
///         - IOwnable.owner() returns a configurable owner
///         - execute() is callable by anyone (EntryPoint would normally check)
///         - installModule() delegates to validator.onInstall()
///
///         The Sepolia fork tests (marked FORK) require real OZ contracts.
contract IntegrationTest is Test {

    // ── Contracts ──────────────────────────────────────────────────────────
    PolicyRegistry      registry;
    IntentRegistry      intentReg;
    EchoPolicyValidator validator;

    // ── Actors ────────────────────────────────────────────────────────────
    address echoOwner  = makeAddr("echoOwner");
    address userWallet = makeAddr("userWallet");    // user's EOA
    address attacker   = makeAddr("attacker");

    // ── Tokens / protocols ─────────────────────────────────────────────────
    address USDC       = makeAddr("USDC");
    address WETH       = makeAddr("WETH");
    address UNI_ROUTER = makeAddr("UniswapRouter");

    bytes4 constant EIS = bytes4(0x414bf389); // exactInputSingle
    bytes4 constant EOS = bytes4(0x4aa4a4fa); // exactOutputSingle

    uint256 constant DAY = 86400;

    // ── Test state ─────────────────────────────────────────────────────────
    bytes32 templateId;
    bytes32 instanceId;
    bytes32 rawExecKey = keccak256("execKey");
    bytes32 execKeyHash;

    MockOZAccount account;

    // ── Setup ──────────────────────────────────────────────────────────────

    function setUp() public {
        registry  = new PolicyRegistry(echoOwner);
        intentReg = new IntentRegistry();
        validator = new EchoPolicyValidator(address(registry), address(intentReg));

        vm.prank(echoOwner);
        registry.setValidator(address(validator));

        vm.prank(echoOwner);
        templateId = registry.createTemplate(
            "Standard", 100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(90 * DAY)
        );

        execKeyHash = keccak256(abi.encode(rawExecKey));

        // Deploy a MockOZAccount owned by userWallet
        account = new MockOZAccount(userWallet, address(validator));

        // Register instance: owner = userWallet (EOA, manages policy)
        // account address is the smart account that will install the module
        address[] memory tokens  = _a2(WETH, USDC);
        uint256[] memory perOps  = _u2(100e6, 500e6);
        uint256[] memory perDays = _u2(500e6, 2000e6);
        address[] memory targets = _a1(UNI_ROUTER);
        bytes4[]  memory sels    = _s2(EIS, EOS);

        vm.prank(userWallet);
        instanceId = registry.registerInstanceStruct(
            IPolicyRegistry.InstanceRegistration({
                owner:             userWallet,
                templateId:         templateId,
                executeKeyHash:     execKeyHash,
                initialTokens:      tokens,
                maxPerOps:          perOps,
                maxPerDays:         perDays,
                targets:            targets,
                selectors:          sels,
                explorationBudget:  50e6,
                explorationPerTx:   10e6,
                globalMaxPerDay:    1000e6,
                globalTotalBudget:  5000e6,
                expiry:             uint64(block.timestamp + 90 * DAY)
            })
        );

        // Install validator on account
        // In real flow: account.installModule() → validator.onInstall()
        // onInstall checks: IOwnable(account).owner() == inst.owner
        //   → userWallet == userWallet ✓
        account.installEchoValidator(instanceId);

        vm.warp(block.timestamp + 2);
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    function _innerSwap(address tIn, address tOut, uint256 amt, address rec)
        internal view returns (bytes memory)
    {
        return abi.encodeWithSelector(
            EIS, tIn, tOut, uint24(3000), rec,
            block.timestamp + 100, amt, uint256(0), uint160(0)
        );
    }

    function _executeCD(address target, address tIn, address tOut, uint256 amt, address rec)
        internal view returns (bytes memory)
    {
        bytes memory inner = _innerSwap(tIn, tOut, amt, rec);
        bytes memory execData = abi.encodePacked(target, uint256(0), inner);
        return abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes32,bytes)")), bytes32(0), execData
        );
    }

    function _validCD(address tIn, address tOut, uint256 amt) internal view returns (bytes memory) {
        return _executeCD(UNI_ROUTER, tIn, tOut, amt, address(account));
    }

    function _op(bytes memory cd, bytes memory sig) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(0), nonce: 0, initCode: "",
            callData: cd, accountGasLimits: bytes32(0),
            preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: sig
        });
    }

    function _rtSig(bytes32 k) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), k);
    }

    // ── Core integration: onInstall ownership ──────────────────────────────

    function test_INT_install_ownershipCheck_passes() public view {
        // Account is installed and instance is registered
        assertEq(validator.getAccountInstance(address(account)), instanceId);
        assertTrue(validator.isInitialized(address(account)));
    }

    function test_INT_install_wrongOwner_reverts() public {
        // Attacker deploys their own account (owner = attacker, not userWallet)
        MockOZAccount attackerAccount = new MockOZAccount(attacker, address(validator));

        // Attacker tries to install with victim's instanceId
        // IOwnable(attackerAccount).owner() = attacker ≠ inst.owner (userWallet)
        vm.expectRevert("onInstall: account owner mismatch");
        attackerAccount.installEchoValidator(instanceId);
    }

    function test_INT_install_correctAccount_anotherInstance_passes() public {
        // User registers a second instance and installs on a second account
        vm.prank(userWallet);
        bytes32 instanceId2 = registry.registerInstanceStruct(
            IPolicyRegistry.InstanceRegistration({
                owner:             userWallet,
                templateId:         templateId,
                executeKeyHash:     keccak256("key2"),
                initialTokens:      new address[](0),
                maxPerOps:          new uint256[](0),
                maxPerDays:         new uint256[](0),
                targets:            new address[](0),
                selectors:          new bytes4[](0),
                explorationBudget:  0,
                explorationPerTx:   0,
                globalMaxPerDay:    1000e6,
                globalTotalBudget:  5000e6,
                expiry:             uint64(block.timestamp + DAY)
            })
        );

        MockOZAccount account2 = new MockOZAccount(userWallet, address(validator));
        account2.installEchoValidator(instanceId2);

        assertEq(validator.getAccountInstance(address(account2)), instanceId2);
    }

    // ── Core integration: full validation flow ─────────────────────────────

    function test_INT_validate_realtimeSwap_passes() public {
        bytes memory cd  = _validCD(USDC, WETH, 50e6);
        bytes memory sig = _rtSig(rawExecKey);
        uint256 result   = account.validate(_op(cd, sig));
        assertEq(result, 0, "real-time swap should pass");
    }

    function test_INT_validate_wrongKey_fails() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        uint256 result  = account.validate(_op(cd, _rtSig(keccak256("wrong"))));
        assertEq(result, 1, "wrong key should fail");
    }

    function test_INT_validate_attackerRecipient_fails() public {
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, attacker);
        uint256 result  = account.validate(_op(cd, _rtSig(rawExecKey)));
        assertEq(result, 1, "attacker recipient should fail");
    }

    function test_INT_validate_badTarget_fails() public {
        bytes memory cd = _executeCD(makeAddr("evil"), USDC, WETH, 50e6, address(account));
        uint256 result  = account.validate(_op(cd, _rtSig(rawExecKey)));
        assertEq(result, 1, "bad target should fail");
    }

    // ── Core integration: spend tracking ──────────────────────────────────

    function test_INT_spendTracking_updates_onPass() public {
        bytes memory cd = _validCD(USDC, WETH, 100e6);
        assertEq(account.validate(_op(cd, _rtSig(rawExecKey))), 0);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.globalTotalSpent, 100e6);
        assertEq(inst.globalDailySpent, 100e6);

        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.dailySpent, 100e6);
        assertEq(tl.totalSpent, 100e6);
    }

    function test_INT_spendTracking_unchanged_onFail() public {
        // Over-budget — fails
        bytes memory cd = _validCD(USDC, WETH, 101e6); // limit 100
        assertEq(account.validate(_op(cd, _rtSig(rawExecKey))), 1);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.globalTotalSpent, 0, "spend must not update on fail");
    }

    // ── Core integration: session flow ────────────────────────────────────

    function test_INT_session_fullFlow() public {
        bytes32 rawSessKey = keccak256("sessKey");

        // User creates session from their EOA
        vm.prank(userWallet);
        bytes32 sessionId = registry.createSession(
            instanceId,
            keccak256(abi.encode(rawSessKey)),
            USDC, WETH,
            50e6, 350e6, 2,
            uint64(block.timestamp + 7 * DAY)
        );

        assertTrue(registry.isActiveSession(sessionId));

        // Agent executes session op
        bytes memory cd  = _validCD(USDC, WETH, 50e6);
        bytes memory sig = abi.encodePacked(uint8(0x02), sessionId, rawSessKey);
        assertEq(account.validate(_op(cd, sig)), 0, "session op should pass");

        IPolicyRegistry.SessionPolicy memory sess = registry.getSession(sessionId);
        assertEq(sess.totalSpent, 50e6);
        assertEq(sess.dailyOps,   1);

        // Revoke from EOA
        vm.prank(userWallet);
        registry.revokeSession(sessionId);

        assertFalse(registry.isActiveSession(sessionId));

        // Next op fails
        vm.warp(block.timestamp + 1);
        assertEq(account.validate(_op(cd, sig)), 1, "revoked session should fail");
    }

    // ── Core integration: policy management from EOA ───────────────────────

    function test_INT_policyManagement_fromEOA() public {
        // User manages policy from their EOA wallet (not from smart account)
        vm.startPrank(userWallet);

        // Add new token limit
        registry.setTokenLimit(instanceId, makeAddr("TRUMP"), 20e6, 60e6);

        // Pause
        registry.pauseInstance(instanceId);
        assertTrue(registry.getInstance(instanceId).paused);

        // Unpause
        registry.unpauseInstance(instanceId);
        assertFalse(registry.getInstance(instanceId).paused);

        // Revoke execute key
        registry.revokeExecuteKey(instanceId, execKeyHash);
        assertFalse(registry.isValidExecuteKey(instanceId, execKeyHash));

        vm.stopPrank();
    }

    function test_INT_policyManagement_attackerBlocked() public {
        vm.prank(attacker);
        vm.expectRevert("Not instance owner");
        registry.pauseInstance(instanceId);
    }

    // ── Core integration: emergency pause ─────────────────────────────────

    function test_INT_emergencyPause() public {
        // Pause from EOA
        vm.prank(userWallet);
        registry.pauseInstance(instanceId);

        // All ops rejected
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        assertEq(account.validate(_op(cd, _rtSig(rawExecKey))), 1, "paused");

        // Unpause
        vm.prank(userWallet);
        registry.unpauseInstance(instanceId);

        vm.warp(block.timestamp + 1);
        assertEq(account.validate(_op(cd, _rtSig(rawExecKey))), 0, "unpaused");
    }

    // ── S1–S4 invariants under integration conditions ─────────────────────

    function test_INT_S1_noBypassViaSession() public {
        // Session only allows USDC→WETH. Attempting USDC→WBTC fails.
        bytes32 rawSessKey = keccak256("sk");
        vm.prank(userWallet);
        bytes32 sid = registry.createSession(
            instanceId, keccak256(abi.encode(rawSessKey)),
            USDC, WETH, 50e6, 350e6, 5,
            uint64(block.timestamp + 7 * DAY)
        );

        bytes memory cd  = _executeCD(UNI_ROUTER, USDC, makeAddr("WBTC"), 50e6, address(account));
        bytes memory sig = abi.encodePacked(uint8(0x02), sid, rawSessKey);
        assertEq(account.validate(_op(cd, sig)), 1, "S1: wrong tokenOut blocked");
    }

    function test_INT_S2_recipientAlwaysAccount() public {
        // Even with valid key, recipient must be the account
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, userWallet);
        assertEq(account.validate(_op(cd, _rtSig(rawExecKey))), 1, "S2: EOA recipient blocked");
    }

    function test_INT_S3_totalSpentNeverDecreases() public {
        bytes memory cd = _validCD(USDC, WETH, 100e6);

        for (uint i = 0; i < 3; i++) {
            uint256 before = registry.getInstance(instanceId).globalTotalSpent;
            if (account.validate(_op(cd, _rtSig(rawExecKey))) == 0) {
                uint256 after_ = registry.getInstance(instanceId).globalTotalSpent;
                assertGe(after_, before, "S3: totalSpent must not decrease");
            }
            vm.warp(block.timestamp + 1);
        }
    }

    function test_INT_S4_agentCannotEscalate() public {
        // Simulate agent trying to call policy management functions
        // Agent has execKey but does not have the userWallet private key
        address agent = makeAddr("agentProcess");

        vm.prank(agent);
        vm.expectRevert("Not instance owner");
        registry.setTokenLimit(instanceId, WETH, 999999e6, 999999e6);

        vm.prank(agent);
        vm.expectRevert("Not instance owner");
        registry.addAllowedTarget(instanceId, makeAddr("evil"), new bytes4[](0));
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    function _a1(address a) internal pure returns (address[] memory r) { r=new address[](1); r[0]=a; }
    function _a2(address a, address b) internal pure returns (address[] memory r) { r=new address[](2); r[0]=a; r[1]=b; }
    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) { r=new uint256[](2); r[0]=a; r[1]=b; }
    function _s2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory r) { r=new bytes4[](2); r[0]=a; r[1]=b; }
}

// ── MockOZAccount ──────────────────────────────────────────────────────────

/// @notice Faithful mock of OZ AccountERC7579 for integration testing.
///         Implements:
///           - IOwnable.owner() — returns configurable owner
///           - installEchoValidator() — calls validator.onInstall as this account
///           - validate() — calls validator.validateUserOp as this account
///
///         The real OZ AccountERC7579:
///           - owner() from OZ Ownable
///           - installModule() calls module.onInstall, enforced by onlySelf
///           - validateUserOp() delegates to installed validator
contract MockOZAccount {
    address private _owner;
    EchoPolicyValidator private _validator;

    constructor(address owner_, address validator_) {
        _owner     = owner_;
        _validator = EchoPolicyValidator(validator_);
    }

    /// @dev IOwnable.owner() — checked by validator.onInstall
    function owner() external view returns (address) {
        return _owner;
    }

    /// @dev Simulate account.installModule(1, validator, abi.encode(instanceId))
    ///      In OZ: onlySelf ensures this is called by the account itself.
    ///      Here: callable externally for test setup.
    function installEchoValidator(bytes32 instanceId) external {
        _validator.onInstall(abi.encode(instanceId));
    }

    /// @dev Forward validateUserOp to the installed validator.
    ///      msg.sender to validator = address(this) = the account.
    function validate(PackedUserOperation calldata op) external returns (uint256) {
        return _validator.validateUserOp(op, bytes32(0));
    }
}
