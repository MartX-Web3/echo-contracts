// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";
import "./interfaces/IIntentRegistry.sol";

/// @dev Minimal Ownable interface — OZ AccountERC7579 inherits Ownable.
interface IOwnable {
    function owner() external view returns (address);
}

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
contract EchoPolicyValidator {

    uint8   private constant MODE_REALTIME   = 0x01;
    uint8   private constant MODE_SESSION    = 0x02;
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant SIG_SUCCESS     = 0;
    uint256 private constant SIG_FAILED      = 1;

    uint256 private constant OUTER_TARGET_START = 100;
    uint256 private constant OUTER_TARGET_END   = 120;
    uint256 private constant OUTER_INNER_START  = 152;

    IPolicyRegistry public immutable registry;
    IIntentRegistry public immutable intentRegistry;

    mapping(address account => bytes32 instanceId) private _accountInstance;
    mapping(address account => uint256 lastOpTimestamp) private _lastOpTimestamp;

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

        IPolicyRegistry.PolicyInstance memory inst = registry.getInstance(instanceId);
        address accountOwner = IOwnable(msg.sender).owner();
        require(accountOwner == inst.owner, "onInstall: account owner mismatch");

        _accountInstance[msg.sender] = instanceId;
    }

    function onUninstall(bytes calldata) external {
        delete _accountInstance[msg.sender];
        delete _lastOpTimestamp[msg.sender];
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

    // ── Real-time: 12 checks ───────────────────────────────────────────────

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

        IPolicyRegistry.InstanceValidation memory instV = registry.getInstanceValidation(instanceId);

        // Check 2 — Not paused
        if (instV.paused) {
            emit ValidationFailed(account, instanceId, "Instance paused");
            return SIG_FAILED;
        }

        // Check 3 — Not expired
        if (block.timestamp >= uint256(instV.expiry)) {
            emit ValidationFailed(account, instanceId, "Instance expired");
            return SIG_FAILED;
        }

        // Check 4 — Anti-replay (strictly monotone: each op must be in a later second)
        if (block.timestamp <= _lastOpTimestamp[account]) {
            emit ValidationFailed(account, instanceId, "Anti-replay: too fast");
            return SIG_FAILED;
        }

        // Check 5 & 6 — target in allowedTargets
        {
            address target = _extractTarget(userOp.callData);
            if (target == address(0)) {
                emit ValidationFailed(account, instanceId, "Cannot extract target");
                return SIG_FAILED;
            }
            if (!registry.isAllowedTarget(instanceId, target)) {
                emit ValidationFailed(account, instanceId, "Target not allowed");
                return SIG_FAILED;
            }
        }

        bytes calldata innerData = _extractInnerCalldata(userOp.callData);

        // Check 7 — selector in allowedSelectors
        if (innerData.length < 4) {
            emit ValidationFailed(account, instanceId, "Inner calldata too short");
            return SIG_FAILED;
        }
        if (!registry.isAllowedSelector(instanceId, bytes4(innerData[:4]))) {
            emit ValidationFailed(account, instanceId, "Selector not allowed");
            return SIG_FAILED;
        }

        (, address tokenOut, uint256 amountIn, address recipient) = _safeDecode(innerData);
        if (tokenOut == address(0)) {
            emit ValidationFailed(account, instanceId, "Calldata decode failed");
            return SIG_FAILED;
        }

        // Check 8 — recipient == account (S2)
        if (recipient != account) {
            emit ValidationFailed(account, instanceId, "Recipient not account");
            return SIG_FAILED;
        }

        // Check 9 & 10 — token limits or exploration
        IPolicyRegistry.TokenLimitValidation memory tlV =
            registry.getTokenLimitValidation(instanceId, tokenOut);
        bool isExploration = (tlV.maxPerOp == 0);

        if (isExploration) {
            if (instV.explorationBudget == 0) {
                emit ValidationFailed(account, instanceId, "Token not permitted");
                return SIG_FAILED;
            }
            if (amountIn > instV.explorationPerTx) {
                emit ValidationFailed(account, instanceId, "Exceeds exploration per-tx");
                return SIG_FAILED;
            }
            if (instV.explorationSpent + amountIn > instV.explorationBudget) {
                emit ValidationFailed(account, instanceId, "Exploration budget exhausted");
                return SIG_FAILED;
            }
        } else {
            if (amountIn > tlV.maxPerOp) {
                emit ValidationFailed(account, instanceId, "Exceeds token per-op limit");
                return SIG_FAILED;
            }
            uint256 effectiveTokenDaily = (tlV.lastOpDay == block.timestamp / SECONDS_PER_DAY)
                ? tlV.dailySpent : 0;
            if (effectiveTokenDaily + amountIn > tlV.maxPerDay) {
                emit ValidationFailed(account, instanceId, "Exceeds token daily limit");
                return SIG_FAILED;
            }
        }

        // Check 11 — global daily cap
        uint256 effectiveGlobalDaily = (instV.lastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? instV.globalDailySpent : 0;
        if (effectiveGlobalDaily + amountIn > instV.globalMaxPerDay) {
            emit ValidationFailed(account, instanceId, "Exceeds global daily limit");
            return SIG_FAILED;
        }

        // Check 12 — global total budget (S3)
        if (instV.globalTotalSpent + amountIn > instV.globalTotalBudget) {
            emit ValidationFailed(account, instanceId, "Global budget exhausted");
            return SIG_FAILED;
        }

        registry.recordSpend(instanceId, bytes32(0), tokenOut, amountIn, isExploration);
        _lastOpTimestamp[account] = block.timestamp;
        emit ValidationPassed(account, instanceId, bytes32(0), tokenOut, amountIn, isExploration);
        return SIG_SUCCESS;
    }

    // ── Session: 12 checks ─────────────────────────────────────────────────

    function _validateSession(
        address account,
        bytes32 instanceId,
        PackedUserOperation calldata userOp
    ) private returns (uint256) {

        bytes32 sessionId  = bytes32(userOp.signature[1:33]);
        bytes32 rawSessKey = bytes32(userOp.signature[33:65]);

        IPolicyRegistry.SessionValidation memory sessV =
            registry.getSessionValidation(sessionId);

        // Check 1 — session key valid
        if (keccak256(abi.encode(rawSessKey)) != sessV.sessionKeyHash) {
            emit ValidationFailed(account, instanceId, "Session Key invalid");
            return SIG_FAILED;
        }

        // Check 2 — session belongs to this instance
        if (sessV.instanceId != instanceId) {
            emit ValidationFailed(account, instanceId, "Session instance mismatch");
            return SIG_FAILED;
        }

        // Check 3 — session active
        if (!sessV.active) {
            emit ValidationFailed(account, instanceId, "Session revoked");
            return SIG_FAILED;
        }

        // Check 4 — session not expired
        if (block.timestamp >= uint256(sessV.sessionExpiry)) {
            emit ValidationFailed(account, instanceId, "Session expired");
            return SIG_FAILED;
        }

        // Checks 5–11: calldata, token match, recipient, session budget/ops
        (uint256 amountIn, bool ok) = _checkSessionCalldataAndLimits(
            account, instanceId, userOp.callData, sessV
        );
        if (!ok) return SIG_FAILED;

        // Check 12 — MetaPolicy global caps + subset re-verification
        // Re-verify that SessionPolicy ⊆ PolicyInstance at validation time.
        // The instance may have changed since session creation (user lowered
        // limits, reduced exploration budget, removed a token, etc.).
        IPolicyRegistry.InstanceValidation memory instV =
            registry.getInstanceValidation(instanceId);

        if (instV.paused) {
            emit ValidationFailed(account, instanceId, "Instance paused");
            return SIG_FAILED;
        }
        if (block.timestamp >= uint256(instV.expiry)) {
            emit ValidationFailed(account, instanceId, "Instance expired");
            return SIG_FAILED;
        }
        if (block.timestamp <= _lastOpTimestamp[account]) {
            emit ValidationFailed(account, instanceId, "Anti-replay: too fast");
            return SIG_FAILED;
        }

        uint256 effectiveGlobalDaily = (instV.lastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? instV.globalDailySpent : 0;
        if (effectiveGlobalDaily + amountIn > instV.globalMaxPerDay) {
            emit ValidationFailed(account, instanceId, "Exceeds global daily limit");
            return SIG_FAILED;
        }
        if (instV.globalTotalSpent + amountIn > instV.globalTotalBudget) {
            emit ValidationFailed(account, instanceId, "Global budget exhausted");
            return SIG_FAILED;
        }

        // Subset re-verification: token-level constraints at validation time.
        // Even though session creation validated these, the instance may have changed.
        IPolicyRegistry.TokenLimitValidation memory tlV =
            registry.getTokenLimitValidation(instanceId, sessV.tokenOut);
        bool isExploration = (tlV.maxPerOp == 0);

        if (isExploration) {
            // tokenOut is still an exploration token — re-verify exploration budget
            if (instV.explorationBudget == 0) {
                emit ValidationFailed(account, instanceId, "Exploration budget removed from instance");
                return SIG_FAILED;
            }
            if (amountIn > instV.explorationPerTx) {
                emit ValidationFailed(account, instanceId, "Exceeds exploration per-tx (re-verify)");
                return SIG_FAILED;
            }
            if (instV.explorationSpent + amountIn > instV.explorationBudget) {
                emit ValidationFailed(account, instanceId, "Exploration budget exhausted (re-verify)");
                return SIG_FAILED;
            }
        } else {
            // tokenOut is a whitelisted token — re-verify token daily cap
            if (tlV.maxPerOp == 0) {
                // Token was removed from tokenLimits since session creation
                emit ValidationFailed(account, instanceId, "Token removed from instance limits");
                return SIG_FAILED;
            }
            if (amountIn > tlV.maxPerOp) {
                emit ValidationFailed(account, instanceId, "Exceeds token per-op limit (re-verify)");
                return SIG_FAILED;
            }
            uint256 effectiveTokenDaily = (tlV.lastOpDay == block.timestamp / SECONDS_PER_DAY)
                ? tlV.dailySpent : 0;
            if (effectiveTokenDaily + amountIn > tlV.maxPerDay) {
                emit ValidationFailed(account, instanceId, "Exceeds token daily limit (re-verify)");
                return SIG_FAILED;
            }
        }

        registry.recordSpend(instanceId, sessionId, sessV.tokenOut, amountIn, isExploration);
        _lastOpTimestamp[account] = block.timestamp;
        emit ValidationPassed(account, instanceId, sessionId, sessV.tokenOut, amountIn, isExploration);
        return SIG_SUCCESS;
    }

    /// @dev Session checks 5–11: target, selector, decode, token match, recipient, budget/ops.
    function _checkSessionCalldataAndLimits(
        address account,
        bytes32 instanceId,
        bytes calldata outerCallData,
        IPolicyRegistry.SessionValidation memory sessV
    ) private returns (uint256 amountIn, bool ok) {

        address target = _extractTarget(outerCallData);
        if (target == address(0)) {
            emit ValidationFailed(account, instanceId, "Cannot extract target");
            return (0, false);
        }
        if (!registry.isAllowedTarget(instanceId, target)) {
            emit ValidationFailed(account, instanceId, "Target not allowed");
            return (0, false);
        }

        bytes calldata innerData = _extractInnerCalldata(outerCallData);
        if (innerData.length < 4) {
            emit ValidationFailed(account, instanceId, "Inner calldata too short");
            return (0, false);
        }
        if (!registry.isAllowedSelector(instanceId, bytes4(innerData[:4]))) {
            emit ValidationFailed(account, instanceId, "Selector not allowed");
            return (0, false);
        }

        (address tokenIn, address tokenOut, uint256 amt, address recipient) = _safeDecode(innerData);
        if (tokenIn == address(0)) {
            emit ValidationFailed(account, instanceId, "Calldata decode failed");
            return (0, false);
        }
        if (tokenIn != sessV.tokenIn) {
            emit ValidationFailed(account, instanceId, "tokenIn mismatch");
            return (0, false);
        }
        if (tokenOut != sessV.tokenOut) {
            emit ValidationFailed(account, instanceId, "tokenOut mismatch");
            return (0, false);
        }
        if (recipient != account) {
            emit ValidationFailed(account, instanceId, "Recipient not account");
            return (0, false);
        }

        amountIn = amt;

        if (amountIn > sessV.maxAmountPerOp) {
            emit ValidationFailed(account, instanceId, "Exceeds session per-op limit");
            return (0, false);
        }
        if (sessV.totalSpent + amountIn > sessV.totalBudget) {
            emit ValidationFailed(account, instanceId, "Session budget exhausted");
            return (0, false);
        }

        uint256 effectiveDailyOps = (sessV.lastOpDay == block.timestamp / SECONDS_PER_DAY)
            ? sessV.dailyOps : 0;
        if (effectiveDailyOps + 1 > sessV.maxOpsPerDay) {
            emit ValidationFailed(account, instanceId, "Session daily ops limit reached");
            return (0, false);
        }

        return (amountIn, true);
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    function _extractTarget(bytes calldata data) private pure returns (address) {
        if (data.length < OUTER_TARGET_END) return address(0);
        return address(bytes20(data[OUTER_TARGET_START:OUTER_TARGET_END]));
    }

    function _extractInnerCalldata(bytes calldata data)
        private pure returns (bytes calldata)
    {
        if (data.length <= OUTER_INNER_START) return data[0:0];
        return data[OUTER_INNER_START:];
    }

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

    function getAccountInstance(address account) external view returns (bytes32) {
        return _accountInstance[account];
    }
}
