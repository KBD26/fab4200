// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ============================================================
    FAB 4200 — you don't buy silicon. you fab it.
    ------------------------------------------------------------
    TRUST MODEL: there is no owner. Not renounced — never existed.
    ZERO PREMINT: supply is 0 at deploy. No genesis allocation, no
    reserve, no team tokens. Every die in this collection — including
    any the deployer ends up holding — was mined by proof-of-work
    under the same rules, at the same time, as everyone else's.
    No Ownable, no onlyOwner, no pause, no upgrade, no proxy,
    no setURI, no withdraw, no rescue. The constructor mints nothing
    and fixes every parameter forever. The deploy transaction is the
    last deployer action in this contract's life.

    MINT: free. mint(uint256 nonce) is nonpayable — this contract
    cannot receive ETH (receive/fallback revert). Cost is work:
    keccak256(chainid ‖ this ‖ minter ‖ nonce) must clear the floor.

    ROYALTY: an immutable bps (may be 0) paid to an immutable
    address via ERC-2981. That address receives no tokens and holds
    no powers; it is a payout destination and nothing else.

    OPEN: block.timestamp >= OPEN_AT (deploy + 48h, immutable).
    Nobody flips a switch. Read the code in the window; math opens
    the mine.
    ============================================================ */

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}
interface IRenderer {
    /// Pure/view renderer deployed FIRST, itself ownerless & immutable.
    function tokenURI(
        uint256 id, bytes32 seed, uint8 bits, uint8 oc, bool burnt,
        uint16 x, uint16 y, uint64 mintedAt, uint16 minted, uint16 burntCount
    ) external view returns (string memory);
}

