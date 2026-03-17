// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountERC7579} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579.sol";
import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {SignerECDSA} from "@openzeppelin/contracts/utils/cryptography/signers/SignerECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {MODULE_TYPE_VALIDATOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @title  EchoAccount
/// @notice Concrete ERC-7579 smart account for Echo Protocol.
///
/// @dev    Inheritance chain:
///           EchoAccount
///             └── AccountERC7579   (ERC-7579 module management + execute)
///                   └── Account    (ERC-4337 validateUserOp, entryPoint)
///                         └── AbstractSigner (_rawSignatureValidation)
///             └── SignerECDSA      (ECDSA signature validation)
///             └── Ownable          (owner = user EOA wallet)
///             └── Initializable    (clone-safe init)
///
///         Deployment pattern (EIP-1167 clone + initialize):
///           1. Deploy EchoAccount as implementation contract (constructor sets
///              entryPoint and dummy signer — these are overwritten on initialize)
///           2. Factory clones implementation with CREATE2
///           3. clone.initialize(userWallet, echoValidator, instanceId)
///              → sets owner = userWallet
///              → sets ECDSA signer = userWallet
///              → installs EchoPolicyValidator as the sole validator module
///
///         Why userWallet as both owner and ECDSA signer:
///           - owner: manages PolicyInstance (pause, setTokenLimit, etc.)
///           - signer: signs UserOperations (MetaMask / WalletConnect)
///           Both are the same EOA in the MVP flow.
///
///         entryPoint() returns the canonical EntryPoint v0.7 address.
///         This is an immutable constant — same on all EVM chains.
contract EchoAccount is AccountERC7579, SignerECDSA, Ownable, Initializable {

    // ── Constants ──────────────────────────────────────────────────────────

    /// @dev Canonical ERC-4337 EntryPoint v0.7 — same address on all EVM chains.
    address private constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // ── Constructor ────────────────────────────────────────────────────────

    /// @dev Called once when the implementation contract is deployed.
    ///      Sets a zero signer and zero owner — only the implementation itself
    ///      is constructed this way. All clones use initialize() instead.
    ///
    ///      SignerECDSA constructor requires an address — we pass address(1)
    ///      as a harmless placeholder that is overwritten on initialize().
    ///      Ownable constructor requires an address — we pass address(1) too.
    ///
    ///      _disableInitializers() prevents the implementation itself from
    ///      being initialized (a standard proxy security practice).
    constructor() SignerECDSA(address(1)) Ownable(address(1)) {
        _disableInitializers();
    }

    // ── Initializer (called on each clone) ────────────────────────────────

    /// @notice Initialize this account for a specific user.
    ///         Called by EchoAccountFactory immediately after CREATE2 clone deployment.
    ///
    /// @param  userWallet   The user's EOA. Becomes Ownable owner AND ECDSA signer.
    /// @param  validator    Address of EchoPolicyValidator.
    /// @param  instanceId   The PolicyInstance ID registered in PolicyRegistry.
    ///                      Passed as initData to validator.onInstall().
    function initialize(
        address userWallet,
        address validator,
        bytes32 instanceId
    ) external initializer {
        require(userWallet != address(0), "EchoAccount: zero wallet");
        require(validator  != address(0), "EchoAccount: zero validator");
        require(instanceId != bytes32(0), "EchoAccount: zero instanceId");

        // Set ECDSA signer = user EOA (signs UserOperations)
        _setSigner(userWallet);

        // Set Ownable owner = user EOA (manages PolicyInstance from MetaMask)
        _transferOwnership(userWallet);

        // Install EchoPolicyValidator as the sole validator module.
        // This calls validator.onInstall(abi.encode(instanceId)).
        // onInstall checks: IOwnable(address(this)).owner() == inst.owner
        //   → userWallet == userWallet ✓
        _installModule(
            MODULE_TYPE_VALIDATOR,
            validator,
            abi.encode(instanceId)
        );
    }

    // ── entryPoint override ────────────────────────────────────────────────

    /// @dev Return the canonical EntryPoint v0.7 address.
    ///      Account.sol declares this as virtual — we must override it.
    ///      Using a constant avoids a storage slot and is gas-efficient.
    function entryPoint() public pure override returns (IEntryPoint) {
        return IEntryPoint(ENTRY_POINT_V07);
    }

    // ── Signature validation ───────────────────────────────────────────────

    /// @dev AbstractSigner requires this to be implemented.
    ///      SignerECDSA provides the ECDSA implementation — we just forward.
    ///      The account validates UserOp signatures using the stored signer (userWallet).
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature)
        internal view override(AccountERC7579, SignerECDSA)
        returns (bool)
    {
        return SignerECDSA._rawSignatureValidation(hash, signature);
    }
}
