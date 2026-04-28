// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Vm.sol";
import {LedgerTestBase} from "./utils/LedgerTestBase.t.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {SignUtil} from "./utils/SignUtil.sol";
import {CelerLedger} from "../src/CelerLedger.sol";
import {CelerWallet} from "../src/CelerWallet.sol";
import {EthPool} from "../src/EthPool.sol";
import {PayRegistry} from "../src/PayRegistry.sol";
import {PayResolver} from "../src/PayResolver.sol";
import {VirtContractResolver} from "../src/VirtContractResolver.sol";
import {BooleanCondMock} from "../src/helper/BooleanCondMock.sol";

/**
 * @title Gas report generator
 * @notice Produces human-readable gas reports under [`gas_logs/`](../gas_logs/),
 *  one file per top-level component. Each report lists per-call gas for the
 *  operations a reviewer typically cares about; `fine_granularity/` adds scaling
 *  sweeps for the operations whose cost is parameterized (pay-list size, batch
 *  size).
 *
 * @dev Top-level reports (per-call gas):
 *  - `gas_logs/CelerLedger-ETH.txt`
 *  - `gas_logs/CelerLedger-ERC20.txt`
 *  - `gas_logs/CelerLedger-Migrate.txt`
 *  - `gas_logs/EthPool.txt`
 *  - `gas_logs/PayResolver.txt`
 *  - `gas_logs/VirtContractResolver.txt`
 *
 *  Fine-granularity scaling sweeps:
 *  - `gas_logs/fine_granularity/IntendSettle-OneState.txt`
 *  - `gas_logs/fine_granularity/ClearPays.txt`
 *  - `gas_logs/fine_granularity/DepositEthInBatch.txt`
 *
 * @dev Run via:
 *      forge test --match-contract GasReport -vv
 *  Each test writes one report file. Measurements use `gasleft()` deltas around
 *  the operation under test, which closely tracks the actual gas cost. When
 *  running under `forge coverage`, file writes are skipped so coverage does not
 *  dirty the committed `gas_logs/` baselines with instrumentation-inflated numbers.
 */
