// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  FAB 4200 — block interiors (ownerless, immutable, pure)
    Called by the primary renderer. Returns one block's interior SVG and
    the advanced RNG state, so the draw sequence stays deterministic
    across the contract boundary.

    Size strategy: repeating textures (cell grids, cache pitch, dot fill,
    IO fingers, lane rails, checker) are emitted as <pattern> fills defined
    once by the primary. Only the signature geometry — die square, PLL
    rings, NPU mesh, decoder, burnout scarring — is drawn element-wise.
*/

library Buf {
    struct B { bytes data; uint256 len; }
    function alloc(uint256 cap) internal pure returns (B memory b) { b.data = new bytes(cap + 64); b.len = 0; }
    function w(B memory b, string memory s) internal pure {
        assembly {
            let dataPtr := mload(b) let len := mload(add(b, 0x20))
            let dst := add(add(dataPtr, 0x20), len) let src := add(s, 0x20) let n := mload(s)
            for { let i := 0 } lt(i, n) { i := add(i, 32) } { mstore(add(dst, i), mload(add(src, i))) }
            mstore(add(b, 0x20), add(len, n))
        }
    }
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
        wu(b, v100 / 100); uint256 f = v100 % 100;
        if (f == 0) return;
        w(b, ".");
        if (f % 10 == 0) { wu(b, f / 10); return; }
        if (f < 10) w(b, "0");
        wu(b, f);
    }
    function done(B memory b) internal pure returns (string memory out) {
        assembly { out := mload(b) mstore(out, mload(add(b, 0x20))) }
    }
}

