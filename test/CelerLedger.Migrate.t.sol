// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LedgerTestBase} from "./utils/LedgerTestBase.t.sol";
import {LedgerStruct} from "../src/lib/ledgerlib/LedgerStruct.sol";
import {CelerLedger} from "../src/CelerLedger.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {SignUtil} from "./utils/SignUtil.sol";

/**
 * @title CelerLedger migration tests
 * @notice Unit tests for peer-controlled cross-version channel migration.
 *  Deploys two CelerLedger versions sharing the same CelerWallet, opens a
 *  channel on the old ledger, and migrates it to the new one. Covers both
 *  Operable and Settling source states for ETH and ERC-20 channels, plus the
 *  expired-deadline and wrong-from-ledger revert paths.
 */
contract CelerLedgerMigrateTest is LedgerTestBase {
    /// @notice The old ledger is `celerLedger` from {LedgerTestBase}; deploy a sibling.
    CelerLedger internal celerLedgerNew;

    function setUp() public override {
        super.setUp();
        celerLedgerNew = new CelerLedger(address(ethPool), address(payRegistry), address(celerWallet));
        vm.label(address(celerLedgerNew), "CelerLedgerNew");

        // Disable balance limits on both for simplicity.
        celerLedger.disableBalanceLimits();
        celerLedgerNew.disableBalanceLimits();

        // Approve the new ledger from the EthPool too.
        vm.prank(peer0);
        ethPool.approve(address(celerLedgerNew), type(uint256).max);
        vm.prank(peer1);
        ethPool.approve(address(celerLedgerNew), type(uint256).max);

        // Fund both peers with ERC20 + approve both ledgers.
        erc20.transfer(peer0, 1_000_000);
        erc20.transfer(peer1, 1_000_000);
        vm.prank(peer0);
        erc20.approve(address(celerLedger), type(uint256).max);
        vm.prank(peer1);
        erc20.approve(address(celerLedger), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Operable channel migration
    // -------------------------------------------------------------------------

    function test_migrate_operableEthChannel_succeeds() public {
        bytes32 channelId = _openFundedEthChannel([uint256(100), 200]);
        _assertOperatorOnChannel(channelId, address(celerLedger));

        _migrate(channelId);

        _assertMigratedFromOldToNew(channelId);
    }

    function test_migrate_operableErc20Channel_succeeds() public {
        bytes32 channelId = _openFundedErc20Channel([uint256(100), 200]);
        _assertOperatorOnChannel(channelId, address(celerLedger));

        _migrate(channelId);

        _assertMigratedFromOldToNew(channelId);
    }

    // -------------------------------------------------------------------------
    // Settling channel migration (migration outranks intendSettle)
    // -------------------------------------------------------------------------

    function test_migrate_settlingEthChannel_returnsToOperableOnNewLedger() public {
        bytes32 channelId = _openFundedEthChannel([uint256(100), 200]);

        // intendSettle on the old ledger to put the channel into Settling.
        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);
        vm.prank(peer0);
        celerLedger.intendSettle(array);
        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Settling));

        _migrate(channelId);

        _assertMigratedFromOldToNew(channelId);
    }

    // -------------------------------------------------------------------------
    // Negative cases
    // -------------------------------------------------------------------------

    function test_migrate_pastDeadline_reverts() public {
        bytes32 channelId = _openFundedEthChannel([uint256(100), 200]);

        bytes memory request =
            _buildMigrationRequest(channelId, address(celerLedger), address(celerLedgerNew), block.timestamp - 1);

        vm.expectRevert(bytes("Passed migration deadline"));
        celerLedgerNew.migrateChannelFrom(address(celerLedger), request);
    }

    function test_migrate_wrongFromLedger_reverts() public {
        bytes32 channelId = _openFundedEthChannel([uint256(100), 200]);

        // Migration request claims a different fromLedger (not address(celerLedger)).
        bytes memory request = _buildMigrationRequest(channelId, stranger, address(celerLedgerNew), 99_999_999);

        vm.expectRevert(bytes("From ledger address is not this"));
        celerLedgerNew.migrateChannelFrom(address(celerLedger), request);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _openFundedErc20Channel(uint256[2] memory _amounts) internal returns (bytes32) {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 channelId) = _buildOpenErc20(address(erc20), _amounts, deadline);
        celerLedger.openChannel(request);
        return channelId;
    }

    function _buildMigrationRequest(bytes32 _channelId, address _fromLedger, address _toLedger, uint256 _deadline)
        internal
        view
        returns (bytes memory)
    {
        Fixtures.ChannelMigrationInfo memory info = Fixtures.ChannelMigrationInfo({
            channelId: _channelId, fromLedger: _fromLedger, toLedger: _toLedger, migrationDeadline: _deadline
        });
        bytes memory body = Fixtures.encChannelMigrationInfo(info);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        return Fixtures.encChannelMigrationRequest(body, sigs);
    }

    function _migrate(bytes32 _channelId) internal {
        bytes memory request = _buildMigrationRequest(
            _channelId, address(celerLedger), address(celerLedgerNew), block.timestamp + 100_000
        );
        celerLedgerNew.migrateChannelFrom(address(celerLedger), request);
    }

    function _assertOperatorOnChannel(bytes32 _channelId, address _expectedOperator) internal view {
        assertEq(celerWallet.getOperator(_channelId), _expectedOperator);
    }

    function _assertMigratedFromOldToNew(bytes32 _channelId) internal view {
        // Wallet operator is now the new ledger.
        _assertOperatorOnChannel(_channelId, address(celerLedgerNew));

        // Old ledger marks the channel Migrated and records migratedTo.
        assertEq(uint256(celerLedger.getChannelStatus(_channelId)), uint256(LedgerStruct.ChannelStatus.Migrated));
        assertEq(celerLedger.getMigratedTo(_channelId), address(celerLedgerNew));

        // New ledger has the channel as Operable.
        assertEq(uint256(celerLedgerNew.getChannelStatus(_channelId)), uint256(LedgerStruct.ChannelStatus.Operable));

        // Channel-level metadata round-trips.
        (uint256 oldDispute, uint256 oldType, address oldToken,) = celerLedger.getChannelMigrationArgs(_channelId);
        (uint256 newDispute, uint256 newType, address newToken,) = celerLedgerNew.getChannelMigrationArgs(_channelId);
        assertEq(oldDispute, newDispute);
        assertEq(oldType, newType);
        assertEq(oldToken, newToken);

        // Per-peer balances round-trip.
        (, uint256[2] memory oldDeposits, uint256[2] memory oldWithdrawals) = celerLedger.getBalanceMap(_channelId);
        (, uint256[2] memory newDeposits, uint256[2] memory newWithdrawals) = celerLedgerNew.getBalanceMap(_channelId);
        assertEq(oldDeposits[0], newDeposits[0]);
        assertEq(oldDeposits[1], newDeposits[1]);
        assertEq(oldWithdrawals[0], newWithdrawals[0]);
        assertEq(oldWithdrawals[1], newWithdrawals[1]);
    }
}
