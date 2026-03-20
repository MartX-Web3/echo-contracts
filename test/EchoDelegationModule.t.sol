// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../src/EchoPolicyValidator.sol";
import "../src/modules/EchoDelegationModule.sol";
import "../src/PolicyRegistry.sol";
import "../src/IntentRegistry.sol";
import "../src/interfaces/IPolicyRegistry.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockSwapRouter.sol";

/// @dev Local alias to avoid importing OZ `IERC4337` alongside `EchoPolicyValidator`'s `PackedUserOperation` struct.
interface IAccountValidateUserOp {
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256);
}

/// @notice EIP-7702 hybrid path: EOA delegates to {EchoDelegationModule}, policy via {EchoPolicyValidator-validateFor7702}.
contract EchoDelegationModuleTest is Test {

    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    PolicyRegistry      internal registry;
    IntentRegistry      internal intentReg;
    EchoPolicyValidator internal validator;
    EchoDelegationModule internal delegation;

    uint256 internal ownerPk = 0xA11CE;
    address internal owner;

    address internal echoAdmin = makeAddr("echoAdmin");

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockSwapRouter internal router;

    bytes4 internal constant EIS = bytes4(0x414bf389);

    uint256 internal constant DAY = 86400;

    bytes32 internal templateId;
    bytes32 internal instanceId;
    bytes32 internal rawExecKey = keccak256("execKey7702");
    bytes32 internal execKeyHash;

    function setUp() public {
        owner = vm.addr(ownerPk);

        registry  = new PolicyRegistry(echoAdmin);
        intentReg = new IntentRegistry();
        validator = new EchoPolicyValidator(address(registry), address(intentReg));
        delegation = new EchoDelegationModule(validator);

        vm.prank(echoAdmin);
        registry.setValidator(address(validator));

        vm.prank(echoAdmin);
        templateId = registry.createTemplate(
            "Standard", 100e6, 500e6, 50e6, 10e6, 1000e6, 5000e6, uint64(90 * DAY)
        );

        execKeyHash = keccak256(abi.encode(rawExecKey));

        weth   = new MockERC20("WETH", "WETH", 18);
        usdc   = new MockERC20("USDC", "USDC", 6);
        router = new MockSwapRouter(address(weth), address(usdc));

        address[] memory tokens  = _a2(address(weth), address(usdc));
        uint256[] memory perOps  = _u2(100e18, 500e6);
        uint256[] memory perDays = _u2(500e18, 2000e6);
        address[] memory targets = _a1(address(router));
        bytes4[]  memory sels    = _s2(EIS, bytes4(0x4aa4a4fa));

        vm.prank(owner);
        instanceId = registry.registerInstanceStruct(
            IPolicyRegistry.InstanceRegistration({
                owner:             owner,
                templateId:        templateId,
                executeKeyHash:    execKeyHash,
                initialTokens:     tokens,
                maxPerOps:         perOps,
                maxPerDays:        perDays,
                targets:           targets,
                selectors:         sels,
                explorationBudget: 50e6,
                explorationPerTx:  10e6,
                globalMaxPerDay:   1000e18,
                globalTotalBudget: 5000e18,
                expiry:            uint64(block.timestamp + 90 * DAY)
            })
        );

        vm.prank(owner);
        validator.registerEip7702(instanceId);

        vm.signAndAttachDelegation(address(delegation), ownerPk);
        vm.warp(block.timestamp + 2);
    }

    function _innerSwap(
        address tIn,
        address tOut,
        uint256 amt,
        address rec
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            EIS,
            tIn,
            tOut,
            uint24(3000),
            rec,
            block.timestamp + 100,
            amt,
            uint256(0),
            uint160(0)
        );
    }

    function _executeCD(
        address target,
        address tIn,
        address tOut,
        uint256 amt,
        address rec
    ) internal view returns (bytes memory) {
        bytes memory innerSwap = _innerSwap(tIn, tOut, amt, rec);
        bytes memory execData   = abi.encodePacked(target, uint256(0), innerSwap);
        return abi.encodeWithSelector(bytes4(keccak256("execute(bytes32,bytes)")), bytes32(0), execData);
    }

    function _sig7702(bytes32 k) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x03), k);
    }

    bytes32 internal rawSessKey = keccak256("sessKey7702");

    function _sessSig(bytes32 sessionId, bytes32 rawKey) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), sessionId, rawKey);
    }

    function _createSession() internal returns (bytes32 sessionId) {
        vm.prank(owner);
        sessionId = registry.createSession(
            instanceId,
            keccak256(abi.encode(rawSessKey)),
            address(usdc),
            address(weth),
            50e6,
            350e6,
            2,
            uint64(block.timestamp + 7 * DAY)
        );
    }

    /// @dev USDC→WETH swap calldata with `recipient = owner` (session token pair).
    function _sessionSwapCd(uint256 amtUsdc) internal view returns (bytes memory) {
        return _executeCD(address(router), address(usdc), address(weth), amtUsdc, owner);
    }

    function _op(bytes memory cd, bytes memory sig)
        internal view returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: owner,
            nonce: 0,
            initCode: "",
            callData: cd,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }

    function test_registerEip7702_setsInstance() public view {
        assertEq(validator.getAccountInstance(owner), instanceId);
    }

    function test_validateUserOp_happy() public {
        // tokenIn=USDC amountIn uses 6 decimals; policy bucket is tokenOut (WETH) — matches EchoPolicyValidator tests.
        bytes memory cd = _executeCD(address(router), address(usdc), address(weth), 100e6, owner);
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(_op(cd, _sig7702(rawExecKey)), bytes32(0), 0);
        assertEq(vd, 0);
    }

    function test_validateUserOp_budgetExceeded_fails() public {
        bytes memory cd = _executeCD(address(router), address(weth), address(usdc), 200e18, owner);
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(_op(cd, _sig7702(rawExecKey)), bytes32(0), 0);
        assertEq(vd, 1);
    }

    function test_validateUserOp_wrongUserOpSender_reverts() public {
        bytes memory cd = _executeCD(address(router), address(usdc), address(weth), 100e6, owner);
        PackedUserOperation memory op = _op(cd, _sig7702(rawExecKey));
        op.sender = makeAddr("notOwner");
        vm.prank(ENTRY_POINT_V07);
        vm.expectRevert(EchoDelegationModule.EchoDelegationSenderMismatch.selector);
        IAccountValidateUserOp(payable(owner)).validateUserOp(op, bytes32(0), 0);
    }

    function test_validateFor7702_wrongCaller_fails() public {
        bytes memory cd = _executeCD(address(router), address(usdc), address(weth), 100e6, owner);
        PackedUserOperation memory op = _op(cd, _sig7702(rawExecKey));
        vm.prank(makeAddr("attacker"));
        uint256 vd = validator.validateFor7702(op, bytes32(0));
        assertEq(vd, 1);
    }

    function test_validateUserOp_session_pass() public {
        bytes32 sid = _createSession();
        bytes memory cd = _sessionSwapCd(50e6);
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(_op(cd, _sessSig(sid, rawSessKey)), bytes32(0), 0);
        assertEq(vd, 0);
    }

    function test_validateUserOp_session_badKey_fails() public {
        bytes32 sid = _createSession();
        bytes memory cd = _sessionSwapCd(50e6);
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(
            _op(cd, _sessSig(sid, keccak256("wrong"))), bytes32(0), 0
        );
        assertEq(vd, 1);
    }

    function test_validateUserOp_session_sigTooShort_fails() public {
        bytes memory cd = _sessionSwapCd(50e6);
        bytes memory badSig = abi.encodePacked(uint8(0x02), bytes32(uint256(1))); // 33 bytes, missing raw key
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(_op(cd, badSig), bytes32(0), 0);
        assertEq(vd, 1);
    }

    function test_validateUserOp_modeRealtime01_rejected() public {
        bytes memory cd = _executeCD(address(router), address(usdc), address(weth), 100e6, owner);
        bytes memory sig = abi.encodePacked(uint8(0x01), rawExecKey);
        vm.prank(ENTRY_POINT_V07);
        uint256 vd = IAccountValidateUserOp(payable(owner)).validateUserOp(_op(cd, sig), bytes32(0), 0);
        assertEq(vd, 1);
    }

    function test_execute_swap_pullsFromEoa_notFromImplementation() public {
        uint256 amt = 1e18;
        weth.mint(owner, amt);
        vm.prank(owner);
        weth.approve(address(router), amt);

        assertEq(weth.balanceOf(owner), amt);
        assertEq(weth.balanceOf(address(delegation)), 0);

        MockSwapRouter.ExactInputSingleParams memory p = MockSwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: uint24(3000),
            recipient: owner,
            amountIn: amt,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        bytes memory inner = abi.encodeCall(MockSwapRouter.exactInputSingle, (p));
        bytes memory execData = abi.encodePacked(address(router), uint256(0), inner);

        vm.prank(ENTRY_POINT_V07);
        EchoDelegationModule(payable(owner)).execute(bytes32(0), execData);

        assertLt(weth.balanceOf(owner), amt);
        assertGt(usdc.balanceOf(owner), 0);
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
