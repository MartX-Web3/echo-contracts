// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";

/// @title  PolicyRegistry
/// @notice Single source of truth for all Echo Protocol permission state:
///         PolicyTemplates, PolicyInstances, SessionPolicies, Execute Keys.
///
/// @dev    Two privileged addresses beyond per-instance owners:
///         - `owner`   (Echo team): create templates, set factory/validator once
///         - `validator` (EchoPolicyValidator): call recordSpend after validation
///         - `factory`   (EchoAccountFactory):  call registerInstanceFor
contract PolicyRegistry is IPolicyRegistry {

    // ── Privileged addresses ───────────────────────────────────────────────

    address public immutable owner;
    address public validator;   // set once
    address public factory;     // set once

    // ── Storage ────────────────────────────────────────────────────────────

    mapping(bytes32 => PolicyTemplate)  private _templates;
    mapping(bytes32 => PolicyInstance)  private _instances;
    mapping(bytes32 => mapping(address => TokenLimit)) private _tokenLimits;
    mapping(bytes32 => mapping(address => bool))       private _targetAllowed;
    mapping(bytes32 => mapping(bytes4  => bool))       private _selectorAllowed;
    mapping(bytes32 => mapping(bytes32 => bool))       private _executeKeys;
    mapping(bytes32 => SessionPolicy)   private _sessions;

    uint256 private _templateNonce;
    uint256 private _instanceNonce;
    uint256 private _sessionNonce;

    uint256 private constant SECONDS_PER_DAY = 86400;

    // ── Constructor ────────────────────────────────────────────────────────

    constructor(address _owner) {
        owner = _owner;
    }

    // ── One-time setup ─────────────────────────────────────────────────────

    function setValidator(address _validator) external {
        require(msg.sender == owner,    "Not owner");
        require(validator == address(0),"Already set");
        require(_validator != address(0),"Zero address");
        validator = _validator;
    }

    function setFactory(address _factory) external {
        require(msg.sender == owner,   "Not owner");
        require(factory == address(0), "Already set");
        require(_factory != address(0),"Zero address");
        factory = _factory;
    }

    // ── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyInstanceOwner(bytes32 instanceId) {
        require(_instances[instanceId].exists,              "Instance not found");
        require(_instances[instanceId].owner == msg.sender, "Not instance owner");
        _;
    }

    modifier onlyValidator() {
        require(msg.sender == validator, "Not validator");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

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
    ) external onlyOwner returns (bytes32 templateId) {
        require(bytes(name).length > 0,             "Empty name");
        require(defaultMaxPerOp > 0,                "maxPerOp zero");
        require(defaultMaxPerDay >= defaultMaxPerOp,"maxPerDay < maxPerOp");
        require(defaultGlobalMaxPerDay >= defaultMaxPerDay, "global < perDay");
        require(defaultExpiry > 0,                  "Expiry zero");

        templateId = keccak256(abi.encodePacked("tpl", ++_templateNonce, block.chainid));
        _templates[templateId] = PolicyTemplate({
            templateId:               templateId,
            creator:                  msg.sender,
            name:                     name,
            defaultMaxPerOp:          defaultMaxPerOp,
            defaultMaxPerDay:         defaultMaxPerDay,
            defaultExplorationBudget: defaultExplorationBudget,
            defaultExplorationPerTx:  defaultExplorationPerTx,
            defaultGlobalMaxPerDay:   defaultGlobalMaxPerDay,
            defaultGlobalTotalBudget: defaultGlobalTotalBudget,
            defaultExpiry:            defaultExpiry,
            exists:                   true
        });
        emit TemplateCreated(templateId, name, msg.sender);
    }

    function getTemplate(bytes32 templateId) external view returns (PolicyTemplate memory) {
        require(_templates[templateId].exists, "Template not found");
        return _templates[templateId];
    }

    // ── Instance ───────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    /// @dev msg.sender becomes owner. Used when user calls directly.
    function registerInstance(
        bytes32   templateId,
        bytes32   executeKeyHash,
        address[] calldata initialTokens,
        uint256[] calldata maxPerOps,
        uint256[] calldata maxPerDays,
        address[] calldata targets,
        bytes4[]  calldata selectors,
        uint256   explorationBudget,
        uint256   explorationPerTx,
        uint256   globalMaxPerDay,
        uint256   globalTotalBudget,
        uint64    expiry
    ) external returns (bytes32 instanceId) {
        return _registerInstance(
            msg.sender, templateId, executeKeyHash,
            initialTokens, maxPerOps, maxPerDays,
            targets, selectors,
            explorationBudget, explorationPerTx,
            globalMaxPerDay, globalTotalBudget, expiry
        );
    }

    /// @inheritdoc IPolicyRegistry
    /// @dev `owner` param is the user address. Called by EchoAccountFactory only.
    function registerInstanceFor(
        address   instanceOwner,
        bytes32   templateId,
        bytes32   executeKeyHash,
        address[] calldata initialTokens,
        uint256[] calldata maxPerOps,
        uint256[] calldata maxPerDays,
        address[] calldata targets,
        bytes4[]  calldata selectors,
        uint256   explorationBudget,
        uint256   explorationPerTx,
        uint256   globalMaxPerDay,
        uint256   globalTotalBudget,
        uint64    expiry
    ) external onlyFactory returns (bytes32 instanceId) {
        require(instanceOwner != address(0), "Zero owner");
        return _registerInstance(
            instanceOwner, templateId, executeKeyHash,
            initialTokens, maxPerOps, maxPerDays,
            targets, selectors,
            explorationBudget, explorationPerTx,
            globalMaxPerDay, globalTotalBudget, expiry
        );
    }

    /// @dev Shared implementation for both registerInstance variants.
    function _registerInstance(
        address   instanceOwner,
        bytes32   templateId,
        bytes32   executeKeyHash,
        address[] calldata initialTokens,
        uint256[] calldata maxPerOps,
        uint256[] calldata maxPerDays,
        address[] calldata targets,
        bytes4[]  calldata selectors,
        uint256   explorationBudget,
        uint256   explorationPerTx,
        uint256   globalMaxPerDay,
        uint256   globalTotalBudget,
        uint64    expiry
    ) internal returns (bytes32 instanceId) {
        require(_templates[templateId].exists,              "Template not found");
        require(executeKeyHash != bytes32(0),               "Zero key hash");
        require(expiry > block.timestamp,                   "Expiry in past");
        require(initialTokens.length == maxPerOps.length,  "Token array mismatch");
        require(initialTokens.length == maxPerDays.length, "Token array mismatch");
        require(globalTotalBudget > 0,                     "Zero global budget");

        instanceId = keccak256(abi.encodePacked(
            "inst", ++_instanceNonce, instanceOwner, block.chainid
        ));

        _instances[instanceId] = PolicyInstance({
            templateId:        templateId,
            owner:             instanceOwner,
            executeKeyHash:    executeKeyHash,
            allowedTargets:    targets,
            allowedSelectors:  selectors,
            tokenList:         initialTokens,
            explorationBudget: explorationBudget,
            explorationPerTx:  explorationPerTx,
            explorationSpent:  0,
            globalMaxPerDay:   globalMaxPerDay,
            globalTotalBudget: globalTotalBudget,
            globalTotalSpent:  0,
            globalDailySpent:  0,
            lastOpDay:         0,
            lastOpTimestamp:   0,
            expiry:            expiry,
            paused:            false,
            exists:            true
        });

        _executeKeys[instanceId][executeKeyHash] = true;

        for (uint256 i = 0; i < initialTokens.length; i++) {
            require(maxPerDays[i] >= maxPerOps[i], "maxPerDay < maxPerOp");
            _tokenLimits[instanceId][initialTokens[i]] = TokenLimit({
                maxPerOp:   maxPerOps[i],
                maxPerDay:  maxPerDays[i],
                dailySpent: 0,
                totalSpent: 0,
                lastOpDay:  0
            });
            emit TokenLimitSet(instanceId, initialTokens[i], maxPerOps[i], maxPerDays[i]);
        }

        for (uint256 i = 0; i < targets.length; i++) {
            _targetAllowed[instanceId][targets[i]] = true;
            emit TargetAdded(instanceId, targets[i]);
        }
        for (uint256 i = 0; i < selectors.length; i++) {
            _selectorAllowed[instanceId][selectors[i]] = true;
        }

        emit InstanceRegistered(instanceId, instanceOwner, templateId);
        emit ExecuteKeyIssued(instanceId, executeKeyHash, "initial");
    }

    // ── Instance field-level updates ───────────────────────────────────────

    function setTokenLimit(bytes32 instanceId, address token, uint256 maxPerOp, uint256 maxPerDay)
        external onlyInstanceOwner(instanceId)
    {
        require(token != address(0), "Zero token");
        require(maxPerOp > 0,        "Zero maxPerOp");
        require(maxPerDay >= maxPerOp,"maxPerDay < maxPerOp");

        bool isNew = _tokenLimits[instanceId][token].maxPerOp == 0;
        _tokenLimits[instanceId][token].maxPerOp  = maxPerOp;
        _tokenLimits[instanceId][token].maxPerDay = maxPerDay;
        if (isNew) _instances[instanceId].tokenList.push(token);
        emit TokenLimitSet(instanceId, token, maxPerOp, maxPerDay);
    }

    function removeTokenLimit(bytes32 instanceId, address token)
        external onlyInstanceOwner(instanceId)
    {
        delete _tokenLimits[instanceId][token];
        address[] storage list = _instances[instanceId].tokenList;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == token) { list[i] = list[list.length-1]; list.pop(); break; }
        }
        emit TokenLimitRemoved(instanceId, token);
    }

    function addAllowedTarget(bytes32 instanceId, address target, bytes4[] calldata selectorList)
        external onlyInstanceOwner(instanceId)
    {
        require(target != address(0),               "Zero target");
        require(!_targetAllowed[instanceId][target],"Already allowed");
        _targetAllowed[instanceId][target] = true;
        _instances[instanceId].allowedTargets.push(target);
        for (uint256 i = 0; i < selectorList.length; i++) {
            if (!_selectorAllowed[instanceId][selectorList[i]]) {
                _selectorAllowed[instanceId][selectorList[i]] = true;
                _instances[instanceId].allowedSelectors.push(selectorList[i]);
            }
        }
        emit TargetAdded(instanceId, target);
    }

    function removeAllowedTarget(bytes32 instanceId, address target)
        external onlyInstanceOwner(instanceId)
    {
        require(_targetAllowed[instanceId][target], "Not allowed");
        _targetAllowed[instanceId][target] = false;
        address[] storage list = _instances[instanceId].allowedTargets;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == target) { list[i] = list[list.length-1]; list.pop(); break; }
        }
        emit TargetRemoved(instanceId, target);
    }

    function setExplorationBudget(bytes32 instanceId, uint256 budget, uint256 perTx)
        external onlyInstanceOwner(instanceId)
    {
        require(perTx <= budget, "perTx > budget");
        _instances[instanceId].explorationBudget = budget;
        _instances[instanceId].explorationPerTx  = perTx;
    }

    function setGlobalMaxPerDay(bytes32 instanceId, uint256 amount)
        external onlyInstanceOwner(instanceId)
    {
        require(amount > 0, "Zero amount");
        _instances[instanceId].globalMaxPerDay = amount;
    }

    function pauseInstance(bytes32 instanceId) external onlyInstanceOwner(instanceId) {
        _instances[instanceId].paused = true;
        emit InstancePaused(instanceId);
    }

    function unpauseInstance(bytes32 instanceId) external onlyInstanceOwner(instanceId) {
        _instances[instanceId].paused = false;
        emit InstanceUnpaused(instanceId);
    }

    // ── Instance views ─────────────────────────────────────────────────────

    function getInstance(bytes32 instanceId) external view returns (PolicyInstance memory) {
        require(_instances[instanceId].exists, "Instance not found");
        return _instances[instanceId];
    }

    function getTokenLimit(bytes32 instanceId, address token) external view returns (TokenLimit memory) {
        return _tokenLimits[instanceId][token];
    }

    function isAllowedTarget(bytes32 instanceId, address target) external view returns (bool) {
        return _targetAllowed[instanceId][target];
    }

    function isAllowedSelector(bytes32 instanceId, bytes4 selector) external view returns (bool) {
        return _selectorAllowed[instanceId][selector];
    }

    // ── Execute Key ────────────────────────────────────────────────────────

    function issueExecuteKey(bytes32 instanceId, bytes32 executeKeyHash, string calldata label)
        external onlyInstanceOwner(instanceId)
    {
        require(executeKeyHash != bytes32(0),              "Zero key hash");
        require(!_executeKeys[instanceId][executeKeyHash], "Key already exists");
        _executeKeys[instanceId][executeKeyHash] = true;
        emit ExecuteKeyIssued(instanceId, executeKeyHash, label);
    }

    function revokeExecuteKey(bytes32 instanceId, bytes32 executeKeyHash)
        external onlyInstanceOwner(instanceId)
    {
        require(_executeKeys[instanceId][executeKeyHash], "Key not found");
        _executeKeys[instanceId][executeKeyHash] = false;
        emit ExecuteKeyRevoked(instanceId, executeKeyHash);
    }

    function isValidExecuteKey(bytes32 instanceId, bytes32 executeKeyHash) external view returns (bool) {
        return _executeKeys[instanceId][executeKeyHash];
    }

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
    ) external onlyInstanceOwner(instanceId) returns (bytes32 sessionId) {
        PolicyInstance storage inst = _instances[instanceId];

        require(sessionKeyHash != bytes32(0),    "Zero session key");
        require(tokenIn  != address(0),          "Zero tokenIn");
        require(tokenOut != address(0),          "Zero tokenOut");
        require(maxAmountPerOp > 0,              "Zero maxAmountPerOp");
        require(totalBudget >= maxAmountPerOp,   "budget < maxPerOp");
        require(sessionExpiry > block.timestamp, "Expiry in past");
        require(sessionExpiry <= inst.expiry,    "Session outlives instance");

        // FIX (problem 3): check remaining global budget
        require(
            inst.globalTotalSpent + totalBudget <= inst.globalTotalBudget,
            "Exceeds remaining global budget"
        );

        bool inLimits      = _tokenLimits[instanceId][tokenOut].maxPerOp > 0;
        bool hasExploration = inst.explorationBudget > 0;
        require(inLimits || hasExploration, "tokenOut not permitted");

        if (inLimits) {
            require(
                maxAmountPerOp <= _tokenLimits[instanceId][tokenOut].maxPerOp,
                "Exceeds token limit"
            );
        } else {
            // tokenOut is an exploration token
            require(
                maxAmountPerOp <= inst.explorationPerTx,
                "Exceeds exploration per-tx"
            );
            // FIX (problem 3): also check remaining exploration budget
            require(
                inst.explorationSpent + totalBudget <= inst.explorationBudget,
                "Exceeds remaining exploration budget"
            );
        }

        sessionId = keccak256(abi.encodePacked(
            "sess", ++_sessionNonce, instanceId, block.chainid
        ));

        _sessions[sessionId] = SessionPolicy({
            instanceId:     instanceId,
            sessionKeyHash: sessionKeyHash,
            tokenIn:        tokenIn,
            tokenOut:       tokenOut,
            maxAmountPerOp: maxAmountPerOp,
            totalBudget:    totalBudget,
            totalSpent:     0,
            maxOpsPerDay:   maxOpsPerDay,
            dailyOps:       0,
            lastOpDay:      0,
            sessionExpiry:  sessionExpiry,
            active:         true,
            exists:         true
        });

        emit SessionCreated(sessionId, instanceId, msg.sender);
    }

    function revokeSession(bytes32 sessionId) external {
        SessionPolicy storage sess = _sessions[sessionId];
        require(sess.exists, "Session not found");
        require(_instances[sess.instanceId].owner == msg.sender, "Not instance owner");
        sess.active = false;
        emit SessionRevoked(sessionId);
    }

    function getSession(bytes32 sessionId) external view returns (SessionPolicy memory) {
        require(_sessions[sessionId].exists, "Session not found");
        return _sessions[sessionId];
    }

    function isActiveSession(bytes32 sessionId) external view returns (bool) {
        SessionPolicy storage sess = _sessions[sessionId];
        return sess.exists && sess.active && block.timestamp < sess.sessionExpiry;
    }

    // ── Validator: recordSpend ──────────────────────────────────────────────

    function recordSpend(
        bytes32 instanceId,
        bytes32 sessionId,
        address token,
        uint256 amount,
        bool    isExploration
    ) external onlyValidator {
        PolicyInstance storage inst = _instances[instanceId];
        uint256 today = block.timestamp / SECONDS_PER_DAY;

        // Daily reset
        if (inst.lastOpDay != today) {
            inst.globalDailySpent = 0;
            inst.lastOpDay        = today;
        }

        // Update global counters
        inst.globalTotalSpent += amount;
        inst.globalDailySpent += amount;
        inst.lastOpTimestamp   = block.timestamp;

        if (isExploration) {
            inst.explorationSpent += amount;
        } else {
            TokenLimit storage tl = _tokenLimits[instanceId][token];
            if (tl.lastOpDay != today) {
                tl.dailySpent = 0;
                tl.lastOpDay  = today;
            }
            tl.dailySpent += amount;
            tl.totalSpent += amount;
        }

        if (sessionId != bytes32(0)) {
            SessionPolicy storage sess = _sessions[sessionId];
            if (sess.lastOpDay != today) {
                sess.dailyOps  = 0;
                sess.lastOpDay = today;
            }
            sess.totalSpent += amount;
            sess.dailyOps   += 1;
        }

        emit PolicySpendUpdated(instanceId, sessionId, token, amount, isExploration);
    }

    // ── Validator fast-read helpers ─────────────────────────────────────────

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
    ) {
        PolicyInstance storage inst = _instances[instanceId];
        require(inst.exists, "Instance not found");
        return (
            inst.executeKeyHash,
            inst.explorationBudget,
            inst.explorationPerTx,
            inst.explorationSpent,
            inst.globalMaxPerDay,
            inst.globalTotalBudget,
            inst.globalTotalSpent,
            inst.globalDailySpent,
            inst.lastOpDay,
            inst.lastOpTimestamp,
            inst.expiry,
            inst.paused
        );
    }

    function getTokenLimitForValidation(bytes32 instanceId, address token) external view returns (
        uint256 maxPerOp,
        uint256 maxPerDay,
        uint256 dailySpent,
        uint256 lastOpDay
    ) {
        TokenLimit storage tl = _tokenLimits[instanceId][token];
        return (tl.maxPerOp, tl.maxPerDay, tl.dailySpent, tl.lastOpDay);
    }

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
    ) {
        SessionPolicy storage sess = _sessions[sessionId];
        require(sess.exists, "Session not found");
        return (
            sess.instanceId,
            sess.sessionKeyHash,
            sess.tokenIn,
            sess.tokenOut,
            sess.maxAmountPerOp,
            sess.totalBudget,
            sess.totalSpent,
            sess.maxOpsPerDay,
            sess.dailyOps,
            sess.lastOpDay,
            sess.sessionExpiry,
            sess.active
        );
    }
}
