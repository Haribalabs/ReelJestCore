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

