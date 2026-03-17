// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";

/// @dev Minimal interface for EchoAccount clones.
interface IEchoAccount {
    function initialize(address userWallet, address validator, bytes32 instanceId) external;
    function owner() external view returns (address);
}

/// @title  EchoAccountFactory
/// @notice Deploys an EchoAccount clone and registers a PolicyInstance
///         in a single transaction.
///
/// @dev    One-transaction setup flow:
///
///         1. Compute deterministic accountAddress via CREATE2 (not yet deployed).
///         2. registry.registerInstanceFor(userWallet, ...)
///              → inst.owner = userWallet
///         3. Deploy EIP-1167 clone of EchoAccount implementation via CREATE2.
///         4. clone.initialize(userWallet, validator, instanceId)
///              → _setSigner(userWallet)
///              → _transferOwnership(userWallet)
///              → _installModule(validator, instanceId)
///                → validator.onInstall(instanceId)
///                → onInstall: IOwnable(clone).owner() = userWallet = inst.owner ✓
contract EchoAccountFactory {

    // ── Immutables ─────────────────────────────────────────────────────────

    IPolicyRegistry public immutable registry;
    address         public immutable validator;
    address         public immutable implementation;

    // ── Events ─────────────────────────────────────────────────────────────

    event AccountCreated(
        address indexed account,
        address indexed userWallet,
        bytes32 indexed instanceId
    );

    // ── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _registry,
        address _validator,
        address _implementation
    ) {
        require(_registry       != address(0), "Zero registry");
        require(_validator      != address(0), "Zero validator");
        require(_implementation != address(0), "Zero implementation");
        registry       = IPolicyRegistry(_registry);
        validator      = _validator;
        implementation = _implementation;
    }

    // ── createAccount ──────────────────────────────────────────────────────

    function createAccount(
        IPolicyRegistry.InstanceRegistration calldata r,
        bytes32 salt
    ) external returns (address account, bytes32 instanceId) {
        require(r.owner != address(0), "Zero userWallet");

        bytes32 create2Salt = _salt(r.owner, salt);
        account = _computeAddress(create2Salt);

        instanceId = registry.registerInstanceForStruct(r);

        if (account.code.length == 0) {
            account = _deploy(create2Salt);
        }

        IEchoAccount(account).initialize(r.owner, validator, instanceId);

        emit AccountCreated(account, r.owner, instanceId);
    }

    // ── getAddress ─────────────────────────────────────────────────────────

    function getAddress(address userWallet, bytes32 salt)
        external view returns (address)
    {
        return _computeAddress(_salt(userWallet, salt));
    }

    // ── Internal ───────────────────────────────────────────────────────────

    function _salt(address userWallet, bytes32 salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(userWallet, salt));
    }

    function _computeAddress(bytes32 create2Salt)
        internal view returns (address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                create2Salt,
                keccak256(_cloneBytecode())
            )
        );
        return address(uint160(uint256(hash)));
    }

    function _deploy(bytes32 create2Salt)
        internal returns (address account)
    {
        bytes memory bytecode = _cloneBytecode();
        assembly {
            account := create2(0, add(bytecode, 0x20), mload(bytecode), create2Salt)
        }
        require(account != address(0), "CREATE2 failed");
    }

    function _cloneBytecode() internal view returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
