// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/EchoPolicyValidator.sol";
import "../src/EchoOnboarding.sol";
import "../src/interfaces/IPolicyRegistry.sol";

contract EchoOnboardingTest is Test {

    PolicyRegistry      registry;
    IntentRegistry      intentReg;
    EchoPolicyValidator validator;
    EchoOnboarding      onboarding;

    address echoAdmin = makeAddr("echoAdmin");
    address user        = makeAddr("user");

    bytes32 templateId;
    bytes32 execKeyHash = keccak256(abi.encode(keccak256("k")));

    address USDC = makeAddr("USDC");
    address WETH = makeAddr("WETH");
    address ROUTER = makeAddr("router");
    bytes4 constant EIS = bytes4(0x414bf389);
    bytes4 constant EOS = bytes4(0x4aa4a4fa);

    function setUp() public {
        registry  = new PolicyRegistry(echoAdmin);
        intentReg = new IntentRegistry();
        validator = new EchoPolicyValidator(address(registry), address(intentReg));
        onboarding = new EchoOnboarding(registry, validator);

        vm.prank(echoAdmin);
        registry.setValidator(address(validator));
        vm.prank(echoAdmin);
        registry.setOnboarding(address(onboarding));
        vm.prank(echoAdmin);
        validator.setEip7702Onboarding(address(onboarding));

        vm.prank(echoAdmin);
        templateId = registry.createTemplate(
            "Std", 100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(block.timestamp + 86400 * 90)
        );
    }

    function test_registerInstanceAndEip7702_bindsUser() public {
        address[] memory tokens  = _a2(WETH, USDC);
        uint256[] memory perOps  = _u2(100e6, 100e6);
        uint256[] memory perDays = _u2(500e6, 500e6);

        vm.prank(user);
        bytes32 iid = onboarding.registerInstanceAndEip7702(
            IPolicyRegistry.InstanceRegistration({
                owner:             user,
                templateId:        templateId,
                executeKeyHash:    execKeyHash,
                initialTokens:     tokens,
                maxPerOps:         perOps,
                maxPerDays:        perDays,
                targets:           _a1(ROUTER),
                selectors:         _s2(EIS, EOS),
                explorationBudget: 50e6,
                explorationPerTx:  10e6,
                globalMaxPerDay:   1000e6,
                globalTotalBudget: 5000e6,
                expiry:            uint64(block.timestamp + 86400 * 90)
            })
        );

        assertEq(registry.getInstance(iid).owner, user);
        assertEq(validator.getAccountInstance(user), iid);
    }

    function test_setEip7702Onboarding_twice_reverts() public {
        vm.prank(echoAdmin);
        vm.expectRevert("Onboarding already set or zero");
        validator.setEip7702Onboarding(makeAddr("x"));
    }

    function test_registerInstanceAndEip7702_wrongOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(EchoOnboarding.EchoOnboardingOwnerMismatch.selector);
        onboarding.registerInstanceAndEip7702(
            IPolicyRegistry.InstanceRegistration({
                owner:             makeAddr("other"),
                templateId:        templateId,
                executeKeyHash:    execKeyHash,
                initialTokens:     _a2(WETH, USDC),
                maxPerOps:         _u2(1, 1),
                maxPerDays:        _u2(1, 1),
                targets:           _a1(ROUTER),
                selectors:         _s2(EIS, EOS),
                explorationBudget: 1,
                explorationPerTx:  1,
                globalMaxPerDay:   1,
                globalTotalBudget: 2,
                expiry:            uint64(block.timestamp + 86400)
            })
        );
    }

    function _a1(address a) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = a;
    }

    function _a2(address a, address b) internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = a;
        m[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = a;
        m[1] = b;
    }

    function _s2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory m) {
        m = new bytes4[](2);
        m[0] = a;
        m[1] = b;
    }
}
