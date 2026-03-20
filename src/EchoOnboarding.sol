// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IPolicyRegistry.sol";
import "./EchoPolicyValidator.sol";

/// @title  EchoOnboarding
/// @notice One transaction for EIP-7702 users: register `PolicyInstance` + `registerEip7702` binding.
/// @dev    Requires `PolicyRegistry.setOnboarding(address(this))` and
///         `EchoPolicyValidator.setEip7702Onboarding(address(this))` once after deploy (registry owner).
///         User calls with `r.owner == msg.sender`; tokens stay on the EOA; follow with EIP-7702 auth + UserOp.
contract EchoOnboarding {

    IPolicyRegistry public immutable registry;
    EchoPolicyValidator public immutable validator;

    error EchoOnboardingZeroAddress();
    error EchoOnboardingOwnerMismatch();

    constructor(IPolicyRegistry _registry, EchoPolicyValidator _validator) {
        if (address(_registry) == address(0) || address(_validator) == address(0)) {
            revert EchoOnboardingZeroAddress();
        }
        registry  = _registry;
        validator = _validator;
    }

    /// @return instanceId New policy instance bound to `msg.sender` for `validateFor7702` (mode `0x03`).
    function registerInstanceAndEip7702(IPolicyRegistry.InstanceRegistration calldata r)
        external
        returns (bytes32 instanceId)
    {
        if (r.owner != msg.sender) revert EchoOnboardingOwnerMismatch();
        instanceId = registry.registerInstanceStructAsOnboarding(r);
        validator.registerEip7702For(msg.sender, instanceId);
    }
}
