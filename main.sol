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
        bytes32 domain
    ) {
        return (MAX_LABELS, MAX_DESC_LEN, MAX_FRAMES_PER_BATCH, MAX_CLIPS_GLOBAL, REVISION, COOLDOWN_BLOCKS, PROTOCOL_FEE_BP, EIP_DOMAIN);
    }

    function getRoleAddresses() external view returns (address governor, address vault, address renderer, address observer) {
        return (GOVERNOR, VAULT, RENDERER, OBSERVER);
    }

    function globalStats() external view returns (
        uint256 totalClips,
        uint256 totalCapWei,
        uint256 totalUsedWei,
        uint256 vaultAccruedWei,
        bool isFrozen
    ) {
        return (clipCounter, globalCapWei, globalUsedWei, vaultBalanceWei, frozen);
    }

    function isClipDone(uint256 clipId) external view returns (bool) {
        return clips[clipId].phase == ClipPhase.Done;
    }

    function computeFee(uint256 usedWei) external pure returns (uint256) {
        return (usedWei * PROTOCOL_FEE_BP) / BASIS_POINTS;
    }

    function clipPhaseName(uint256 clipId) external view returns (uint8) {
        return uint8(clips[clipId].phase);
    }

    function totalFramesForClip(uint256 clipId) external view returns (uint256) {
        return _frameHashes[clipId].length;
    }

    function hasScriptBeenUsed(bytes32 scriptHash) external view returns (bool) {
        return scriptConsumed[scriptHash];
    }

    uint256 public constant MAX_BULK_QUERY = 88;
    uint256 public constant MIN_GOOF_SCORE = 0;
    uint256 public constant MAX_GOOF_SCORE = 99999;
    uint256 public constant BLOCKS_PER_EPOCH = 64;
    uint256 public constant EPOCH_REWARD_SCALE_BP = 50;
    bytes32 public constant VERSION_TAG = keccak256("ReelJestCore.0x_vidgen_sup.7");

    struct ClipSummary {
        uint256 clipId;
        address owner;
        uint32 goofScore;
        uint96 capWei;
        uint96 usedWei;
        ClipPhase phase;
        uint64 birthBlock;
    }

    struct BulkClipResult {
        ClipSummary[] summaries;
        uint256 nextOffset;
        bool hasMore;
    }

    function getClipSummaries(uint256 fromId, uint256 count) external view returns (ClipSummary[] memory result) {
        if (count == 0 || count > MAX_BULK_QUERY) revert RJC_BadParams();
        uint256 end = fromId + count;
        if (end > clipCounter + 1) end = clipCounter + 1;
        uint256 len = end > fromId ? end - fromId : 0;
        result = new ClipSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = fromId + i;
            ClipRecord storage c = clips[id];
            if (c.clipId == 0) continue;
            result[i] = ClipSummary({
                clipId: c.clipId,
                owner: c.owner,
                goofScore: c.goofScore,
                capWei: c.capWei,
                usedWei: c.usedWei,
                phase: c.phase,
                birthBlock: c.birthBlock
            });
        }
    }

    function getBulkClips(uint256 offset, uint256 limit) external view returns (BulkClipResult memory) {
        if (limit > MAX_BULK_QUERY) limit = MAX_BULK_QUERY;
        uint256 total = clipCounter;
        if (offset >= total) {
            return BulkClipResult({ summaries: new ClipSummary[](0), nextOffset: offset, hasMore: false });
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        ClipSummary[] memory arr = new ClipSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = offset + i + 1;
            ClipRecord storage c = clips[id];
            arr[i] = ClipSummary({
                clipId: c.clipId,
                owner: c.owner,
                goofScore: c.goofScore,
                capWei: c.capWei,
                usedWei: c.usedWei,
                phase: c.phase,
                birthBlock: c.birthBlock
            });
        }
        return BulkClipResult({
            summaries: arr,
            nextOffset: end,
            hasMore: end < total
        });
    }

    function getClipsInPhase(ClipPhase phase, uint256 fromId, uint256 count) external view returns (uint256[] memory ids) {
        if (count > MAX_BULK_QUERY) count = MAX_BULK_QUERY;
        uint256[] memory temp = new uint256[](count);
        uint256 found = 0;
        uint256 start = fromId == 0 ? 1 : fromId;
        for (uint256 id = start; id <= clipCounter && found < count; id++) {
            if (clips[id].phase == phase) {
                temp[found] = id;
                found++;
            }
        }
        ids = new uint256[](found);
        for (uint256 i = 0; i < found; i++) ids[i] = temp[i];
    }

    function countClipsByPhase(ClipPhase phase) external view returns (uint256) {
        uint256 n = 0;
        for (uint256 id = 1; id <= clipCounter; id++) {
            if (clips[id].phase == phase) n++;
        }
        return n;
    }

    function getOwnerClipCount(address owner) external view returns (uint256) {
        return _clipsByOwner[owner].length;
    }

    function getOwnerClipsPaginated(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage arr = _clipsByOwner[owner];
        if (offset >= arr.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > arr.length) end = arr.length;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = arr[offset + i];
    }

    function getClipOutputHash(uint256 clipId) external view returns (bytes32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].outputHash;
    }

    function getClipScriptHash(uint256 clipId) external view returns (bytes32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].scriptHash;
    }

    function getClipOwner(uint256 clipId) external view returns (address) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].owner;
    }

    function getClipCapWei(uint256 clipId) external view returns (uint96) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].capWei;
    }

    function getClipUsedWei(uint256 clipId) external view returns (uint96) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].usedWei;
    }

    function getClipBirthBlock(uint256 clipId) external view returns (uint64) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].birthBlock;
    }

    function getClipLastTouchBlock(uint256 clipId) external view returns (uint64) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].lastTouchBlock;
    }

    function getClipGoofScore(uint256 clipId) external view returns (uint32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].goofScore;
    }

    function getClipVibeNonce(uint256 clipId) external view returns (uint32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].vibeNonce;
    }

    function getClipAdultOk(uint256 clipId) external view returns (bool) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].adultOk;
    }

    function getMetricsTotalFrames(uint256 clipId) external view returns (uint64) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clipMetrics[clipId].totalFramesSubmitted;
    }

    function getMetricsPeakGoof(uint256 clipId) external view returns (uint32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clipMetrics[clipId].peakGoofScore;
    }

    function getMetricsLastActivity(uint256 clipId) external view returns (uint64) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clipMetrics[clipId].lastActivityBlock;
    }

    function getMetricsFlagged(uint256 clipId) external view returns (bool) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clipMetrics[clipId].flaggedForReview;
    }

    function blocksSinceGenesis() external view returns (uint256) {
        return block.number - GENESIS_BLOCK;
    }

    function currentEpoch() external view returns (uint256) {
        return (block.number - GENESIS_BLOCK) / BLOCKS_PER_EPOCH;
    }

    function epochAtBlock(uint256 blockNum) external view returns (uint256) {
        if (blockNum < GENESIS_BLOCK) return 0;
        return (blockNum - GENESIS_BLOCK) / BLOCKS_PER_EPOCH;
    }

    function estimateRefund(uint256 clipId, uint96 proposedUsedWei) external view returns (uint256 refundWei, uint256 feeWei) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        ClipRecord storage c = clips[clipId];
        if (proposedUsedWei > c.capWei) return (0, 0);
        feeWei = (uint256(proposedUsedWei) * PROTOCOL_FEE_BP) / BASIS_POINTS;
        refundWei = uint256(c.capWei) - uint256(proposedUsedWei);
    }

    function canStartRendering(uint256 clipId) external view returns (bool) {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0 || c.phase != ClipPhase.Pending) return false;
        return block.number >= uint256(c.lastTouchBlock) + COOLDOWN_BLOCKS;
    }

    function blocksUntilRenderingAllowed(uint256 clipId) external view returns (uint256) {
        ClipRecord storage c = clips[clipId];
        if (c.clipId == 0 || c.phase != ClipPhase.Pending) return 0;
        uint256 required = uint256(c.lastTouchBlock) + COOLDOWN_BLOCKS;
        if (block.number >= required) return 0;
        return required - block.number;
    }

    function getConfigCompact() external pure returns (
        uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g, uint256 h
    ) {
        return (
            MAX_LABELS,
            MAX_DESC_LEN,
            MAX_FRAMES_PER_BATCH,
            MAX_CLIPS_GLOBAL,
            REVISION,
            COOLDOWN_BLOCKS,
            PROTOCOL_FEE_BP,
            MAX_BULK_QUERY
        );
    }

    function getDomainAndVersion() external pure returns (bytes32 domain, bytes32 version) {
        return (EIP_DOMAIN, VERSION_TAG);
    }

    function getSaltBlob() external pure returns (bytes32) {
        return SALT_BLOB;
    }

    function getGenesisBlock() external view returns (uint256) {
        return GENESIS_BLOCK;
    }

    function getGovernor() external view returns (address) {
        return GOVERNOR;
    }

    function getVault() external view returns (address) {
        return VAULT;
    }

    function getRenderer() external view returns (address) {
        return RENDERER;
    }

    function getObserver() external view returns (address) {
        return OBSERVER;
    }

    function isFrozen() external view returns (bool) {
        return frozen;
    }

    function getClipCounter() external view returns (uint256) {
        return clipCounter;
    }

    function getGlobalCapWei() external view returns (uint256) {
        return globalCapWei;
    }

    function getGlobalUsedWei() external view returns (uint256) {
        return globalUsedWei;
    }

    function getVaultBalanceWei() external view returns (uint256) {
        return vaultBalanceWei;
    }

    function getClipRecordFull(uint256 clipId) external view returns (
        uint256 id,
        address ownerAddr,
        uint64 birthBlk,
        uint64 lastBlk,
        uint32 goof,
        uint32 vibe,
        uint96 cap,
        uint96 used,
        bytes32 scriptH,
        bytes32 outputH,
        ClipPhase ph,
        bool adult
    ) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        ClipRecord storage c = clips[clipId];
        return (
            c.clipId,
            c.owner,
            c.birthBlock,
            c.lastTouchBlock,
            c.goofScore,
            c.vibeNonce,
            c.capWei,
            c.usedWei,
            c.scriptHash,
            c.outputHash,
            c.phase,
            c.adultOk
        );
    }

    function getFrameHashAt(uint256 clipId, uint256 index) external view returns (bytes32) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        bytes32[] storage f = _frameHashes[clipId];
        if (index >= f.length) revert RJC_BadParams();
        return f[index];
    }

    function getLabelAt(uint256 clipId, uint256 index) external view returns (string memory) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        string[] storage labels = _clipLabels[clipId];
        if (index >= labels.length) revert RJC_BadParams();
        return labels[index];
    }

    function getLabelCount(uint256 clipId) external view returns (uint256) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return _clipLabels[clipId].length;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }

    function protocolInfo() external pure returns (string memory name, uint256 rev, bytes32 domain) {
        name = "ReelJestCore";
        rev = REVISION;
        domain = EIP_DOMAIN;
    }

    function getPhaseName(ClipPhase phase) external pure returns (string memory) {
        if (phase == ClipPhase.Absent) return "Absent";
        if (phase == ClipPhase.Pending) return "Pending";
        if (phase == ClipPhase.InProgress) return "InProgress";
        if (phase == ClipPhase.Done) return "Done";
        if (phase == ClipPhase.Aborted) return "Aborted";
        return "Unknown";
    }

    function getPhaseFromClip(uint256 clipId) external view returns (ClipPhase) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return clips[clipId].phase;
    }

    function totalLabelsForClip(uint256 clipId) external view returns (uint256) {
        return _clipLabels[clipId].length;
    }

    function clipExists(uint256 clipId) external view returns (bool) {
        return clips[clipId].clipId != 0;
    }

    function getClipsByOwnerSlice(address owner, uint256 start, uint256 length) external view returns (uint256[] memory) {
        uint256[] storage arr = _clipsByOwner[owner];
        if (start >= arr.length) return new uint256[](0);
        uint256 end = start + length;
        if (end > arr.length) end = arr.length;
        uint256 len = end - start;
        uint256[] memory out = new uint256[](len);
        for (uint256 i = 0; i < len; i++) out[i] = arr[start + i];
        return out;
    }

    function aggregateCapByOwner(address owner) external view returns (uint256 total) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            total += clips[ids[i]].capWei;
        }
    }

    function aggregateUsedByOwner(address owner) external view returns (uint256 total) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            total += clips[ids[i]].usedWei;
        }
    }

    function aggregateDoneCountByOwner(address owner) external view returns (uint256 count) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            if (clips[ids[i]].phase == ClipPhase.Done) count++;
        }
    }

    function aggregatePendingCountByOwner(address owner) external view returns (uint256 count) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            if (clips[ids[i]].phase == ClipPhase.Pending) count++;
        }
    }

    function aggregateInProgressCountByOwner(address owner) external view returns (uint256 count) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            if (clips[ids[i]].phase == ClipPhase.InProgress) count++;
        }
    }

    function aggregateAbortedCountByOwner(address owner) external view returns (uint256 count) {
        uint256[] storage ids = _clipsByOwner[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            if (clips[ids[i]].phase == ClipPhase.Aborted) count++;
        }
    }

    function sumGlobalCapWei() external view returns (uint256) {
        return globalCapWei;
    }

    function sumGlobalUsedWei() external view returns (uint256) {
        return globalUsedWei;
    }

    function sumVaultBalanceWei() external view returns (uint256) {
        return vaultBalanceWei;
    }

    function checkScriptAvailable(bytes32 scriptHash) external view returns (bool) {
        return !scriptConsumed[scriptHash];
    }

    function remainingClipSlots() external view returns (uint256) {
        if (clipCounter >= MAX_CLIPS_GLOBAL) return 0;
        return MAX_CLIPS_GLOBAL - clipCounter;
    }

    function maxClipsGlobal() external pure returns (uint256) {
        return MAX_CLIPS_GLOBAL;
    }

    function maxLabels() external pure returns (uint256) {
        return MAX_LABELS;
    }

    function maxDescLen() external pure returns (uint256) {
        return MAX_DESC_LEN;
    }

    function maxFramesPerBatch() external pure returns (uint256) {
        return MAX_FRAMES_PER_BATCH;
    }

    function revision() external pure returns (uint256) {
        return REVISION;
    }

    function cooldownBlocks() external pure returns (uint256) {
        return COOLDOWN_BLOCKS;
    }

    function protocolFeeBp() external pure returns (uint256) {
        return PROTOCOL_FEE_BP;
    }

    function basisPoints() external pure returns (uint256) {
        return BASIS_POINTS;
    }

    function reentrancyFlagValue() external pure returns (uint256) {
        return REENTRANCY_FLAG;
    }

    function eipDomain() external pure returns (bytes32) {
        return EIP_DOMAIN;
    }

    function saltBlobConstant() external pure returns (bytes32) {
        return SALT_BLOB;
    }

    function versionTag() external pure returns (bytes32) {
        return VERSION_TAG;
    }

    function maxBulkQuery() external pure returns (uint256) {
        return MAX_BULK_QUERY;
    }

    function minGoofScore() external pure returns (uint256) {
        return MIN_GOOF_SCORE;
    }

    function maxGoofScore() external pure returns (uint256) {
        return MAX_GOOF_SCORE;
    }

    function blocksPerEpoch() external pure returns (uint256) {
        return BLOCKS_PER_EPOCH;
    }

    function epochRewardScaleBp() external pure returns (uint256) {
        return EPOCH_REWARD_SCALE_BP;
    }

    function getFramesBatch(uint256 clipId, uint256[] calldata indices) external view returns (bytes32[] memory out) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        bytes32[] storage f = _frameHashes[clipId];
        out = new bytes32[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < f.length) out[i] = f[indices[i]];
        }
    }

    function getLabelsBatch(uint256 clipId, uint256[] calldata indices) external view returns (string[] memory out) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        string[] storage labels = _clipLabels[clipId];
        out = new string[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < labels.length) out[i] = labels[indices[i]];
        }
    }

    function getClipIdsInRange(uint256 low, uint256 high) external view returns (uint256[] memory ids) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint256[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = low + i;
    }

    function getPhasesForRange(uint256 low, uint256 high) external view returns (uint8[] memory phases) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint8[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        phases = new uint8[](len);
        for (uint256 i = 0; i < len; i++) phases[i] = uint8(clips[low + i].phase);
    }

    function getOwnersForRange(uint256 low, uint256 high) external view returns (address[] memory owners) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new address[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        owners = new address[](len);
        for (uint256 i = 0; i < len; i++) owners[i] = clips[low + i].owner;
    }

    function getCapWeiForRange(uint256 low, uint256 high) external view returns (uint96[] memory caps) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint96[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        caps = new uint96[](len);
        for (uint256 i = 0; i < len; i++) caps[i] = clips[low + i].capWei;
    }

    function getUsedWeiForRange(uint256 low, uint256 high) external view returns (uint96[] memory used) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint96[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        used = new uint96[](len);
        for (uint256 i = 0; i < len; i++) used[i] = clips[low + i].usedWei;
    }

    function getScriptHashesForRange(uint256 low, uint256 high) external view returns (bytes32[] memory hashes) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new bytes32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) hashes[i] = clips[low + i].scriptHash;
    }

    function getOutputHashesForRange(uint256 low, uint256 high) external view returns (bytes32[] memory hashes) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new bytes32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) hashes[i] = clips[low + i].outputHash;
    }

    function getGoofScoresForRange(uint256 low, uint256 high) external view returns (uint32[] memory scores) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        scores = new uint32[](len);
        for (uint256 i = 0; i < len; i++) scores[i] = clips[low + i].goofScore;
    }

    function getBirthBlocksForRange(uint256 low, uint256 high) external view returns (uint64[] memory blocks) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint64[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        blocks = new uint64[](len);
        for (uint256 i = 0; i < len; i++) blocks[i] = clips[low + i].birthBlock;
    }

    function getLastTouchBlocksForRange(uint256 low, uint256 high) external view returns (uint64[] memory blocks) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new uint64[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        blocks = new uint64[](len);
        for (uint256 i = 0; i < len; i++) blocks[i] = clips[low + i].lastTouchBlock;
    }

    function getAdultOkForRange(uint256 low, uint256 high) external view returns (bool[] memory flags) {
        if (low == 0) low = 1;
        if (high > clipCounter) high = clipCounter;
        if (low > high) return new bool[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK_QUERY) len = MAX_BULK_QUERY;
        flags = new bool[](len);
        for (uint256 i = 0; i < len; i++) flags[i] = clips[low + i].adultOk;
    }

    function totalFrameCountGlobal() external view returns (uint256 total) {
        for (uint256 id = 1; id <= clipCounter; id++) {
            total += _frameHashes[id].length;
        }
    }

    function totalLabelCountGlobal() external view returns (uint256 total) {
        for (uint256 id = 1; id <= clipCounter; id++) {
            total += _clipLabels[id].length;
        }
    }

    function clipWithMostFrames() external view returns (uint256 clipId, uint256 frameCount) {
        for (uint256 id = 1; id <= clipCounter; id++) {
            uint256 len = _frameHashes[id].length;
            if (len > frameCount) {
                frameCount = len;
                clipId = id;
            }
        }
    }

    function clipWithHighestGoof(uint256 fromId, uint256 limit) external view returns (uint256 clipId, uint32 score) {
        uint256 end = fromId + limit;
        if (end > clipCounter) end = clipCounter + 1;
        for (uint256 id = fromId == 0 ? 1 : fromId; id < end; id++) {
            uint32 s = clipMetrics[id].peakGoofScore;
            if (s > score) {
                score = s;
                clipId = id;
            }
        }
    }

    function computeEpochFromBlock(uint256 blockNum) internal pure returns (uint256) {
        return blockNum / BLOCKS_PER_EPOCH;
    }

    function getEpochForClip(uint256 clipId) external view returns (uint256) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return computeEpochFromBlock(clips[clipId].birthBlock);
    }

    function getEpochForClipLastTouch(uint256 clipId) external view returns (uint256) {
        if (clips[clipId].clipId == 0) revert RJC_InvalidClip();
        return computeEpochFromBlock(clips[clipId].lastTouchBlock);
    }

    function feeForAmount(uint256 amountWei) external pure returns (uint256) {
        return (amountWei * PROTOCOL_FEE_BP) / BASIS_POINTS;
    }

    function netAfterFee(uint256 amountWei) external pure returns (uint256) {
        return amountWei - (amountWei * PROTOCOL_FEE_BP) / BASIS_POINTS;
    }

    function validateGoofScore(uint32 score) external pure returns (bool) {
        return score >= MIN_GOOF_SCORE && score <= MAX_GOOF_SCORE;
    }

    function validateLabelLength(string calldata label) external pure returns (bool) {
        uint256 len = bytes(label).length;
        return len > 0 && len <= MAX_DESC_LEN;
    }

    function validateLabelCount(uint256 count) external pure returns (bool) {
        return count <= MAX_LABELS;
    }

    function validateFrameBatchSize(uint256 size) external pure returns (bool) {
        return size > 0 && size <= MAX_FRAMES_PER_BATCH;
    }

    function validateClipId(uint256 clipId) external view returns (bool) {
        return clipId != 0 && clipId <= clipCounter && clips[clipId].clipId != 0;
    }

    function getClipRecordStruct(uint256 clipId) external view returns (ClipRecord memory) {
