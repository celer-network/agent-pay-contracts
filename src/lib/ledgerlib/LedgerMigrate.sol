// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./LedgerOperation.sol";
import "./LedgerChannel.sol";
import "./LedgerStruct.sol";
import "../../interfaces/ICelerLedger.sol";
import "../AgentPayErrors.sol";
import "../data/PbChain.sol";
import "../data/PbEntity.sol";

/**
 * @title LedgerMigrate
 * @notice Library implementing peer-controlled cross-version channel migration. The
 *  new ledger's `migrateChannelFrom` orchestrates the flow end-to-end: validating
 *  the co-signed migration request, calling `migrateChannelTo` on the old ledger,
 *  verifying the wallet operatorship transfer, and importing the channel state.
 *  Migration outranks `intendSettle` — a `Settling` channel returns to `Operable`
 *  on the new ledger.
 */
library LedgerMigrate {
    using LedgerChannel for LedgerStruct.Channel;
    using LedgerOperation for LedgerStruct.Ledger;

    /**
     * @notice Migrate a channel from this CelerLedger to a new CelerLedger
     * @param _self storage data of CelerLedger contract
     * @param _migrationRequest bytes of migration request message
     * @return migrated channel id
     */
    function migrateChannelTo(LedgerStruct.Ledger storage _self, bytes calldata _migrationRequest)
        external
        returns (bytes32)
    {
        PbChain.ChannelMigrationRequest memory migrationRequest = PbChain.decChannelMigrationRequest(_migrationRequest);
        PbEntity.ChannelMigrationInfo memory migrationInfo =
            PbEntity.decChannelMigrationInfo(migrationRequest.channelMigrationInfo);
        bytes32 channelId = migrationInfo.channelId;
        LedgerStruct.Channel storage c = _self.channelMap[channelId];
        address toLedgerAddr = migrationInfo.toLedgerAddress;

        require(
            c.status == LedgerStruct.ChannelStatus.Operable || c.status == LedgerStruct.ChannelStatus.Settling,
            AgentPayErrors.ChannelNotOperableOrSettling()
        );
        bytes32 h = keccak256(migrationRequest.channelMigrationInfo);
        require(c._checkCoSignatures(h, migrationRequest.sigs), AgentPayErrors.InvalidCoSignatures());
        require(migrationInfo.fromLedgerAddress == address(this), AgentPayErrors.FromLedgerAddressMismatch());
        require(toLedgerAddr == msg.sender, AgentPayErrors.ToLedgerAddressMismatch());
        require(block.timestamp <= migrationInfo.migrationDeadline, AgentPayErrors.DeadlinePassed());

        _self._updateChannelStatus(c, LedgerStruct.ChannelStatus.Migrated);
        c.migratedTo = toLedgerAddr;
        emit MigrateChannelTo(channelId, toLedgerAddr);

        _self.celerWallet.transferOperatorship(channelId, toLedgerAddr);

        return channelId;
    }

    /**
     * @notice Migrate a channel from an old CelerLedger to this CelerLedger
     * @param _self storage data of CelerLedger contract
     * @param _fromLedgerAddr the old ledger address to migrate from
     * @param _migrationRequest bytes of migration request message
     */
    // TODO: think about future multi versions upgrade (if-else branch for addr and import libs as mini-v1, mini-v2, mini-v3,
    //       otherwise, only one interface can be used because all interfaces share the same name.)
    function migrateChannelFrom(
        LedgerStruct.Ledger storage _self,
        address _fromLedgerAddr,
        bytes calldata _migrationRequest
    ) external {
        address payable fromLedgerAddrPayable = payable(_fromLedgerAddr);
        bytes32 channelId = ICelerLedger(fromLedgerAddrPayable).migrateChannelTo(_migrationRequest);
        LedgerStruct.Channel storage c = _self.channelMap[channelId];
        require(c.status == LedgerStruct.ChannelStatus.Uninitialized, AgentPayErrors.ChannelAlreadyMigrated());
        require(_self.celerWallet.getOperator(channelId) == address(this), AgentPayErrors.OperatorshipNotTransferred());

        _self._updateChannelStatus(c, LedgerStruct.ChannelStatus.Operable);
        // Do not migrate WithdrawIntent, in other words, migration will implicitly veto
        // pending WithdrawIntent if any.
        c._importChannelMigrationArgs(fromLedgerAddrPayable, channelId);
        c._importPeersMigrationInfo(fromLedgerAddrPayable, channelId);

        emit MigrateChannelFrom(channelId, _fromLedgerAddr);
    }

    event MigrateChannelTo(bytes32 indexed channelId, address indexed newLedgerAddr);

    event MigrateChannelFrom(bytes32 indexed channelId, address indexed oldLedgerAddr);
}
