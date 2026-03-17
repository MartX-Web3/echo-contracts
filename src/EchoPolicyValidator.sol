// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";
import "./interfaces/IIntentRegistry.sol";

/// @dev Minimal ERC-4337 UserOperation struct (EntryPoint v0.7).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes   initCode;
    bytes   callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes   paymasterAndData;
    bytes   signature;
}

/// @title  EchoPolicyValidator
/// @notice ERC-7579 type-1 validator module for Echo Protocol.
///
/// @dev    CALLDATA LAYOUT (problem 4 fix)
///         userOp.callData is AccountERC7579.execute() — the outer call.
///         IntentRegistry.decode() expects the inner swap calldata only.
///         We must extract the inner calldata before passing to IntentRegistry.
///
///         AccountERC7579.execute(bytes32 mode, bytes calldata executionCalldata)
///         ABI layout:
///           [0:4]    selector of execute()
///           [4:36]   mode (bytes32)
///           [36:68]  ABI offset pointer to executionCalldata (always 0x40 = 64)
///           [68:100] length of executionCalldata bytes
///           [100:120] target address (20 bytes, packed — no padding in encodePacked)
///           [120:152] value (uint256, 32 bytes)
///           [152:...]  inner calldata (the actual swap calldata)
///
///         _extractTarget reads [100:120].
///         _extractInnerCalldata reads [152:].
///         Both operate on the outer userOp.callData.
///
///         ERC-7562 storage compliance:
///           _accountInstance[msg.sender] — keyed by calling account, compliant.
///           PolicyRegistry reads are view calls on storage derived from that key.
///
///         Signature encoding:
///           Real-time: [0x01][executeKey (32b)]                  = 33 bytes
///           Session:   [0x02][sessionId (32b)][sessionKey (32b)] = 65 bytes
contract EchoPolicyValidator {

    // ── Constants ──────────────────────────────────────────────────────────

    uint8   private constant MODE_REALTIME = 0x01;
    uint8   private constant MODE_SESSION  = 0x02;
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant SIG_SUCCESS   = 0;
    uint256 private constant SIG_FAILED    = 1;

    // Outer calldata offsets (all positions in userOp.callData bytes):
    uint256 private constant OUTER_TARGET_START  = 100; // 20-byte address starts here
    uint256 private constant OUTER_TARGET_END    = 120;
    uint256 private constant OUTER_INNER_START   = 152; // inner swap calldata starts here
    uint256 private constant OUTER_MIN_LEN       = 153; // at least 1 byte of inner data

    // ── Immutables ─────────────────────────────────────────────────────────

    IPolicyRegistry public immutable registry;
    IIntentRegistry public immutable intentRegistry;

    // ── Storage (ERC-7562: keyed by account address = msg.sender) ─────────

    mapping(address account => bytes32 instanceId) private _accountInstance;

    // ── Events ─────────────────────────────────────────────────────────────

    event ValidationPassed(
        address indexed account,
        bytes32 indexed instanceId,
        bytes32 indexed sessionId,
        address tokenOut,
        uint256 amountIn,
        bool    isExploration
    );

    event ValidationFailed(
        address indexed account,
        bytes32 indexed instanceId,
        string  reason
    );

    // ── Constructor ────────────────────────────────────────────────────────

    constructor(address _registry, address _intentRegistry) {
        require(_registry       != address(0), "Zero registry");
        require(_intentRegistry != address(0), "Zero intentRegistry");
        registry       = IPolicyRegistry(_registry);
        intentRegistry = IIntentRegistry(_intentRegistry);
    }

    // ── ERC-7579 module ────────────────────────────────────────────────────

    function onInstall(bytes calldata data) external {
        require(data.length >= 32, "onInstall: data too short");
        bytes32 instanceId = abi.decode(data, (bytes32));
        require(instanceId != bytes32(0), "onInstall: zero instanceId");

        // SECURITY (CRITICAL-1): msg.sender must be the PolicyInstance owner.
        // Without this, any address could bind itself to someone else's instanceId
        // and drain their budget. In ERC-7579, onInstall is called by the smart
        // account itself (msg.sender = the account), so we verify the account
        // is the registered owner of the PolicyInstance it is installing.
        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        require(inst.owner == msg.sender, "onInstall: not instance owner");

        _accountInstance[msg.sender] = instanceId;
    }

    function onUninstall(bytes calldata) external {
        delete _accountInstance[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 1;
    }

    function isInitialized(address account) external view returns (bool) {
        return _accountInstance[account] != bytes32(0);
    }

    // ── validateUserOp ─────────────────────────────────────────────────────

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/
    ) external returns (uint256) {
        address account    = msg.sender;
        bytes32 instanceId = _accountInstance[account];

        if (instanceId == bytes32(0)) {
            emit ValidationFailed(account, bytes32(0), "No instance installed");
            return SIG_FAILED;
        }

        bytes calldata sig = userOp.signature;

        if (sig.length < 33) {
            emit ValidationFailed(account, instanceId, "Signature too short");
            return SIG_FAILED;
        }

        uint8 mode = uint8(sig[0]);

        if (mode == MODE_REALTIME) {
            return _validateRealtime(account, instanceId, userOp);
        }
        if (mode == MODE_SESSION) {
            if (sig.length < 65) {
                emit ValidationFailed(account, instanceId, "Session sig too short");
                return SIG_FAILED;
            }
            return _validateSession(account, instanceId, userOp);
        }

        emit ValidationFailed(account, instanceId, "Unknown mode");
        return SIG_FAILED;
    }

    // ── Real-time mode: 12 checks ──────────────────────────────────────────

    function _validateRealtime(
        address account,
        bytes32 instanceId,
        PackedUserOperation calldata userOp
    ) private returns (uint256) {

        bytes32 rawExecuteKey = bytes32(userOp.signature[1:33]);

        // Check 1 — Execute Key valid
        if (!registry.isValidExecuteKey(instanceId, keccak256(abi.encode(rawExecuteKey)))) {
            emit ValidationFailed(account, instanceId, "Execute Key invalid");
            return SIG_FAILED;
        }

        (
            ,
            uint256 explorationBudget,
            uint256 explorationPerTx,
            uint256 explorationSpent,
            uint256 globalMaxPerDay,
            uint256 globalTotalBudget,
            uint256 globalTotalSpent,
            uint256 globalDailySpent,
            uint256 lastOpDay,
            uint256 lastOpTimestamp,
            uint64  expiry,
            bool    paused
        ) = registry.getInstanceForValidation(instanceId);

        // Check 2 — Not paused
        if (paused) {
            emit ValidationFailed(account, instanceId, "Instance paused");
            return SIG_FAILED;
        }

        // Check 3 — Not expired
        if (block.timestamp >= uint256(expiry)) {
            emit ValidationFailed(account, instanceId, "Instance expired");
            return SIG_FAILED;
        }

        // Check 4 — Anti-replay
        if (block.timestamp <= lastOpTimestamp) {
            emit ValidationFailed(account, instanceId, "Anti-replay: too fast");
            return SIG_FAILED;
        }

        // Check 5 — Extract target and inner calldata from outer execute() call
        address target = _extractTarget(userOp.callData);
        if (target == address(0)) {
            emit ValidationFailed(account, instanceId, "Cannot extract target");
            return SIG_FAILED;
        }

        // Check 6 — Target in allowedTargets
        if (!registry.isAllowedTarget(instanceId, target)) {
            emit ValidationFailed(account, instanceId, "Target not allowed");
            return SIG_FAILED;
        }

        // Extract inner swap calldata and decode
        bytes calldata innerData = _extractInnerCalldata(userOp.callData);

        // Check 7 — Selector in allowedSelectors
        if (innerData.length < 4) {
            emit ValidationFailed(account, instanceId, "Inner calldata too short");
            return SIG_FAILED;
        }
        bytes4 selector = bytes4(innerData[:4]);
        if (!registry.isAllowedSelector(instanceId, selector)) {
            emit ValidationFailed(account, instanceId, "Selector not allowed");
            return SIG_FAILED;
        }

        // Decode inner calldata via IntentRegistry
        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            address recipient
        ) = _safeDecode(innerData);

        if (tokenIn == address(0)) {
            emit ValidationFailed(account, instanceId, "Calldata decode failed");
            return SIG_FAILED;
        }

        // Check 8 — Recipient must be this account (S2)
        if (recipient != account) {
            emit ValidationFailed(account, instanceId, "Recipient not account");
            return SIG_FAILED;
        }

        // Check 9 & 10 — Token limits or exploration
        (
            uint256 tokenMaxPerOp,
            uint256 tokenMaxPerDay,
            uint256 tokenDailySpent,
            uint256 tokenLastOpDay
        ) = registry.getTokenLimitForValidation(instanceId, tokenOut);

        bool isExploration = (tokenMaxPerOp == 0);

        if (isExploration) {
            if (explorationBudget == 0) {
                emit ValidationFailed(account, instanceId, "Token not permitted");
                return SIG_FAILED;
            }
            if (amountIn > explorationPerTx) {
                emit ValidationFailed(account, instanceId, "Exceeds exploration per-tx");
                return SIG_FAILED;
            }
            if (explorationSpent + amountIn > explorationBudget) {
                emit ValidationFailed(account, instanceId, "Exploration budget exhausted");
                return SIG_FAILED;
            }
        } else {
            if (amountIn > tokenMaxPerOp) {
                emit ValidationFailed(account, instanceId, "Exceeds token per-op limit");
                return SIG_FAILED;
            }
            uint256 effectiveTokenDaily = (tokenLastOpDay == block.timestamp / SECONDS_PER_DAY)
                ? tokenDailySpent : 0;
            if (effectiveTokenDaily + amountIn > tokenMaxPerDay) {
                emit ValidationFailed(account, instanceId, "Exceeds token daily limit");
                return SIG_FAILED;
            }
        }

        // Check 11 — Global daily cap
        uint256 effectiveGlobalDaily = (lastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? globalDailySpent : 0;
        if (effectiveGlobalDaily + amountIn > globalMaxPerDay) {
            emit ValidationFailed(account, instanceId, "Exceeds global daily limit");
            return SIG_FAILED;
        }

        // Check 12 — Global total budget (S3)
        if (globalTotalSpent + amountIn > globalTotalBudget) {
            emit ValidationFailed(account, instanceId, "Global budget exhausted");
            return SIG_FAILED;
        }

        registry.recordSpend(instanceId, bytes32(0), tokenOut, amountIn, isExploration);
        emit ValidationPassed(account, instanceId, bytes32(0), tokenOut, amountIn, isExploration);
        return SIG_SUCCESS;
    }

    // ── Session mode: 12 checks ────────────────────────────────────────────

    function _validateSession(
        address account,
        bytes32 instanceId,
        PackedUserOperation calldata userOp
    ) private returns (uint256) {

        bytes32 sessionId  = bytes32(userOp.signature[1:33]);
        bytes32 rawSessKey = bytes32(userOp.signature[33:65]);

        (
            bytes32 sessInstanceId,
            bytes32 sessionKeyHash,
            address sessTokenIn,
            address sessTokenOut,
            uint256 sessMaxPerOp,
            uint256 sessTotalBudget,
            uint256 sessTotalSpent,
            uint256 sessMaxOpsPerDay,
            uint256 sessDailyOps,
            uint256 sessLastOpDay,
            uint64  sessExpiry,
            bool    sessActive
        ) = registry.getSessionForValidation(sessionId);

        // Check 1 — Session Key valid
        if (keccak256(abi.encode(rawSessKey)) != sessionKeyHash) {
            emit ValidationFailed(account, instanceId, "Session Key invalid");
            return SIG_FAILED;
        }

        // Check 2 — Session belongs to this instance
        if (sessInstanceId != instanceId) {
            emit ValidationFailed(account, instanceId, "Session instance mismatch");
            return SIG_FAILED;
        }

        // Check 3 — Session active
        if (!sessActive) {
            emit ValidationFailed(account, instanceId, "Session revoked");
            return SIG_FAILED;
        }

        // Check 4 — Session not expired
        if (block.timestamp >= uint256(sessExpiry)) {
            emit ValidationFailed(account, instanceId, "Session expired");
            return SIG_FAILED;
        }

        // Extract target and inner calldata from outer execute() call
        address target = _extractTarget(userOp.callData);
        if (target == address(0)) {
            emit ValidationFailed(account, instanceId, "Cannot extract target");
            return SIG_FAILED;
        }

        // SECURITY (CRITICAL-2): session mode must also enforce allowedTargets
        // and allowedSelectors. Without this, a compromised agent with a session
        // key could call ANY contract, not just whitelisted DeFi protocols.
        if (!registry.isAllowedTarget(instanceId, target)) {
            emit ValidationFailed(account, instanceId, "Target not allowed");
            return SIG_FAILED;
        }

        bytes calldata innerData = _extractInnerCalldata(userOp.callData);

        if (innerData.length < 4) {
            emit ValidationFailed(account, instanceId, "Inner calldata too short");
            return SIG_FAILED;
        }
        bytes4 selector = bytes4(innerData[:4]);
        if (!registry.isAllowedSelector(instanceId, selector)) {
            emit ValidationFailed(account, instanceId, "Selector not allowed");
            return SIG_FAILED;
        }

        // Check 5 — Decode inner calldata
        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            address recipient
        ) = _safeDecode(innerData);

        if (tokenIn == address(0)) {
            emit ValidationFailed(account, instanceId, "Calldata decode failed");
            return SIG_FAILED;
        }

        // Check 6 — tokenIn matches session
        if (tokenIn != sessTokenIn) {
            emit ValidationFailed(account, instanceId, "tokenIn mismatch");
            return SIG_FAILED;
        }

        // Check 7 — tokenOut matches session
        if (tokenOut != sessTokenOut) {
            emit ValidationFailed(account, instanceId, "tokenOut mismatch");
            return SIG_FAILED;
        }

        // Check 8 — Recipient must be this account (S2)
        if (recipient != account) {
            emit ValidationFailed(account, instanceId, "Recipient not account");
            return SIG_FAILED;
        }

        // Check 9 — Amount within session per-op limit
        if (amountIn > sessMaxPerOp) {
            emit ValidationFailed(account, instanceId, "Exceeds session per-op limit");
            return SIG_FAILED;
        }

        // Check 10 — Session total budget (S3)
        if (sessTotalSpent + amountIn > sessTotalBudget) {
            emit ValidationFailed(account, instanceId, "Session budget exhausted");
            return SIG_FAILED;
        }

        // Check 11 — Session daily ops limit
        uint256 effectiveDailyOps = (sessLastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? sessDailyOps : 0;
        if (effectiveDailyOps + 1 > sessMaxOpsPerDay) {
            emit ValidationFailed(account, instanceId, "Session daily ops limit reached");
            return SIG_FAILED;
        }

        // Check 12 — MetaPolicy global caps (re-verified)
        (
            ,
            ,
            ,
            ,
            uint256 globalMaxPerDay,
            uint256 globalTotalBudget,
            uint256 globalTotalSpent,
            uint256 globalDailySpent,
            uint256 lastOpDay,
            uint256 lastOpTimestamp,
            uint64  instExpiry,
            bool    paused
        ) = registry.getInstanceForValidation(instanceId);

        if (paused) {
            emit ValidationFailed(account, instanceId, "Instance paused");
            return SIG_FAILED;
        }
        if (block.timestamp >= uint256(instExpiry)) {
            emit ValidationFailed(account, instanceId, "Instance expired");
            return SIG_FAILED;
        }
        if (block.timestamp <= lastOpTimestamp) {
            emit ValidationFailed(account, instanceId, "Anti-replay: too fast");
            return SIG_FAILED;
        }

        uint256 effectiveGlobalDaily = (lastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? globalDailySpent : 0;
        if (effectiveGlobalDaily + amountIn > globalMaxPerDay) {
            emit ValidationFailed(account, instanceId, "Exceeds global daily limit");
            return SIG_FAILED;
        }
        if (globalTotalSpent + amountIn > globalTotalBudget) {
            emit ValidationFailed(account, instanceId, "Global budget exhausted");
            return SIG_FAILED;
        }

        (uint256 tokenMaxPerOp,,,) = registry.getTokenLimitForValidation(instanceId, sessTokenOut);
        bool isExploration = (tokenMaxPerOp == 0);

        registry.recordSpend(instanceId, sessionId, sessTokenOut, amountIn, isExploration);
        emit ValidationPassed(account, instanceId, sessionId, sessTokenOut, amountIn, isExploration);
        return SIG_SUCCESS;
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Extract the target contract address from AccountERC7579.execute() calldata.
    ///      executionCalldata = abi.encodePacked(target, value, innerCalldata)
    ///      target is packed at bytes [100:120] of the outer callData.
    ///      Returns address(0) if callData is too short.
    function _extractTarget(bytes calldata data) private pure returns (address) {
        if (data.length < OUTER_TARGET_END) return address(0);
        return address(bytes20(data[OUTER_TARGET_START:OUTER_TARGET_END]));
    }

    /// @dev Extract the inner swap calldata from AccountERC7579.execute() calldata.
    ///      Inner calldata starts at byte 152 (after selector + mode + offset + length
    ///      + target + value).
    ///      Returns empty bytes slice if callData is too short.
    function _extractInnerCalldata(bytes calldata data)
        private pure returns (bytes calldata inner)
    {
        if (data.length <= OUTER_INNER_START) {
            // Return empty calldata slice
            return data[0:0];
        }
        return data[OUTER_INNER_START:];
    }

    /// @dev Safe wrapper around IntentRegistry.decode().
    ///      Returns zero values instead of reverting so validateUserOp
    ///      can return SIG_FAILED cleanly without reverting.
    function _safeDecode(bytes calldata data) private view returns (
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) {
        try intentRegistry.decode(data) returns (
            address _in, address _out, uint256 _amt, address _rec
        ) {
            return (_in, _out, _amt, _rec);
        } catch {
            return (address(0), address(0), 0, address(0));
        }
    }

    /// @notice Returns the instanceId associated with an account.
    function getAccountInstance(address account) external view returns (bytes32) {
        return _accountInstance[account];
    }
}