contract FAB4200Interiors {
    using Buf for Buf.B;

    struct Ctx {
        uint8  eng;      // 0 lanes,1 ring,2 chaos,3 fragile,4 clock,5 mesh,6 mono,7 heavy
        uint8  bin;      // 1..6
        uint8  oc;       // 0..3
        bool   burnt;
        bool   fine;     // bin >= 6
        bool   anim;
        uint16 dur100;   // animation period x100 (seconds)
    }
    struct S { uint32 s; }
    struct Rect { uint256 x; uint256 y; uint256 w; uint256 h; uint256 ix; uint256 iy; uint256 iw; uint256 ih; }

    string internal constant ROBIN = "#CCFF00";
    string internal constant INK   = "#9FB58A";
    string internal constant DIM   = "#26320B";
    string internal constant MAG   = "#FF2FD6";
    string internal constant CYAN  = "#00E5FF";

    // 12 unit-circle steps (30 deg), scaled 1000 — avoids trig on-chain
    function _dir(uint256 k) internal pure returns (int256 cx, int256 sy) {
        uint256 m = k % 12;
        if (m == 0) return (1000, 0);      if (m == 1) return (866, 500);
        if (m == 2) return (500, 866);     if (m == 3) return (0, 1000);
        if (m == 4) return (-500, 866);    if (m == 5) return (-866, 500);
        if (m == 6) return (-1000, 0);     if (m == 7) return (-866, -500);
        if (m == 8) return (-500, -866);   if (m == 9) return (0, -1000);
        if (m == 10) return (500, -866);   return (866, -500);
    }

    function _rnd(S memory r) internal pure returns (uint32) {
        unchecked {
            r.s = r.s + 0x9e3779b9;
            uint32 z = r.s;
            z = z ^ (z >> 16); z = z * 0x21f0aaad;
            z = z ^ (z >> 15); z = z * 0x735a2d97;
            return z ^ (z >> 15);
        }
    }
    function _ri(S memory r, uint256 a, uint256 b) internal pure returns (uint256) {
        return a + (uint256(_rnd(r)) * (b - a + 1)) / 4294967296;
    }
    function _frac(S memory r, uint256 scale) internal pure returns (uint256) {
        return (uint256(_rnd(r)) * scale) / 4294967296;
    }
    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    function blockSVG(
        uint16 bx, uint16 by, uint16 bw, uint16 bh, uint8 t, Ctx calldata c, uint32 rng
    ) external pure returns (string memory, uint32) {
        Buf.B memory b = Buf.alloc(9000);
        S memory r = S(rng);

        b.w('<rect x="'); b.wu(bx); b.w('" y="'); b.wu(by);
        b.w('" width="'); b.wu(bw); b.w('" height="'); b.wu(bh);
        b.w('" fill="#0D1013" stroke="#39430E" stroke-width="1.5"/>');
        if (bw < 40 || bh < 40) return (b.done(), r.s);

        Rect memory q = Rect(bx, by, bw, bh, uint256(bx) + 10, uint256(by) + 10, uint256(bw) - 20, uint256(bh) - 20);

        if (t == 1) _core(b, r, c, q);
        else if (t == 2) _fillPat(b, q.ix, q.iy, q.iw, q.ih, "pk");
        else if (t == 3) _io(b, q);
        else if (t == 4) _pll(b, r, c, q);
        else if (t == 5) _npu(b, r, c, q);
        else if (t == 6) _fillPat(b, q.ix, q.iy, q.iw, q.ih, "pl");
        else if (t == 7) _decoder(b, c, q);
        else _fillPat(b, q.ix, q.iy, q.iw, q.ih, "pd");

        return (b.done(), r.s);
    }

    function _fillPat(Buf.B memory b, uint256 x, uint256 y, uint256 w, uint256 h, string memory id) internal pure {
        b.w('<rect x="'); b.wu(x); b.w('" y="'); b.wu(y);
        b.w('" width="'); b.wu(w); b.w('" height="'); b.wu(h);
        b.w('" fill="url(#'); b.w(id); b.w(')"/>');
    }

    // ---------------- CORE ----------------
    function _core(Buf.B memory b, S memory r, Ctx calldata c, Rect memory q) internal pure {
        _fillPat(b, q.ix, q.iy, q.iw, q.ih, "pc"); // cell grid via pattern

        uint256 cx100 = q.x * 100 + q.w * 50;
        uint256 cy100 = q.y * 100 + q.h * 50;
        uint256 R100 = _min(q.iw, q.ih) * 26;

        if (c.burnt) {
            b.w('<ellipse cx="'); b.wf(cx100); b.w('" cy="'); b.wf(cy100);
            b.w('" rx="'); b.wf(R100 * 3 / 2); b.w('" ry="'); b.wf(R100 * 12 / 10);
            b.w('" fill="#17110A" opacity="0.92"/>');
            _cracks(b, r, cx100, cy100, R100);
            b.w('<text x="'); b.wf(cx100); b.w('" y="'); b.wf(cy100 + R100 + 2200);
            b.w('" text-anchor="middle" font-family="monospace" font-size="15" fill="');
            b.w(MAG); b.w('" opacity="0.85">MAGIC SMOKE ESCAPED</text>');
            return;
        }

        string memory hot = c.oc >= 3 ? "#FFFFFF" : ROBIN;
        b.w('<rect x="'); b.wf(cx100 - R100); b.w('" y="'); b.wf(cy100 - R100);
        b.w('" width="'); b.wf(2 * R100); b.w('" height="'); b.wf(2 * R100);
        b.w('" fill="none" stroke="'); b.w(hot); b.w('" stroke-width="3.2" filter="url(#gc)"/>');

        _brackets(b, cx100, cy100, R100, hot);
        _sigGrid(b, cx100, cy100, R100, hot);

        if (c.eng == 6) { // mono: fab striations
            for (uint256 f = 0; f < 3; f++) {
                uint256 fx = q.x + (20 + 28 * f) * q.w / 100;
                b.w('<line x1="'); b.wu(fx); b.w('" y1="'); b.wu(q.y + 8);
                b.w('" x2="'); b.wu(fx + q.h * 40 / 100); b.w('" y2="'); b.wu(q.y + q.h - 8);
                b.w('" stroke="#FFFFFF" stroke-width="2" opacity="0.1"/>');
            }
        }
    }


    function _cracks(Buf.B memory b, S memory r, uint256 cx100, uint256 cy100, uint256 R100) internal pure {
        for (uint256 k = 0; k < 4; k++) {
            int256 px = int256(cx100); int256 py = int256(cy100);
            b.w('<path d="M '); b.wf(cx100); b.w(" "); b.wf(cy100);
            for (uint256 seg = 0; seg < 3; seg++) {
                px += int256(_frac(r, 2 * R100)) - int256(R100);
                py += int256(_frac(r, 2 * R100)) - int256(R100);
                if (px < 0) px = 0; if (py < 0) py = 0;
                b.w(" L "); b.wf(uint256(px)); b.w(" "); b.wf(uint256(py));
            }
            b.w('" stroke="#000000" stroke-width="2.5" fill="none"/>');
        }
    }

    function _brackets(Buf.B memory b, uint256 cx100, uint256 cy100, uint256 R100, string memory hot) internal pure {
        for (uint256 q = 0; q < 4; q++) {
            int256 sx = (q == 0 || q == 2) ? int256(-1) : int256(1);
            int256 sy = (q < 2) ? int256(-1) : int256(1);
            b.w('<path d="M ');
            b.wf(uint256(int256(cx100) + sx * int256(R100 + 900))); b.w(" ");
            b.wf(uint256(int256(cy100) + sy * int256(R100))); b.w(" L ");
            b.wf(uint256(int256(cx100) + sx * int256(R100 + 900))); b.w(" ");
            b.wf(uint256(int256(cy100) + sy * int256(R100 + 900))); b.w(" L ");
            b.wf(uint256(int256(cx100) + sx * int256(R100))); b.w(" ");
            b.wf(uint256(int256(cy100) + sy * int256(R100 + 900)));
            b.w('" stroke="'); b.w(hot); b.w('" stroke-width="2" fill="none" opacity="0.8"/>');
        }
    }

    function _sigGrid(Buf.B memory b, uint256 cx100, uint256 cy100, uint256 R100, string memory hot) internal pure {
        uint256 k100 = R100 * 34 / 100;
        for (uint256 g = 0; g < 9; g++) {
            uint256 gi = g / 3; uint256 gj = g % 3;
            bool center = (gi == 1 && gj == 1);
            b.w('<rect x="');
            b.wf(uint256(int256(cx100) + (int256(gi) - 1) * int256(k100) - int256(k100 * 38 / 100)));
            b.w('" y="');
            b.wf(uint256(int256(cy100) + (int256(gj) - 1) * int256(k100) - int256(k100 * 38 / 100)));
            b.w('" width="'); b.wf(k100 * 76 / 100); b.w('" height="'); b.wf(k100 * 76 / 100);
            b.w('" fill="'); b.w(hot); b.w('" opacity="'); b.w(center ? "0.95" : "0.28");
            b.w('"'); if (center) b.w(' filter="url(#gc)"'); b.w("/>");
        }
    }

    // ---------------- IO ----------------
    function _io(Buf.B memory b, Rect memory q) internal pure {
        _fillPat(b, q.ix, q.iy + q.ih - 16, q.iw, 14, "pi");
        _fillPat(b, q.ix, q.iy, q.iw, 6, "pj");
    }

    // ---------------- PLL ----------------
    function _pll(Buf.B memory b, S memory r, Ctx calldata c, Rect memory q) internal pure {
        uint256 cx100 = q.x * 100 + q.w * 50;
        uint256 cy100 = q.y * 100 + q.h * 50;
        uint256 R100 = _min(q.iw, q.ih) * 50;
        for (uint256 k = 1; k <= 3; k++) {
            b.w('<circle cx="'); b.wf(cx100); b.w('" cy="'); b.wf(cy100);
            b.w('" r="'); b.wf(R100 * k / 34 * 10 / 10); b.w('" fill="none" stroke="');
            b.w(DIM); b.w('" stroke-width="2"/>');
        }
        b.w('<circle cx="'); b.wf(cx100); b.w('" cy="'); b.wf(cy100);
        b.w('" r="4.5" fill="'); b.w(ROBIN); b.w('" filter="url(#gt)"/>');

        if (c.eng == 4) { // clock: tick ring + countdown label + rising vias
            for (uint256 k = 0; k < 12; k++) {
                (int256 dx, int256 dy) = _dir(k);
                uint256 r1 = R100 * 88 / 100; uint256 r2 = R100 * 99 / 100;
                b.w('<line x1="'); b.wf(uint256(int256(cx100) + dx * int256(r1) / 1000));
                b.w('" y1="'); b.wf(uint256(int256(cy100) + dy * int256(r1) / 1000));
                b.w('" x2="'); b.wf(uint256(int256(cx100) + dx * int256(r2) / 1000));
                b.w('" y2="'); b.wf(uint256(int256(cy100) + dy * int256(r2) / 1000));
                b.w('" stroke="'); b.w(INK); b.w('" stroke-width="2" opacity="0.7"/>');
            }
            b.w('<text x="'); b.wf(cx100); b.w('" y="'); b.wf(cy100 + R100 + 1600);
            b.w('" font-family="monospace" font-size="12" fill="'); b.w(INK);
            b.w('" text-anchor="middle" opacity="0.8">T-4200</text>');
            if (c.anim && !c.burnt) {
                for (uint256 v = 0; v < 5; v++) {
                    uint256 vx100 = cx100 - 3000 + _frac(r, 6000);
                    uint256 vy100 = q.y * 100 + 600;
                    uint256 dur = 260 + _frac(r, 200);
                    b.w('<circle cx="'); b.wf(vx100); b.w('" cy="'); b.wf(vy100);
                    b.w('" r="'); b.wf(200 + _frac(r, 200)); b.w('" fill="');
                    b.w(v % 2 == 1 ? "#FFFFFF" : CYAN); b.w('" opacity="0.5">');
                    b.w('<animate attributeName="cy" from="'); b.wf(vy100); b.w('" to="');
                    b.wf(vy100 > 7000 ? vy100 - 7000 : 0); b.w('" dur="'); b.wf(dur);
                    b.w('s" repeatCount="indefinite"/>');
                    b.w('<animate attributeName="opacity" values="0.55;0" dur="'); b.wf(dur);
                    b.w('s" repeatCount="indefinite"/></circle>');
                }
            }
        }
    }

    // ---------------- NPU ----------------
    function _npu(Buf.B memory b, S memory r, Ctx calldata c, Rect memory q) internal pure {
        uint256 x = q.ix; uint256 y = q.iy; uint256 w = q.iw; uint256 h = q.ih;
        if (c.eng != 5) {
            _fillPat(b, x, y, w, h, "px");
            b.w('<text x="'); b.wu(x + 4); b.w('" y="'); b.wu(y + h - 6);
            b.w('" font-family="monospace" font-size="12" fill="'); b.w(INK); b.w('" opacity="0.7">NPU</text>');
            return;
        }
        uint256 n = 26 + _ri(r, 0, 10);
        uint256[] memory px = new uint256[](n);
        uint256[] memory py = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            px[i] = (x + 6) * 100 + _frac(r, (w - 12) * 100);
            py[i] = (y + 6) * 100 + _frac(r, (h - 12) * 100);
        }
        // nearest-earlier-neighbour graph — the agent fabric
        for (uint256 i = 1; i < n; i++) {
            uint256 bi = 0; uint256 bd = type(uint256).max;
            for (uint256 j = 0; j < i; j++) {
                uint256 dx = px[i] > px[j] ? px[i] - px[j] : px[j] - px[i];
                uint256 dy = py[i] > py[j] ? py[i] - py[j] : py[j] - py[i];
                uint256 d = dx * dx + dy * dy;
                if (d < bd) { bd = d; bi = j; }
            }
            b.w('<line x1="'); b.wf(px[i]); b.w('" y1="'); b.wf(py[i]);
            b.w('" x2="'); b.wf(px[bi]); b.w('" y2="'); b.wf(py[bi]);
            b.w('" stroke="'); b.w(ROBIN); b.w('" stroke-width="1" opacity="0.4"/>');
        }
        _npuNodes(b, c, px, py, n, (x + w / 2) * 100, (y + h / 2) * 100, _min(w, h) * 22);
        b.w('<text x="'); b.wu(x + 4); b.w('" y="'); b.wu(y + h - 6);
        b.w('" font-family="monospace" font-size="12" fill="'); b.w(INK);
        b.w('" opacity="0.7">NPU \xc2\xb7 AGENT FABRIC</text>');
    }

    function _npuNodes(
        Buf.B memory b, Ctx calldata c,
        uint256[] memory px, uint256[] memory py, uint256 n,
        uint256 ccx, uint256 ccy, uint256 rad
    ) internal pure {
        for (uint256 i = 0; i < n; i++) {
            uint256 dx = px[i] > ccx ? px[i] - ccx : ccx - px[i];
            uint256 dy = py[i] > ccy ? py[i] - ccy : ccy - py[i];
            bool cent = dx * dx + dy * dy < rad * rad;
            b.w('<circle cx="'); b.wf(px[i]); b.w('" cy="'); b.wf(py[i]);
            b.w('" r="'); b.w(cent ? "3.2" : "2"); b.w('" fill="'); b.w(ROBIN);
            if (cent) b.w('" filter="url(#gt)');
            b.w('" opacity="0.9">');
            if (c.anim && !c.burnt) {
                b.w('<animate attributeName="opacity" values="0.35;1;0.35" dur="');
                b.wf(c.dur100); b.w('s" begin="-'); b.wf(i * 9); b.w('s" repeatCount="indefinite"/>');
            }
            b.w("</circle>");
        }
    }

    // ---------------- DECODER ----------------
    function _decoder(Buf.B memory b, Ctx calldata c, Rect memory q) internal pure {
        b.w('<rect x="'); b.wu(q.x + 6); b.w('" y="'); b.wu(q.y + 6);
        b.w('" width="'); b.wu(q.w - 12); b.w('" height="'); b.wu(q.h - 12);
        b.w('" fill="none" stroke="'); b.w(ROBIN); b.w('" stroke-width="2.5" opacity="0.9" filter="url(#gt)"/>');
        uint256 ix100 = q.x * 100 + q.w * 50;
        uint256 iy100 = q.y * 100 + q.h * 50;
        b.w('<rect x="'); b.wf(ix100 - 2200); b.w('" y="'); b.wf(iy100 - 1400);
        b.w('" width="44" height="28" fill="'); b.w(ROBIN); b.w('" opacity="0.9" filter="url(#gc)">');
        if (c.anim && !c.burnt) {
            b.w('<animate attributeName="opacity" values="0.9;0.2;0.9" dur="');
            b.wf(c.dur100 / 3 + 30); b.w('s" repeatCount="indefinite"/>');
        }
        b.w("</rect>");
        b.w('<text x="'); b.wf(ix100); b.w('" y="'); b.wu(q.y + q.h - 12);
        b.w('" font-family="monospace" font-size="12" fill="'); b.w(INK);
        b.w('" text-anchor="middle" opacity="0.8">MEME DECODER</text>');
    }
}
