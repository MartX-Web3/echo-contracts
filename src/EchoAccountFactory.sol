// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";

/// @dev Minimal interfaces for OZ AccountERC7579 and related contracts.
///      Full implementations come from the OZ dependency.

interface IEntryPoint {
    function getSenderAddress(bytes memory initCode) external;
}

/// @dev OZ AccountERC7579 bootstrap configuration.
struct BootstrapConfig {
    address module;
    bytes   initData;
}

/// @dev OZ ERC7579Bootstrap — sets up modules via delegatecall during init.
interface IBootstrap {
    function singleValidator(BootstrapConfig calldata validator)
        external view returns (bytes memory);
}

/// @dev OZ AccountERC7579 — ERC-4337 smart account with ERC-7579 modules.
interface IAccountERC7579 {
    function initialize(address owner, address bootstrap, bytes calldata bootstrapData) external;
}

/// @title  EchoAccountFactory
/// @notice Deploys an OZ AccountERC7579 and registers a PolicyInstance
///         in a single transaction.
///
/// @dev    One-transaction setup flow:
///
///         1. Compute deterministic accountAddress via CREATE2 (not yet deployed).
///         2. Call registry.registerInstanceForStruct(...) — inst.owner = userWallet.
///            NOTE: we do NOT use accountAddress as owner. The user EOA wallet
///            is the policy owner so they can manage it from MetaMask/Dashboard.
///            We pass accountAddress only to derive the instanceId deterministically.
///         3. Deploy AccountERC7579 with CREATE2:
///            - owner = userWallet (OZ Ownable)
///            - bootstrap = ERC7579Bootstrap.singleValidator(EchoPolicyValidator, instanceId)
///            - Bootstrap runs via delegatecall, calling validator.onInstall(instanceId)
///            - onInstall checks: IOwnable(account).owner() == inst.owner
///              → userWallet == userWallet ✓
///         4. Return accountAddress.
///
///         Deterministic address: same inputs → same address, always.
///         If the account already exists (re-call), createAccount returns the
///         existing address without re-deploying (standard CREATE2 behavior).
///
///         ERC-7562 note: Factory is listed as a "staked factory" in ERC-4337.
///         For Sepolia testnet, Pimlico accepts unstaked factories. For mainnet,
///         this factory must be staked with the EntryPoint.
contract EchoAccountFactory {

    /// @notice Parameters for `createAccount`.
    /// @dev    Bundled into a struct to avoid "stack too deep" with many arguments.
    struct CreateAccountParams {
        IPolicyRegistry.InstanceRegistration registration;
        bytes32 salt;
    }

    // ── Immutables ─────────────────────────────────────────────────────────

    IPolicyRegistry  public immutable registry;
    address          public immutable validator;       // EchoPolicyValidator
    address          public immutable implementation;  // AccountERC7579 logic contract
    IBootstrap       public immutable bootstrap;       // ERC7579Bootstrap
    address          public immutable entryPoint;      // ERC-4337 EntryPoint v0.7

    // ── Events ─────────────────────────────────────────────────────────────

    event AccountCreated(
        address indexed account,
        address indexed owner,
        bytes32 indexed instanceId
    );

    // ── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _registry,
        address _validator,
        address _implementation,
        address _bootstrap,
        address _entryPoint
    ) {
        require(_registry       != address(0), "Zero registry");
        require(_validator      != address(0), "Zero validator");
        require(_implementation != address(0), "Zero implementation");
        require(_bootstrap      != address(0), "Zero bootstrap");
        require(_entryPoint     != address(0), "Zero entryPoint");

        registry       = IPolicyRegistry(_registry);
        validator      = _validator;
        implementation = _implementation;
        bootstrap      = IBootstrap(_bootstrap);
        entryPoint     = _entryPoint;
    }

    // ── createAccount ──────────────────────────────────────────────────────

    /// @notice Deploy an Echo smart account in one transaction.
    ///
    /// @param p Parameters bundle:
    ///        - p.registration.owner             User EOA wallet (PolicyInstance owner + Account owner)
    ///        - p.registration.templateId        PolicyTemplate ID
    ///        - p.registration.executeKeyHash    keccak256(rawExecuteKey)
    ///        - p.registration.initialTokens     Tokens to pre-configure with limits
    ///        - p.registration.maxPerOps         Per-token per-op limits
    ///        - p.registration.maxPerDays        Per-token daily limits
    ///        - p.registration.targets           Allowed target contracts
    ///        - p.registration.selectors         Allowed function selectors
    ///        - p.registration.explorationBudget Exploration budget for unlisted tokens
    ///        - p.registration.explorationPerTx  Per-tx cap within exploration budget
    ///        - p.registration.globalMaxPerDay   Global daily cap
    ///        - p.registration.globalTotalBudget Global lifetime cap
    ///        - p.registration.expiry            Instance expiry timestamp
    ///        - p.salt                           User-provided salt for CREATE2 determinism
    ///
    /// @return account     The deployed (or already-deployed) smart account address.
    /// @return instanceId  The registered PolicyInstance ID.
    function createAccount(CreateAccountParams calldata p)
        external
        returns (address account, bytes32 instanceId)
    {
        address userWallet = p.registration.owner;
        require(userWallet != address(0), "Zero userWallet");

        // ── Step 1: Register PolicyInstance (owner = userWallet) ──────────
        // registerInstanceFor is onlyFactory — only this contract can call it.
        // inst.owner = userWallet so the user can manage their policy from EOA.
        instanceId = registry.registerInstanceForStruct(p.registration);

        // ── Step 2: Compute deterministic account address ──────────────────
        bytes32 create2Salt = _computeSalt(userWallet, p.salt);
        account = _computeAddress(create2Salt);

        // ── Step 3: Deploy AccountERC7579 if not already deployed ──────────
        if (account.code.length == 0) {
            // Build bootstrap calldata: install EchoPolicyValidator as the
            // sole validator, passing instanceId as initData.
            // Bootstrap runs via delegatecall during account initialization,
            // which means msg.sender to onInstall = account address.
            // onInstall verifies: IOwnable(account).owner() == inst.owner
            //   → userWallet == userWallet ✓
            bytes memory bootstrapData = bootstrap.singleValidator(
                BootstrapConfig({
                    module:   validator,
                    initData: abi.encode(instanceId)
                })
            );

            // Deploy via CREATE2 using minimal proxy (EIP-1167 clone) of implementation
            account = _deploy(create2Salt, userWallet, bootstrapData);
        }

        emit AccountCreated(account, userWallet, instanceId);
    }

    // ── getAddress ─────────────────────────────────────────────────────────

    /// @notice Compute the deterministic address for a given owner + salt.
    ///         Returns the same address before and after deployment.
    function getAddress(address userWallet, bytes32 salt)
        external view returns (address)
    {
        return _computeAddress(_computeSalt(userWallet, salt));
    }

    // ── Internal ───────────────────────────────────────────────────────────

    /// @dev Combine userWallet and user-provided salt into a single CREATE2 salt.
    ///      Including userWallet in the salt ensures different users always get
    ///      different addresses even if they pass the same salt.
    function _computeSalt(address userWallet, bytes32 salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(userWallet, salt));
    }

    /// @dev Compute CREATE2 address for an EIP-1167 clone of `implementation`.
    function _computeAddress(bytes32 create2Salt)
        internal view returns (address)
    {
        // EIP-1167 minimal proxy bytecode (45 bytes):
        bytes memory initCode = _cloneInitCode(implementation);
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), create2Salt, keccak256(initCode))
        );
        return address(uint160(uint256(hash)));
    }

    /// @dev Deploy an EIP-1167 clone of `implementation` and initialize it.
    function _deploy(bytes32 create2Salt, address userWallet, bytes memory bootstrapData)
        internal returns (address account)
    {
        bytes memory initCode = _cloneInitCode(implementation);
        assembly {
            account := create2(0, add(initCode, 0x20), mload(initCode), create2Salt)
        }
        require(account != address(0), "CREATE2 failed");

        // Initialize the account: set owner and install modules via bootstrap
        IAccountERC7579(account).initialize(userWallet, address(bootstrap), bootstrapData);
    }

    /// @dev EIP-1167 minimal proxy initCode for a given implementation address.
    ///      Returns the 55-byte creation code that deploys a clone proxy.
    function _cloneInitCode(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
