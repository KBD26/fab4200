// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  FAB 4200 — primary on-chain renderer (STAGE 1: geometry core)
    ------------------------------------------------------------
    Ownerless, immutable, pure. Emits the die floorplan from a seed.
    Stage 1 scope: buffer, PRNG, traits, BSP floorplan, blocks, pads.
    Stages to come: block interiors, routing, text/etches, animation,
    metadata assembly.

    DESIGN NOTE — canonical math: the JS reference renderer used IEEE
    floats. Exact float parity on-chain is impossible, so this contract
    uses deterministic fixed-point (1e6) and IS the canonical art. The
    JS reference will be regenerated to match this, byte for byte.
*/

// ------------------------------------------------------------------
// O(n) append-only buffer. Naive bytes.concat is quadratic and would
// blow the gas budget on a 30KB document; this writes in place.
// ------------------------------------------------------------------
library Buf {
    struct B { bytes data; uint256 len; }

    function alloc(uint256 cap) internal pure returns (B memory b) {
        b.data = new bytes(cap + 64); // slack: word-wise copy may overrun
        b.len = 0;
    }

    function w(B memory b, string memory s) internal pure {
        assembly {
            let dataPtr := mload(b)
            let len := mload(add(b, 0x20))
            let dst := add(add(dataPtr, 0x20), len)
            let src := add(s, 0x20)
            let n := mload(s)
            for { let i := 0 } lt(i, n) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
            mstore(add(b, 0x20), add(len, n))
        }
    }

    // unsigned integer, ascii
    function wu(B memory b, uint256 v) internal pure {
        if (v == 0) { w(b, "0"); return; }
        uint256 digits; uint256 t = v;
        while (t != 0) { digits++; t /= 10; }
        assembly {
            let dp := mload(b)
            let len := mload(add(b, 0x20))
            let ptr := add(add(add(dp, 0x20), len), digits)
            for { } gt(v, 0) { } {
                ptr := sub(ptr, 1)
                mstore8(ptr, add(48, mod(v, 10)))
                v := div(v, 10)
            }
            mstore(add(b, 0x20), add(len, digits))
        }
    }
    function wf(B memory b, uint256 v100) internal pure {
        wu(b, v100 / 100);
        uint256 f = v100 % 100;
        if (f == 0) return;
        w(b, ".");
        if (f % 10 == 0) { wu(b, f / 10); return; }
        if (f < 10) w(b, "0");
        wu(b, f);
    }

    function done(B memory b) internal pure returns (string memory out) {
        assembly {
            out := mload(b)
            mstore(out, mload(add(b, 0x20)))
        }
    }
}

interface IInteriors {
    struct Ctx { uint8 eng; uint8 bin; uint8 oc; bool burnt; bool fine; bool anim; uint16 dur100; }
    function blockSVG(uint16 bx, uint16 by, uint16 bw, uint16 bh, uint8 t, Ctx calldata c, uint32 rng)
        external pure returns (string memory, uint32);
}

interface IDecor {
    struct D {
        uint8 eng; uint8 bin; uint8 oc; uint8 memeIdx; uint8 archIdx; uint8 palIdx; uint8 bits;
        bool burnt; bool fine; bool golden4200; bool anim;
        uint16 x; uint16 y; bytes4 lot;
        uint16 railDur100; uint16 ledDur100; uint16 minted; uint16 burntCount;
    }
    function defs(bool fine, bool burnt) external pure returns (string memory);
    function attrs(D calldata d, uint256 id) external pure returns (string memory);
    function rails(D calldata d) external pure returns (string memory);
    function etches(D calldata d) external pure returns (string memory);
    function glyphs(D calldata d) external pure returns (string memory);
    function laneWords(uint16[16] calldata rects, uint8 count, uint32 rng, bool burnt, bool anim)
        external pure returns (string memory, uint32);
}

