// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PolicyRegistry.sol";
import "../src/interfaces/IPolicyRegistry.sol";

contract PolicyRegistryTest is Test {

    PolicyRegistry public registry;

    address public echoOwner   = makeAddr("echoOwner");
    address public user        = makeAddr("user");
    address public user2       = makeAddr("user2");
    address public mockValidator = makeAddr("mockValidator");

    address public WETH  = makeAddr("WETH");
    address public USDC  = makeAddr("USDC");
    address public WBTC  = makeAddr("WBTC");
    address public TRUMP = makeAddr("TRUMP");
    address public UNI_ROUTER = makeAddr("UniswapRouter");

    bytes4 public constant EXACT_INPUT_SINGLE = bytes4(0x414bf389);
    bytes4 public constant EXACT_OUTPUT_SINGLE = bytes4(0x4aa4a4fa);

    bytes32 public templateId;
    bytes32 public instanceId;

    uint256 constant DAY = 86400;

    function setUp() public {
        registry = new PolicyRegistry(echoOwner);

        // Set validator
        vm.prank(echoOwner);
        registry.setValidator(mockValidator);

        // Create a standard template
        vm.prank(echoOwner);
        templateId = registry.createTemplate(
            "Standard",
            100e6,   // defaultMaxPerOp  100 USDC
            500e6,   // defaultMaxPerDay 500 USDC
            50e6,    // defaultExplorationBudget
            10e6,    // defaultExplorationPerTx
            1000e6,  // defaultGlobalMaxPerDay
            5000e6,  // defaultGlobalTotalBudget
            uint64(90 * DAY) // defaultExpiry
        );

        // Register an instance for `user`
        vm.prank(user);
        address[] memory tokens   = new address[](2);
        uint256[] memory perOps   = new uint256[](2);
        uint256[] memory perDays  = new uint256[](2);
        tokens[0] = WETH; perOps[0] = 100e6; perDays[0] = 500e6;
        tokens[1] = WBTC; perOps[1] = 100e6; perDays[1] = 300e6;

        address[] memory targets  = new address[](1);
        targets[0] = UNI_ROUTER;
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = EXACT_INPUT_SINGLE;
        sels[1] = EXACT_OUTPUT_SINGLE;

        bytes32 execKeyHash = keccak256(abi.encode("rawExecuteKey"));

        instanceId = registry.registerInstance(
            templateId,
            execKeyHash,
            tokens, perOps, perDays,
            targets, sels,
            50e6,    // explorationBudget
            10e6,    // explorationPerTx
            1000e6,  // globalMaxPerDay
            5000e6,  // globalTotalBudget
            uint64(block.timestamp + 90 * DAY)
        );
    }

    // ── Template tests ─────────────────────────────────────────────────────

    function test_createTemplate_success() public view {
        IPolicyRegistry.PolicyTemplate memory t = registry.getTemplate(templateId);
        assertEq(t.name, "Standard");
        assertEq(t.defaultMaxPerOp, 100e6);
        assertEq(t.creator, echoOwner);
        assertTrue(t.exists);
    }

    function test_createTemplate_nonOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert("Not owner");
        registry.createTemplate("Bad", 1, 1, 0, 0, 1, 1, 30);
    }

    function test_createTemplate_emptyName_reverts() public {
        vm.prank(echoOwner);
        vm.expectRevert("Empty name");
        registry.createTemplate("", 100, 100, 0, 0, 100, 1000, 30);
    }

    function test_getTemplate_notFound_reverts() public {
        vm.expectRevert("Template not found");
        registry.getTemplate(bytes32(0));
    }

    // ── Instance tests ─────────────────────────────────────────────────────

    function test_registerInstance_success() public view {
        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.owner, user);
        assertEq(inst.globalTotalBudget, 5000e6);
        assertEq(inst.explorationBudget, 50e6);
        assertFalse(inst.paused);
        assertTrue(inst.exists);
        assertEq(inst.tokenList.length, 2);
    }

    function test_registerInstance_tokenLimits() public view {
        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.maxPerOp, 100e6);
        assertEq(tl.maxPerDay, 500e6);
        assertEq(tl.dailySpent, 0);
        assertEq(tl.totalSpent, 0);
    }

    function test_registerInstance_allowedTargets() public view {
        assertTrue(registry.isAllowedTarget(instanceId, UNI_ROUTER));
        assertTrue(registry.isAllowedSelector(instanceId, EXACT_INPUT_SINGLE));
        assertTrue(registry.isAllowedSelector(instanceId, EXACT_OUTPUT_SINGLE));
        assertFalse(registry.isAllowedTarget(instanceId, makeAddr("random")));
    }

    function test_registerInstance_badTemplate_reverts() public {
        vm.prank(user);
        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;
        vm.expectRevert("Template not found");
        registry.registerInstance(bytes32(0), bytes32(uint256(1)), t,p,d,tgt,sel,0,0,1000,5000,uint64(block.timestamp+1));
    }

    function test_registerInstance_zeroKeyHash_reverts() public {
        vm.prank(user);
        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;
        vm.expectRevert("Zero key hash");
        registry.registerInstance(templateId, bytes32(0), t,p,d,tgt,sel,0,0,1000,5000,uint64(block.timestamp+1));
    }

    function test_registerInstance_expiryInPast_reverts() public {
        vm.prank(user);
        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;
        vm.expectRevert("Expiry in past");
        registry.registerInstance(templateId, keccak256("k"), t,p,d,tgt,sel,0,0,1000,5000,uint64(block.timestamp));
    }

    // ── setTokenLimit ──────────────────────────────────────────────────────

    function test_setTokenLimit_newToken() public {
        vm.prank(user);
        registry.setTokenLimit(instanceId, TRUMP, 20e6, 60e6);

        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, TRUMP);
        assertEq(tl.maxPerOp,  20e6);
        assertEq(tl.maxPerDay, 60e6);

        // TRUMP should be in tokenList
        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        bool found;
        for (uint i = 0; i < inst.tokenList.length; i++) {
            if (inst.tokenList[i] == TRUMP) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_setTokenLimit_updateExisting() public {
        vm.prank(user);
        registry.setTokenLimit(instanceId, WETH, 200e6, 1000e6);
        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.maxPerOp, 200e6);
        // tokenList length should NOT increase (already there)
        assertEq(registry.getInstance(instanceId).tokenList.length, 2);
    }

    function test_setTokenLimit_nonOwner_reverts() public {
        vm.prank(user2);
        vm.expectRevert("Not instance owner");
        registry.setTokenLimit(instanceId, TRUMP, 10e6, 30e6);
    }

    function test_setTokenLimit_perDayLessThanPerOp_reverts() public {
        vm.prank(user);
        vm.expectRevert("maxPerDay < maxPerOp");
        registry.setTokenLimit(instanceId, TRUMP, 100e6, 50e6);
    }

    // ── removeTokenLimit ───────────────────────────────────────────────────

    function test_removeTokenLimit() public {
        vm.prank(user);
        registry.removeTokenLimit(instanceId, WETH);

        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.maxPerOp, 0);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        bool found;
        for (uint i = 0; i < inst.tokenList.length; i++) {
            if (inst.tokenList[i] == WETH) { found = true; break; }
        }
        assertFalse(found);
    }

    // ── addAllowedTarget / removeAllowedTarget ─────────────────────────────

    function test_addAllowedTarget() public {
        address newTarget = makeAddr("newDex");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(0xdeadbeef);

        vm.prank(user);
        registry.addAllowedTarget(instanceId, newTarget, sels);

        assertTrue(registry.isAllowedTarget(instanceId, newTarget));
        assertTrue(registry.isAllowedSelector(instanceId, bytes4(0xdeadbeef)));
    }

    function test_addAllowedTarget_duplicate_reverts() public {
        bytes4[] memory sels;
        vm.prank(user);
        vm.expectRevert("Already allowed");
        registry.addAllowedTarget(instanceId, UNI_ROUTER, sels);
    }

    function test_removeAllowedTarget() public {
        vm.prank(user);
        registry.removeAllowedTarget(instanceId, UNI_ROUTER);
        assertFalse(registry.isAllowedTarget(instanceId, UNI_ROUTER));
    }

    function test_removeAllowedTarget_nonOwner_reverts() public {
        vm.prank(user2);
        vm.expectRevert("Not instance owner");
        registry.removeAllowedTarget(instanceId, UNI_ROUTER);
    }

    // ── Pause / Unpause ────────────────────────────────────────────────────

    function test_pause_unpause() public {
        vm.prank(user);
        registry.pauseInstance(instanceId);
        assertTrue(registry.getInstance(instanceId).paused);

        vm.prank(user);
        registry.unpauseInstance(instanceId);
        assertFalse(registry.getInstance(instanceId).paused);
    }

    function test_pause_nonOwner_reverts() public {
        vm.prank(user2);
        vm.expectRevert("Not instance owner");
        registry.pauseInstance(instanceId);
    }

    // ── Execute Key ────────────────────────────────────────────────────────

    function test_issueExecuteKey() public {
        bytes32 newHash = keccak256(abi.encode("newKey"));
        vm.prank(user);
        registry.issueExecuteKey(instanceId, newHash, "openclaw-v2");
        assertTrue(registry.isValidExecuteKey(instanceId, newHash));
    }

    function test_issueExecuteKey_duplicate_reverts() public {
        bytes32 existingHash = keccak256(abi.encode("rawExecuteKey"));
        vm.prank(user);
        vm.expectRevert("Key already exists");
        registry.issueExecuteKey(instanceId, existingHash, "dup");
    }

    function test_revokeExecuteKey() public {
        bytes32 existingHash = keccak256(abi.encode("rawExecuteKey"));
        assertTrue(registry.isValidExecuteKey(instanceId, existingHash));

        vm.prank(user);
        registry.revokeExecuteKey(instanceId, existingHash);
        assertFalse(registry.isValidExecuteKey(instanceId, existingHash));
    }

    function test_revokeExecuteKey_nonOwner_reverts() public {
        bytes32 h = keccak256(abi.encode("rawExecuteKey"));
        vm.prank(user2);
        vm.expectRevert("Not instance owner");
        registry.revokeExecuteKey(instanceId, h);
    }

    // ── Session ────────────────────────────────────────────────────────────

    function _createSession() internal returns (bytes32 sessionId) {
        vm.prank(user);
        sessionId = registry.createSession(
            instanceId,
            keccak256("sessionKey"),
            USDC, WETH,
            50e6,    // maxAmountPerOp
            350e6,   // totalBudget
            1,       // maxOpsPerDay
            uint64(block.timestamp + 7 * DAY)
        );
    }

    function test_createSession_success() public {
        bytes32 sessionId = _createSession();
        IPolicyRegistry.SessionPolicy memory sess = registry.getSession(sessionId);
        assertEq(sess.tokenIn,  USDC);
        assertEq(sess.tokenOut, WETH);
        assertEq(sess.maxAmountPerOp, 50e6);
        assertEq(sess.totalBudget, 350e6);
        assertTrue(sess.active);
        assertTrue(sess.exists);
        assertTrue(registry.isActiveSession(sessionId));
    }

    function test_createSession_tokenOutNotPermitted_reverts() public {
        // USDC not in tokenLimits and exploration budget is non-zero but
        // trying to use a token not in limits with exploration
        // Actually USDC is not in tokenList (WETH, WBTC are)
        // But exploration budget > 0, so USDC should be allowed via exploration
        // Let's test with exploration budget = 0
        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;
        vm.prank(user2);
        bytes32 inst2 = registry.registerInstance(
            templateId,
            keccak256("k2"),
            t, p, d, tgt, sel,
            0, 0,    // no exploration budget
            1000e6,
            5000e6,
            uint64(block.timestamp + DAY)
        );

        vm.prank(user2);
        vm.expectRevert("tokenOut not permitted");
        registry.createSession(
            inst2, keccak256("s"), USDC, TRUMP, 10e6, 50e6, 1,
            uint64(block.timestamp + DAY - 1)
        );
    }

    function test_createSession_exceedsGlobalBudget_reverts() public {
        vm.prank(user);
        vm.expectRevert("Exceeds remaining global budget");
        registry.createSession(
            instanceId,
            keccak256("s"),
            USDC, WETH,
            100e6,
            6000e6,  // > globalTotalBudget (5000)
            1,
            uint64(block.timestamp + DAY)
        );
    }

    function test_createSession_expiryInPast_reverts() public {
        vm.prank(user);
        vm.expectRevert("Expiry in past");
        registry.createSession(
            instanceId, keccak256("s"), USDC, WETH, 50e6, 350e6, 1,
            uint64(block.timestamp)
        );
    }

    function test_revokeSession() public {
        bytes32 sessionId = _createSession();
        assertTrue(registry.isActiveSession(sessionId));

        vm.prank(user);
        registry.revokeSession(sessionId);

        assertFalse(registry.isActiveSession(sessionId));
        assertFalse(registry.getSession(sessionId).active);
    }

    function test_revokeSession_nonOwner_reverts() public {
        bytes32 sessionId = _createSession();
        vm.prank(user2);
        vm.expectRevert("Not instance owner");
        registry.revokeSession(sessionId);
    }

    function test_session_expiry() public {
        bytes32 sessionId = _createSession();
        assertTrue(registry.isActiveSession(sessionId));

        vm.warp(block.timestamp + 8 * DAY);
        assertFalse(registry.isActiveSession(sessionId));
    }

    // ── recordSpend ────────────────────────────────────────────────────────

    function test_recordSpend_realtime_updates_all_counters() public {
        vm.prank(mockValidator);
        registry.recordSpend(instanceId, bytes32(0), WETH, 50e6, false);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.globalTotalSpent, 50e6);
        assertEq(inst.globalDailySpent, 50e6);

        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.dailySpent, 50e6);
        assertEq(tl.totalSpent, 50e6);
    }

    function test_recordSpend_exploration() public {
        vm.prank(mockValidator);
        registry.recordSpend(instanceId, bytes32(0), TRUMP, 10e6, true);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.explorationSpent, 10e6);
        assertEq(inst.globalTotalSpent, 10e6);
        // Token limit for TRUMP should NOT be updated (exploration path)
        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, TRUMP);
        assertEq(tl.totalSpent, 0);
    }

    function test_recordSpend_session_updates_session_counters() public {
        bytes32 sessionId = _createSession();

        vm.prank(mockValidator);
        registry.recordSpend(instanceId, sessionId, WETH, 50e6, false);

        IPolicyRegistry.SessionPolicy memory sess = registry.getSession(sessionId);
        assertEq(sess.totalSpent, 50e6);
        assertEq(sess.dailyOps,   1);
    }

    function test_recordSpend_daily_reset() public {
        vm.prank(mockValidator);
        registry.recordSpend(instanceId, bytes32(0), WETH, 50e6, false);

        // Advance one day
        vm.warp(block.timestamp + DAY + 1);

        vm.prank(mockValidator);
        registry.recordSpend(instanceId, bytes32(0), WETH, 30e6, false);

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        assertEq(inst.globalDailySpent, 30e6);  // reset
        assertEq(inst.globalTotalSpent, 80e6);  // accumulates

        IPolicyRegistry.TokenLimit memory tl = registry.getTokenLimit(instanceId, WETH);
        assertEq(tl.dailySpent, 30e6);   // reset
        assertEq(tl.totalSpent, 80e6);   // accumulates
    }

    function test_recordSpend_nonValidator_reverts() public {
        vm.prank(user);
        vm.expectRevert("Not validator");
        registry.recordSpend(instanceId, bytes32(0), WETH, 50e6, false);
    }

    // ── setValidator ───────────────────────────────────────────────────────

    function test_setValidator_twice_reverts() public {
        vm.prank(echoOwner);
        vm.expectRevert("Already set");
        registry.setValidator(makeAddr("another"));
    }

    // ── setFactory ─────────────────────────────────────────────────────────

    function test_setFactory_success() public {
        PolicyRegistry reg2 = new PolicyRegistry(echoOwner);
        address mockFactory = makeAddr("mockFactory");
        vm.prank(echoOwner);
        reg2.setFactory(mockFactory);
        assertEq(reg2.factory(), mockFactory);
    }

    function test_setFactory_nonOwner_reverts() public {
        PolicyRegistry reg2 = new PolicyRegistry(echoOwner);
        vm.prank(makeAddr("random"));
        vm.expectRevert("Not owner");
        reg2.setFactory(makeAddr("f"));
    }

    function test_setFactory_twice_reverts() public {
        PolicyRegistry reg2 = new PolicyRegistry(echoOwner);
        vm.prank(echoOwner);
        reg2.setFactory(makeAddr("f1"));
        vm.prank(echoOwner);
        vm.expectRevert("Already set");
        reg2.setFactory(makeAddr("f2"));
    }

    // ── registerInstanceFor ────────────────────────────────────────────────

    function test_registerInstanceFor_ownerIsUser() public {
        // Deploy fresh registry with factory set
        PolicyRegistry reg2 = new PolicyRegistry(echoOwner);
        address mockFactory2 = makeAddr("factory2");
        address userWallet   = makeAddr("userWallet");

        vm.prank(echoOwner);
        reg2.setValidator(mockValidator);
        vm.prank(echoOwner);
        reg2.setFactory(mockFactory2);

        // Echo team creates template
        vm.prank(echoOwner);
        bytes32 tId = reg2.createTemplate(
            "Standard", 100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(90 * DAY)
        );

        // Factory calls registerInstanceFor on behalf of userWallet
        address[] memory tokens  = new address[](1);
        uint256[] memory perOps  = new uint256[](1);
        uint256[] memory perDays = new uint256[](1);
        tokens[0] = WETH; perOps[0] = 100e6; perDays[0] = 500e6;

        address[] memory targets = new address[](1);
        targets[0] = UNI_ROUTER;
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(0x414bf389);

        vm.prank(mockFactory2);
        bytes32 iId = reg2.registerInstanceFor(
            userWallet, tId, keccak256("key"),
            tokens, perOps, perDays,
            targets, sels,
            50e6, 10e6, 1000e6, 5000e6,
            uint64(block.timestamp + DAY)
        );

        // Owner must be userWallet, not factory
        IPolicyRegistry.PolicyInstance memory inst = reg2.getInstance(iId);
        assertEq(inst.owner, userWallet, "owner must be user, not factory");
        assertNotEq(inst.owner, mockFactory2, "factory must not be owner");
    }

    function test_registerInstanceFor_nonFactory_reverts() public {
        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;

        vm.prank(makeAddr("notFactory"));
        vm.expectRevert("Not factory");
        registry.registerInstanceFor(
            makeAddr("user"), templateId, keccak256("k"),
            t, p, d, tgt, sel,
            0, 0, 1000e6, 5000e6,
            uint64(block.timestamp + DAY)
        );
    }

    function test_registerInstanceFor_zeroOwner_reverts() public {
        // Need a registry with factory set
        PolicyRegistry reg2 = new PolicyRegistry(echoOwner);
        address mockFactory2 = makeAddr("factory2");
        vm.prank(echoOwner);
        reg2.setFactory(mockFactory2);
        vm.prank(echoOwner);
        bytes32 tId = reg2.createTemplate(
            "T", 100e6, 500e6, 0, 0, 1000e6, 5000e6, uint64(90 * DAY)
        );

        address[] memory t; uint256[] memory p; uint256[] memory d;
        address[] memory tgt; bytes4[] memory sel;

        vm.prank(mockFactory2);
        vm.expectRevert("Zero owner");
        reg2.registerInstanceFor(
            address(0), tId, keccak256("k"),
            t, p, d, tgt, sel,
            0, 0, 1000e6, 5000e6,
            uint64(block.timestamp + DAY)
        );
    }

    // ── S4 Security invariant: only owner modifies instance ────────────────

    function test_invariant_S4_only_owner_modifies() public {
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        vm.expectRevert("Not instance owner");
        registry.setTokenLimit(instanceId, TRUMP, 1, 1);

        vm.expectRevert("Not instance owner");
        registry.addAllowedTarget(instanceId, makeAddr("evil"), new bytes4[](0));

        vm.expectRevert("Not instance owner");
        registry.createSession(instanceId, keccak256("sk"), USDC, WETH, 1, 1, 1, uint64(block.timestamp + 1));

        vm.expectRevert("Not instance owner");
        registry.pauseInstance(instanceId);

        vm.expectRevert("Not instance owner");
        registry.issueExecuteKey(instanceId, keccak256("k"), "evil");
        vm.stopPrank();
    }

    // ── Fast-read helpers for Validator ────────────────────────────────────

    function test_getInstanceForValidation() public view {
        (
            bytes32 execKeyHash,
            ,,,,,,,,,
            uint64 expiry,
            bool paused
        ) = registry.getInstanceForValidation(instanceId);

        assertEq(execKeyHash, keccak256(abi.encode("rawExecuteKey")));
        assertFalse(paused);
        assertGt(expiry, uint64(block.timestamp));
    }

    function test_getTokenLimitForValidation() public view {
        (uint256 maxPerOp, uint256 maxPerDay,,) =
            registry.getTokenLimitForValidation(instanceId, WETH);
        assertEq(maxPerOp,  100e6);
        assertEq(maxPerDay, 500e6);
    }

    function test_getSessionForValidation() public {
        bytes32 sessionId = _createSession();
        (
            bytes32 instId,
            bytes32 sessKeyHash,
            address tokenIn,
            address tokenOut,
            uint256 maxPerOp,
            uint256 budget,
            uint256 spent,
            ,,,, uint64 exp, bool active
        ) = registry.getSessionForValidation(sessionId);

        assertEq(instId,       instanceId);
        assertEq(sessKeyHash,  keccak256("sessionKey"));
        assertEq(tokenIn,      USDC);
        assertEq(tokenOut,     WETH);
        assertEq(maxPerOp,     50e6);
        assertEq(budget,       350e6);
        assertEq(spent,        0);
        assertTrue(active);
        assertGt(exp, uint64(block.timestamp));
    }
}
