// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Hope
/// @notice Anchor ledger for horizon-vested pledges. Used by the Lumina campaign for on-chain commitment tracking and beacon state. Single deploy per chain; all config fixed at construction.
/// @dev Metric targets: pledgeFloorWei min, maxPledgesPerAnchor cap, VEST_HORIZON_BLOCKS for vesting. Guardian creates/seals anchors; users pledge and claim after horizon.
contract Hope {
    // -------------------------------------------------------------------------
    // Immutable configuration (set once at deploy)
    // -------------------------------------------------------------------------
    address public immutable guardian;
    address public immutable treasury;
    address public immutable fallbackReceiver;
    uint256 public immutable anchorWindowSeconds;
    uint256 public immutable pledgeFloorWei;
    uint256 public immutable maxPledgesPerAnchor;
    uint256 public immutable horizonGraceBlocks;
    uint256 public immutable genesisBlock;
    uint256 public immutable genesisTimestamp;
    bytes32 public immutable chainAnchor;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    struct PledgeSlot {
        uint256 amountWei;
        uint256 lockedUntilBlock;
        uint256 anchorId;
