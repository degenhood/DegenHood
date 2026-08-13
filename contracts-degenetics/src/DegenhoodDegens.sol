// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEntropySource} from "./interfaces/IEntropySource.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";

/*//////////////////////////////////////////////////////////////////////////
    DEGENHOOD DEGENS — spec v0.2
    1,000 sealed packs · 66,666,666 $DEGEN backing each · hard floor
    Oracle-free tick pricing · weighted continuous distributor
    No snipe. No leaders. No limits. Just Degens.
//////////////////////////////////////////////////////////////////////////*/

contract DegenhoodDegens is ERC721, ReentrancyGuard, IERC2981 {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Canonical parameters (spec §2) — immutable by construction
    // ------------------------------------------------------------------
    uint256 public constant TOKENS_PER_NFT = 66_666_666e18;
    uint16 public constant MAX_SUPPLY = 1000;
    uint16 public constant PHASE1_SUPPLY = 500;
    // Activation: tier chosen AT activation (Stonk model — Base..T4 are alternative
    // activation costs, not upgrades). Locked until transfer clears it; re-activation
    // after any hand-change is a fresh choice.
    uint16 public constant MINT_FEE_BPS = 1000; // 10%, phase 2
    uint16 public constant REDEEM_FEE_BPS = 1000; // 10%
    uint16 public constant REROLL_FEE_BPS = 1500; // 15%
    uint16 public constant HOLDER_SHARE_BPS = 6666;
    uint16 public constant BURN_SHARE_BPS = 1667;
    // protocol share = remainder (1667)
    uint96 public constant ROYALTY_BPS = 333; // 3.33% (ERC-2981)
    uint16 public constant PHASE1_WALLET_CAP = 5;
    uint256 public constant CAP_WINDOW = 12 hours;

    // tier => activation cost / weight (1e4 units; base = 10000 = 1.0x)
    uint256[5] public TIER_COST = [6_666_666e18, 16_666_666e18, 33_333_333e18, 66_666_666e18, 166_666_666e18];
    uint32[5] public TIER_WEIGHT = [10_000, 12_500, 16_700, 22_200, 33_300];

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------
    // External systems (immutable wiring)
    // ------------------------------------------------------------------
    IERC20 public immutable degen;
    IPriceSource public immutable price;
    IEntropySource public immutable entropy;
    address public immutable treasury; // fee sink ONLY - never needs to sign
    address public admin; // signs the rare admin ops (URIs, provenance, one-shots); storage not immutable - saves runtime size, ops are rare

    // ------------------------------------------------------------------
    // Supply / escrow state
    // ------------------------------------------------------------------
    uint16 public minted; // NFTs ever minted (monotonic, <= MAX_SUPPLY)
    uint16 public outstanding; // held by users (minted - inventory count)
    uint256 public escrowBalance; // MUST equal outstanding * TOKENS_PER_NFT
    uint256 public phase1OpenedAt;
    mapping(address => uint16) public phase1Minted;

    // vault inventory: tokenIds held by this contract, index for O(1) random pick
    uint16[] public inventory;
    mapping(uint256 => uint256) internal inventoryIndex; // tokenId => index+1 (0 = not in inventory)

    // ------------------------------------------------------------------
    // Reveal state (spec §12b two-stage)
    // ------------------------------------------------------------------
    enum RevealStage {
        Sealed,
        TierRevealed,
        ArtRevealed
    }

    struct Reveal {
        RevealStage stage;
        uint8 tier; // 0..4 = Common..Legendary (valid from TierRevealed)
        uint16 artIndex; // valid from ArtRevealed
        uint64 pendingRound; // entropy round awaited (0 = none)
        uint8 pendingKind; // 1 = tier rip, 2 = art assign, 3 = inventory draw
        uint8 voucherTier; // 0 = none; 1..4 = free booster-premium at that tier (set at tier reveal)
        bool voucherSpent; // one-time, bound to the tokenId, never regenerates
    }
    mapping(uint256 => Reveal) public reveals;

    // FWA/TokenWorks defense: strict FIFO over every entropy-consuming finalize.
    uint64 public requestSeq;
    uint64 public processedSeq;
    mapping(uint256 => uint64) public ripSeq;

    uint16[5] public tierRemaining = [600, 250, 100, 40, 10]; // committed census
    bytes32 public provenanceHash; // committed once, before Stage B
    bool public artFrozen;

    // ------------------------------------------------------------------
    // Distributor (spec §8): weighted continuous accumulator
    // ------------------------------------------------------------------
    uint256 public accEthPerWeight; // 1e18-scaled
    uint256 public accSpyPerWeight; // 1e18-scaled (SPY LP rewards lane)
    uint256 public totalWeight; // sum of active weights (1e4 units)
    mapping(uint256 => uint32) public weightOf; // 0 = not activated
    mapping(uint256 => uint256) public ethDebt;
    mapping(uint256 => uint256) public spyDebt;
    IERC20 public immutable spy;

    // ------------------------------------------------------------------
    // Distribution epoch (spec §8 amendment, 2026-08-06): the holder share
    // stacks in an on-chain pool until the collection has minted out AND at
    // least one Degen is activated; it then flushes pro-rata by weight and
    // distribution turns continuous. Any later zero-weight window defers
    // again until weight returns. Replaces the pre-activation treasury
    // fallback entirely - holder value never diverts to the treasury.
    // ------------------------------------------------------------------
    uint256 public pendingHolderEthWei; // stacked holder-share ETH awaiting flush
    uint256 public pendingHolderSpyWei; // stacked holder-share SPY awaiting flush
    bool public distributionOpened; // latched at the first flush after mint-out
    /// @notice Deadline fallback: if the collection has not minted out within 7 days
    /// of launch, the pool opens anyway at the next activation (or flush poke) - the
    /// mint-out FOMO story holds, but a stalled mint can never strand holder value.
    uint256 public immutable epochDeadline;

    // ------------------------------------------------------------------
    // Price cache (spec §5): per-block, oracle-free
    // ------------------------------------------------------------------
    uint64 internal cachedBlock;
    uint256 internal cachedNotionalWei; // ETH value of TOKENS_PER_NFT
    uint256 public feeFloorWei;
    uint256 public feeCapWei;

    // On-chain lore (spec: "the Hood remembers")
    mapping(uint256 => string[]) public lore;
    uint256 public constant LORE_COST = 666_666e18; // 50% burn / 50% protocol

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Minted(address indexed to, uint256 indexed tokenId, uint8 phase);
    event Redeemed(address indexed by, uint256 indexed tokenId);
    event RerollRequested(address indexed by, uint256 indexed depositedId, uint64 round);
    event Activated(uint256 indexed tokenId, address indexed by);
    event Boosted(uint256 indexed tokenId, uint8 tierIdx, uint32 newWeight);
    event VoucherRedeemed(uint256 indexed tokenId, uint8 tierIdx);
    event Deactivated(uint256 indexed tokenId);
    event TierRipRequested(uint256 indexed tokenId, uint64 round);
    event TierRevealed(uint256 indexed tokenId, uint8 tier);
    event ArtRevealed(uint256 indexed tokenId, uint16 artIndex);
    event Claimed(uint256 indexed tokenId, address indexed to, uint256 ethAmt, uint256 spyAmt);
    /// @notice Earnings source tag - makes the holder-revenue split provable on-chain.
    enum FeeSource {
        Action, // mint/reroll/swap/redeem ETH fees (routed by this contract's own actions)
        LpFee, // harvested WETH LP fees forwarded via notifyLpFees()
        Royalty, // marketplace royalties forwarded via notifyRoyalty()
        External // untagged inflows via receive()
    }

    event FeesRouted(uint8 indexed source, uint256 toHolders, uint256 toBurn, uint256 toTreasury);
    event SpyNotified(address indexed from, uint256 amount);
    /// @notice Holder share parked in the epoch pool (pre mint-out or zero weight).
    event HolderShareDeferred(uint256 ethAmt, uint256 spyAmt, uint256 ethPool, uint256 spyPool);
    /// @notice Holder value credited to the continuous distributor - emitted on EVERY
    /// credit (epoch-pool flushes and per-fee splits alike), so the lifetime total
    /// distributed to Degens is exactly the sum of this event.
    event HolderShareFlushed(uint256 ethAmt, uint256 spyAmt, uint256 totalWeight);
    /// @notice Latched once: mint-out reached with at least one activated Degen.
    event DistributionOpened(uint256 totalWeight);
    /// @notice Credits actually paid out to a wallet (the provable third stage).
    event Withdrawn(address indexed to, uint256 ethAmt, uint256 spyAmt);
    event MetadataUpdate(uint256 tokenId); // ERC-4906
    event LoreAppended(uint256 indexed tokenId, string entry);
    /// keeper index: every entropy request announces its FIFO position.
    /// kind: 1 = tier rip (refId = tokenId), 2 = art reveal (tokenId), 3 = draw (drawId)
    event EntropyQueued(uint64 indexed seq, uint8 kind, uint256 refId);

    error WrongPhase();
    error FeeTooHigh(); // exceeded caller's maxFeeWei slippage allowance
    error NotOwner();
    error NotRevealed();
    error CapExceeded();
    error EntropyNotReady();
    error NothingPending();

    constructor(address degen_, address spy_, address price_, address entropy_, address treasury_, address admin_)
        ERC721("Degenhood Degens", "DEGENS")
    {
        degen = IERC20(degen_);
        spy = IERC20(spy_);
        price = IPriceSource(price_);
        entropy = IEntropySource(entropy_);
        require(treasury_ != address(0) && admin_ != address(0), "zero");
        treasury = treasury_;
        admin = admin_;
        phase1OpenedAt = block.timestamp;
        epochDeadline = block.timestamp + 7 days;
        feeFloorWei = 0.0001 ether;
        feeCapWei = 10 ether;
    }

    // ==================================================================
    // PRICING — oracle-free, per-block cached (spec §5)
    // ==================================================================
    function _notionalWei() internal returns (uint256 n) {
        if (cachedBlock == uint64(block.number)) return cachedNotionalWei;
        uint256 sp = uint256(price.sqrtPriceX96());
        // price(WETH per DEGEN) = sp^2 / 2^192 ; both tokens 18 dec.
        // Overflow-safe: mulDiv keeps the 512-bit intermediate (ethskills: oracle math).
        uint256 priceX96 = Math.mulDiv(sp, sp, 1 << 96); // sp^2 / 2^96
        n = Math.mulDiv(TOKENS_PER_NFT, priceX96, 1 << 96); // / 2^96 again
        cachedBlock = uint64(block.number);
        cachedNotionalWei = n;
    }

    function _fee(uint16 bps, uint256 maxFeeWei) internal returns (uint256 f) {
        f = (_notionalWei() * bps) / 10_000;
        if (f < feeFloorWei) f = feeFloorWei;
        if (f > feeCapWei) f = feeCapWei;
        if (f > maxFeeWei) revert FeeTooHigh();
    }

    // ==================================================================
    // MINT (spec §4.2, §12b) — $DEGEN exclusively, sealed packs
    // ==================================================================
    function mintPhase1(uint16 qty) external nonReentrant {
        if (minted >= PHASE1_SUPPLY) revert WrongPhase();
        if (minted + qty > PHASE1_SUPPLY) revert WrongPhase();
        if (block.timestamp < phase1OpenedAt + CAP_WINDOW) {
            phase1Minted[msg.sender] += qty;
            if (phase1Minted[msg.sender] > PHASE1_WALLET_CAP) revert CapExceeded();
        }
        _pullBackingAndMint(qty, 1);
    }

    function mintPhase2(uint16 qty, uint256 maxFeeWei) external payable nonReentrant {
        if (minted < PHASE1_SUPPLY) revert WrongPhase();
        if (minted + qty > MAX_SUPPLY) revert WrongPhase();
        uint256 fee = _fee(MINT_FEE_BPS, maxFeeWei) * qty;
        require(msg.value >= fee, "fee");
        _pullBackingAndMint(qty, 2);
        _routeEth(fee, FeeSource.Action);
        _tryFlushHolderPool(); // the final mint is one of the two epoch triggers
        _refund(msg.value - fee);
    }

    function _pullBackingAndMint(uint16 qty, uint8 phase) internal {
        degen.safeTransferFrom(msg.sender, address(this), uint256(qty) * TOKENS_PER_NFT);
        escrowBalance += uint256(qty) * TOKENS_PER_NFT;
        for (uint16 i; i < qty; ++i) {
            uint256 id = ++minted;
            ++outstanding;
            _safeMint(msg.sender, id);
            emit Minted(msg.sender, id, phase);
        }
        _assertSolvency();
    }

    // ==================================================================
    // TIER RIP — stage A (spec §12b); free, optional, commit-reveal
    // ==================================================================
    function requestTierRip(uint256 id) public {
        if (ownerOf(id) != msg.sender && msg.sender != address(this)) revert NotOwner();
        require(minted >= PHASE1_SUPPLY, "phase 2");
        Reveal storage r = reveals[id];
        require(r.stage == RevealStage.Sealed && r.pendingRound == 0, "already");
        r.pendingRound = entropy.nextRound();
        r.pendingKind = 1;
        ripSeq[id] = ++requestSeq;
        emit TierRipRequested(id, r.pendingRound);
        emit EntropyQueued(requestSeq, 1, id);
    }

    /// @notice anyone may finalize once entropy lands — a bad roll cannot be abandoned
    function finalizeTierRip(uint256 id) public {
        Reveal storage r = reveals[id];
        if (r.pendingRound == 0 || r.pendingKind != 1) revert NothingPending();
        require(ripSeq[id] == processedSeq + 1, "out of order"); // strict FIFO
        bytes32 e = entropy.entropyOf(r.pendingRound); // reverts if not ready
        ++processedSeq;
        uint256 roll = uint256(keccak256(abi.encode(e, id, address(this))));
        r.tier = _drawTier(roll);
        r.voucherTier = r.tier; // Uncommon->T1 .. Legendary->T4; Common=0=none
        r.stage = RevealStage.TierRevealed;
        r.pendingRound = 0;
        emit TierRevealed(id, r.tier);
        emit MetadataUpdate(id);
    }

    function _drawTier(uint256 roll) internal returns (uint8) {
        uint256 total =
            uint256(tierRemaining[0]) + tierRemaining[1] + tierRemaining[2] + tierRemaining[3] + tierRemaining[4];
        uint256 x = roll % total;
        for (uint8 t; t < 5; ++t) {
            if (x < tierRemaining[t]) {
                --tierRemaining[t];
                return t;
            }
            x -= tierRemaining[t];
        }
        revert(); // unreachable
    }

    // ==================================================================
    // REDEEM (spec §4.2) — full backing out, ETH fee, NFT -> inventory
    // ==================================================================
    function redeem(uint256 id, uint256 maxFeeWei) external payable nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        uint256 fee = _fee(REDEEM_FEE_BPS, maxFeeWei);
        require(msg.value >= fee, "fee");

        // auto-rip sealed packs on the way into the vault (spec §12b.4).
        // Step 1: a sealed pack's redeem REQUESTS the rip and refunds everything —
        // call redeem again once entropy lands (seconds later) to complete.
        Reveal storage r = reveals[id];
        if (r.stage == RevealStage.Sealed) {
            if (r.pendingRound == 0) {
                requestTierRip(id);
                _refund(msg.value);
                return;
            }
            finalizeTierRip(id); // reverts if entropy not landed yet
        }

        // effects before interactions
        _transfer(msg.sender, address(this), id); // clears activation + force-claims via _update
        _pushInventory(id);
        --outstanding;
        escrowBalance -= TOKENS_PER_NFT;

        degen.safeTransfer(msg.sender, TOKENS_PER_NFT);
        _routeEth(fee, FeeSource.Action);
        _refund(msg.value - fee);
        emit Redeemed(msg.sender, id);
        _assertSolvency();
    }

    // ==================================================================
    // REROLL / RANDOM SWAP (spec §4.2) — VRNG random, never FIFO, no snipe
    // ==================================================================
    struct Draw {
        address claimant;
        uint256 depositedId;
        uint64 round;
        bool isSwap;
        uint64 seq;
    }
    mapping(uint256 => Draw) public draws; // drawId => request
    uint256 public nextDrawId;

    /// @notice deposit your Degen, draw a random other from inventory (15% ETH fee)
    function reroll(uint256 id, uint256 maxFeeWei) external payable nonReentrant returns (uint256 drawId) {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        require(minted >= PHASE1_SUPPLY, "phase 2 only");
        if (reveals[id].stage == RevealStage.Sealed) revert NotRevealed();
        require((MAX_SUPPLY - minted) + inventory.length > 0, "vault empty");
        uint256 fee = _fee(REROLL_FEE_BPS, maxFeeWei);
        require(msg.value >= fee, "fee");

        _transfer(msg.sender, address(this), id);
        _pushInventory(id);

        drawId = ++nextDrawId;
        draws[drawId] = Draw(msg.sender, id, entropy.nextRound(), false, ++requestSeq);
        _routeEth(fee, FeeSource.Action);
        _refund(msg.value - fee);
        emit RerollRequested(msg.sender, id, draws[drawId].round);
        emit EntropyQueued(requestSeq, 3, drawId);
    }

    /// @notice own nothing? buy a random Degen from inventory: full backing + reroll fee
    function swapRandom(uint256 maxFeeWei) external payable nonReentrant returns (uint256 drawId) {
        require(minted >= PHASE1_SUPPLY, "phase 2 only");
        require((MAX_SUPPLY - minted) + inventory.length > 0, "vault empty");
        uint256 fee = _fee(REROLL_FEE_BPS, maxFeeWei);
        require(msg.value >= fee, "fee");
        degen.safeTransferFrom(msg.sender, address(this), TOKENS_PER_NFT);
        escrowBalance += TOKENS_PER_NFT;

        drawId = ++nextDrawId;
        draws[drawId] = Draw(msg.sender, 0, entropy.nextRound(), true, ++requestSeq);
        _routeEth(fee, FeeSource.Action);
        _refund(msg.value - fee);
        emit EntropyQueued(requestSeq, 3, drawId);
    }

    /// @notice anyone may finalize; excludes the claimant's own deposit from the draw
    function finalizeDraw(uint256 drawId) external nonReentrant {
        Draw memory d = draws[drawId];
        require(d.claimant != address(0), "no draw");
        require(d.seq == processedSeq + 1, "out of order");
        bytes32 e = entropy.entropyOf(d.round);
        ++processedSeq;
        delete draws[drawId];
        uint256 freshLeft = MAX_SUPPLY - minted;
        uint256 invN = inventory.length;
        bool exclude = !d.isSwap && d.depositedId != 0 && inventoryIndex[d.depositedId] != 0;
        uint256 invAvail = exclude ? invN - 1 : invN;
        uint256 vaultN = freshLeft + invAvail;
        require(vaultN > 0, "vault empty");
        uint256 pick = uint256(keccak256(abi.encode(e, drawId))) % vaultN;
        uint256 wonId;
        if (pick < freshLeft) {
            wonId = ++minted;
            _mint(d.claimant, wonId);
        } else {
            uint256 idx = pick - freshLeft;
            if (exclude) {
                uint256 exIdx = inventoryIndex[d.depositedId] - 1;
                if (idx >= exIdx) idx += 1;
            }
            wonId = inventory[idx];
            _popInventory(wonId);
            _transfer(address(this), d.claimant, wonId);
        }
        if (d.isSwap) ++outstanding;
        emit MetadataUpdate(wonId);
        _assertSolvency();
        // A fresh pull can be the 1000th mint: draws must trigger the epoch too.
        _tryFlushHolderPool();
    }

    // ==================================================================
    // ACTIVATION & BOOSTERS (spec §8, §10) — cleared on every transfer
    // ==================================================================
    /// @notice choose your tier when you activate — Base (1.0x) through T4 (3.33x).
    /// One choice per activation cycle; any transfer clears it and the next
    /// activation picks fresh. No upgrades (climbing would overpay vs buying the
    /// target tier outright — Stonk model).
    function activate(uint256 id, uint8 tierIdx) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        require(tierIdx <= 4, "tier");
        require(weightOf[id] == 0, "active");
        Reveal storage rv = reveals[id];
        uint256 cost = TIER_COST[tierIdx];
        if (tierIdx != 0 && rv.voucherTier == tierIdx && !rv.voucherSpent) {
            cost = TIER_COST[0]; // voucher: premium covered once, base still paid & burned
            rv.voucherSpent = true;
            emit VoucherRedeemed(id, tierIdx);
        }
        _splitDegen(cost);
        _setWeight(id, TIER_WEIGHT[tierIdx]);
        emit Activated(id, msg.sender);
        emit Boosted(id, tierIdx, TIER_WEIGHT[tierIdx]);
        _tryFlushHolderPool(); // weight appearing is the other epoch trigger
    }

    function _splitDegen(uint256 amount) internal {
        degen.safeTransferFrom(msg.sender, DEAD, amount / 2);
        degen.safeTransferFrom(msg.sender, treasury, amount - amount / 2);
    }

    function _setWeight(uint256 id, uint32 w) internal {
        totalWeight += w;
        weightOf[id] = w;
        ethDebt[id] = accEthPerWeight;
        spyDebt[id] = accSpyPerWeight;
    }

    /// @dev activation + boosts clear on EVERY transfer; pending force-claims to prior owner
    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (weightOf[id] != 0) {
            _claimTo(id, from);
            totalWeight -= weightOf[id];
            weightOf[id] = 0;
            emit Deactivated(id);
        }
    }

    // ==================================================================
    // DISTRIBUTOR (spec §8) — continuous, weighted, O(1)
    // ==================================================================
    /// @notice on-chain voucher check for marketplaces/metadata renderers
    function voucherOf(uint256 id) external view returns (uint8 tierIdx, bool spent) {
        Reveal storage r = reveals[id];
        return (r.voucherTier, r.voucherSpent);
    }

    function pendingEth(uint256 id) public view returns (uint256) {
        return uint256(weightOf[id]) * (accEthPerWeight - ethDebt[id]) / 1e18;
    }

    function pendingSpy(uint256 id) public view returns (uint256) {
        return uint256(weightOf[id]) * (accSpyPerWeight - spyDebt[id]) / 1e18;
    }

    function claim(uint256 id) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _claim(id);
    }

    /// @notice one transaction for a whole bag: claim every listed Degen you own.
    /// Credits owedEth/owedSpy exactly like per-token claims; withdraw() then pays
    /// the wallet once for all of them.
    function claimMany(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            if (ownerOf(ids[i]) != msg.sender) revert NotOwner();
            _claim(ids[i]);
        }
    }

    function _claim(uint256 id) internal {
        _claimTo(id, ownerOf(id));
    }

    // Pull-payment credits: forced claims (transfer hook) NEVER make external calls —
    // a receiver that reverts on ETH (or SPY transfer restrictions) must not brick transfers.
    mapping(address => uint256) public owedEth;
    mapping(address => uint256) public owedSpy;

    function _claimTo(uint256 id, address to) internal {
        uint256 e = pendingEth(id);
        uint256 sAmt = pendingSpy(id);
        ethDebt[id] = accEthPerWeight;
        spyDebt[id] = accSpyPerWeight;
        if (e > 0) owedEth[to] += e;
        if (sAmt > 0) owedSpy[to] += sAmt;
        if (e > 0 || sAmt > 0) emit Claimed(id, to, e, sAmt);
    }

    /// @notice withdraw accumulated credits (from claims and forced claims)
    function withdraw() external nonReentrant {
        uint256 e = owedEth[msg.sender];
        uint256 sAmt = owedSpy[msg.sender];
        owedEth[msg.sender] = 0;
        owedSpy[msg.sender] = 0;
        if (e > 0 || sAmt > 0) emit Withdrawn(msg.sender, e, sAmt);
        if (e > 0) {
            (bool ok,) = msg.sender.call{value: e}("");
            require(ok, "send");
        }
        if (sAmt > 0) spy.safeTransfer(msg.sender, sAmt);
    }

    /// @notice permissionless: WETH LP fees, royalties, any ETH revenue for holders
    function notifyEth() external payable nonReentrant {
        _notifyEth(msg.value);
    }

    function _notifyEth(uint256 amount) internal {
        if (!distributionOpened || totalWeight == 0) {
            pendingHolderEthWei += amount;
            emit HolderShareDeferred(amount, 0, pendingHolderEthWei, pendingHolderSpyWei);
            return;
        }
        accEthPerWeight += amount * 1e18 / totalWeight;
        emit HolderShareFlushed(amount, 0, totalWeight);
    }

    /// @notice permissionless: SPY LP rewards from the PositionLocker
    function notifySpy(uint256 amount) external nonReentrant {
        spy.safeTransferFrom(msg.sender, address(this), amount);
        emit SpyNotified(msg.sender, amount);
        if (!distributionOpened || totalWeight == 0) {
            pendingHolderSpyWei += amount;
            emit HolderShareDeferred(0, amount, pendingHolderEthWei, pendingHolderSpyWei);
            return;
        }
        accSpyPerWeight += amount * 1e18 / totalWeight;
        emit HolderShareFlushed(0, amount, totalWeight);
    }

    /// @dev Open the epoch and/or release the pool when the conditions hold:
    /// mint-out reached and at least one Degen activated. Called on the two
    /// transitions that can satisfy them (final mint, weight appearing).
    function _tryFlushHolderPool() internal {
        if (totalWeight == 0) return;
        if (!distributionOpened) {
            if (minted < MAX_SUPPLY && block.timestamp < epochDeadline) return;
            distributionOpened = true;
            emit DistributionOpened(totalWeight);
        }
        uint256 e = pendingHolderEthWei;
        uint256 sAmt = pendingHolderSpyWei;
        if (e == 0 && sAmt == 0) return;
        pendingHolderEthWei = 0;
        pendingHolderSpyWei = 0;
        if (e > 0) accEthPerWeight += e * 1e18 / totalWeight;
        if (sAmt > 0) accSpyPerWeight += sAmt * 1e18 / totalWeight;
        emit HolderShareFlushed(e, sAmt, totalWeight);
    }

    /// @notice permissionless poke: opens/flushes the pool the moment the conditions
    /// hold (mint-out or deadline, with weight) without waiting for the next
    /// activation or mint to happen to come along.
    function flushHolderPool() external nonReentrant {
        _tryFlushHolderPool();
    }

    // ==================================================================
    // FEE ROUTER (spec §7) — 66.66 / 16.67 / 16.67, no keeper tips
    // ==================================================================
    uint256 public burnAccruedWei; // ETH awaiting buy-and-burn execution

    function _routeEth(uint256 fee, FeeSource source) internal {
        uint256 toHolders = fee * HOLDER_SHARE_BPS / 10_000;
        uint256 toBurn = fee * BURN_SHARE_BPS / 10_000;
        uint256 toTreasury = fee - toHolders - toBurn;
        _notifyEth(toHolders);
        burnAccruedWei += toBurn; // executed by permissionless flushBurn via router — no tip
        (bool ok,) = treasury.call{value: toTreasury}("");
        require(ok, "send");
        emit FeesRouted(uint8(source), toHolders, toBurn, toTreasury);
    }

    /// @notice Forward harvested WETH LP fees into the holder split, tagged at source.
    function notifyLpFees() external payable nonReentrant {
        _routeEth(msg.value, FeeSource.LpFee);
    }

    /// @notice Forward marketplace royalties into the holder split, tagged at source.
    function notifyRoyalty() external payable nonReentrant {
        _routeEth(msg.value, FeeSource.Royalty);
    }

    // NOTE: buy-and-burn execution (ETH -> DEGEN -> DEAD via the v4 pool) requires a
    // swap-router integration; isolated in a separate BuyBurner module wired post
    // fork-test so the core vault never holds swap logic. burnAccruedWei is claimable
    // ONLY by the immutable BuyBurner once set. See spec §7.
    address public buyBurner;

    function setBuyBurnerOnce(address b) external {
        require(msg.sender == admin && buyBurner == address(0), "once");
        buyBurner = b;
    }

    function pullBurnBudget() external returns (uint256 amt) {
        require(msg.sender == buyBurner, "burner only");
        amt = burnAccruedWei;
        burnAccruedWei = 0;
        (bool ok,) = buyBurner.call{value: amt}("");
        require(ok);
    }

    function _refund(uint256 amount) internal {
        if (amount > 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "refund");
        }
    }

    // ==================================================================
    // LORE (spec: the Hood remembers)
    // ==================================================================
    function appendLore(uint256 id, string calldata entry) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _splitDegen(LORE_COST);
        lore[id].push(entry);
        emit LoreAppended(id, entry);
    }

    // ==================================================================
    // INVENTORY helpers — O(1) push/pop
    // ==================================================================
    function inventorySize() external view returns (uint256) {
        return inventory.length;
    }

    function _pushInventory(uint256 id) internal {
        inventory.push(uint16(id));
        inventoryIndex[id] = inventory.length; // index+1
    }

    function _popInventory(uint256 id) internal {
        uint256 i = inventoryIndex[id];
        require(i != 0, "not in inv");
        uint256 last = inventory[inventory.length - 1];
        inventory[i - 1] = uint16(last);
        inventoryIndex[last] = i;
        inventory.pop();
        delete inventoryIndex[id];
    }

    // ==================================================================
    // SOLVENCY INVARIANT (spec §4.1) — checked on every state change
    // ==================================================================
    function _assertSolvency() internal view {
        require(degen.balanceOf(address(this)) >= uint256(outstanding) * TOKENS_PER_NFT, "INSOLVENT");
    }

    // ==================================================================
    // ERC-2981 royalties — receiver defaults to this contract's distributor.
    // Marketplaces that settle royalties in WETH (e.g. OpenSea offers) need the
    // HoodFeeForwarder (royalty mode) as receiver: set it once, post-deploy.
    // ==================================================================
    address public royaltyReceiver; // zero = this contract (raw-ETH royalties auto-route)

    function setRoyaltyReceiverOnce(address r) external {
        require(msg.sender == admin && royaltyReceiver == address(0), "once");
        royaltyReceiver = r;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        address receiver = royaltyReceiver == address(0) ? address(this) : royaltyReceiver;
        return (receiver, salePrice * ROYALTY_BPS / 10_000);
    }

    // ==================================================================
    // Marketplace conventions — carry NO authority in this contract
    // ==================================================================
    /// @notice OpenSea-style collection claiming reads owner(); it grants nothing here.
    function owner() external view returns (address) {
        return admin;
    }

    string private _contractURI; // ERC-7572 collection metadata
    event ContractURIUpdated();

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice collection-level metadata (name/description/image for marketplaces);
    /// display-only, treasury-editable.
    function setContractURI(string calldata uri) external {
        require(msg.sender == admin, "admin");
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @dev royalties & LP fees arrive as plain ETH — route them like fees.
    /// nonReentrant: routing runs well past any 2300-gas stipend anyway, and the
    /// guard closes the re-entry window from refunds/withdraw sends bouncing back.
    receive() external payable nonReentrant {
        if (msg.sender != buyBurner) _routeEth(msg.value, FeeSource.External);
    }

    // ==================================================================
    // METADATA — dynamic tokenURI walks Sealed -> Tier -> Art (ERC-4906)
    // ==================================================================
    string public baseSealedURI;
    string[5] public tierURIs;
    string public artBaseURI;
    bool public urisFrozen;

    /// @notice treasury sets pack/tier URIs once before mint marketing; freeze locks forever
    function setURIs(string calldata sealed_, string[5] calldata tiers_, bool freeze) external {
        require(msg.sender == admin && !urisFrozen, "frozen");
        baseSealedURI = sealed_;
        for (uint256 i; i < 5; ++i) {
            tierURIs[i] = tiers_[i];
        }
        if (freeze) urisFrozen = true;
    }

    /// @notice one-shot: commit the art provenance hash + final base URI (spec §12b Stage B)
    function commitProvenance(bytes32 hash_, string calldata artBase_) external {
        require(msg.sender == admin && !artFrozen, "committed");
        provenanceHash = hash_;
        artBaseURI = artBase_;
        artFrozen = true;
    }

    // ---- Stage B: art assignment within fixed tier (sparse Fisher-Yates) ----
    mapping(uint8 => uint16) public artAssignedCount; // per tier
    mapping(uint8 => mapping(uint16 => uint16)) internal artPool; // sparse shuffle (stored val+1)
    uint16[5] internal TIER_SIZE = [600, 250, 100, 40, 10];

    function requestArtReveal(uint256 id) external {
        // Owner-gated like requestTierRip: reveal timing belongs to the holder, and an
        // open entrypoint would let anyone spam the shared FIFO with others' tokens.
        if (ownerOf(id) != msg.sender) revert NotOwner();
        require(artFrozen, "no art");
        Reveal storage r = reveals[id];
        require(r.stage == RevealStage.TierRevealed && r.pendingRound == 0, "state");
        r.pendingRound = entropy.nextRound();
        r.pendingKind = 2;
        ripSeq[id] = ++requestSeq;
        emit EntropyQueued(requestSeq, 2, id);
    }

    function finalizeArtReveal(uint256 id) external {
        Reveal storage r = reveals[id];
        if (r.pendingRound == 0 || r.pendingKind != 2) revert NothingPending();
        require(ripSeq[id] == processedSeq + 1, "out of order"); // strict FIFO
        bytes32 e = entropy.entropyOf(r.pendingRound);
        ++processedSeq;
        uint8 t = r.tier;
        uint16 remaining = TIER_SIZE[t] - artAssignedCount[t];
        uint16 j = uint16(uint256(keccak256(abi.encode(e, id))) % remaining);
        // sparse Fisher-Yates draw over [0, remaining)
        uint16 last = remaining - 1;
        uint16 vj = artPool[t][j] == 0 ? j : artPool[t][j] - 1;
        uint16 vl = artPool[t][last] == 0 ? last : artPool[t][last] - 1;
        artPool[t][j] = vl + 1;
        artPool[t][last] = vj + 1; // shrunk out next round
        ++artAssignedCount[t];
        r.artIndex = vj;
        r.stage = RevealStage.ArtRevealed;
        r.pendingRound = 0;
        emit ArtRevealed(id, vj);
        emit MetadataUpdate(id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Reveal storage r = reveals[id];
        if (r.stage == RevealStage.Sealed) return baseSealedURI;
        if (r.stage == RevealStage.TierRevealed) return tierURIs[r.tier];
        return string(abi.encodePacked(artBaseURI, _toString(r.artIndex), ".json"));
    }

    function _toString(uint256 v) internal pure returns (string memory str) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            ++len;
            j /= 10;
        }
        bytes memory b = new bytes(len);
        while (v != 0) {
            b[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        str = string(b);
    }

    function supportsInterface(bytes4 iid) public view override(ERC721, IERC165) returns (bool) {
        return iid == type(IERC2981).interfaceId || super.supportsInterface(iid);
    }
}
