// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPolicyRegistry {

    // ── Structs ────────────────────────────────────────────────────────────

    struct TokenLimit {
        uint256 maxPerOp;
        uint256 maxPerDay;
        uint256 dailySpent;
        uint256 totalSpent;    // append-only
        uint256 lastOpDay;
    }

    struct PolicyTemplate {
        bytes32  templateId;
        address  creator;
        string   name;
        uint256  defaultMaxPerOp;
        uint256  defaultMaxPerDay;
        uint256  defaultExplorationBudget;
        uint256  defaultExplorationPerTx;
        uint256  defaultGlobalMaxPerDay;
        uint256  defaultGlobalTotalBudget;
        uint64   defaultExpiry;
        bool     exists;
    }

    struct PolicyInstance {
        bytes32   templateId;
        address   owner;
        bytes32   executeKeyHash;
        address[] allowedTargets;
        bytes4[]  allowedSelectors;
        address[] tokenList;
        uint256   explorationBudget;
        uint256   explorationPerTx;
        uint256   explorationSpent;
        uint256   globalMaxPerDay;
        uint256   globalTotalBudget;
        uint256   globalTotalSpent;    // append-only
        uint256   globalDailySpent;
        uint256   lastOpDay;
        uint256   lastOpTimestamp;
        uint64    expiry;
        bool      paused;
        bool      exists;
    }

    struct SessionPolicy {
        bytes32  instanceId;
        bytes32  sessionKeyHash;
        address  tokenIn;
        address  tokenOut;
        uint256  maxAmountPerOp;
        uint256  totalBudget;
        uint256  totalSpent;    // append-only
        uint256  maxOpsPerDay;
        uint256  dailyOps;
        uint256  lastOpDay;
        uint64   sessionExpiry;
        bool     active;
        bool     exists;
    }

    /// @notice Bundle of parameters for registering a PolicyInstance.
    /// @dev    Exists to avoid "stack too deep" in callers that need to forward
    ///         many dynamic arrays (e.g. EchoAccountFactory).
    struct InstanceRegistration {
        address   owner;
        bytes32   templateId;
        bytes32   executeKeyHash;
        address[] initialTokens;
        uint256[] maxPerOps;
        uint256[] maxPerDays;
        address[] targets;
        bytes4[]  selectors;
        uint256   explorationBudget;
        uint256   explorationPerTx;
        uint256   globalMaxPerDay;
        uint256   globalTotalBudget;
        uint64    expiry;
    }

    /// @notice Minimal instance fields needed during validation.
    struct InstanceValidation {
        uint256 explorationBudget;
        uint256 explorationPerTx;
        uint256 explorationSpent;
        uint256 globalMaxPerDay;
        uint256 globalTotalBudget;
        uint256 globalTotalSpent;
        uint256 globalDailySpent;
        uint256 lastOpDay;
        uint256 lastOpTimestamp;
        uint64  expiry;
        bool    paused;
    }

    /// @notice Minimal session fields needed during validation.
    struct SessionValidation {
        bytes32 instanceId;
        bytes32 sessionKeyHash;
        address tokenIn;
        address tokenOut;
        uint256 maxAmountPerOp;
        uint256 totalBudget;
        uint256 totalSpent;
        uint256 maxOpsPerDay;
        uint256 dailyOps;
        uint256 lastOpDay;
        uint64  sessionExpiry;
        bool    active;
    }

    /// @notice Minimal token limit fields needed during validation.
    struct TokenLimitValidation {
        uint256 maxPerOp;
        uint256 maxPerDay;
        uint256 dailySpent;
        uint256 lastOpDay;
    }

    // ── Events ─────────────────────────────────────────────────────────────

    event TemplateCreated(bytes32 indexed templateId, string name, address creator);
    event InstanceRegistered(bytes32 indexed instanceId, address indexed owner, bytes32 templateId);
    event TokenLimitSet(bytes32 indexed instanceId, address indexed token, uint256 maxPerOp, uint256 maxPerDay);
    event TokenLimitRemoved(bytes32 indexed instanceId, address indexed token);
    event TargetAdded(bytes32 indexed instanceId, address target);
    event TargetRemoved(bytes32 indexed instanceId, address target);
    event ExecuteKeyIssued(bytes32 indexed instanceId, bytes32 executeKeyHash, string label);
    event ExecuteKeyRevoked(bytes32 indexed instanceId, bytes32 executeKeyHash);
    event SessionCreated(bytes32 indexed sessionId, bytes32 indexed instanceId, address owner);
    event SessionRevoked(bytes32 indexed sessionId);
    event InstancePaused(bytes32 indexed instanceId);
    event InstanceUnpaused(bytes32 indexed instanceId);
    event PolicySpendUpdated(
        bytes32 indexed instanceId,
        bytes32 indexed sessionId,
        address tokenOut,
        uint256 amountIn,
        bool    isExploration
    );

    // ── Template ───────────────────────────────────────────────────────────

    function createTemplate(
        string calldata name,
        uint256 defaultMaxPerOp,
        uint256 defaultMaxPerDay,
        uint256 defaultExplorationBudget,
        uint256 defaultExplorationPerTx,
        uint256 defaultGlobalMaxPerDay,
        uint256 defaultGlobalTotalBudget,
        uint64  defaultExpiry
    ) external returns (bytes32 templateId);

    function getTemplate(bytes32 templateId) external view returns (PolicyTemplate memory);

    // ── Instance ───────────────────────────────────────────────────────────

    /// @notice Register an instance where msg.sender becomes owner.
    /// @dev    Uses a struct bundle to avoid stack-too-deep in callers.
    ///         Implementations should enforce r.owner == msg.sender.
    function registerInstanceStruct(
        InstanceRegistration calldata r
    ) external returns (bytes32 instanceId);

    /// @notice Register an instance on behalf of `InstanceRegistration.owner`.
    /// @dev    Only callable by EchoAccountFactory (onlyFactory).
    function registerInstanceForStruct(
        InstanceRegistration calldata r
    ) external returns (bytes32 instanceId);

    function setTokenLimit(bytes32 instanceId, address token, uint256 maxPerOp, uint256 maxPerDay) external;
    function removeTokenLimit(bytes32 instanceId, address token) external;
    function addAllowedTarget(bytes32 instanceId, address target, bytes4[] calldata selectorList) external;
    function removeAllowedTarget(bytes32 instanceId, address target) external;
    function setExplorationBudget(bytes32 instanceId, uint256 budget, uint256 perTx) external;
    function setGlobalMaxPerDay(bytes32 instanceId, uint256 amount) external;
    function pauseInstance(bytes32 instanceId) external;
    function unpauseInstance(bytes32 instanceId) external;

    function getInstance(bytes32 instanceId) external view returns (PolicyInstance memory);
    function getTokenLimit(bytes32 instanceId, address token) external view returns (TokenLimit memory);
    function isAllowedTarget(bytes32 instanceId, address target) external view returns (bool);
    function isAllowedSelector(bytes32 instanceId, bytes4 selector) external view returns (bool);

    // ── Execute Key ────────────────────────────────────────────────────────

    function issueExecuteKey(bytes32 instanceId, bytes32 executeKeyHash, string calldata label) external;
    function revokeExecuteKey(bytes32 instanceId, bytes32 executeKeyHash) external;
    function isValidExecuteKey(bytes32 instanceId, bytes32 executeKeyHash) external view returns (bool);

    // ── Session ────────────────────────────────────────────────────────────

    function createSession(
        bytes32 instanceId,
        bytes32 sessionKeyHash,
        address tokenIn,
        address tokenOut,
        uint256 maxAmountPerOp,
        uint256 totalBudget,
        uint256 maxOpsPerDay,
        uint64  sessionExpiry
    ) external returns (bytes32 sessionId);

    function revokeSession(bytes32 sessionId) external;
    function getSession(bytes32 sessionId) external view returns (SessionPolicy memory);
    function isActiveSession(bytes32 sessionId) external view returns (bool);

    // ── Validator spend recording ───────────────────────────────────────────

    function recordSpend(
        bytes32 instanceId,
        bytes32 sessionId,
        address token,
        uint256 amount,
        bool    isExploration
    ) external;

    // ── Validator fast-read helpers ─────────────────────────────────────────
    // Named consistently with implementation. Called only by EchoPolicyValidator.

    function getInstanceForValidation(bytes32 instanceId) external view returns (
        bytes32 executeKeyHash,
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
    );

    /// @notice Struct-return version of instance validation data.
    function getInstanceValidation(bytes32 instanceId) external view returns (InstanceValidation memory v);

    function getTokenLimitForValidation(bytes32 instanceId, address token) external view returns (
        uint256 maxPerOp,
        uint256 maxPerDay,
        uint256 dailySpent,
        uint256 lastOpDay
    );

    /// @notice Struct-return version of token limit validation data.
    function getTokenLimitValidation(bytes32 instanceId, address token)
        external
        view
        returns (TokenLimitValidation memory v);

    function getSessionForValidation(bytes32 sessionId) external view returns (
        bytes32 instanceId,
        bytes32 sessionKeyHash,
        address tokenIn,
        address tokenOut,
        uint256 maxAmountPerOp,
        uint256 totalBudget,
        uint256 totalSpent,
        uint256 maxOpsPerDay,
        uint256 dailyOps,
        uint256 lastOpDay,
        uint64  sessionExpiry,
        bool    active
    );

    /// @notice Struct-return version of session validation data.
    function getSessionValidation(bytes32 sessionId) external view returns (SessionValidation memory v);
}
