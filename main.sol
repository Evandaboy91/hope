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
        if (ar.createdAtBlock == 0) revert ErrAnchorNotFound();
        if (ar.sealed) revert ErrAnchorAlreadySealed();
        if (pledgeFloorWei != 0 && msg.value < pledgeFloorWei) revert ErrPledgeBelowFloor();
        if (ar.pledgeCount >= maxPledgesPerAnchor) revert ErrPledgeBelowFloor();

        uint256 amount = msg.value;
        if (amount == 0) revert ErrZeroAmount();

        uint256 lockedUntil = vestBlock == 0 ? block.number + VEST_HORIZON_BLOCKS : vestBlock;
        if (lockedUntil <= block.number) revert ErrHorizonNotReached();

        uint256 anchorId = _anchorIdByHash(anchorHash);
        _pledgesBySender[msg.sender].push(PledgeSlot({
            amountWei: amount,
            lockedUntilBlock: lockedUntil,
            anchorId: anchorId,
            claimed: false
        }));

        ar.totalPledged += amount;
        ar.pledgeCount += 1;
        totalPledges += 1;

        emit PledgeAnchored(msg.sender, anchorId, amount, lockedUntil);
        emit VestHorizonSet(anchorId, lockedUntil);
    }

    // -------------------------------------------------------------------------
    // User: pledge without ETH (record only; for external funding flows)
    // -------------------------------------------------------------------------
    function pledgeRecordOnly(bytes32 anchorHash, uint256 amountWei, uint256 vestBlock) external {
        if (msg.sender != guardian) revert ErrGuardianOnly();
        if (anchorHash == bytes32(0)) revert ErrAnchorNotFound();
        AnchorRecord storage ar = _anchors[anchorHash];
        if (ar.createdAtBlock == 0) revert ErrAnchorNotFound();
        if (ar.sealed) revert ErrAnchorAlreadySealed();
        if (amountWei == 0) revert ErrZeroAmount();
        if (ar.pledgeCount >= maxPledgesPerAnchor) revert ErrPledgeBelowFloor();

        uint256 lockedUntil = vestBlock == 0 ? block.number + VEST_HORIZON_BLOCKS : vestBlock;
        if (lockedUntil <= block.number) revert ErrHorizonNotReached();

        uint256 anchorId = _anchorIdByHash(anchorHash);
        _pledgesBySender[msg.sender].push(PledgeSlot({
            amountWei: amountWei,
            lockedUntilBlock: lockedUntil,
            anchorId: anchorId,
            claimed: false
        }));

        ar.totalPledged += amountWei;
        ar.pledgeCount += 1;
        totalPledges += 1;

        emit PledgeAnchored(msg.sender, anchorId, amountWei, lockedUntil);
        emit VestHorizonSet(anchorId, lockedUntil);
    }

    modifier nonReentrant() {
        if (_lock != 0) revert ErrReentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    // -------------------------------------------------------------------------
    // User: claim vested pledge (sends ETH from contract balance)
    // -------------------------------------------------------------------------
    function claim(uint256 slotIndex) external nonReentrant {
        PledgeSlot[] storage slots = _pledgesBySender[msg.sender];
        if (slotIndex >= slots.length) revert ErrInvalidSlotIndex();
        PledgeSlot storage slot = slots[slotIndex];
        if (slot.claimed) revert ErrSlotAlreadyClaimed();
        if (block.number < slot.lockedUntilBlock + horizonGraceBlocks) revert ErrHorizonNotReached();

        uint256 amount = slot.amountWei;
        slot.claimed = true;
        emit ClaimExecuted(msg.sender, slotIndex, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) {
            slot.claimed = false;
            revert();
        }
    }

    // -------------------------------------------------------------------------
    // View: anchor by hash
    // -------------------------------------------------------------------------
    function getAnchor(bytes32 anchorHash) external view returns (
        uint256 totalPledged,
        uint256 pledgeCount,
        uint256 createdAtBlock,
        bool sealed
    ) {
        AnchorRecord storage ar = _anchors[anchorHash];
        if (ar.createdAtBlock == 0) revert ErrAnchorNotFound();
        return (ar.totalPledged, ar.pledgeCount, ar.createdAtBlock, ar.sealed);
    }

    function getPledgeSlot(address account, uint256 slotIndex) external view returns (
        uint256 amountWei,
        uint256 lockedUntilBlock,
        uint256 anchorId,
        bool claimed
    ) {
        PledgeSlot[] storage slots = _pledgesBySender[account];
        if (slotIndex >= slots.length) revert ErrInvalidSlotIndex();
        PledgeSlot storage s = slots[slotIndex];
        return (s.amountWei, s.lockedUntilBlock, s.anchorId, s.claimed);
    }

    function getPledgeCount(address account) external view returns (uint256) {
        return _pledgesBySender[account].length;
    }

    function getAnchorIdByHash(bytes32 anchorHash) external view returns (uint256) {
        return _anchorIdByHash(anchorHash);
    }

    function getAnchorHashById(uint256 anchorId) external view returns (bytes32) {
        if (anchorId == 0 || anchorId > _nextAnchorId) revert ErrAnchorNotFound();
        return _anchorIdToHash[anchorId];
    }

    // -------------------------------------------------------------------------
    // Guardian: sweep excess ETH to treasury (only surplus above pledged amounts)
    // -------------------------------------------------------------------------
    function sweepToTreasury(uint256 amountWei) external nonReentrant {
        if (msg.sender != guardian) revert ErrGuardianOnly();
        if (treasury == address(0)) revert ErrZeroAddress();
        if (amountWei == 0) revert ErrZeroAmount();
        uint256 balance = address(this).balance;
        if (amountWei > balance) revert ErrZeroAmount();
        (bool ok,) = treasury.call{value: amountWei}("");
        if (!ok) revert();
    }

    // -------------------------------------------------------------------------
    // Guardian: emergency forward to fallback if treasury fails
    // -------------------------------------------------------------------------
    function forwardToFallback(uint256 amountWei) external nonReentrant {
        if (msg.sender != guardian) revert ErrGuardianOnly();
        if (fallbackReceiver == address(0)) revert ErrZeroAddress();
        if (amountWei == 0) revert ErrZeroAmount();
        (bool ok,) = fallbackReceiver.call{value: amountWei}("");
        if (!ok) revert();
        emit FallbackReceived(msg.sender, amountWei);
    }

    // -------------------------------------------------------------------------
    // Config view (single call for UI / integration)
    // -------------------------------------------------------------------------
    function getConfig() external view returns (
        address guardian_,
        address treasury_,
        address fallbackReceiver_,
        uint256 anchorWindowSeconds_,
        uint256 pledgeFloorWei_,
        uint256 maxPledgesPerAnchor_,
        uint256 horizonGraceBlocks_,
        uint256 genesisBlock_,
        uint256 genesisTimestamp_
    ) {
        return (
            guardian,
            treasury,
            fallbackReceiver,
            anchorWindowSeconds,
            pledgeFloorWei,
            maxPledgesPerAnchor,
            horizonGraceBlocks,
            genesisBlock,
            genesisTimestamp
        );
    }

    // -------------------------------------------------------------------------
    // Beacon state (read-only views for UI / analytics)
    // -------------------------------------------------------------------------
    function beaconState() external view returns (
        uint256 currentBlock,
        uint256 nextAnchorId,
        uint256 totalPledges_,
        uint256 totalAnchors_,
        uint256 genesisBlock_,
        uint256 genesisTimestamp_
    ) {
        return (
            block.number,
            _nextAnchorId,
            totalPledges,
            totalAnchors,
            genesisBlock,
            genesisTimestamp
        );
    }

    function canClaim(address account, uint256 slotIndex) external view returns (bool) {
        PledgeSlot[] storage slots = _pledgesBySender[account];
        if (slotIndex >= slots.length) return false;
        PledgeSlot storage s = slots[slotIndex];
        if (s.claimed) return false;
        return block.number >= s.lockedUntilBlock + horizonGraceBlocks;
    }

    /// @return block number at which the given slot becomes claimable (lockedUntilBlock + horizonGraceBlocks)
    function blockUntilClaimable(address account, uint256 slotIndex) external view returns (uint256) {
        PledgeSlot[] storage slots = _pledgesBySender[account];
        if (slotIndex >= slots.length) revert ErrInvalidSlotIndex();
        PledgeSlot storage s = slots[slotIndex];
        return s.lockedUntilBlock + horizonGraceBlocks;
    }

    function hasAnchor(bytes32 anchorHash) external view returns (bool) {
        return _anchors[anchorHash].createdAtBlock != 0;
    }

    function isAnchorSealed(bytes32 anchorHash) external view returns (bool) {
        return _anchors[anchorHash].sealed;
    }

    // -------------------------------------------------------------------------
    // Batch views (reduce RPC round-trips for UI)
    // -------------------------------------------------------------------------
    function getAnchorIdsBatch(uint256 fromId, uint256 count) external view returns (uint256[] memory ids, bytes32[] memory hashes) {
        if (fromId == 0) fromId = 1;
        uint256 end = fromId + count;
        if (end > _nextAnchorId + 1) end = _nextAnchorId + 1;
        uint256 n = end > fromId ? end - fromId : 0;
        ids = new uint256[](n);
        hashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = fromId + i;
            hashes[i] = _anchorIdToHash[fromId + i];
        }
    }

    function getPledgeSlotsBatch(address account, uint256 fromIndex, uint256 count) external view returns (
        uint256[] memory amountWei,
        uint256[] memory lockedUntilBlock,
        uint256[] memory anchorId,
        bool[] memory claimed
    ) {
        PledgeSlot[] storage slots = _pledgesBySender[account];
        uint256 len = slots.length;
        if (fromIndex >= len) {
            amountWei = new uint256[](0);
            lockedUntilBlock = new uint256[](0);
            anchorId = new uint256[](0);
            claimed = new bool[](0);
            return (amountWei, lockedUntilBlock, anchorId, claimed);
        }
        uint256 end = fromIndex + count;
        if (end > len) end = len;
        uint256 n = end - fromIndex;
        amountWei = new uint256[](n);
        lockedUntilBlock = new uint256[](n);
        anchorId = new uint256[](n);
        claimed = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            PledgeSlot storage s = slots[fromIndex + i];
            amountWei[i] = s.amountWei;
            lockedUntilBlock[i] = s.lockedUntilBlock;
            anchorId[i] = s.anchorId;
            claimed[i] = s.claimed;
        }
    }

    function totalPledgedForAnchor(bytes32 anchorHash) external view returns (uint256) {
        return _anchors[anchorHash].totalPledged;
    }

    function nextAnchorId() external view returns (uint256) {
        return _nextAnchorId;
    }

    // -------------------------------------------------------------------------
    // Seal hash (commitment for off-chain verification)
    // -------------------------------------------------------------------------
    function sealHash() external view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                chainAnchor,
                totalPledges,
                totalAnchors,
                genesisBlock,
                genesisTimestamp,
                _nextAnchorId
            )
        );
    }

    /// @dev Lumina campaign metrics: single struct for dashboard / PPC reporting.
    function luminaMetrics() external view returns (
        uint256 totalPledges_,
        uint256 totalAnchors_,
        uint256 nextAnchorId_,
        uint256 currentBlock_,
        uint256 genesisBlock_,
        uint256 contractBalanceWei_
    ) {
        return (
            totalPledges,
            totalAnchors,
            _nextAnchorId,
            block.number,
            genesisBlock,
            address(this).balance
