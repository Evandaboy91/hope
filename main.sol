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
    // -------------------------------------------------------------------------
    error ErrGuardianOnly();
    error ErrAnchorAlreadySealed();
    error ErrPledgeBelowFloor();
    error ErrHorizonNotReached();
    error ErrAnchorNotFound();
    error ErrSlotAlreadyClaimed();
    error ErrZeroAmount();
    error ErrLabelTooLong();
    error ErrBeaconCooldown();
    error ErrAnchorNotSealed();
    error ErrInvalidSlotIndex();
    error ErrZeroAddress();
    error ErrReentrancy();

    // -------------------------------------------------------------------------
    // Events (unique signatures)
    // -------------------------------------------------------------------------
    event BeaconLit(uint256 indexed anchorId, bytes32 indexed anchorHash, uint256 totalPledged, uint256 pledgeCount);
    event PledgeAnchored(address indexed sender, uint256 indexed anchorId, uint256 amountWei, uint256 lockedUntilBlock);
    event VestHorizonSet(uint256 indexed anchorId, uint256 vestBlock);
    event ClaimExecuted(address indexed sender, uint256 slotIndex, uint256 amountWei);
    event AnchorSealed(bytes32 indexed anchorHash, uint256 totalPledged, uint256 pledgeCount);
    event FallbackReceived(address indexed from, uint256 amountWei);

    // -------------------------------------------------------------------------
    // Constructor — all config set here; no callable init
    // -------------------------------------------------------------------------
    constructor() {
        guardian = msg.sender;
        treasury = address(0xb4e2f6a8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2);
        fallbackReceiver = address(0x7c1d3e5a9b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0);
        anchorWindowSeconds = 259200;
        pledgeFloorWei = 0.001 ether;
        maxPledgesPerAnchor = 500;
        horizonGraceBlocks = 64;
        genesisBlock = block.number;
        genesisTimestamp = block.timestamp;
        chainAnchor = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                block.prevrandao,
                block.timestamp,
                "Hope_Lumina_Anchor_v1"
            )
        );
    }

    // -------------------------------------------------------------------------
    // Guardian-only: create and seal anchors
    // -------------------------------------------------------------------------
    function createAnchor(bytes32 anchorHash, bytes calldata label) external {
        if (msg.sender != guardian) revert ErrGuardianOnly();
        if (label.length > MAX_ANCHOR_LABEL_LEN) revert ErrLabelTooLong();
        if (_anchors[anchorHash].createdAtBlock != 0) revert ErrAnchorAlreadySealed();

        _nextAnchorId += 1;
        _anchorIdToHash[_nextAnchorId] = anchorHash;
        _anchors[anchorHash] = AnchorRecord({
            totalPledged: 0,
            pledgeCount: 0,
            createdAtBlock: block.number,
            sealed: false
        });
        totalAnchors += 1;
        emit BeaconLit(_nextAnchorId, anchorHash, 0, 0);
    }

    function sealAnchor(bytes32 anchorHash) external {
        if (msg.sender != guardian) revert ErrGuardianOnly();
        AnchorRecord storage ar = _anchors[anchorHash];
        if (ar.createdAtBlock == 0) revert ErrAnchorNotFound();
        if (ar.sealed) revert ErrAnchorAlreadySealed();
        ar.sealed = true;
        emit AnchorSealed(anchorHash, ar.totalPledged, ar.pledgeCount);
    }

    // -------------------------------------------------------------------------
    // User: pledge into an anchor (no ETH transfer; record only)
    // -------------------------------------------------------------------------
    function pledge(bytes32 anchorHash, uint256 vestBlock) external {
        if (anchorHash == bytes32(0)) revert ErrAnchorNotFound();
        AnchorRecord storage ar = _anchors[anchorHash];
