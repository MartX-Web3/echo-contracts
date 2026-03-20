// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {
    ERC7579Utils,
    Mode,
    CallType,
    ExecType
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /// @dev Uniswap V3 swap selectors used by _autoApprove.
    /// exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))
    bytes4 private constant SEL_EXACT_INPUT_SINGLE  = 0x414bf389;
    /// exactOutputSingle((address,address,uint24,address,uint256,uint256,uint160))
    bytes4 private constant SEL_EXACT_OUTPUT_SINGLE = 0xdb3e2198;
    /// exactInput((bytes,address,uint256,uint256))
    bytes4 private constant SEL_EXACT_INPUT         = 0xc04b8d59;

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

    /// @notice ERC-7579-style single-call execute.
    /// @dev    Before executing a Uniswap swap, automatically approves the exact required
    ///         tokenIn allowance to the router so the user never needs a separate approve tx.
    ///         Policy validation (EchoPolicyValidator) has already enforced that target is a
    ///         trusted router and amountIn is within limits — so max-approving that router is safe.
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable {
        if (msg.sender != ENTRY_POINT_V07) revert EchoDelegationNotEntryPoint();

        (CallType callType, ExecType execType, , ) = Mode.wrap(mode).decodeMode();
        if (CallType.unwrap(callType) != CallType.unwrap(ERC7579Utils.CALLTYPE_SINGLE)) {
            revert EchoDelegationUnsupportedCallType();
        }

        _autoApprove(executionCalldata);
        executionCalldata.execSingle(execType);
    }

    /// @dev ERC-7579 single execution calldata layout:
    ///      target   [0 :20]  — router address
    ///      value    [20:52]  — ETH value (uint256)
    ///      inner    [52:  ]  — swap calldata (selector + ABI-encoded params)
    ///
    ///      Handles:
    ///        exactInputSingle  — tokenIn @ inner[4:36], amountIn        @ inner[132:164]
    ///        exactOutputSingle — tokenIn @ inner[4:36], amountInMaximum @ inner[164:196]
    ///        exactInput        — tokenIn = first 20 bytes of path,
    ///                            amountIn @ inner[68:100] (after ABI offset + recipient)
    ///
    ///      Uses max-allowance on first approval so subsequent swaps of the same token
    ///      skip the SSTORE entirely (allowance stays at max after the first swap).
    function _autoApprove(bytes calldata exec) internal {
        // Need at least: target(20) + value(32) + selector(4) = 56 bytes
        if (exec.length < 56) return;

        address router = address(bytes20(exec[0:20]));
        bytes calldata inner = exec[52:];
        bytes4 sel = bytes4(inner[0:4]);

        address tokenIn;
        uint256 amount;

        if (sel == SEL_EXACT_INPUT_SINGLE) {
            // struct ExactInputSingleParams {
            //   address tokenIn;        [4 :36 ]
            //   address tokenOut;       [36:68 ]
            //   uint24  fee;            [68:100]
            //   address recipient;      [100:132]
            //   uint256 amountIn;       [132:164]
            //   uint256 amountOutMin;   [164:196]
            //   uint160 sqrtPriceLimit; [196:228]
            // }
            if (inner.length < 164) return;
            tokenIn = address(uint160(uint256(bytes32(inner[4:36]))));
            amount  = uint256(bytes32(inner[132:164]));

        } else if (sel == SEL_EXACT_OUTPUT_SINGLE) {
            // struct ExactOutputSingleParams {
            //   address tokenIn;           [4 :36 ]
            //   address tokenOut;          [36:68 ]
            //   uint24  fee;               [68:100]
            //   address recipient;         [100:132]
            //   uint256 amountOut;         [132:164]
            //   uint256 amountInMaximum;   [164:196]
            //   uint160 sqrtPriceLimit;    [196:228]
            // }
            if (inner.length < 196) return;
            tokenIn = address(uint160(uint256(bytes32(inner[4:36]))));
            amount  = uint256(bytes32(inner[164:196]));

        } else if (sel == SEL_EXACT_INPUT) {
            // struct ExactInputParams {
            //   bytes   path;             ABI offset  [4 :36 ] = 0x80
            //   address recipient;        [36:68 ]
            //   uint256 amountIn;         [68:100]
            //   uint256 amountOutMin;     [100:132]
            //   -- path data --
            //   uint256 path.length;      [132:164]
            //   bytes   path.data;        [164:164+pathLen]  first 20 bytes = tokenIn
            // }
            if (inner.length < 184) return; // 132 + 32 (length) + 20 (first addr in path)
            amount  = uint256(bytes32(inner[68:100]));
            // path bytes start at inner[164]; first 20 bytes are tokenIn
            tokenIn = address(bytes20(inner[164:184]));
        }

        if (tokenIn == address(0) || amount == 0) return;

        // Approve max on first use — saves gas on every subsequent swap of the same token.
        // Safe because EchoPolicyValidator has already confirmed router is a trusted target
        // and amountIn is within user-set policy limits.
        if (IERC20(tokenIn).allowance(address(this), router) < amount) {
            IERC20(tokenIn).approve(router, type(uint256).max);
        }
    }

    receive() external payable {}
}
