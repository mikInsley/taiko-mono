// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.18;

import {AddressResolver} from "../../../common/AddressResolver.sol";
import {LibAddress} from "../../../libs/LibAddress.sol";
import {LibEthDepositing_A3} from "./LibEthDepositing_A3.sol";
import {LibUtils_A3} from "./LibUtils_A3.sol";
import {SafeCastUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TaikoData} from "../../TaikoData.sol";

library LibProposing_A3 {
    using SafeCastUpgradeable for uint256;
    using LibAddress for address;
    using LibAddress for address payable;
    using LibUtils_A3 for TaikoData.State;

    event BlockProposed(uint256 indexed id, TaikoData.BlockMetadata meta, uint64 blockFee);

    error L1_BLOCK_ID();
    error L1_INSUFFICIENT_TOKEN();
    error L1_INVALID_METADATA();
    error L1_TOO_MANY_BLOCKS();
    error L1_TX_LIST_NOT_EXIST();
    error L1_TX_LIST_HASH();
    error L1_TX_LIST_RANGE();
    error L1_TX_LIST();

    function proposeBlock(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        AddressResolver resolver,
        TaikoData.BlockMetadataInput memory input,
        bytes calldata txList
    ) internal returns (TaikoData.BlockMetadata memory meta) {
        uint8 cacheTxListInfo =
            _validateBlock({state: state, config: config, input: input, txList: txList});

        if (cacheTxListInfo != 0) {
            state.txListInfo[input.txListHash] = TaikoData.TxListInfo({
                validSince: uint64(block.timestamp),
                size: uint24(txList.length)
            });
        }

        // After The Merge, L1 mixHash contains the prevrandao
        // from the beacon chain. Since multiple Taiko blocks
        // can be proposed in one Ethereum block, we need to
        // add salt to this random number as L2 mixHash

        meta.id = state.slot7.numBlocks;
        meta.txListHash = input.txListHash;
        meta.txListByteStart = input.txListByteStart;
        meta.txListByteEnd = input.txListByteEnd;
        meta.gasLimit = input.gasLimit;
        meta.beneficiary = input.beneficiary;
        meta.treasury = resolver.resolve(config.chainId, "treasury", false);
        meta.depositsProcessed = LibEthDepositing_A3.processDeposits(state, config, input.beneficiary);

        unchecked {
            meta.timestamp = uint64(block.timestamp);
            meta.l1Height = uint64(block.number - 1);
            meta.l1Hash = blockhash(block.number - 1);
            meta.mixHash = bytes32(block.difficulty * state.slot7.numBlocks);
        }

        TaikoData.Block_A3 storage blk = state.blocks_A3[state.slot7.numBlocks % config.blockRingBufferSize];

        blk.blockId = state.slot7.numBlocks;
        blk.proposedAt = meta.timestamp;
        blk.nextForkChoiceId = 1;
        blk.verifiedForkChoiceId = 0;
        blk.metaHash = LibUtils_A3.hashMetadata(meta);
        blk.proposer = msg.sender;

        uint64 blockFee = state.slot8.blockFee;
        if (state.taikoTokenBalances[msg.sender] < blockFee) {
            revert L1_INSUFFICIENT_TOKEN();
        }

        unchecked {
            state.taikoTokenBalances[msg.sender] -= blockFee;
            state.slot7.accBlockFees += blockFee;
            state.slot7.accProposedAt += meta.timestamp;
        }

        emit BlockProposed(state.slot7.numBlocks, meta, blockFee);
        unchecked {
            ++state.slot7.numBlocks;
        }
    }

    function getBlock(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        uint256 blockId
    ) internal view returns (TaikoData.Block_A3 storage blk) {
        blk = state.blocks_A3[blockId % config.blockRingBufferSize];
        if (blk.blockId != blockId) revert L1_BLOCK_ID();
    }

    function _validateBlock(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        TaikoData.BlockMetadataInput memory input,
        bytes calldata txList
    ) private view returns (uint8 cacheTxListInfo) {
        if (
            input.beneficiary == address(0) || input.gasLimit == 0
                || input.gasLimit > config.blockMaxGasLimit
        ) revert L1_INVALID_METADATA();

        if (state.slot7.numBlocks >= state.slot8.lastVerifiedBlockId + config.blockMaxProposals + 1) {
            revert L1_TOO_MANY_BLOCKS();
        }

        uint64 timeNow = uint64(block.timestamp);
        // handling txList
        {
            uint24 size = uint24(txList.length);
            if (size > config.blockMaxTxListBytes) revert L1_TX_LIST();

            if (input.txListByteStart > input.txListByteEnd) {
                revert L1_TX_LIST_RANGE();
            }

            if (config.blockTxListExpiry == 0) {
                // caching is disabled
                if (input.txListByteStart != 0 || input.txListByteEnd != size) {
                    revert L1_TX_LIST_RANGE();
                }
            } else {
                // caching is enabled
                if (size == 0) {
                    // This blob shall have been submitted earlier
                    TaikoData.TxListInfo memory info = state.txListInfo[input.txListHash];

                    if (input.txListByteEnd > info.size) {
                        revert L1_TX_LIST_RANGE();
                    }

                    if (info.size == 0 || info.validSince + config.blockTxListExpiry < timeNow) {
                        revert L1_TX_LIST_NOT_EXIST();
                    }
                } else {
                    if (input.txListByteEnd > size) revert L1_TX_LIST_RANGE();
                    if (input.txListHash != keccak256(txList)) {
                        revert L1_TX_LIST_HASH();
                    }

                    cacheTxListInfo = uint8(input.cacheTxListInfo);//To be compatible with A4
                }
            }
        }
    }
}