contract FAB4200 {
    // ---------------- constants (all immutable-by-language) ----------------
    uint256 public constant SUPPLY        = 4200;
    uint8   public constant FLOOR_OPEN    = 26;   // free mint: work is the whole cost
    uint8   public constant FLOOR_MAX     = 40;
    uint8   public constant WALLET_ESC    = 2;    // +2 bits per prior mint from same wallet
    uint8   public constant OC_MAX        = 3;
    uint64  public constant TARGET_SECS   = 90;   // desired mint cadence for retarget
    uint16  public constant RETARGET_EVERY= 16;   // mints per retarget check (tightened)
    uint16  public constant GRID          = 67;   // 67x67 = 4489 sites > 4200, bijection below
    uint256 private constant SITE_STRIDE  = 2741; // prime, coprime with 4489

    // ---------------- immutables (set once in constructor) ----------------
    uint64  public immutable OPEN_AT;             // deploy + 48h
    address public immutable ROYALTY_ADDR;        // ERC-2981 payout destination only
    uint96  public immutable ROYALTY_BPS;         // fixed forever (may be 0)
    IRenderer public immutable RENDERER;          // frozen at deploy — QC before, not after
    IRenderer public immutable FALLBACK_RENDERER; // ownerless recovery metadata if primary ever reverts

    // ---------------- token state ----------------
    struct Die { address minter; uint64 mintedAt; uint8 bits; uint8 oc; bool burnt; }
    mapping(uint256 => Die)     private _die;
    mapping(uint256 => bytes32) public  seedOf;      // the workHash IS the seed
    mapping(uint256 => uint256) public  nonceOf;     // stored so verify() can re-run the PoW forever
    mapping(bytes32 => bool)    public  usedSeed;    // one hash mints once, ever
    mapping(address => uint32)  public  walletMints; // escalation counter

    uint16 public minted;
    uint16 public burntCount;
    uint8  public floorBase;      // algorithmic only — no function can set it
    uint64 private lastMintAt;
    uint64 private emaInterval;

    // ---------------- ERC721 minimal ----------------
    string public constant name   = "FAB 4200";
    string public constant symbol = "FAB4200";
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) public  balanceOf;
    mapping(uint256 => address) public  getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdate(uint256 _tokenId); // ERC-4906
    event Fabbed(uint256 indexed id, address indexed minter, bytes32 seed, uint8 bits, uint256 nonce);
    event Overclocked(uint256 indexed id, uint8 level);
    event Burnt(uint256 indexed id, uint8 attemptedLevel);
    event FloorRetarget(uint8 newFloor);

    error FreeMintNoETH();
    error NotOpenYet();
    error SoldOut();
    error SeedUsed();
    error BelowFloor(uint8 got, uint8 need);
    error NotYourDie();
    error DieIsBurnt();
    error OCMaxed();
    error Nonexistent();
    error NotAuthorized();
    error UnsafeReceiver();

    constructor(address royaltyAddr, IRenderer renderer, IRenderer fallbackRenderer, uint96 royaltyBps) {
        require(royaltyBps <= 1000, "royalty>10%");
        ROYALTY_ADDR = royaltyAddr;
        RENDERER = renderer;
        FALLBACK_RENDERER = fallbackRenderer;
        ROYALTY_BPS = royaltyBps;
        OPEN_AT = uint64(block.timestamp) + 48 hours;
        floorBase = FLOOR_OPEN;
        // NOTHING IS MINTED HERE. Supply is 0 until the mine opens.

        // lastMintAt stays 0: EMA primes at the first mint (see _retarget)
    }

    // ---------------- the mine ----------------
    /// FREE and NONPAYABLE. The only cost is the nonce search.
    function mint(uint256 nonce) external returns (uint256 id) {
        if (block.timestamp < OPEN_AT) revert NotOpenYet();
        if (minted >= SUPPLY) revert SoldOut();

        bytes32 h = keccak256(abi.encodePacked(block.chainid, address(this), msg.sender, nonce));
        if (usedSeed[h]) revert SeedUsed();

        uint8 bits = _lz(h);
        uint8 need = currentFloor(msg.sender);
        if (bits < need) revert BelowFloor(bits, need);

        usedSeed[h] = true;
        unchecked { id = ++minted; }
        seedOf[id] = h;
        nonceOf[id] = nonce;
        _die[id] = Die(msg.sender, uint64(block.timestamp), bits, 0, false);
        walletMints[msg.sender] += 1;

        _ownerOf[id] = msg.sender;
        unchecked { balanceOf[msg.sender] += 1; }
        emit Transfer(address(0), msg.sender, id);
        emit Fabbed(id, msg.sender, h, bits, nonce);

        _retarget();
    }

    /// Effective floor for a wallet: algorithmic base + per-wallet escalation.
    function currentFloor(address who) public view returns (uint8) {
        uint256 f = uint256(floorBase) + uint256(walletMints[who]) * WALLET_ESC;
        return f > FLOOR_MAX ? FLOOR_MAX : uint8(f);
    }

    function _retarget() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (lastMintAt == 0) { lastMintAt = nowTs; return; } // prime: first public mint sets the clock
        uint64 dt = nowTs - lastMintAt;
        lastMintAt = nowTs;
        emaInterval = emaInterval == 0 ? dt : uint64((uint256(emaInterval) * 7 + dt) / 8);
        if (minted % RETARGET_EVERY == 0) {
            if (emaInterval < TARGET_SECS / 4 && floorBase + 2 <= FLOOR_MAX) {
                floorBase += 2; emit FloorRetarget(floorBase);      // fast-clamp vs bursts
            } else if (emaInterval < TARGET_SECS / 2 && floorBase < FLOOR_MAX) {
                floorBase += 1; emit FloorRetarget(floorBase);
            } else if (emaInterval > TARGET_SECS * 2 && floorBase > FLOOR_OPEN) {
                floorBase -= 1; emit FloorRetarget(floorBase);
            }
        }
    }

    // ---------------- overclock / silicon lottery ----------------
    /// Headroom is a pure function of the seed — the lottery happened at
    /// mining time. Anyone may precompute; most won't. Fully deterministic:
    /// no oracle, no randomness dependency, no admin.
    function headroomOf(uint256 id) public view returns (uint8) {
        Die memory d = _dieChecked(id);
        uint8 bin = _bin(d.bits);
        uint8 base = bin <= 2 ? 1 : bin <= 4 ? 2 : 3;
        uint8 v = uint8(seedOf[id][31]) % 4 == 0 ? 1 : 0;
        uint8 h = base + v;
        return h > OC_MAX ? OC_MAX : h;
    }

    function overclock(uint256 id) external {
        Die storage d = _die[id];
        if (_ownerOf[id] == address(0)) revert Nonexistent();
        if (msg.sender != _ownerOf[id]) revert NotYourDie();
        if (d.burnt) revert DieIsBurnt();
        if (d.oc >= OC_MAX) revert OCMaxed();
        uint8 attempt = d.oc + 1;
        if (attempt > headroomOf(id)) {
            d.burnt = true;
            unchecked { burntCount += 1; }
            emit Burnt(id, attempt);
        } else {
            d.oc = attempt;
            emit Overclocked(id, attempt);
        }
        emit MetadataUpdate(id); // marketplaces refresh the art
    }

    // ---------------- coordinates: fixed public bijection ----------------
    /// siteOf is a constant permutation of tokenId over a 67x67 wafer grid.
    /// No salt, no reveal, no team action — and ZERO rarity weight, so
    /// timing-sniping a pretty seat is permitted sport, not an exploit.
    function siteOf(uint256 id) public pure returns (uint16 x, uint16 y) {
        uint256 idx = (id * SITE_STRIDE) % (uint256(GRID) * GRID);
        return (uint16(idx % GRID), uint16(idx / GRID));
    }

    // ---------------- verification ----------------
    function verify(uint256 id) external view returns (
        bool ok, uint8 bits, uint8 oc, bool burnt,
        address minter, bytes32 seed, uint16 x, uint16 y
    ) {
        Die memory d = _dieChecked(id);
        seed = seedOf[id];
        // FULL re-verification: every token re-runs its proof-of-work from
        // the stored (minter, nonce). There are no exempt tokens.
        bytes32 expect = keccak256(abi.encodePacked(block.chainid, address(this), d.minter, nonceOf[id]));
        ok = expect == seed && _lz(seed) == d.bits;
        (x, y) = siteOf(id);
        return (ok, d.bits, d.oc, d.burnt, d.minter, seed, x, y);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        Die memory d = _dieChecked(id);
        (uint16 x, uint16 y) = siteOf(id);
        try RENDERER.tokenURI(id, seedOf[id], d.bits, d.oc, d.burnt, x, y, d.mintedAt, minted, burntCount)
            returns (string memory s) { return s; }
        catch { // ownerless resilience: tokens can degrade, never brick
            return FALLBACK_RENDERER.tokenURI(id, seedOf[id], d.bits, d.oc, d.burnt, x, y, d.mintedAt, minted, burntCount);
        }
    }

    // ---------------- ERC721 core ----------------
    function ownerOf(uint256 id) public view returns (address o) {
        o = _ownerOf[id];
        if (o == address(0)) revert Nonexistent();
    }
    function approve(address spender, uint256 id) external {
        address o = ownerOf(id);
        if (msg.sender != o && !isApprovedForAll[o][msg.sender]) revert NotAuthorized();
        getApproved[id] = spender;
        emit Approval(o, spender, id);
    }
    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
        emit ApprovalForAll(msg.sender, op, ok);
    }
    function transferFrom(address from, address to, uint256 id) public {
        if (from != _ownerOf[id]) revert NotAuthorized();
        if (to == address(0)) revert NotAuthorized();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender] && msg.sender != getApproved[id])
            revert NotAuthorized();
        delete getApproved[id];
        unchecked { balanceOf[from] -= 1; balanceOf[to] += 1; }
        _ownerOf[id] = to;
        emit Transfer(from, to, id);
    }
    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }
    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length != 0 &&
            IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
              != IERC721Receiver.onERC721Received.selector) revert UnsafeReceiver();
    }

    // ---------------- ERC165 / 2981 / contractURI ----------------
    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x01ffc9a7 || i == 0x80ac58cd || i == 0x5b5e139f // 165/721/721Metadata
            || i == 0x2a55205a || i == 0x49064906;                    // 2981 / 4906
    }
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (ROYALTY_ADDR, salePrice * ROYALTY_BPS / 10000);
    }
    function contractURI() external pure returns (string memory) {
        return "data:application/json,%7B%22name%22%3A%22FAB%204200%22%2C%22description%22%3A%22You%20don%27t%20buy%20silicon.%20You%20fab%20it.%20Free%20PoW%20mint%2C%20fully%20on-chain%2C%20no%20owner%2C%20zero%20premint%20%E2%80%94%20every%20die%20mined%20under%20the%20same%20rules.%22%7D";
    }

    // ---------------- the money doors are welded shut ----------------
    receive() external payable { revert FreeMintNoETH(); }
    fallback() external payable { revert FreeMintNoETH(); }

    // ---------------- internals ----------------
    function _dieChecked(uint256 id) internal view returns (Die memory d) {
        if (_ownerOf[id] == address(0)) revert Nonexistent();
        d = _die[id];
    }
    function _bin(uint8 bits) internal pure returns (uint8) {
        if (bits < FLOOR_OPEN) return 1;
        uint8 b = 1 + (bits - FLOOR_OPEN) / 2;
        return b > 6 ? 6 : b;
    }
    function _lz(bytes32 h) internal pure returns (uint8 n) {
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(h[i]);
            if (b == 0) { n += 8; continue; }
            if (b < 2) n += 7; else if (b < 4) n += 6; else if (b < 8) n += 5;
            else if (b < 16) n += 4; else if (b < 32) n += 3; else if (b < 64) n += 2;
            else if (b < 128) n += 1;
            break;
        }
    }
}
