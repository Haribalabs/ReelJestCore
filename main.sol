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
            lastActivityBlock: uint64(block.number),
            flaggedForReview: false
        });
        for (uint256 i = 0; i < labels.length; i++) {
            if (bytes(labels[i]).length == 0 || bytes(labels[i]).length > MAX_DESC_LEN) revert RJC_BadParams();
            _clipLabels[clipId].push(labels[i]);
        }
        _clipsByOwner[msg.sender].push(clipId);
        globalCapWei += msg.value;
        emit ClipEnqueued(clipId, msg.sender, scriptHash, cap);
    }

    function startRendering(uint256 clipId) external onlyRenderer whenThawed {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        if (c.phase != ClipPhase.Pending) revert RJC_WrongPhase();
        if (block.number < uint256(c.lastTouchBlock) + COOLDOWN_BLOCKS) revert RJC_Cooldown();
        ClipPhase oldPhase = c.phase;
        c.phase = ClipPhase.InProgress;
        c.lastTouchBlock = uint64(block.number);
        emit PhaseTransition(clipId, oldPhase, c.phase, uint64(block.number));
    }

    function pushFrames(uint256 clipId, bytes32[] calldata frameHashes) external onlyRenderer whenThawed {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        if (c.phase != ClipPhase.InProgress) revert RJC_WrongPhase();
        if (frameHashes.length == 0 || frameHashes.length > MAX_FRAMES_PER_BATCH) revert RJC_BadParams();
        ClipMetrics storage m = clipMetrics[clipId];
        for (uint256 i = 0; i < frameHashes.length; i++) {
            if (frameHashes[i] == bytes32(0)) revert RJC_BadParams();
            _frameHashes[clipId].push(frameHashes[i]);
            m.totalFramesSubmitted += 1;
            emit FrameAppended(clipId, frameHashes[i], uint32(_frameHashes[clipId].length - 1), uint64(block.number));
        }
        c.lastTouchBlock = uint64(block.number);
        m.lastActivityBlock = uint64(block.number);
    }

    function completeClip(uint256 clipId, bytes32 outputHash, uint96 usedWei) external onlyRenderer whenThawed noReentrancy {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        if (c.phase != ClipPhase.InProgress) revert RJC_WrongPhase();
        if (outputHash == bytes32(0)) revert RJC_BadParams();
        if (usedWei > c.capWei) revert RJC_BadParams();
        uint256 fee = (uint256(usedWei) * PROTOCOL_FEE_BP) / BASIS_POINTS;
        vaultBalanceWei += fee;
        globalUsedWei += usedWei;
        c.outputHash = outputHash;
        c.usedWei = usedWei;
        ClipPhase oldPhase = c.phase;
        c.phase = ClipPhase.Done;
        c.lastTouchBlock = uint64(block.number);
        uint256 refund = uint256(c.capWei) - uint256(usedWei);
        if (refund != 0) {
            (bool ok,) = payable(c.owner).call{ value: refund }("");
            if (!ok) revert RJC_Forbidden();
        }
        emit PhaseTransition(clipId, oldPhase, c.phase, uint64(block.number));
        emit ClipCompleted(clipId, outputHash, usedWei, uint64(block.number));
    }

    function abortClip(uint256 clipId) external noReentrancy {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        if (msg.sender != c.owner && msg.sender != GOVERNOR) revert RJC_Forbidden();
        if (c.phase == ClipPhase.Done || c.phase == ClipPhase.Absent || c.phase == ClipPhase.Aborted) revert RJC_WrongPhase();
        ClipPhase oldPhase = c.phase;
        c.phase = ClipPhase.Aborted;
        c.lastTouchBlock = uint64(block.number);
        uint256 cap = uint256(c.capWei);
        c.capWei = 0;
        if (cap != 0) {
            (bool ok,) = payable(c.owner).call{ value: cap }("");
            if (!ok) revert RJC_Forbidden();
        }
        emit PhaseTransition(clipId, oldPhase, c.phase, uint64(block.number));
        emit ClipAborted(clipId, uint64(block.number));
    }

    function withdrawVault() external noReentrancy {
        if (msg.sender != GOVERNOR && msg.sender != VAULT) revert RJC_Forbidden();
        uint256 amount = vaultBalanceWei;
        vaultBalanceWei = 0;
        if (amount != 0) {
            (bool ok,) = payable(VAULT).call{ value: amount }("");
            if (!ok) revert RJC_Forbidden();
            emit VaultWithdrawn(VAULT, amount);
        }
    }

    function setFreeze(bool freeze) external onlyGovernor {
        frozen = freeze;
        emit FreezeFlipped(frozen, uint64(block.number));
    }

    function updateGoofScore(uint256 clipId, uint32 newScore) external onlyRenderer whenThawed {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        ClipMetrics storage m = clipMetrics[clipId];
        if (newScore > m.peakGoofScore) m.peakGoofScore = newScore;
        c.goofScore = newScore;
        c.lastTouchBlock = uint64(block.number);
        emit GoofScoreUpdated(clipId, newScore, uint64(block.number));
    }

    function flagForReview(uint256 clipId, bool flag) external {
        if (msg.sender != GOVERNOR && msg.sender != OBSERVER) revert RJC_Forbidden();
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0) revert RJC_InvalidClip();
        clipMetrics[clipId].flaggedForReview = flag;
    }

    function getClip(uint256 clipId) external view returns (ClipRecord memory) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId];
    }

    function getClipLabels(uint256 clipId) external view returns (string[] memory) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return _clipLabels[clipId];
    }

    function getClipsByOwner(address owner) external view returns (uint256[] memory) {
        return _clipsByOwner[owner];
    }

    function getClipMetrics(uint256 clipId) external view returns (ClipMetrics memory) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clipMetrics[clipId];
    }

    function getFrames(uint256 clipId, uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        bytes32[] storage f = _frameHashes[clipId];
        if (offset >= f.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > f.length) end = f.length;
        out = new bytes32[](end - offset);
        for (uint256 i = 0; i < out.length; i++) out[i] = f[offset + i];
    }

    function getGlobalConfig() external pure returns (
        uint256 maxLabels,
        uint256 maxDescLen,
        uint256 maxFramesPerBatch,
        uint256 maxClipsGlobal,
        uint256 revision,
        uint256 cooldownBlocks,
        uint256 protocolFeeBp,
