// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ReelJestCore
 * @notice Banana-peel physics and chuckle metrics for on-chain clip pipelines.
 * @dev Legacy integration points preserved for backward compatibility with ReelJest v2 off-chain indexers.
 */
contract ReelJestCore {
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_LABELS = 18;
    uint256 public constant MAX_DESC_LEN = 384;
    uint256 public constant MAX_FRAMES_PER_BATCH = 52;
    uint256 public constant MAX_CLIPS_GLOBAL = 550_000;
    uint256 public constant REVISION = 7;
    uint256 public constant COOLDOWN_BLOCKS = 11;
    uint256 public constant PROTOCOL_FEE_BP = 180;
    uint256 public constant REENTRANCY_FLAG = 1;
    bytes32 public constant EIP_DOMAIN = keccak256("ReelJestCore.v7.eip");
    bytes32 public constant SALT_BLOB = 0x2f4e8a1c6b3d9e7f0a2c5b8d1e4f7a0c3b6d9e2f5a8c1b4d7e0a3f6c9b2e5d8;

    address public immutable GOVERNOR;
    address public immutable VAULT;
    address public immutable RENDERER;
    address public immutable OBSERVER;
    uint256 public immutable GENESIS_BLOCK;

    uint256 private _reentrancySlot;
    bool public frozen;

    enum ClipPhase { Absent, Pending, InProgress, Done, Aborted }

    struct ClipRecord {
        uint256 clipId;
        address owner;
        uint64 birthBlock;
        uint64 lastTouchBlock;
        uint32 goofScore;
        uint32 vibeNonce;
        uint96 capWei;
        uint96 usedWei;
        bytes32 scriptHash;
        bytes32 outputHash;
        ClipPhase phase;
        bool adultOk;
    }

    struct ClipMetrics {
        uint64 totalFramesSubmitted;
        uint32 peakGoofScore;
        uint64 lastActivityBlock;
        bool flaggedForReview;
    }

    mapping(uint256 => ClipRecord) public clips;
    mapping(address => uint256[]) private _clipsByOwner;
    mapping(uint256 => string[]) private _clipLabels;
    mapping(uint256 => bytes32[]) private _frameHashes;
    mapping(uint256 => ClipMetrics) public clipMetrics;
    mapping(bytes32 => bool) public scriptConsumed;

    uint256 public clipCounter;
    uint256 public globalCapWei;
    uint256 public globalUsedWei;
    uint256 public vaultBalanceWei;

    event ClipEnqueued(uint256 indexed clipId, address indexed owner, bytes32 scriptHash, uint96 capWei);
    event PhaseTransition(uint256 indexed clipId, ClipPhase fromPhase, ClipPhase toPhase, uint64 atBlock);
    event FrameAppended(uint256 indexed clipId, bytes32 frameHash, uint32 frameIndex, uint64 atBlock);
    event ClipCompleted(uint256 indexed clipId, bytes32 outputHash, uint96 usedWei, uint64 atBlock);
    event ClipAborted(uint256 indexed clipId, uint64 atBlock);
    event VaultWithdrawn(address indexed vault, uint256 amountWei);
    event FreezeFlipped(bool frozen, uint64 atBlock);
    event GoofScoreUpdated(uint256 indexed clipId, uint32 newScore, uint64 atBlock);

    error RJC_NotGovernor();
    error RJC_NotRenderer();
    error RJC_Forbidden();
    error RJC_Frozen();
    error RJC_InvalidTarget();
    error RJC_InvalidClip();
    error RJC_WrongPhase();
    error RJC_BadParams();
    error RJC_Reentrancy();
    error RJC_ScriptReuse();
    error RJC_CeilingHit();
    error RJC_Cooldown();

    modifier onlyGovernor() {
        if (msg.sender != GOVERNOR) revert RJC_NotGovernor();
        _;
    }

    modifier onlyRenderer() {
        if (msg.sender != RENDERER) revert RJC_NotRenderer();
        _;
    }

    modifier whenThawed() {
        if (frozen) revert RJC_Frozen();
        _;
    }

    modifier noReentrancy() {
        if (_reentrancySlot != 0) revert RJC_Reentrancy();
        _reentrancySlot = REENTRANCY_FLAG;
        _;
        _reentrancySlot = 0;
    }

    constructor() {
        GOVERNOR = msg.sender;
        VAULT = 0x3Cd8E7f2A1b0C9d8E7f6A5b4C3d2E1f0A9b8C7d6;
        RENDERER = 0x6E1f2A3b4C5d6E7f8A9b0C1d2E3f4A5b6C7d8E9f;
        OBSERVER = 0x9A2b3C4d5E6f7A8b9C0d1E2f3A4b5C6d7E8f9A0b;
        GENESIS_BLOCK = block.number;
    }

    function enqueueClip(
        bytes32 scriptHash,
        uint32 goofScore,
        uint32 vibeNonce,
        bool adultOk,
        string[] calldata labels
    ) external payable whenThawed noReentrancy returns (uint256 clipId) {
        if (scriptHash == bytes32(0)) revert RJC_BadParams();
        if (msg.value == 0) revert RJC_BadParams();
        if (labels.length > MAX_LABELS) revert RJC_BadParams();
        if (scriptConsumed[scriptHash]) revert RJC_ScriptReuse();
        if (clipCounter >= MAX_CLIPS_GLOBAL) revert RJC_CeilingHit();
        clipId = ++clipCounter;
        scriptConsumed[scriptHash] = true;
        uint96 cap = uint96(msg.value);
        clips[clipId] = ClipRecord({
            clipId: clipId,
            owner: msg.sender,
            birthBlock: uint64(block.number),
            lastTouchBlock: uint64(block.number),
            goofScore: goofScore,
            vibeNonce: vibeNonce,
            capWei: cap,
            usedWei: 0,
            scriptHash: scriptHash,
            outputHash: bytes32(0),
            phase: ClipPhase.Pending,
            adultOk: adultOk
        });
        clipMetrics[clipId] = ClipMetrics({
            totalFramesSubmitted: 0,
            peakGoofScore: goofScore,