contract FAB4200Renderer {
    IInteriors public immutable INTERIORS;
    IDecor public immutable DECOR;
    constructor(IInteriors interiors, IDecor decor) { INTERIORS = interiors; DECOR = decor; }

    using Buf for Buf.B;

    // ---------- die geometry ----------
    uint16 internal constant RX0 = 130;
    uint16 internal constant RY0 = 130;
    uint16 internal constant RX1 = 870;
    uint16 internal constant RY1 = 870;
    uint16 internal constant GUT = 7;
    uint8  internal constant FLOOR_OPEN = 26;

    // ---------- palette ----------
    string internal constant ROBIN = "#CCFF00";
    string internal constant GOLD  = "#FFD24D";
    string internal constant INK   = "#9FB58A";
    string internal constant DIM   = "#26320B";
    string internal constant DIMMER= "#39430E";
    string internal constant DEAD  = "#3A4147";

    // engines: 0 lanes,1 ring,2 chaos,3 fragile,4 clock,5 mesh,6 mono,7 heavy
    // arch index -> engine
    function _engineOf(uint8 archIdx) internal pure returns (uint8) {
        if (archIdx == 0) return 0;
        if (archIdx == 1) return 1;
        if (archIdx == 2) return 2;
        if (archIdx == 3) return 3;
        if (archIdx == 4) return 4;
        if (archIdx == 5) return 5;
        if (archIdx == 6) return 6;
        if (archIdx == 7) return 7;
        if (archIdx == 8) return 2; // ROB THE RICH -> chaos
        return 5;                   // GIVE TO POOR -> mesh
    }

    // ---------- traits ----------
    struct T {
        uint32 s;          // rng state
        uint8  palIdx;     // 0 PURE 1 ICE 2 HOT 3 SPECTRUM
        uint8  archIdx;    // 0..9
        uint8  eng;        // 0..7
        uint8  memeIdx;    // 0..8, 100 = TRUST ME BRO (rare)
        uint8  bin;        // 1..6
        uint8  hrVar;
        bool   golden4200;
        bool   fine;
        bool   gold;
        bytes4 lot;        // hash nibbles 8..11, uppercase hex
    }

    struct Block { uint16 x; uint16 y; uint16 w; uint16 h; uint8 t; }
    // block types: 0 NONE 1 CORE 2 CACHE 3 IO 4 PLL 5 NPU 6 LANE 7 DECODER 8 FILL

    // ---------- PRNG: splitmix32, ported for determinism ----------
    function _rnd(T memory t) internal pure returns (uint32) {
        unchecked {
            t.s = t.s + 0x9e3779b9;
            uint32 z = t.s;
            z = z ^ (z >> 16);
            z = z * 0x21f0aaad;
            z = z ^ (z >> 15);
            z = z * 0x735a2d97;
            return z ^ (z >> 15);
        }
    }
    // integer in [a,b] inclusive
    function _ri(T memory t, uint256 a, uint256 b) internal pure returns (uint256) {
        return a + (uint256(_rnd(t)) * (b - a + 1)) / 4294967296;
    }
    // true with probability pct/100 (pct scaled by 100: 300 == 3.00%)
    function _chance(T memory t, uint256 pctScaled) internal pure returns (bool) {
        return uint256(_rnd(t)) * 10000 < pctScaled * 4294967296;
    }

    function _bin(uint8 bits) internal pure returns (uint8) {
        if (bits < FLOOR_OPEN) return 1;
        uint8 b = 1 + (bits - FLOOR_OPEN) / 2;
        return b > 6 ? 6 : b;
    }

    function _hexUp(uint8 nib) internal pure returns (bytes1) {
        return nib < 10 ? bytes1(uint8(48 + nib)) : bytes1(uint8(55 + nib)); // 'A'=65=55+10
    }

    function _derive(bytes32 seed, uint8 bits) internal pure returns (T memory t) {
        // state = 0x9d2c5680 XOR each 32-bit word of the hash
        uint32 a = 0x9d2c5680;
        unchecked {
            for (uint256 i = 0; i < 8; i++) {
                a = a ^ uint32(uint256(seed) >> (224 - 32 * i));
            }
        }
        t.s = a;

        // palette: weighted 60/18/14/8 over roll in [0,100)
        uint256 roll = (uint256(_rnd(t)) * 100) / 4294967296;
        if (roll < 60) t.palIdx = 0;
        else if (roll < 78) t.palIdx = 1;
        else if (roll < 92) t.palIdx = 2;
        else t.palIdx = 3;

        t.archIdx = uint8((uint256(_rnd(t)) * 10) / 4294967296);
        t.eng = _engineOf(t.archIdx);

        // 3% rare override; when it fires the common draw is NOT consumed
        if (_chance(t, 300)) t.memeIdx = 100;
        else t.memeIdx = uint8((uint256(_rnd(t)) * 9) / 4294967296);

        // legacy coordinate draws: consumed and discarded so the art matches
        // the reference renderer. Real coordinates come from siteOf(id).
        _ri(t, 0, 63);
        _ri(t, 0, 63);

        // lot code: hash nibbles 8..11, uppercase
        bytes memory l = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            uint8 nib = uint8(uint256(seed) >> (252 - 4 * (8 + i))) & 0x0f;
            l[i] = _hexUp(nib);
        }
        t.lot = bytes4(bytes(l));

        // golden lot: does the hash contain the nibble run 4,2,0,0 ?
        for (uint256 i = 0; i + 3 < 64; i++) {
            if (uint8(uint256(seed) >> (252 - 4 * i)) & 0x0f == 4 &&
                uint8(uint256(seed) >> (252 - 4 * (i + 1))) & 0x0f == 2 &&
                uint8(uint256(seed) >> (252 - 4 * (i + 2))) & 0x0f == 0 &&
                uint8(uint256(seed) >> (252 - 4 * (i + 3))) & 0x0f == 0) { t.golden4200 = true; break; }
        }

        t.hrVar = _chance(t, 2500) ? 1 : 0;
        t.bin = _bin(bits);
        t.fine = t.bin >= 6;
        t.gold = t.golden4200 || t.bin >= 6;
    }

    // ---------- BSP floorplan ----------
    struct FP { Block[] bs; uint256 n; }

    function _push(FP memory f, uint16 x, uint16 y, uint16 w, uint16 h) internal pure {
        f.bs[f.n] = Block(x, y, w, h, 0);
        f.n++;
    }

    function _bsp(
        T memory t, FP memory f,
        uint16 x, uint16 y, uint16 w, uint16 h,
        uint8 d, uint32 lo, uint32 hi
    ) internal pure {
        if (f.n >= 18) { _push(f, x, y, w, h); return; }
        bool stop = (d == 0 || w < 175 || h < 175);
        if (!stop && d < 3) { stop = _chance(t, 1200); }
        if (stop) { _push(f, x, y, w, h); return; }

        bool horiz;
        if (w > h) horiz = true;
        else if (h > w) horiz = false;
        else horiz = _chance(t, 5000);

        uint32 frac = lo + uint32((uint256(_rnd(t)) * (hi - lo)) / 4294967296); // 1e6 scale
        if (horiz) {
            uint16 w1 = uint16((uint256(w) * frac + 500000) / 1000000);
            if (w1 <= GUT || w1 + GUT >= w) { _push(f, x, y, w, h); return; }
            _bsp(t, f, x, y, w1 - GUT, h, d - 1, lo, hi);
            _bsp(t, f, x + w1 + GUT, y, w - w1 - GUT, h, d - 1, lo, hi);
        } else {
            uint16 h1 = uint16((uint256(h) * frac + 500000) / 1000000);
            if (h1 <= GUT || h1 + GUT >= h) { _push(f, x, y, w, h); return; }
            _bsp(t, f, x, y, w, h1 - GUT, d - 1, lo, hi);
            _bsp(t, f, x, y + h1 + GUT, w, h - h1 - GUT, d - 1, lo, hi);
        }
    }

    function _floorplan(T memory t) internal pure returns (Block[] memory, uint256) {
        FP memory f;
        f.bs = new Block[](20);
        uint16 W = RX1 - RX0;
        uint16 H = RY1 - RY0;

        if (t.eng == 6) { // mono: one dominant core, side stack
            uint16 w1 = uint16((uint256(W) * (560000 + (uint256(_rnd(t)) * 100000) / 4294967296) + 500000) / 1000000);
            _push(f, RX0, RY0, w1 - GUT, H);
            f.bs[0].t = 1; // CORE
            _bsp(t, f, RX0 + w1 + GUT, RY0, W - w1 - GUT, H, 3, 340000, 660000);
            uint256 cache = 0;
            for (uint256 i = 1; i < f.n; i++) {
                if (f.bs[i].t == 0) {
                    f.bs[i].t = cache < 2 ? 2 : (cache == 2 ? 4 : 8); // CACHE,CACHE,PLL,FILL
                    cache++;
                }
            }
            return (f.bs, f.n);
        }

        if (t.eng == 0) { // lanes: horizontal meme lanes + decoder
            uint16 rem = H - GUT * 3;
            uint16[4] memory hs;
            for (uint256 i = 0; i < 3; i++) {
                uint256 pct = 200000 + (uint256(_rnd(t)) * 140000) / 4294967296; // .20-.34
                uint16 hh = uint16((uint256(rem) * pct + 500000) / 1000000);
                hs[i] = hh; rem -= hh;
            }
            hs[3] = rem;
            uint16 yy = RY0;
            for (uint256 i = 0; i < 4; i++) {
                if (i == 2) {
                    uint256 pct = 300000 + (uint256(_rnd(t)) * 140000) / 4294967296;
                    uint16 w1 = uint16((uint256(W) * pct + 500000) / 1000000);
                    _push(f, RX0, yy, w1 - GUT, hs[i]);
                    f.bs[f.n - 1].t = 7; // DECODER
                    _push(f, RX0 + w1 + GUT, yy, W - w1 - GUT, hs[i]);
                    f.bs[f.n - 1].t = 6; // LANE
                } else {
                    _push(f, RX0, yy, W, hs[i]);
                    f.bs[f.n - 1].t = 6; // LANE
                }
                yy += hs[i] + GUT;
            }
            return (f.bs, f.n);
        }

        // default: BSP, wider splits for chaos
        uint32 lo = t.eng == 2 ? 220000 : 340000;
        uint32 hi = t.eng == 2 ? 780000 : 660000;
        uint8 depth = _chance(t, 5000) ? 4 : 3;
        _bsp(t, f, RX0, RY0, W, H, depth, lo, hi);
        _typeBlocks(t, f);
        return (f.bs, f.n);
    }

    // assign block roles over an area-descending index view (stable)
    function _typeBlocks(T memory t, FP memory f) internal pure {
        uint256 n = f.n;
        uint256[] memory idx = new uint256[](n);
        for (uint256 i = 0; i < n; i++) idx[i] = i;
        // stable insertion sort, area descending
        for (uint256 i = 1; i < n; i++) {
            uint256 key = idx[i];
            uint256 ka = uint256(f.bs[key].w) * f.bs[key].h;
            uint256 j = i;
            while (j > 0 && uint256(f.bs[idx[j - 1]].w) * f.bs[idx[j - 1]].h < ka) {
                idx[j] = idx[j - 1]; j--;
            }
            idx[j] = key;
        }

        f.bs[idx[0]].t = 1; // CORE = largest

        uint256 io = 0;
        for (uint256 i = 1; i < n && io < 2; i++) {
            Block memory b = f.bs[idx[i]];
            bool onEdge = b.x <= RX0 + 2 || b.y <= RY0 + 2 || b.x + b.w >= RX1 - 2 || b.y + b.h >= RY1 - 2;
            if (b.t == 0 && onEdge && uint256(b.w) * b.h < 90000) { f.bs[idx[i]].t = 3; io++; }
        }
        uint256 cache = 0;
        for (uint256 i = 1; i < n && cache < 2; i++) {
            if (f.bs[idx[i]].t == 0) { f.bs[idx[i]].t = 2; cache++; }
        }
        // smallest untyped -> PLL
        uint256 best = type(uint256).max; uint256 bestI = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            uint256 k = idx[i];
            if (f.bs[k].t != 0) continue;
            uint256 area = uint256(f.bs[k].w) * f.bs[k].h;
            if (area < best) { best = area; bestI = k; }
        }
        if (bestI != type(uint256).max) f.bs[bestI].t = 4;
        // NPU: mesh always, else 20%
        bool npu = t.eng == 5 ? true : _chance(t, 2000);
        if (npu) {
            for (uint256 i = 0; i < n; i++) {
                if (f.bs[idx[i]].t == 0) { f.bs[idx[i]].t = 5; break; }
            }
        }
        for (uint256 i = 0; i < n; i++) if (f.bs[i].t == 0) f.bs[i].t = 8; // FILL
    }


    // ---------------- channel routing ----------------
    struct Route { uint32[8] p; uint8 n; uint16 op100; bool coreLink; bool viaEnd; }

    function _exit(T memory t, Block memory a, Block memory bb) internal pure returns (uint32 px, uint32 py, bool horiz) {
        int256 dx = (int256(uint256(bb.x)) + int256(uint256(bb.w)) / 2) - (int256(uint256(a.x)) + int256(uint256(a.w)) / 2);
        int256 dy = (int256(uint256(bb.y)) + int256(uint256(bb.h)) / 2) - (int256(uint256(a.y)) + int256(uint256(a.h)) / 2);
        uint256 frac = 250000 + (uint256(_rnd(t)) * 500000) / 4294967296; // .25-.75
        uint256 adx = dx < 0 ? uint256(-dx) : uint256(dx);
        uint256 ady = dy < 0 ? uint256(-dy) : uint256(dy);
        if (adx >= ady) {
            px = uint32((dx > 0 ? uint256(a.x) + a.w : uint256(a.x)) * 100);
            py = uint32(uint256(a.y) * 100 + uint256(a.h) * frac / 10000);
            horiz = true;
        } else {
            px = uint32(uint256(a.x) * 100 + uint256(a.w) * frac / 10000);
            py = uint32((dy > 0 ? uint256(a.y) + a.h : uint256(a.y)) * 100);
            horiz = false;
        }
    }

    function _routes(T memory t, Block[] memory bs, uint256 n, uint8 oc)
        internal pure returns (Route[] memory rt, uint256 rn)
    {
        oc;
        rt = new Route[](14);
        if (t.eng == 0) { // lanes: four taps into the decoder
            uint256 dec = 0;
            for (uint256 i = 0; i < n; i++) if (bs[i].t == 7) { dec = i; break; }
            for (uint256 i = 0; i < 4; i++) {
                uint32 tx = uint32((uint256(bs[dec].x) + 20) * 100 + (uint256(_rnd(t)) * (uint256(bs[dec].w) - 40) * 100) / 4294967296);
                bool up = i % 2 == 0;
                uint32 yA = up ? uint32(uint256(RY0 + 10) * 100) : uint32(uint256(RY1 - 10) * 100);
                uint32 yB = up ? uint32(uint256(bs[dec].y) * 100) : uint32((uint256(bs[dec].y) + bs[dec].h) * 100);
                rt[rn].p[0] = tx; rt[rn].p[1] = yA; rt[rn].p[2] = tx; rt[rn].p[3] = yB;
                rt[rn].n = 2; rt[rn].viaEnd = true;
                rt[rn].op100 = uint16(75 + (uint256(_rnd(t)) * 20) / 4294967296);
                rn++;
            }
            return (rt, rn);
        }

        uint256 core = 0;
        for (uint256 i = 0; i < n; i++) if (bs[i].t == 1) { core = i; break; }
        (uint256[14] memory pa, uint256[14] memory pb, uint256 np) = _pairs(t, bs, n, core);

        for (uint256 i = 0; i < np && rn < 12; i++) {
            if (pa[i] == pb[i]) continue;
            rt[rn] = _buildRoute(t, bs[pa[i]], bs[pb[i]], rn);
            rt[rn].coreLink = (pa[i] == core || pb[i] == core);
            rn++;
        }
    }

    function _pairs(T memory t, Block[] memory bs, uint256 n, uint256 core)
        internal pure returns (uint256[14] memory pa, uint256[14] memory pb, uint256 np)
    {
        uint256 others = n - 1;
        uint256 want = others + 4 < uint256(5 + t.bin) ? others + 4 : uint256(5 + t.bin);
        if (want > 12) want = 12;
        for (uint256 i = 0; i < n && np < want; i++) {
            uint8 bt = bs[i].t;
            if (i != core && (bt == 2 || bt == 3 || bt == 4 || bt == 5)) { pa[np] = core; pb[np] = i; np++; }
        }
        while (np < want && others > 1) {
            uint256 ia = (uint256(_rnd(t)) * others) / 4294967296;
            uint256 ib = (uint256(_rnd(t)) * others) / 4294967296;
            if (ia >= core) ia++;
            if (ib >= core) ib++;
            pa[np] = ia; pb[np] = ib; np++;
        }
    }

    function _buildRoute(T memory t, Block memory ba, Block memory bb, uint256 lane)
        internal pure returns (Route memory r)
    {
        (uint32 x1, uint32 y1, bool ah) = _exit(t, ba, bb);
        (uint32 x2, uint32 y2, bool bh) = _exit(t, bb, ba);
        int256 off = (int256(lane % 5) - 2) * 900;
        if (t.eng == 2) off += (int256(uint256(_rnd(t))) * 2600 / 4294967296) - 1300;
        if (ah && bh) {
            uint32 mx = uint32(uint256(int256((uint256(x1) + uint256(x2)) / 2) + off));
            r.p[0] = x1; r.p[1] = y1; r.p[2] = mx; r.p[3] = y1;
            r.p[4] = mx; r.p[5] = y2; r.p[6] = x2; r.p[7] = y2; r.n = 4;
        } else if (!ah && !bh) {
            uint32 my = uint32(uint256(int256((uint256(y1) + uint256(y2)) / 2) + off));
            r.p[0] = x1; r.p[1] = y1; r.p[2] = x1; r.p[3] = my;
            r.p[4] = x2; r.p[5] = my; r.p[6] = x2; r.p[7] = y2; r.n = 4;
        } else if (ah) {
            r.p[0] = x1; r.p[1] = y1; r.p[2] = x2; r.p[3] = y1;
            r.p[4] = x2; r.p[5] = y2; r.n = 3;
        } else {
            r.p[0] = x1; r.p[1] = y1; r.p[2] = x1; r.p[3] = y2;
            r.p[4] = x2; r.p[5] = y2; r.n = 3;
        }
        r.op100 = uint16(72 + (uint256(_rnd(t)) * 23) / 4294967296);
    }

    function _path(Buf.B memory b, Route memory r) internal pure {
        b.w("M "); b.wf(r.p[0]); b.w(" "); b.wf(r.p[1]);
        for (uint256 k = 1; k < r.n; k++) { b.w(" L "); b.wf(r.p[2 * k]); b.w(" "); b.wf(r.p[2 * k + 1]); }
    }


    // ---------- emit ----------
    function _rect(Buf.B memory b, uint256 x, uint256 y, uint256 w, uint256 h, string memory fill) internal pure {
        b.w('<rect x="'); b.wu(x);
        b.w('" y="'); b.wu(y);
        b.w('" width="'); b.wu(w);
        b.w('" height="'); b.wu(h);
        b.w('" fill="'); b.w(fill); b.w('"/>');
    }

    function _pads(Buf.B memory b, T memory t) internal pure {
        uint256 nP = _ri(t, 15, 22);
        uint256 deadPad = type(uint256).max;
        if (t.eng == 3) deadPad = _ri(t, 0, nP * 4 - 1); // fragile: one dead pad
        string memory padFill = t.gold ? GOLD : "#9AA79F";
        uint256 padIdx = 0;
        for (uint256 i = 0; i < nP; i++) {
            // o = 85 + 820*(2i+1)/(2*nP), to 2 decimals
            uint256 num = 41000 * (2 * i + 1);
            uint256 o100 = 8500 + (num + nP / 2) / nP;
            for (uint256 side = 0; side < 4; side++) {
                bool dead = (padIdx == deadPad);
                padIdx++;
                b.w('<rect x="');
                if (side == 0 || side == 1) b.wf(o100); else b.w(side == 2 ? "52" : "924");
                b.w('" y="');
                if (side == 0) b.w("52"); else if (side == 1) b.w("924"); else b.wf(o100);
                b.w('" width="'); b.w(side < 2 ? "10" : "24");
                b.w('" height="'); b.w(side < 2 ? "24" : "10");
                b.w('" fill="'); b.w(dead ? DEAD : padFill);
                b.w('" opacity="0.9"/>');
            }
        }
    }

    struct In { bytes32 seed; uint8 bits; uint8 oc; bool burnt; uint16 wx; uint16 wy; uint16 minted; uint16 burntCount; }

    /// Full die render. Called by tokenURI; also public for verification.
    function renderSVG(
        bytes32 seed, uint8 bits, uint8 oc, bool burnt,
        uint16 wx, uint16 wy, uint16 minted, uint16 burntCount
    ) public view returns (string memory) {
        return _render(In(seed, bits, oc, burnt, wx, wy, minted, burntCount));
    }

    function _render(In memory q) internal view returns (string memory) {
        if (q.oc > 3) q.oc = 3;
        if (q.wx > 66) q.wx = 66;
        if (q.wy > 66) q.wy = 66;
        if (q.burntCount > q.minted) q.burntCount = q.minted;
        T memory t = _derive(q.seed, q.bits);
        (Block[] memory bs, uint256 n) = _floorplan(t);
        (Route[] memory rt, uint256 rn) = _routes(t, bs, n, q.oc);

        Buf.B memory b = Buf.alloc(52000);
        b.w('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">');
        b.w(DECOR.defs(t.fine, q.burnt));
        _frame(b, q.burnt);
        _pads(b, t);
        _emitInteriors(b, t, bs, n, q.oc, q.burnt);
        if (t.eng == 1) _ring(b, q.burnt);
        _emitRoutes(b, t, rt, rn, q.burnt);
        _emitPulses(b, t, rt, rn, q.oc, q.burnt);
        if (t.eng == 0) _emitLaneWords(b, t, bs, n, q.burnt);
        _emitDecor(b, t, q);
        b.w("</svg>");
        return b.done();
    }

    function _frame(Buf.B memory b, bool burnt) internal pure {
        _rect(b, 0, 0, 1000, 1000, "#07090B");
        b.w('<rect x="88" y="88" width="824" height="824" fill="#0B0E10" stroke="#1A2126" stroke-width="2"/>');
        b.w('<rect x="90" y="90" width="820" height="820" fill="none" stroke="');
        b.w(burnt ? "#241C10" : DIM); b.w('" stroke-width="1"/>');
    }

    function _ring(Buf.B memory b, bool burnt) internal pure {
        b.w('<path d="M 116 116 H 884 V 884 H 116 Z" stroke="#141A08" stroke-width="9" fill="none"/>');
        b.w('<path d="M 116 116 H 884 V 884 H 116 Z" stroke="');
        b.w(burnt ? DEAD : ROBIN); b.w('" stroke-width="4.5" fill="none" opacity="0.85" filter="url(#gt)"/>');
    }

    function _emitDecor(Buf.B memory b, T memory t, In memory q) internal view {
        IDecor.D memory d = IDecor.D({
            eng: t.eng, bin: t.bin, oc: q.oc, memeIdx: t.memeIdx, archIdx: t.archIdx, palIdx: t.palIdx, bits: q.bits,
            burnt: q.burnt, fine: t.fine, golden4200: t.golden4200, anim: true,
            x: q.wx, y: q.wy, lot: t.lot,
            railDur100: uint16(1100 * 100 / (100 + 45 * uint256(q.oc) + 18 * (uint256(t.bin) - 1))),
            ledDur100: uint16(230 - 30 * uint256(q.oc) - 10 * uint256(t.bin)),
            minted: q.minted, burntCount: q.burntCount
        });
        b.w(DECOR.rails(d));
        b.w(DECOR.etches(d));
        b.w(DECOR.glyphs(d));
    }

    function _emitLaneWords(Buf.B memory b, T memory t, Block[] memory bs, uint256 n, bool burnt) internal view {
        uint16[16] memory rects;
        uint8 cnt;
        for (uint256 i = 0; i < n && cnt < 4; i++) {
            if (bs[i].t != 6) continue;
            rects[cnt * 4] = bs[i].x; rects[cnt * 4 + 1] = bs[i].y;
            rects[cnt * 4 + 2] = bs[i].w; rects[cnt * 4 + 3] = bs[i].h;
            cnt++;
        }
        if (cnt == 0) return;
        (string memory chunk, uint32 ns) = DECOR.laneWords(rects, cnt, t.s, burnt, true);
        t.s = ns;
        b.w(chunk);
    }

    function _emitInteriors(Buf.B memory b, T memory t, Block[] memory bs, uint256 n, uint8 oc, bool burnt) internal view {
        IInteriors.Ctx memory c = IInteriors.Ctx({
            eng: t.eng, bin: t.bin, oc: oc, burnt: burnt, fine: t.fine,
            anim: true, dur100: uint16(260 / (1 + uint256(oc)) + 60)
        });
        for (uint256 i = 0; i < n; i++) {
            (string memory chunk, uint32 ns) = _one(bs[i], c, t.s);
            t.s = ns;
            b.w(chunk);
        }
    }

    function _one(Block memory k, IInteriors.Ctx memory c, uint32 rng)
        internal view returns (string memory, uint32)
    {
        return INTERIORS.blockSVG(k.x, k.y, k.w, k.h, k.t, c, rng);
    }

    function _emitRoutes(Buf.B memory b, T memory t, Route[] memory rt, uint256 rn, bool burnt) internal pure {
        for (uint256 i = 0; i < rn; i++) {
            b.w('<path d="'); _path(b, rt[i]);
            b.w('" stroke="#141A08" stroke-width="'); b.w(t.eng == 6 ? "6.5" : t.eng == 3 ? "4.7" : "5.5");
            b.w('" fill="none"/>');
        }
        for (uint256 i = 0; i < rn; i++) {
            bool dead = burnt ? _chance(t, 4500) : false;
            bool broken = (t.eng == 3 && rn > 1 && i == 1);
            b.w('<path d="');
            if (broken) {
                b.w("M "); b.wf(rt[i].p[0]); b.w(" "); b.wf(rt[i].p[1]);
                b.w(" L "); b.wf(rt[i].p[2]); b.w(" "); b.wf(rt[i].p[3]);
            } else _path(b, rt[i]);
            b.w('" stroke="'); b.w(dead ? DEAD : ROBIN);
            b.w('" stroke-width="'); b.w(t.eng == 6 ? "3.2" : t.eng == 3 ? "1.4" : "2.2");
            b.w('" fill="none" opacity="'); b.wf(rt[i].op100); b.w('" filter="url(#gt)">');
            if ((t.eng == 3 || t.eng == 2) && rn > 2 && i == 2 && !burnt) {
                b.w('<animate attributeName="opacity" values="');
                b.w(t.eng == 2 ? "0.95;0.2;0.9;0.5;1" : "0.85;0.25;0.85");
                b.w('" dur="'); b.w(t.eng == 2 ? "0.9" : "3.4"); b.w('s" repeatCount="indefinite"/>');
            }
            b.w("</path>");
            if (!broken) _vias(b, rt[i], dead);
        }
    }

    function _vias(Buf.B memory b, Route memory r, bool dead) internal pure {
        uint256 vs = r.viaEnd ? uint256(r.n) - 1 : 1;
        uint256 ve = r.viaEnd ? uint256(r.n) : uint256(r.n) - 1;
        for (uint256 k = vs; k < ve; k++) {
            b.w('<circle cx="'); b.wf(r.p[2 * k]); b.w('" cy="'); b.wf(r.p[2 * k + 1]);
            b.w('" r="3.4" fill="'); b.w(dead ? DEAD : ROBIN); b.w('" opacity="0.95"/>');
        }
    }

    function _emitPulses(Buf.B memory b, T memory t, Route[] memory rt, uint256 rn, uint8 oc, bool burnt) internal pure {
        if (rn == 0) return;
        uint256 np = burnt ? 1 : (1 + uint256(t.bin) + uint256(oc));
        if (np > 10) np = 10;
        uint256 dur = 520 * 100 / (100 + 45 * uint256(oc) + 18 * (uint256(t.bin) - 1));
        for (uint256 i = 0; i < np; i++) {
            b.w('<circle r="4.6" fill="');
            b.w(t.palIdx == 1 ? "#00E5FF" : t.palIdx == 2 ? "#FF2FD6" : ROBIN);
            b.w('" filter="url(#gc)"><animateMotion dur="'); b.wf(dur);
            b.w('s" begin="-'); b.wf(i * 70); b.w('s" repeatCount="indefinite" path="');
            _path(b, rt[i % rn]); b.w('"/></circle>');
        }
    }

    bytes internal constant B64T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function _b64(bytes memory data) internal pure returns (string memory result) {
        if (data.length == 0) return "";
        bytes memory tbl = B64T;
        result = new string(4 * ((data.length + 2) / 3));
        assembly {
            let tablePtr := add(tbl, 1)
            let resultPtr := add(result, 32)
            let dataPtr := add(data, 32)
            let endPtr := add(dataPtr, mload(data))
            for { } lt(dataPtr, endPtr) { } {
                let remaining := sub(endPtr, dataPtr)
                let input := 0
                switch gt(remaining, 2)
                case 1 { input := shr(232, mload(dataPtr)) dataPtr := add(dataPtr, 3) }
                default {
                    switch remaining
                    case 2 { input := shl(8, shr(240, mload(dataPtr))) dataPtr := endPtr }
                    default { input := shl(16, shr(248, mload(dataPtr))) dataPtr := endPtr }
                }
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F)))) resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 { mstore8(sub(resultPtr, 1), 0x3d) mstore8(sub(resultPtr, 2), 0x3d) }
            case 2 { mstore8(sub(resultPtr, 1), 0x3d) }
        }
    }

    function _pad4(uint256 v) internal pure returns (string memory) {
        Buf.B memory b = Buf.alloc(8);
        if (v < 1000) b.w("0"); if (v < 100) b.w("0"); if (v < 10) b.w("0");
        b.wu(v);
        return b.done();
    }

    /// IRenderer entry point — full on-chain metadata per the locked schema.
    function tokenURI(
        uint256 id, bytes32 seed, uint8 bits, uint8 oc, bool burnt,
        uint16 x, uint16 y, uint64 mintedAt, uint16 minted, uint16 burntCount
    ) external view returns (string memory) {
        mintedAt;
        return _meta(id, In(seed, bits, oc, burnt, x, y, minted, burntCount));
    }

    function _meta(uint256 id, In memory q) internal view returns (string memory) {
        string memory img = _b64(bytes(_render(q)));
        if (q.oc > 3) q.oc = 3;
        T memory t = _derive(q.seed, q.bits);
        IDecor.D memory d = IDecor.D({
            eng: t.eng, bin: t.bin, oc: q.oc, memeIdx: t.memeIdx, archIdx: t.archIdx,
            palIdx: t.palIdx, bits: q.bits, burnt: q.burnt, fine: t.fine,
            golden4200: t.golden4200, anim: true, x: q.wx, y: q.wy, lot: t.lot,
            railDur100: 0, ledDur100: 0, minted: q.minted, burntCount: q.burntCount
        });
        Buf.B memory b = Buf.alloc(bytes(img).length + 4000);
        b.w('{"name":"FAB 4200 \xc2\xb7 DIE #'); b.w(_pad4(id));
        b.w('","description":"Fully on-chain generative die, fabbed by proof-of-work on Robinhood Chain. ');
        b.w("The winning hash is the seed; difficulty is the bin grade. Free mint, no owner. ");
        b.w("Verify this die with verify("); b.wu(id); b.w(') on the collection contract.",');
        b.w('"image":"data:image/svg+xml;base64,'); b.w(img); b.w('",');
        b.w(DECOR.attrs(d, id));
        b.w("}");
        return string(abi.encodePacked("data:application/json;base64,", _b64(bytes(b.done()))));
    }

    function _typeName(uint8 tt) internal pure returns (string memory) {
        if (tt == 1) return "CORE";
        if (tt == 2) return "CACHE";
        if (tt == 3) return "IO";
        if (tt == 4) return "PLL";
        if (tt == 5) return "NPU";
        if (tt == 6) return "LANE";
        if (tt == 7) return "DECODER";
        return "FILL";
    }

    /// QC introspection: traits without rendering
    function traitsOf(bytes32 seed, uint8 bits) external pure returns (
        uint8 palIdx, uint8 archIdx, uint8 eng, uint8 memeIdx, uint8 bin,
        bool golden4200, bool fine, bytes4 lot, uint256 blocks
    ) {
        T memory t = _derive(seed, bits);
        (, uint256 n) = _floorplan(t);
        return (t.palIdx, t.archIdx, t.eng, t.memeIdx, t.bin, t.golden4200, t.fine, t.lot, n);
    }
}
