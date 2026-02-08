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
        bool claimed;
    }

    struct AnchorRecord {
        uint256 totalPledged;
        uint256 pledgeCount;
        uint256 createdAtBlock;
        bool sealed;
    }

    mapping(address => PledgeSlot[]) private _pledgesBySender;
    mapping(bytes32 => AnchorRecord) private _anchors;
    mapping(uint256 => bytes32) private _anchorIdToHash;
    uint256 private _nextAnchorId;
    uint256 public totalPledges;
    uint256 public totalAnchors;
    uint256 private _lock;

    // -------------------------------------------------------------------------
    // Constants (per-contract unique values)
    // -------------------------------------------------------------------------
    uint256 public constant VEST_HORIZON_BLOCKS = 17280;
    uint256 public constant BEACON_COOLDOWN_BLOCKS = 12;
    uint256 public constant MAX_ANCHOR_LABEL_LEN = 64;
    bytes32 public constant DOMAIN_LABEL = 0x8a3f91c2e4b6d8a0c2e4f6a8b0d2e4f6a8b0d2e4f6a8b0d2e4f6a8b0d2e4f6a;

    // -------------------------------------------------------------------------
    // Errors (unique names and messages)
