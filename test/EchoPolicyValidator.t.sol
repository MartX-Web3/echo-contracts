// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/interfaces/IPolicyRegistry.sol";

/// @notice Minimal mock smart account.
///         Simulates AccountERC7579: receives onInstall/onUninstall from the module
///         and forwards validateUserOp calls as msg.sender = this account.
contract MockAccount {
    EchoPolicyValidator public validator;
    constructor(EchoPolicyValidator _v) { validator = _v; }
    function owner() external view returns (address) { return address(this); }
    function installValidator(bytes memory data) external { validator.onInstall(data); }
    function uninstallValidator() external { validator.onUninstall(""); }
    function validate(PackedUserOperation calldata op) external returns (uint256) {
        return validator.validateUserOp(op, bytes32(0));
    }
}

contract EchoPolicyValidatorTest is Test {

    PolicyRegistry      public registry;
    IntentRegistry      public intentReg;
    EchoPolicyValidator public validator;
    MockAccount         public account;

    address public echoOwner  = makeAddr("echoOwner");
    address public USDC       = makeAddr("USDC");
    address public WETH       = makeAddr("WETH");
    address public WBTC       = makeAddr("WBTC");
    address public TRUMP      = makeAddr("TRUMP");
    address public UNI_ROUTER = makeAddr("UniswapRouter");

    bytes4 constant EIS = bytes4(0x414bf389); // exactInputSingle
    bytes4 constant EOS = bytes4(0x4aa4a4fa); // exactOutputSingle

    uint256 constant DAY = 86400;

    bytes32 public templateId;
    bytes32 public instanceId;
    bytes32 public rawExecKey = keccak256("execKey");
    bytes32 public execKeyHash;

    // ── Setup ──────────────────────────────────────────────────────────────

    function setUp() public {
        registry  = new PolicyRegistry(echoOwner);
        intentReg = new IntentRegistry();
        validator = new EchoPolicyValidator(address(registry), address(intentReg));
        account   = new MockAccount(validator);

        vm.prank(echoOwner);
        registry.setValidator(address(validator));

        vm.prank(echoOwner);
        templateId = registry.createTemplate(
            "Standard", 100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(90 * DAY)
        );

        execKeyHash = keccak256(abi.encode(rawExecKey));

        address[] memory tokens  = _a2(WETH, WBTC);
        uint256[] memory perOps  = _u2(100e6, 100e6);
        uint256[] memory perDays = _u2(500e6, 300e6);
        address[] memory targets = _a1(UNI_ROUTER);
        bytes4[]  memory sels    = _s2(EIS, EOS);

        vm.prank(address(account));
        instanceId = registry.registerInstanceStruct(
            IPolicyRegistry.InstanceRegistration({
                owner:             address(account),
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

        vm.prank(address(account));
        account.installValidator(abi.encode(instanceId));

        vm.warp(block.timestamp + 2);
    }

    // ── Calldata builders ──────────────────────────────────────────────────

    /// @dev Build raw exactInputSingle calldata (inner swap calldata).
    function _innerSwap(
        address tIn, address tOut, uint256 amt, address rec
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            EIS, tIn, tOut, uint24(3000), rec,
            block.timestamp + 100, amt, uint256(0), uint160(0)
        );
    }

    /// @dev Build the full AccountERC7579.execute() calldata that wraps the swap.
    ///      This is what userOp.callData actually contains in production.
    ///
    ///      execute(bytes32 mode, bytes calldata executionCalldata)
    ///      executionCalldata = abi.encodePacked(target, value, innerSwapCalldata)
    ///
    ///      ABI layout of the full outer callData:
    ///        [0:4]     selector of execute()
    ///        [4:36]    mode (bytes32(0) = CALLTYPE_SINGLE)
    ///        [36:68]   offset pointer to executionCalldata (= 0x40 = 64 in ABI)
    ///        [68:100]  length of executionCalldata bytes
    ///        [100:120] target address (20 bytes packed)
    ///        [120:152] value (uint256 = 0)
    ///        [152:...]  innerSwapCalldata
    function _executeCD(
        address target,
        address tIn, address tOut, uint256 amt, address rec
    ) internal view returns (bytes memory) {
        bytes memory innerSwap = _innerSwap(tIn, tOut, amt, rec);

        // executionCalldata = target (20b) + value (32b) + innerSwap
        bytes memory execData = abi.encodePacked(
            target,
            uint256(0),   // value = 0
            innerSwap
        );

        // Full outer callData: execute(bytes32, bytes)
        return abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes32,bytes)")),
            bytes32(0),   // mode = CALLTYPE_SINGLE
            execData
        );
    }

    /// @dev Convenience: build execute() callData for a valid swap to account.
    function _validCD(address tIn, address tOut, uint256 amt)
        internal view returns (bytes memory)
    {
        return _executeCD(UNI_ROUTER, tIn, tOut, amt, address(account));
    }

    function _op(bytes memory cd, bytes memory sig)
        internal pure returns (PackedUserOperation memory)
    {
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
    function _sessSig(bytes32 sid, bytes32 k) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), sid, k);
    }
    function _pass(uint256 r, string memory lbl) internal pure { assertEq(r, 0, lbl); }
    function _fail(uint256 r, string memory lbl) internal pure { assertEq(r, 1, lbl); }

    // ── Module lifecycle ───────────────────────────────────────────────────

    function test_install_setsInstance() public view {
        assertEq(validator.getAccountInstance(address(account)), instanceId);
        assertTrue(validator.isInitialized(address(account)));
    }

    function test_uninstall_clears() public {
        vm.prank(address(account));
        account.uninstallValidator();
        assertFalse(validator.isInitialized(address(account)));
    }

    function test_isModuleType_validator() public view {
        assertTrue(validator.isModuleType(1));
        assertFalse(validator.isModuleType(2));
    }

    // ── Signature format ───────────────────────────────────────────────────

    function test_noInstance_fails() public {
        MockAccount bare = new MockAccount(validator);
        _fail(bare.validate(_op("", _rtSig(rawExecKey))), "no instance");
    }

    function test_sigTooShort_fails() public {
        _fail(account.validate(_op("", hex"01")), "sig too short");
    }

    function test_unknownMode_fails() public {
        bytes memory sig = abi.encodePacked(uint8(0x99), rawExecKey);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), sig)), "unknown mode");
    }

    function test_eip7702_mode_rejected_on_module_validateUserOp() public {
        bytes memory sig = abi.encodePacked(uint8(0x03), rawExecKey);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), sig)), "eip7702 on SA");
    }

    // ── Real-time: happy path ──────────────────────────────────────────────

    function test_RT_valid_pass() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        _pass(account.validate(_op(cd, _rtSig(rawExecKey))), "valid RT");
    }

    // ── Real-time: 12 checks individually ─────────────────────────────────

    // Check 1a: wrong key
    function test_RT_check1_badKey() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        _fail(account.validate(_op(cd, _rtSig(keccak256("bad")))), "RT1 bad key");
    }

    // Check 1b: revoked key
    function test_RT_check1_revokedKey() public {
        vm.prank(address(account));
        registry.revokeExecuteKey(instanceId, execKeyHash);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _rtSig(rawExecKey))), "RT1 revoked");
    }

    // Check 2: paused
    function test_RT_check2_paused() public {
        vm.prank(address(account));
        registry.pauseInstance(instanceId);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _rtSig(rawExecKey))), "RT2 paused");
    }

    // Check 3: expired
    function test_RT_check3_expired() public {
        vm.warp(block.timestamp + 91 * DAY);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _rtSig(rawExecKey))), "RT3 expired");
    }

    // Check 4a: anti-replay same second
    function test_RT_check4_sameSecond_fails() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        _pass(account.validate(op), "first");
        _fail(account.validate(op), "RT4 same second");
    }

    // Check 4b: next second passes
    function test_RT_check4_nextSecond_passes() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        _pass(account.validate(op), "first");
        vm.warp(block.timestamp + 1);
        _pass(account.validate(op), "next second");
    }

    // Check 5 (outer calldata too short to extract target)
    function test_RT_check5_shortCalldata_fails() public {
        bytes memory cd = hex"deadbeef";  // too short, no valid target
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "RT5 short calldata");
    }

    // Check 6: target not in allowedTargets
    function test_RT_check6_targetNotAllowed_fails() public {
        address badTarget = makeAddr("badTarget");
        bytes memory cd = _executeCD(badTarget, USDC, WETH, 50e6, address(account));
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "RT6 bad target");
    }

    // Check 6: allowedTarget passes
    function test_RT_check6_allowedTarget_passes() public {
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, address(account));
        _pass(account.validate(_op(cd, _rtSig(rawExecKey))), "RT6 allowed target");
    }

    // Check 7: unknown selector
    function test_RT_check7_unknownSelector_fails() public {
        // Build execute() wrapping a call with an unknown selector
        bytes memory innerBad = abi.encodeWithSelector(bytes4(0xdeadbeef), USDC, WETH);
        bytes memory execData = abi.encodePacked(UNI_ROUTER, uint256(0), innerBad);
        bytes memory cd = abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes32,bytes)")), bytes32(0), execData
        );
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "RT7 bad selector");
    }

    // Check 8: wrong recipient (S2)
    function test_RT_check8_wrongRecipient_fails() public {
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, makeAddr("attacker"));
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "RT8 bad recipient");
    }

    // Check 9: exceeds per-op limit
    function test_RT_check9_exceedsPerOp_fails() public {
        bytes memory cd = _validCD(USDC, WETH, 101e6); // limit is 100
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "RT9 per-op");
    }

    // Check 10: exceeds token daily limit
    function test_RT_check10_exceedsTokenDaily_fails() public {
        bytes memory cd = _validCD(USDC, WETH, 100e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        uint256 t = block.timestamp;
        for (uint i = 0; i < 5; i++) {
            _pass(account.validate(op), "op");
            t += 1;
            vm.warp(t);
        }
        _fail(account.validate(op), "RT10 token daily");
    }

    // Check 11: exceeds global daily limit
    function test_RT_check11_exceedsGlobalDaily_fails() public {
        // WETH daily 500, WBTC daily 300, global daily 1000
        // Raise WBTC daily cap so global cap becomes the binding constraint.
        vm.prank(address(account));
        registry.setTokenLimit(instanceId, WBTC, 100e6, 1000e6);

        // Max out WETH (5 ops × 100)
        bytes memory cdW = _validCD(USDC, WETH, 100e6);
        PackedUserOperation memory opW = _op(cdW, _rtSig(rawExecKey));
        uint256 t = block.timestamp;
        for (uint i = 0; i < 5; i++) {
            _pass(account.validate(opW), "weth");
            t += 1;
            vm.warp(t);
        }
        // Spend WBTC (5 ops × 100 = 500, global now 1000)
        bytes memory cdB = _validCD(USDC, WBTC, 100e6);
        PackedUserOperation memory opB = _op(cdB, _rtSig(rawExecKey));
        for (uint i = 0; i < 5; i++) {
            _pass(account.validate(opB), "wbtc");
            t += 1;
            vm.warp(t);
        }
        _fail(account.validate(opB), "RT11 global daily");
    }

    // Check 12: global budget exhausted
    function test_RT_check12_globalBudgetExhausted_fails() public {
        bytes memory cd = _validCD(USDC, WETH, 100e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        uint256 spent = 0;
        uint256 t = block.timestamp;
        for (uint day = 0; day < 60 && spent < 5000e6; day++) {
            for (uint i = 0; i < 5 && spent < 5000e6; i++) {
                if (account.validate(op) == 0) spent += 100e6;
                t += 1;
                vm.warp(t);
            }
            t += DAY;
            vm.warp(t);
        }
        _fail(account.validate(op), "RT12 global budget");
    }

    // Exploration: unknown token passes
    function test_RT_exploration_pass() public {
        bytes memory cd = _validCD(USDC, TRUMP, 10e6);
        _pass(account.validate(_op(cd, _rtSig(rawExecKey))), "exploration pass");
    }

    // Exploration: exceeds per-tx
    function test_RT_exploration_exceedsPerTx_fails() public {
        bytes memory cd = _validCD(USDC, TRUMP, 11e6);
        _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "exploration per-tx");
    }

    // Exploration: budget exhausted
    function test_RT_exploration_budgetExhausted_fails() public {
        bytes memory cd = _validCD(USDC, TRUMP, 10e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        uint256 t = block.timestamp;
        for (uint i = 0; i < 5; i++) {
            _pass(account.validate(op), "expl");
            t += 1;
            vm.warp(t);
        }
        _fail(account.validate(op), "exploration exhausted");
    }

    // ── Security invariants ────────────────────────────────────────────────

    // S2: recipient always account, never third party
    function test_S2_attackerRecipient_fails() public {
        address[3] memory bad = [makeAddr("a"), address(0xdead), address(registry)];
        uint256 t = block.timestamp;
        for (uint i = 0; i < 3; i++) {
            bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, bad[i]);
            _fail(account.validate(_op(cd, _rtSig(rawExecKey))), "S2");
            t += 1;
            vm.warp(t);
        }
    }

    // S3: globalTotalSpent only increases
    function test_S3_totalSpentAppendOnly() public {
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        _pass(account.validate(_op(cd, _rtSig(rawExecKey))), "first");
        assertEq(registry.getInstance(instanceId).globalTotalSpent, 50e6);
        vm.warp(block.timestamp + 1);
        _pass(account.validate(_op(cd, _rtSig(rawExecKey))), "second");
        assertEq(registry.getInstance(instanceId).globalTotalSpent, 100e6);
    }

    // S4: only owner can modify policy
    function test_S4_onlyOwnerModifies() public {
        address impostor = makeAddr("impostor");
        vm.startPrank(impostor);
        vm.expectRevert("Not instance owner");
        registry.setTokenLimit(instanceId, TRUMP, 999e6, 999e6);
        vm.expectRevert("Not instance owner");
        registry.addAllowedTarget(instanceId, makeAddr("evil"), new bytes4[](0));
        vm.stopPrank();
    }

    // ── Session mode ───────────────────────────────────────────────────────

    bytes32 public rawSessKey = keccak256("sessKey");

    function _createSess() internal returns (bytes32) {
        vm.prank(address(account));
        return registry.createSession(
            instanceId, keccak256(abi.encode(rawSessKey)),
            USDC, WETH, 50e6, 350e6, 2,
            uint64(block.timestamp + 7 * DAY)
        );
    }

    function test_sess_valid_pass() public {
        bytes32 sid = _createSess();
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        _pass(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "sess valid");
    }

    function test_sess_check1_badKey() public {
        bytes32 sid = _createSess();
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        _fail(account.validate(_op(cd, _sessSig(sid, keccak256("bad")))), "sess1");
    }

    function test_sess_check3_revoked() public {
        bytes32 sid = _createSess();
        vm.prank(address(account)); registry.revokeSession(sid);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _sessSig(sid, rawSessKey))), "sess3");
    }

    function test_sess_check4_expired() public {
        bytes32 sid = _createSess();
        vm.warp(block.timestamp + 8 * DAY);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _sessSig(sid, rawSessKey))), "sess4");
    }

    function test_sess_check6_wrongTokenIn() public {
        bytes32 sid = _createSess(); // USDC→WETH
        bytes memory cd = _validCD(WETH, WBTC, 50e6); // wrong tokenIn
        _fail(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "sess6");
    }

    function test_sess_check7_wrongTokenOut() public {
        bytes32 sid = _createSess(); // USDC→WETH
        bytes memory cd = _validCD(USDC, WBTC, 50e6); // wrong tokenOut
        _fail(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "sess7");
    }

    function test_sess_check8_wrongRecipient() public {
        bytes32 sid = _createSess();
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, makeAddr("attacker"));
        _fail(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "sess8");
    }

    function test_sess_check9_exceedsPerOp() public {
        bytes32 sid = _createSess(); // maxPerOp = 50
        _fail(account.validate(_op(_validCD(USDC, WETH, 51e6), _sessSig(sid, rawSessKey))), "sess9");
    }

    function test_sess_check10_budgetExhausted() public {
        bytes32 sid = _createSess(); // totalBudget=350, maxOpsPerDay=2
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        PackedUserOperation memory op = _op(cd, _sessSig(sid, rawSessKey));
        uint256 spent = 0;
        uint256 t = block.timestamp;
        for (uint day = 0; day < 10 && spent < 350e6; day++) {
            for (uint i = 0; i < 2 && spent < 350e6; i++) {
                if (account.validate(op) == 0) spent += 50e6;
                t += 1;
                vm.warp(t);
            }
            t += DAY;
            vm.warp(t);
        }
        _fail(account.validate(op), "sess10 budget");
    }

    function test_sess_check11_dailyOpsLimit() public {
        bytes32 sid = _createSess(); // maxOpsPerDay = 2
        bytes memory cd = _validCD(USDC, WETH, 50e6);
        PackedUserOperation memory op = _op(cd, _sessSig(sid, rawSessKey));
        uint256 t = block.timestamp;
        _pass(account.validate(op), "op1"); t += 1; vm.warp(t);
        _pass(account.validate(op), "op2"); t += 1; vm.warp(t);
        _fail(account.validate(op), "sess11 daily ops");
        t += DAY; vm.warp(t);
        _pass(account.validate(op), "resets next day");
    }

    function test_sess_check12_instancePaused_fails() public {
        bytes32 sid = _createSess();
        vm.prank(address(account)); registry.pauseInstance(instanceId);
        _fail(account.validate(_op(_validCD(USDC, WETH, 50e6), _sessSig(sid, rawSessKey))), "sess12 paused");
    }

    // ── Daily reset ────────────────────────────────────────────────────────

    function test_dailyReset_tokenLimit() public {
        bytes memory cd = _validCD(USDC, WETH, 100e6);
        PackedUserOperation memory op = _op(cd, _rtSig(rawExecKey));
        uint256 t = block.timestamp;
        for (uint i = 0; i < 5; i++) {
            _pass(account.validate(op), "hit 500");
            t += 1;
            vm.warp(t);
        }
        _fail(account.validate(op), "limit hit");
        t += DAY;
        vm.warp(t);
        _pass(account.validate(op), "resets");
    }

    // ── CRITICAL security tests ────────────────────────────────────────────

    // CRITICAL-1: onInstall must reject non-owners
    function test_CRITICAL1_onInstall_nonOwner_reverts() public {
        // attacker tries to bind their account to victim's instanceId
        MockAccount attacker = new MockAccount(validator);
        vm.prank(address(attacker));
        vm.expectRevert("onInstall: account owner mismatch");
        attacker.installValidator(abi.encode(instanceId));
    }

    // CRITICAL-1: owner can install
    function test_CRITICAL1_onInstall_owner_succeeds() public view {
        // account (the owner) already installed in setUp — verify
        assertEq(validator.getAccountInstance(address(account)), instanceId);
    }

    // CRITICAL-1: attacker cannot drain victim budget even if they somehow
    // managed to bind — belt and suspenders: confirm the ownership check works
    function test_CRITICAL1_attackerCannotBind() public {
        MockAccount attacker = new MockAccount(validator);

        // Attacker tries to install with victim's instanceId
        vm.prank(address(attacker));
        vm.expectRevert("onInstall: account owner mismatch");
        attacker.installValidator(abi.encode(instanceId));

        // Attacker has no instance bound
        assertEq(validator.getAccountInstance(address(attacker)), bytes32(0));
    }

    // CRITICAL-2: session mode must check allowedTargets
    function test_CRITICAL2_session_targetNotAllowed_fails() public {
        bytes32 sid = _createSess();
        address badTarget = makeAddr("badTarget");
        bytes memory cd = _executeCD(badTarget, USDC, WETH, 50e6, address(account));
        _fail(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "C2 bad target");
    }

    // CRITICAL-2: session mode must check allowedSelectors
    function test_CRITICAL2_session_selectorNotAllowed_fails() public {
        bytes32 sid = _createSess();
        // Build execute() with UNI_ROUTER as target but unknown selector
        bytes memory innerBad = abi.encodeWithSelector(bytes4(0xdeadbeef), USDC, WETH, 50e6);
        bytes memory execData = abi.encodePacked(UNI_ROUTER, uint256(0), innerBad);
        bytes memory cd = abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes32,bytes)")), bytes32(0), execData
        );
        _fail(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "C2 bad selector");
    }

    // CRITICAL-2: session mode with allowed target and selector passes
    function test_CRITICAL2_session_allowedTargetSelector_passes() public {
        bytes32 sid = _createSess();
        bytes memory cd = _executeCD(UNI_ROUTER, USDC, WETH, 50e6, address(account));
        _pass(account.validate(_op(cd, _sessSig(sid, rawSessKey))), "C2 allowed target+selector");
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    function _a1(address a) internal pure returns (address[] memory r) { r=new address[](1); r[0]=a; }
    function _a2(address a, address b) internal pure returns (address[] memory r) { r=new address[](2); r[0]=a; r[1]=b; }
    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) { r=new uint256[](2); r[0]=a; r[1]=b; }
    function _s2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory r) { r=new bytes4[](2); r[0]=a; r[1]=b; }
}
