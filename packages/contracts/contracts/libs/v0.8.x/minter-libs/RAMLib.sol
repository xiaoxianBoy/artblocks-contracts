// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

pragma solidity ^0.8.0;

import {IMinterFilterV1} from "../../../interfaces/v0.8.x/IMinterFilterV1.sol";

import {BitMaps256} from "../BitMap.sol";
import {ABHelpers} from "../ABHelpers.sol";
import {SplitFundsLib} from "./SplitFundsLib.sol";
import {MaxInvocationsLib} from "./MaxInvocationsLib.sol";

import {IERC721} from "@openzeppelin-5.0/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin-5.0/contracts/utils/math/SafeCast.sol";

/**
 * @title Art Blocks RAM Minter Library
 * @notice This library is designed for the Art Blocks platform. It includes
 * Structs and functions that help with ranked auction minters.
 * @author Art Blocks Inc.
 */

library RAMLib {
    using SafeCast for uint256;
    using BitMaps256 for uint256;

    /**
     * @notice Admin-controlled refund gas limit updated
     * @param refundGasLimit Gas limit to use when refunding the previous
     * highest bidder, prior to using fallback force-send to refund
     */
    event MinterRefundGasLimitUpdated(uint24 refundGasLimit);

    // position of RAM Lib storage, using a diamond storage pattern
    // for this library
    bytes32 constant RAM_LIB_STORAGE_POSITION = keccak256("ramlib.storage");

    // 60 sec/min * 60 min/hr * 24 hr
    uint256 constant TWENTY_FOUR_HOURS = 60 * 60 * 24;

    enum ProjectMinterStates {
        A, // Pre-Auction
        B, // Live-Auction
        C, // Post-Auction, not all bids handled, 24h
        D, // Post-Auction, not all bids handled, post-24h
        E // Post-Auction, all bids handled
    }

    // project-specific parameters
    struct RAMProjectConfig {
        // array of bids for each slot
        mapping(uint256 slot => Bid[] bids) bidsBySlot;
        // --- slot metadata for efficiency ---
        // bitmap with index set only if one or more active bids exist for the corresponding slot
        uint256 slotsBitmap;
        // minimum bitmap index with an active bid
        uint8 minBidIndex;
        // maximum bitmap index with an unminted bid
        // TODO - this could be populated when finishing auction via function input, bitshifting to verify...
        uint8 maxUnmintedBidSlotIndex;
        // TODO - determine if this should be updated on insertion/removal, or initialized when finishing auction
        uint24 maxUnmintedBidArrayIndex;
        // --- auction parameters ---
        // @dev max uint24 is 16,777,215 > 1_000_000 max project size
        uint24 numTokensInAuction;
        uint24 numBids;
        uint24 numBidsMintedTokens;
        uint24 numBidsErrorRefunded;
        // TODO start time, end time, min bid, bid spacing, etc.
        uint40 timestampStart;
        uint40 timestampEnd;
        uint88 maxPrice;
        uint88 basePrice;
        // --- auction state ---
        bool allWinningBidsSettled; // default false
    }

    struct Bid {
        address bidder;
        bool isSettled; // TODO: could remove this if amount is changed when settling
        bool isMinted; // TODO: determine if this is needed
    }

    // Diamond storage pattern is used in this library
    struct RAMLibStorage {
        mapping(address coreContract => mapping(uint256 projectId => RAMProjectConfig)) RAMProjectConfigs;
    }

    function setAuctionDetails(
        uint256 projectId,
        address coreContract,
        uint40 auctionTimestampStart,
        uint40 auctionTimestampEnd,
        uint88 maxPrice,
        uint88 basePrice,
        uint24 numTokensInAuction
    ) internal {
        // load project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // set auction details
        RAMProjectConfig_.numTokensInAuction = numTokensInAuction;
        RAMProjectConfig_.timestampStart = auctionTimestampStart;
        RAMProjectConfig_.timestampEnd = auctionTimestampEnd;
        RAMProjectConfig_.maxPrice = maxPrice;
        RAMProjectConfig_.basePrice = basePrice;
    }

    // TODO must limit to only active auctions, etc.
    function placeBid(
        uint256 projectId,
        address coreContract,
        uint8 slotIndex,
        address bidder,
        uint256 minterRefundGasLimit
    ) internal {
        // load project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // determine if have reached max bids
        bool reachedMaxBids = RAMProjectConfig_.numBids ==
            RAMProjectConfig_.numTokensInAuction;
        if (reachedMaxBids) {
            // remove + refund the minimum Bid
            uint8 removedSlotIndex = removeMinBid({
                projectId: projectId,
                coreContract: coreContract,
                minterRefundGasLimit: minterRefundGasLimit
            });
            // require new bid is greater than removed minimum bid
            require(slotIndex > removedSlotIndex, "Insufficient bid value");
        }
        // insert the new Bid
        insertBid({
            RAMProjectConfig_: RAMProjectConfig_,
            slotIndex: slotIndex,
            bidder: bidder
        });
    }

    // TODO: add assumptions/protections about max bids, active auction, etc.
    function insertBid(
        RAMProjectConfig storage RAMProjectConfig_,
        uint8 slotIndex,
        address bidder
    ) private {
        // add the new Bid
        Bid[] storage bids = RAMProjectConfig_.bidsBySlot[slotIndex];
        bids.push(Bid({bidder: bidder, isSettled: false, isMinted: false}));
        // update number of active bids
        RAMProjectConfig_.numBids++;
        // update metadata if first bid for this slot
        // @dev assumes minting has not yet started
        if (bids.length == 1) {
            // set the slot in the bitmap
            RAMProjectConfig_.slotsBitmap = RAMProjectConfig_.slotsBitmap.set(
                slotIndex
            );
            // update bitmap metadata - reduce min bid index if necessary
            if (slotIndex < RAMProjectConfig_.minBidIndex) {
                RAMProjectConfig_.minBidIndex = slotIndex;
            }
            // update bitmap metadata - increase max unminted bid index if necessary
            if (slotIndex > RAMProjectConfig_.maxUnmintedBidSlotIndex) {
                RAMProjectConfig_.maxUnmintedBidSlotIndex = slotIndex;
            }
        }
    }

    function removeMinBid(
        uint256 projectId,
        address coreContract,
        uint256 minterRefundGasLimit
    ) private returns (uint8 removedSlotIndex) {
        // get project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // get the minimum bid
        uint8 minBidIndex = RAMProjectConfig_.minBidIndex;
        // get the bids array for that slot
        Bid[] storage bids = RAMProjectConfig_.bidsBySlot[minBidIndex];
        // record the previous min bidder
        address removedBidder = bids[bids.length - 1].bidder;
        // pop the last active bid in the array
        // @dev implicitly deletes the last bid in the array
        // @dev appropriate because earlier bids (lower index) have priority;
        // TODO: gas-optimize this by only editing array length since once remove a bid, will never re-add on that slot
        bids.pop();
        RAMProjectConfig_.numBids--;
        // record the slot index of the removed bid as return value
        removedSlotIndex = minBidIndex;
        // update metadata if no more active bids for this slot
        if (bids.length == 0) {
            // clear the slot from the bitmap
            RAMProjectConfig_.slotsBitmap = RAMProjectConfig_.slotsBitmap.unset(
                minBidIndex
            );
            // update minBidIndex, efficiently starting at minBidIndex + 1
            // @dev intentionally reverts due to overflow if removing from the last slot
            RAMProjectConfig_.minBidIndex = uint8(
                RAMProjectConfig_.slotsBitmap.minBitSet(removedSlotIndex + 1)
            );
        }
        // refund the removed bidder
        uint256 removedBidAmount = bidValueFromSlotIndex({
            RAMProjectConfig_: RAMProjectConfig_,
            slotIndex: removedSlotIndex
        });
        SplitFundsLib.forceSafeTransferETH({
            to: removedBidder,
            amount: removedBidAmount,
            minterRefundGasLimit: minterRefundGasLimit
        });
    }

    function bidValueFromSlotIndex(
        RAMProjectConfig storage RAMProjectConfig_,
        uint8 slotIndex
    ) internal view returns (uint256 amount) {
        // TODO - update this with an exponential spacing function
        uint256 range = RAMProjectConfig_.maxPrice -
            RAMProjectConfig_.basePrice;
        // TODO linear for now
        return ((range * slotIndex) / 255) + RAMProjectConfig_.basePrice;
    }

    function getMinBid(
        uint256 projectId,
        address coreContract
    ) internal view returns (Bid storage minBid, uint8 minSlotIndex) {
        // get first slot with an active bid
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        minSlotIndex = RAMProjectConfig_.minBidIndex;
        // get the bids array for that slot
        Bid[] storage bids = RAMProjectConfig_.bidsBySlot[minSlotIndex];
        // get the last active bid in the array
        // @dev get last because earlier bids (lower index) have priority
        minBid = bids[bids.length - 1];
    }

    function getAuctionDetails(
        uint256 projectId,
        address coreContract
    )
        internal
        view
        returns (
            uint40 auctionTimestampStart,
            uint40 auctionTimestampEnd,
            uint88 maxPrice,
            uint88 basePrice,
            uint24 numTokensInAuction,
            uint24 numBids
        )
    {
        // get project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // get auction details
        auctionTimestampStart = RAMProjectConfig_.timestampStart;
        auctionTimestampEnd = RAMProjectConfig_.timestampEnd;
        maxPrice = RAMProjectConfig_.maxPrice;
        basePrice = RAMProjectConfig_.basePrice;
        numTokensInAuction = RAMProjectConfig_.numTokensInAuction;
        numBids = RAMProjectConfig_.numBids;
    }

    function getState(
        uint256 projectId,
        address coreContract
    ) internal view returns (ProjectMinterStates) {
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // State A: Pre-Auction
        // @dev load to memory for gas efficiency
        uint256 timestampStart = RAMProjectConfig_.timestampStart;
        // helper value(s) for readability
        bool auctionIsConfigured = timestampStart > 0;
        bool isPreAuction = block.timestamp < timestampStart;
        // confirm that auction is either not configured or is pre-auction
        if ((!auctionIsConfigured) || isPreAuction) {
            return ProjectMinterStates.A;
        }
        // State B: Live-Auction
        // @dev auction is configured due to previous State A return
        // helper value(s) for readability
        // @dev load to memory for gas efficiency
        uint256 timestampEnd = RAMProjectConfig_.timestampEnd;
        bool isPostAuction = block.timestamp > timestampEnd;
        bool isLiveAuction = !(isPreAuction || isPostAuction);
        if (isLiveAuction) {
            return ProjectMinterStates.B;
        }
        // States C, D, E: Post-Auction, not all winners sent tokens, 24h
        // @dev auction is configured and post auction due to previous States A, B returns
        // all winners sent tokens means all bids have either been minted tokens or refunded if error state occurred
        bool allBidsHandled = RAMProjectConfig_.numBidsMintedTokens +
            RAMProjectConfig_.numBidsErrorRefunded ==
            RAMProjectConfig_.numBids;
        if (allBidsHandled) {
            // State E: Post-Auction, all bids handled
            return ProjectMinterStates.E;
        }
        // @dev all bids not handled due to previous State E return
        // helper value(s) for readability
        bool within24h = block.timestamp < timestampEnd + TWENTY_FOUR_HOURS;
        if (within24h) {
            // State C: Post-Auction, not all bids handled, 24h
            return ProjectMinterStates.C;
        }
        // State D: Post-Auction, not all bids handled, post-24h
        // @dev states are mutually exclusive, so must be in final remaining state
        return ProjectMinterStates.D;
    }

    /**
     * @notice Returns if project minter is in FLAG state F1.
     * F1: tokens owed < invocations available
     * Occurs when: auction ends before selling out
     * @param projectId Project Id to query
     * @param coreContract Core contract address to query
     */
    function isFlagF1(
        uint256 projectId,
        address coreContract
    ) internal view returns (bool) {
        // get project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // F1: Tokens owed < invocations available
        // @dev underflow impossible given what the parameters represent
        uint256 tokensOwed = RAMProjectConfig_.numBids -
            (RAMProjectConfig_.numBidsMintedTokens +
                RAMProjectConfig_.numBidsErrorRefunded);
        uint256 invocationsAvailable = MaxInvocationsLib
            .getInvocationsAvailable({
                projectId: projectId,
                coreContract: coreContract
            });
        return tokensOwed < invocationsAvailable;
    }

    /**
     * @notice Returns if project minter is in ERROR state E1.
     * E1: Tokens owed > invocations available
     * Occurs when: tokens are minted on different minter after auction begins,
     * or when core contract max invocations are reduced after auction begins.
     * Resolution: Admin must refund the lowest bids after auction ends.
     * @param projectId Project Id to query
     * @param coreContract Core contract address to query
     */
    function isErrorE1(
        uint256 projectId,
        address coreContract
    ) internal view returns (bool) {
        // get project config
        RAMProjectConfig storage RAMProjectConfig_ = getRAMProjectConfig({
            projectId: projectId,
            coreContract: coreContract
        });
        // E1: Tokens owed > invocations available
        // @dev underflow impossible given what the parameters represent
        uint256 tokensOwed = RAMProjectConfig_.numBids -
            (RAMProjectConfig_.numBidsMintedTokens +
                RAMProjectConfig_.numBidsErrorRefunded);
        uint256 invocationsAvailable = MaxInvocationsLib
            .getInvocationsAvailable({
                projectId: projectId,
                coreContract: coreContract
            });
        return tokensOwed > invocationsAvailable;
    }

    /**
     * Loads the RAMProjectConfig for a given project and core
     * contract.
     * @param projectId Project Id to get config for
     * @param coreContract Core contract address to get config for
     */
    function getRAMProjectConfig(
        uint256 projectId,
        address coreContract
    ) internal view returns (RAMProjectConfig storage) {
        return s().RAMProjectConfigs[coreContract][projectId];
    }

    /**
     * @notice Return the storage struct for reading and writing. This library
     * uses a diamond storage pattern when managing storage.
     * @return storageStruct The SEALibStorage struct.
     */
    function s() internal pure returns (RAMLibStorage storage storageStruct) {
        bytes32 position = RAM_LIB_STORAGE_POSITION;
        assembly ("memory-safe") {
            storageStruct.slot := position
        }
    }
}
