// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {
    ERC7579Utils,
    Mode,
    CallType,
    ExecType
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";

import {EchoPolicyValidator, PackedUserOperation} from "../EchoPolicyValidator.sol";

/// @title  EchoDelegationModule
/// @notice EIP-7702 delegation target: minimal ERC-4337 account + ERC-7579-style `execute` encoding.
/// @dev    When an EOA authorizes this implementation, `address(this)` during execution is the EOA.
///         Policy enforcement is delegated to {EchoPolicyValidator-validateFor7702} (signature `0x03` realtime, `0x02` session).
///         Uses the same `PackedUserOperation` definition as {EchoPolicyValidator} (OZ-compatible layout).
///
///         **Product note:** Keeps ERC-20 swap balances on the user EOA while using ERC-4337 + paymaster.
///         A separate contract account as 4337 sender would see `msg.sender` = that contract at the router,
///         so standard Uniswap pulls would not debit the EOA without EIP-7702 (or a custom router).
contract EchoDelegationModule {
    using ERC7579Utils for bytes;
    using ERC7579Utils for Mode;

    /// @dev Canonical ERC-4337 EntryPoint v0.7.
    address private constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    EchoPolicyValidator public immutable validator;

    error EchoDelegationNotEntryPoint();
    error EchoDelegationSenderMismatch();
    error EchoDelegationUnsupportedCallType();

    constructor(EchoPolicyValidator _validator) {
        require(address(_validator) != address(0), "EchoDelegation: zero validator");
        validator = _validator;
    }

    function entryPoint() external pure returns (address) {
        return ENTRY_POINT_V07;
    }

    /// @dev ERC-4337 `IAccount.validateUserOp` selector-compatible entry.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != ENTRY_POINT_V07) revert EchoDelegationNotEntryPoint();
        if (address(this) != userOp.sender) revert EchoDelegationSenderMismatch();

        if (missingAccountFunds > 0) {
            LowLevelCall.callNoReturn(msg.sender, missingAccountFunds, "");
        }
        return validator.validateFor7702(userOp, userOpHash);
    }

    /// @notice Same encoding as OpenZeppelin `AccountERC7579.execute` (single call only in MVP).
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable {
        if (msg.sender != ENTRY_POINT_V07) revert EchoDelegationNotEntryPoint();

        (CallType callType, ExecType execType, , ) = Mode.wrap(mode).decodeMode();
        if (CallType.unwrap(callType) != CallType.unwrap(ERC7579Utils.CALLTYPE_SINGLE)) {
            revert EchoDelegationUnsupportedCallType();
        }

        executionCalldata.execSingle(execType);
    }

    receive() external payable {}
}