contract GasReport is LedgerTestBase {
    function setUp() public override {
        super.setUp();
        celerLedger.disableBalanceLimits();

        erc20.transfer(peer0, 1_000_000_000);
        erc20.transfer(peer1, 1_000_000_000);
        vm.prank(peer0);
        erc20.approve(address(celerLedger), type(uint256).max);
        vm.prank(peer1);
        erc20.approve(address(celerLedger), type(uint256).max);
    }

    // =========================================================================
    // Top-level report — CelerLedger ETH
    // =========================================================================

    function test_writeReport_CelerLedgerEth() public {
        string memory s = "********** Gas Measurement: CelerLedger ETH **********\n\n";
        s = string.concat(s, "***** Deploy Gas Used *****\n");
        s = string.concat(s, _deployRow("VirtContractResolver", _measureDeploy_virt()));
        s = string.concat(s, _deployRow("EthPool", _measureDeploy_ethPool()));
        s = string.concat(s, _deployRow("PayRegistry", _measureDeploy_payRegistry()));
        s = string.concat(s, _deployRow("CelerWallet", _measureDeploy_celerWallet()));
        s = string.concat(s, _deployRow("PayResolver", _measureDeploy_payResolver()));
        s = string.concat(s, _deployRow("CelerLedger", _measureDeploy_celerLedger()));

        s = string.concat(s, "\n***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("openChannel() with zero deposit", _measure_openChannel_zeroDeposit()));
        s = string.concat(s, _row("openChannel() using EthPool and msg.value", _measure_openChannel_funded()));
        s = string.concat(s, _row("setBalanceLimits()", _measure_setBalanceLimits()));
        s = string.concat(s, _row("disableBalanceLimits()", _measure_disableBalanceLimits()));
        s = string.concat(s, _row("enableBalanceLimits()", _measure_enableBalanceLimits()));
        s = string.concat(s, _row("deposit() via msg.value", _measure_deposit_msgValue()));
        s = string.concat(s, _row("deposit() via EthPool", _measure_deposit_ethPool()));
        s = string.concat(s, _row("depositInBatch() with 5 deposits", _measure_depositInBatch_5()));
        s = string.concat(s, _row("intendWithdraw()", _measure_intendWithdraw()));
        s = string.concat(s, _row("vetoWithdraw()", _measure_vetoWithdraw()));
        s = string.concat(s, _row("confirmWithdraw()", _measure_confirmWithdraw()));
        s = string.concat(s, _row("cooperativeWithdraw()", _measure_cooperativeWithdraw()));
        s = string.concat(s, _row("snapshotStates() with one non-null simplex state", _measure_snapshotStates()));
        s = string.concat(s, _row("intendSettle() with a null state", _measure_intendSettle_nullState()));
        s = string.concat(
            s, _row("intendSettle() with two 2-payment-hashList states", _measure_intendSettle_twoStatesTwoPays())
        );
        s = string.concat(s, _row("clearPays() with 2 payments", _measure_clearPays_twoPayments()));
        s = string.concat(s, _row("confirmSettle()", _measure_confirmSettle()));
        s = string.concat(s, _row("cooperativeSettle()", _measure_cooperativeSettle()));

        _writeReport("gas_logs/CelerLedger-ETH.txt", s);
    }

    // =========================================================================
    // Top-level report — CelerLedger ERC20
    // =========================================================================

    function test_writeReport_CelerLedgerErc20() public {
        string memory s = "********** Gas Measurement: CelerLedger ERC20 **********\n\n";
        s = string.concat(s, "***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("openChannel() with zero deposit", _measure_openChannel_erc20_zero()));
        s = string.concat(s, _row("openChannel() with non-zero ERC20 deposits", _measure_openChannel_erc20_funded()));
        s = string.concat(s, _row("deposit()", _measure_deposit_erc20()));
        s = string.concat(s, _row("cooperativeWithdraw()", _measure_cooperativeWithdraw_erc20()));
        s = string.concat(s, _row("cooperativeSettle()", _measure_cooperativeSettle_erc20()));
        _writeReport("gas_logs/CelerLedger-ERC20.txt", s);
    }

    // =========================================================================
    // Top-level report — Migration
    // =========================================================================

    function test_writeReport_CelerLedgerMigrate() public {
        string memory s = "********** Gas Measurement: CelerLedger Migration **********\n\n";
        s = string.concat(s, "***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("migrateChannelFrom() an Operable ETH channel", _measure_migrate_operableEth()));
        s = string.concat(s, _row("migrateChannelFrom() a Settling ETH channel", _measure_migrate_settlingEth()));
        s = string.concat(s, _row("migrateChannelFrom() an Operable ERC20 channel", _measure_migrate_operableErc20()));
        _writeReport("gas_logs/CelerLedger-Migrate.txt", s);
    }

    // =========================================================================
    // Top-level report — PayResolver / VirtContractResolver / EthPool
    // =========================================================================

    function test_writeReport_PayResolver() public {
        string memory s = "********** Gas Measurement: PayResolver **********\n\n";
        s = string.concat(s, "***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("resolvePaymentByConditions()", _measure_resolveByConditions()));
        s = string.concat(s, _row("resolvePaymentByVouchedResult()", _measure_resolveByVouchedResult()));
        _writeReport("gas_logs/PayResolver.txt", s);
    }

    function test_writeReport_VirtContractResolver() public {
        string memory s = "********** Gas Measurement: VirtContractResolver **********\n\n";
        s = string.concat(s, "***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("deploy() - BooleanCondMock", _measure_virtDeploy()));
        _writeReport("gas_logs/VirtContractResolver.txt", s);
    }

    function test_writeReport_EthPool() public {
        string memory s = "********** Gas Measurement: EthPool **********\n\n";
        s = string.concat(s, "***** Function Calls Gas Used *****\n");
        s = string.concat(s, _row("deposit()", _measure_ethPool_deposit()));
        s = string.concat(s, _row("withdraw()", _measure_ethPool_withdraw()));
        s = string.concat(s, _row("approve()", _measure_ethPool_approve()));
        s = string.concat(s, _row("transferFrom()", _measure_ethPool_transferFrom()));
        s = string.concat(s, _row("increaseAllowance()", _measure_ethPool_increaseAllowance()));
        s = string.concat(s, _row("decreaseAllowance()", _measure_ethPool_decreaseAllowance()));
        _writeReport("gas_logs/EthPool.txt", s);
    }

    // =========================================================================
    // Fine-granularity report — intendSettle one state with N pays
    // =========================================================================

    function test_writeReport_FineGran_IntendSettleOneState() public {
        // Representative sweep covering small / medium / large pay-list sizes.
        // The set is intentionally short for quick refresh; expand here if a
        // tighter regression curve is needed.
        uint256[] memory sizes = new uint256[](7);
        sizes[0] = 1;
        sizes[1] = 5;
        sizes[2] = 10;
        sizes[3] = 25;
        sizes[4] = 50;
        sizes[5] = 100;
        sizes[6] = 200;

        string memory s = "********** Gas Measurement of intendSettle() one state with multi pays **********\n\n";
        s = string.concat(s, "pay number in head payIdList\tused gas\n");

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 gasUsed = _measure_intendSettle_oneState_nPays(sizes[i]);
            s = string.concat(s, vm.toString(sizes[i]), "\t", vm.toString(gasUsed), "\n");
        }

        _writeReport("gas_logs/fine_granularity/IntendSettle-OneState.txt", s);
    }

    // =========================================================================
    // Fine-granularity report — depositInBatch
    // =========================================================================

    function test_writeReport_FineGran_DepositEthInBatch() public {
        uint256[] memory sizes = new uint256[](6);
        sizes[0] = 1;
        sizes[1] = 5;
        sizes[2] = 10;
        sizes[3] = 25;
        sizes[4] = 50;
        sizes[5] = 75;

        string memory s = "********** Gas Measurement of depositInBatch() - ETH **********\n\n";
        s = string.concat(s, "batch size\tused gas\n");

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 gasUsed = _measure_depositInBatch_n(sizes[i]);
            s = string.concat(s, vm.toString(sizes[i]), "\t", vm.toString(gasUsed), "\n");
        }

        _writeReport("gas_logs/fine_granularity/DepositEthInBatch.txt", s);
    }

    // =========================================================================
    // Fine-granularity report — clearPays (multi-segment list)
    // =========================================================================

    function test_writeReport_FineGran_ClearPays() public {
        uint256[] memory sizes = new uint256[](6);
        sizes[0] = 1;
        sizes[1] = 5;
        sizes[2] = 10;
        sizes[3] = 25;
        sizes[4] = 50;
        sizes[5] = 100;

        string memory s = "********** Gas Measurement of clearPays() - N pays per following list **********\n\n";
        s = string.concat(s, "pay number per following payIdList\tused gas\n");

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 gasUsed = _measure_clearPays_n(sizes[i]);
            s = string.concat(s, vm.toString(sizes[i]), "\t", vm.toString(gasUsed), "\n");
        }

        _writeReport("gas_logs/fine_granularity/ClearPays.txt", s);
    }

    // =========================================================================
    // Formatting helpers
    // =========================================================================

    function _row(string memory _label, uint256 _gas) internal pure returns (string memory) {
        return string.concat(_label, ": ", vm.toString(_gas), "\n");
    }

    function _deployRow(string memory _name, uint256 _gas) internal pure returns (string memory) {
        return string.concat(_name, " Deploy Gas: ", vm.toString(_gas), "\n");
    }

    function _writeReport(string memory _path, string memory _data) internal {
        // Coverage disables optimizer/viaIR and inflates gas numbers, so do not
        // overwrite the committed regression baselines in that context.
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) {
            return;
        }

        vm.writeFile(_path, _data);
    }

    // =========================================================================
    // Per-op measurement helpers
    // =========================================================================
    // Pattern: snapshot → setup → measure (gasleft delta) → revert. The snapshot
    // bracket isolates each measurement so accumulated state from earlier ops
    // doesn't leak into the next gas number.

    function _measureDeploy_virt() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new VirtContractResolver();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measureDeploy_ethPool() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new EthPool();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measureDeploy_payRegistry() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new PayRegistry();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measureDeploy_celerWallet() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new CelerWallet();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measureDeploy_payResolver() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new PayResolver(address(payRegistry), address(virtResolver));
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measureDeploy_celerLedger() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        new CelerLedger(address(ethPool), address(payRegistry), address(celerWallet));
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_openChannel_zeroDeposit() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory request,,) = _buildOpenEth([uint256(0), 0], 0, openDeadlineCursor++);
        uint256 g0 = gasleft();
        celerLedger.openChannel(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_openChannel_funded() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory request,,) = _buildOpenEth([uint256(100), 200], 0, openDeadlineCursor++);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.openChannel{value: 100}(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_openChannel_erc20_zero() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory request,,) = _buildOpenErc20(address(erc20), [uint256(0), 0], openDeadlineCursor++);
        uint256 g0 = gasleft();
        celerLedger.openChannel(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_openChannel_erc20_funded() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory request,,) = _buildOpenErc20(address(erc20), [uint256(100), 200], openDeadlineCursor++);
        uint256 g0 = gasleft();
        celerLedger.openChannel(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_setBalanceLimits() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        celerLedger.enableBalanceLimits();
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 1_000_000;
        uint256 g0 = gasleft();
        celerLedger.setBalanceLimits(tokens, limits);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_disableBalanceLimits() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        celerLedger.enableBalanceLimits();
        uint256 g0 = gasleft();
        celerLedger.disableBalanceLimits();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_enableBalanceLimits() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        // Already disabled in setUp.
        uint256 g0 = gasleft();
        celerLedger.enableBalanceLimits();
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_deposit_msgValue() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openZeroEthChannel();
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.deposit{value: 50}(ch, peer0, 0);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_deposit_ethPool() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openZeroEthChannel();
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.deposit(ch, peer0, 100);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_deposit_erc20() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory request,, bytes32 ch) = _buildOpenErc20(address(erc20), [uint256(0), 0], openDeadlineCursor++);
        celerLedger.openChannel(request);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.deposit(ch, peer0, 100);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_depositInBatch_5() internal returns (uint256 g) {
        return _measure_depositInBatch_n(5);
    }

    function _measure_depositInBatch_n(uint256 _n) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32[] memory ids = new bytes32[](_n);
        address[] memory receivers = new address[](_n);
        uint256[] memory amounts = new uint256[](_n);
        for (uint256 i = 0; i < _n; i++) {
            ids[i] = _openZeroEthChannel();
            receivers[i] = peer0;
            amounts[i] = 30;
        }
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.depositInBatch(ids, receivers, amounts);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_intendWithdraw() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.intendWithdraw(ch, 50, bytes32(0));
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_vetoWithdraw() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        vm.prank(peer0);
        celerLedger.intendWithdraw(ch, 50, bytes32(0));
        vm.prank(peer1);
        uint256 g0 = gasleft();
        celerLedger.vetoWithdraw(ch);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_confirmWithdraw() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        vm.prank(peer0);
        celerLedger.intendWithdraw(ch, 50, bytes32(0));
        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 g0 = gasleft();
        celerLedger.confirmWithdraw(ch);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_cooperativeWithdraw() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        bytes memory request = _buildCoopWithdraw(ch, 1, peer0, 100, block.number + 1000, bytes32(0));
        uint256 g0 = gasleft();
        celerLedger.cooperativeWithdraw(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_cooperativeWithdraw_erc20() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory openReq,, bytes32 ch) = _buildOpenErc20(address(erc20), [uint256(200), 0], openDeadlineCursor++);
        celerLedger.openChannel(openReq);
        bytes memory request = _buildCoopWithdraw(ch, 1, peer0, 100, block.number + 1000, bytes32(0));
        uint256 g0 = gasleft();
        celerLedger.cooperativeWithdraw(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_snapshotStates() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        bytes memory simplex = _buildSignedSimplex(ch, peer0, 1, 50);
        bytes memory array = _wrapStateArray(simplex, "");
        uint256 g0 = gasleft();
        celerLedger.snapshotStates(array);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_intendSettle_nullState() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        bytes memory s0 = _buildNullSimplex(ch, peer0Pk);
        bytes memory s1 = _buildNullSimplex(ch, peer1Pk);
        bytes memory array = _wrapStateArray(s0, s1);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.intendSettle(array);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_intendSettle_twoStatesTwoPays() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 200]);

        bytes32 payA0 = _resolveHashLockPay(10, "p1", 1);
        bytes32 payA1 = _resolveHashLockPay(15, "p2", 2);
        bytes32 payB0 = _resolveHashLockPay(5, "p3", 3);
        bytes32 payB1 = _resolveHashLockPay(8, "p4", 4);

        bytes32[] memory aIds = new bytes32[](2);
        aIds[0] = payA0;
        aIds[1] = payA1;
        bytes32[] memory bIds = new bytes32[](2);
        bIds[0] = payB0;
        bIds[1] = payB1;

        bytes memory aListBytes = Fixtures.encPayIdList(aIds, bytes32(0));
        bytes memory bListBytes = Fixtures.encPayIdList(bIds, bytes32(0));

        bytes memory s0 = _buildSimplexWithPayList(ch, peer0, 1, aListBytes, 25);
        bytes memory s1 = _buildSimplexWithPayList(ch, peer1, 1, bListBytes, 13);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.roll(block.number + 10);

        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.intendSettle(array);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_intendSettle_oneState_nPays(uint256 _n) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200_000_000), 0]);

        bytes32[] memory payIds = new bytes32[](_n);
        uint256 totalPending = 0;
        for (uint256 i = 0; i < _n; i++) {
            uint256 amt = 10 + i;
            payIds[i] = _resolveHashLockPay(amt, abi.encodePacked("p", vm.toString(i)), i + 1);
            totalPending += amt;
        }
        bytes memory list = Fixtures.encPayIdList(payIds, bytes32(0));

        bytes memory s0 = _buildSimplexWithPayList(ch, peer0, 1, list, totalPending);
        bytes memory s1 = _buildSignedSimplex(ch, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.roll(block.number + 10);

        vm.prank(peer0);
        uint256 g0 = gasleft();
        celerLedger.intendSettle(array);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_clearPays_twoPayments() internal returns (uint256 g) {
        return _measure_clearPays_n(2);
    }

    function _measure_clearPays_n(uint256 _n) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200_000_000), 0]);

        // Head list: 1 pay; tail list: _n pays.
        bytes32 headPayId = _resolveHashLockPay(10, "head", 1);
        bytes32[] memory tailIds = new bytes32[](_n);
        uint256 tailTotal = 0;
        for (uint256 i = 0; i < _n; i++) {
            uint256 amt = 5 + i;
            tailIds[i] = _resolveHashLockPay(amt, abi.encodePacked("t", vm.toString(i)), 1000 + i + 1);
            tailTotal += amt;
        }

        bytes memory tailList = Fixtures.encPayIdList(tailIds, bytes32(0));
        bytes32 tailHash = keccak256(tailList);

        bytes32[] memory headIds = new bytes32[](1);
        headIds[0] = headPayId;
        bytes memory headList = Fixtures.encPayIdList(headIds, tailHash);

        bytes memory s0 = _buildSimplexWithPayList(ch, peer0, 1, headList, 10 + tailTotal);
        bytes memory s1 = _buildSignedSimplex(ch, peer1, 1, 0);

        vm.roll(block.number + 10);

        vm.prank(peer0);
        celerLedger.intendSettle(_wrapStateArray(s0, s1));

        uint256 g0 = gasleft();
        celerLedger.clearPays(ch, peer0, tailList);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_confirmSettle() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        bytes memory s0 = _buildSignedSimplex(ch, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(ch, peer1, 1, 0);
        vm.prank(peer0);
        celerLedger.intendSettle(_wrapStateArray(s0, s1));
        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 g0 = gasleft();
        celerLedger.confirmSettle(ch);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_cooperativeSettle() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(200), 0]);
        bytes memory request = _buildCoopSettle(ch, 1, [uint256(120), 80], block.number + 1000);
        uint256 g0 = gasleft();
        celerLedger.cooperativeSettle(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_cooperativeSettle_erc20() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory openReq,, bytes32 ch) = _buildOpenErc20(address(erc20), [uint256(200), 0], openDeadlineCursor++);
        celerLedger.openChannel(openReq);
        bytes memory request = _buildCoopSettle(ch, 1, [uint256(120), 80], block.number + 1000);
        uint256 g0 = gasleft();
        celerLedger.cooperativeSettle(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_resolveByConditions() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condHashLock(keccak256("preimage"));
        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: 1,
            src: peer0,
            dest: peer1,
            conditions: conds,
            logicType: 0,
            maxAmount: 10,
            resolveDeadline: 9_999_999,
            resolveTimeout: 5,
            payResolver: address(payResolver)
        });
        bytes memory payBytes = Fixtures.encConditionalPay(pay);
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = bytes("preimage");
        bytes memory request = Fixtures.encResolvePayByConditionsRequest(payBytes, preimages);

        uint256 g0 = gasleft();
        payResolver.resolvePaymentByConditions(request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_resolveByVouchedResult() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        Fixtures.Condition[] memory numConds = new Fixtures.Condition[](2);
        numConds[0] = Fixtures.condDeployedNumeric(makeAddr("numericMock"), 10);
        numConds[1] = Fixtures.condDeployedNumeric(makeAddr("numericMock"), 25);
        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: 2,
            src: peer0,
            dest: peer1,
            conditions: numConds,
            logicType: 3,
            maxAmount: 100,
            resolveDeadline: 9_999_999,
            resolveTimeout: 10,
            payResolver: address(payResolver)
        });
        bytes memory payBytes = Fixtures.encConditionalPay(pay);
        bytes memory result = Fixtures.encCondPayResult(payBytes, 20);
        bytes memory sigSrc = SignUtil.sign(peer0Pk, result);
        bytes memory sigDest = SignUtil.sign(peer1Pk, result);
        bytes memory vouched = Fixtures.encVouchedCondPayResult(result, sigSrc, sigDest);

        uint256 g0 = gasleft();
        payResolver.resolvePaymentByVouchedResult(vouched);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_virtDeploy() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes memory mockBytecode = type(BooleanCondMock).creationCode;
        uint256 g0 = gasleft();
        virtResolver.deploy(mockBytecode, 12_345);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_migrate_operableEth() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(100), 200]);
        CelerLedger newLedger = _deployNewLedgerSiblingAndApprove();
        bytes memory request =
            _buildMigrationRequest(ch, address(celerLedger), address(newLedger), block.number + 100_000);

        uint256 g0 = gasleft();
        newLedger.migrateChannelFrom(address(celerLedger), request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_migrate_settlingEth() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        bytes32 ch = _openFundedEthChannel([uint256(100), 200]);
        bytes memory s0 = _buildSignedSimplex(ch, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(ch, peer1, 1, 0);
        vm.prank(peer0);
        celerLedger.intendSettle(_wrapStateArray(s0, s1));

        CelerLedger newLedger = _deployNewLedgerSiblingAndApprove();
        bytes memory request =
            _buildMigrationRequest(ch, address(celerLedger), address(newLedger), block.number + 100_000);

        uint256 g0 = gasleft();
        newLedger.migrateChannelFrom(address(celerLedger), request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_migrate_operableErc20() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        (bytes memory openReq,, bytes32 ch) = _buildOpenErc20(address(erc20), [uint256(100), 200], openDeadlineCursor++);
        celerLedger.openChannel(openReq);

        CelerLedger newLedger = _deployNewLedgerSiblingAndApprove();
        bytes memory request =
            _buildMigrationRequest(ch, address(celerLedger), address(newLedger), block.number + 100_000);

        uint256 g0 = gasleft();
        newLedger.migrateChannelFrom(address(celerLedger), request);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_deposit() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        uint256 g0 = gasleft();
        ethPool.deposit{value: 100}(peer0);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_withdraw() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.deal(peer0, 1 ether);
        vm.prank(peer0);
        ethPool.deposit{value: 100}(peer0);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        ethPool.withdraw(100);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_approve() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.prank(peer0);
        uint256 g0 = gasleft();
        ethPool.approve(stranger, 200);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_transferFrom() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.deal(peer0, 1 ether);
        vm.prank(peer0);
        ethPool.deposit{value: 200}(peer0);
        vm.prank(peer0);
        ethPool.approve(stranger, 200);
        vm.prank(stranger);
        uint256 g0 = gasleft();
        ethPool.transferFrom(peer0, payable(makeAddr("recipient")), 150);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_increaseAllowance() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.prank(peer0);
        ethPool.approve(stranger, 50);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        ethPool.increaseAllowance(stranger, 50);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    function _measure_ethPool_decreaseAllowance() internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        vm.prank(peer0);
        ethPool.approve(stranger, 100);
        vm.prank(peer0);
        uint256 g0 = gasleft();
        ethPool.decreaseAllowance(stranger, 80);
        g = g0 - gasleft();
        vm.revertToState(snap);
    }

    // =========================================================================
    // Common reusable helpers (PayIdList / migration / hash-lock pay).
    // =========================================================================

    function _resolveHashLockPay(uint256 _maxAmount, bytes memory _preimage, uint256 _payTimestamp)
        internal
        returns (bytes32)
    {
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condHashLock(keccak256(_preimage));
        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: _payTimestamp,
            src: peer0,
            dest: peer1,
            conditions: conds,
            logicType: 0,
            maxAmount: _maxAmount,
            resolveDeadline: 9_999_999,
            resolveTimeout: 5,
            payResolver: address(payResolver)
        });
        bytes memory payBytes = Fixtures.encConditionalPay(pay);
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = _preimage;
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));
        return keccak256(abi.encodePacked(keccak256(payBytes), address(payResolver)));
    }

    function _buildSimplexWithPayList(
        bytes32 _channelId,
        address _peerFrom,
        uint256 _seqNum,
        bytes memory _payIdList,
        uint256 _totalPending
    ) internal view returns (bytes memory) {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: _channelId,
            peerFrom: _peerFrom,
            seqNum: _seqNum,
            transferAmount: 0,
            pendingPayIds: _payIdList,
            lastPayResolveDeadline: block.number + 1000,
            totalPendingAmount: _totalPending
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, simplex);
        return Fixtures.encSignedSimplexState(simplex, sigs);
    }

    function _deployNewLedgerSiblingAndApprove() internal returns (CelerLedger newLedger) {
        newLedger = new CelerLedger(address(ethPool), address(payRegistry), address(celerWallet));
        newLedger.disableBalanceLimits();
        vm.prank(peer0);
        ethPool.approve(address(newLedger), type(uint256).max);
        vm.prank(peer1);
        ethPool.approve(address(newLedger), type(uint256).max);
    }

    function _buildMigrationRequest(bytes32 _channelId, address _fromLedger, address _toLedger, uint256 _deadline)
        internal
        view
        returns (bytes memory)
    {
        Fixtures.ChannelMigrationInfo memory info = Fixtures.ChannelMigrationInfo({
            channelId: _channelId,
            fromLedger: _fromLedger,
            toLedger: _toLedger,
            migrationDeadline: _deadline
        });
        bytes memory body = Fixtures.encChannelMigrationInfo(info);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        return Fixtures.encChannelMigrationRequest(body, sigs);
    }
}
