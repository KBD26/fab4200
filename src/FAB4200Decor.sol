// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  FAB 4200 — decor (ownerless, immutable, pure)
    defs/patterns, silkscreen etches, scrolling meme rails, status
    banners, live fab counter, wafer mark + die crystal glyphs.
    Word lists are the approved production sets and are frozen here. */

library Buf {
    struct B { bytes data; uint256 len; }
    function alloc(uint256 cap) internal pure returns (B memory b) { b.data = new bytes(cap + 64); b.len = 0; }
    function w(B memory b, string memory s) internal pure {
        assembly {
            let dp := mload(b) let len := mload(add(b, 0x20))
            let dst := add(add(dp, 0x20), len) let src := add(s, 0x20) let n := mload(s)
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

contract FAB4200Decor {
    using Buf for Buf.B;

    struct D {
        uint8  eng; uint8 bin; uint8 oc; uint8 memeIdx; uint8 archIdx; uint8 palIdx; uint8 bits;
        bool   burnt; bool fine; bool golden4200; bool anim;
        uint16 x; uint16 y;          // wafer site from siteOf(id)
        bytes4 lot;
        uint16 railDur100;           // meme rail scroll period x100
        uint16 ledDur100;            // status LED blink period x100
        uint16 minted; uint16 burntCount;
    }

    string internal constant ROBIN = "#CCFF00";
    string internal constant GOLD  = "#FFD24D";
    string internal constant INK   = "#9FB58A";
    string internal constant DIM   = "#26320B";
    string internal constant MAG   = "#FF2FD6";
    string internal constant DOT   = "\xc2\xb7";       // ·
    string internal constant BULL  = "\xe2\x80\xa2";   // •

    // ---------- frozen word lists ----------
    function archName(uint8 i) public pure returns (string memory) {
        if (i == 0) return "FOMO PIPELINE";
        if (i == 1) return "RUG";
        if (i == 2) return "REKT";
        if (i == 3) return "RUGGED";
        if (i == 4) return "WEN MOON";
        if (i == 5) return "NFT CABAL";
        if (i == 6) return "FAKE TREASURY";
        if (i == 7) return "FAKE CLARITY ACT";
        if (i == 8) return "ROB THE RICH";
        return "GIVE TO POOR";
    }
    function memeName(uint8 i, bool burnt) public pure returns (string memory) {
        if (burnt) return "OFF CHAIN";
        if (i == 100) return "TRUST ME BRO";
        if (i == 0) return "HODL";
        if (i == 1) return "REKT";
        if (i == 2) return "DIAMOND HANDS";
        if (i == 3) return "RUGPROOF SILICON";
        if (i == 4) return "WAGMI";
        if (i == 5) return "LIQUIDITY FLOWS";
        if (i == 6) return "PUMP N DUMP";
        if (i == 7) return "NGMI";
        return "SCAM";
    }
    function _memeShort(uint8 i, bool burnt) internal pure returns (bool) {
        if (burnt) return true;              // OFF CHAIN
        if (i == 3 || i == 5) return false;  // RUGPROOF SILICON, LIQUIDITY FLOWS
        return true;
    }
    function laneWord(uint8 i) public pure returns (string memory) {
        if (i == 0) return "HODL";
        if (i == 1) return "FOMO";
        if (i == 2) return "RUG";
        if (i == 3) return "CABAL";
        if (i == 4) return "SEND IT";
        if (i == 5) return "TRENCHES";
        return "FUGAZI";
    }
    function paletteName(uint8 i) public pure returns (string memory) {
        if (i == 0) return "PURE";
        if (i == 1) return "ICE";
        if (i == 2) return "HOT";
        return "SPECTRUM";
    }
    function nodeName(uint8 bin) public pure returns (string memory) {
        if (bin <= 1) return "14nm";
        if (bin == 2) return "10nm";
        if (bin == 3) return "7nm";
        if (bin == 4) return "5nm";
        if (bin == 5) return "3nm";
        return "2nm";
    }

    function _rnd(uint32 s) internal pure returns (uint32 ns, uint32 v) {
        unchecked {
            ns = s + 0x9e3779b9;
            uint32 z = ns;
            z = z ^ (z >> 16); z = z * 0x21f0aaad;
            z = z ^ (z >> 15); z = z * 0x735a2d97;
            v = z ^ (z >> 15);
        }
    }

    // ---------------- defs ----------------
    function defs(bool fine, bool burnt) external pure returns (string memory) {
        Buf.B memory b = Buf.alloc(3000);
        b.w("<defs>");
        b.w('<filter id="gt" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="2.6" result="bl"/><feMerge><feMergeNode in="bl"/><feMergeNode in="SourceGraphic"/></feMerge></filter>');
        b.w('<filter id="gc" x="-80%" y="-80%" width="260%" height="260%"><feGaussianBlur stdDeviation="6" result="bl"/><feMerge><feMergeNode in="bl"/><feMergeNode in="SourceGraphic"/></feMerge></filter>');
        b.w('<path id="rail" d="M 120 96 H 880"/>');
        uint256 cell = fine ? 18 : 24;
        b.w('<pattern id="pc" width="'); b.wu(cell); b.w('" height="'); b.wu(cell);
        b.w('" patternUnits="userSpaceOnUse"><rect x="3" y="3" width="'); b.wu(cell - 8);
        b.w('" height="'); b.wu(cell - 8); b.w('" fill="none" stroke="');
        b.w(burnt ? "#241C10" : DIM); b.w('" stroke-width="1.4"/></pattern>');
        uint256 pitch = fine ? 4 : 7;
        b.w('<pattern id="pk" width="8" height="'); b.wu(pitch * 2);
        b.w('" patternUnits="userSpaceOnUse"><line x1="0" y1="0" x2="8" y2="0" stroke="');
        b.w(burnt ? "#1C2312" : DIM); b.w('" stroke-width="'); b.w(fine ? "1.4" : "2");
        b.w('" opacity="0.9"/><line x1="0" y1="'); b.wu(pitch); b.w('" x2="8" y2="'); b.wu(pitch);
        b.w('" stroke="'); b.w(burnt ? "#1C2312" : DIM); b.w('" stroke-width="'); b.w(fine ? "1.4" : "2");
        b.w('" opacity="0.45"/></pattern>');
        b.w('<pattern id="pi" width="16" height="14" patternUnits="userSpaceOnUse"><rect width="9" height="14" fill="#8E9A92" opacity="0.85"/></pattern>');
        b.w('<pattern id="pj" width="16" height="6" patternUnits="userSpaceOnUse"><rect width="9" height="6" fill="'); b.w(DIM); b.w('"/></pattern>');
        b.w('<pattern id="pl" width="8" height="16" patternUnits="userSpaceOnUse"><line x1="0" y1="8" x2="8" y2="8" stroke="'); b.w(DIM); b.w('" stroke-width="1.5" opacity="0.3"/></pattern>');
        uint256 dp = fine ? 9 : 14;
        b.w('<pattern id="pd" width="'); b.wu(dp); b.w('" height="'); b.wu(dp);
        b.w('" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="'); b.w(fine ? "1.1" : "1.4");
        b.w('" fill="#222B22"/></pattern>');
        b.w('<pattern id="px" width="32" height="32" patternUnits="userSpaceOnUse"><rect width="14" height="14" fill="');
        b.w(ROBIN); b.w('" opacity="0.14"/><rect x="16" y="16" width="14" height="14" fill="');
        b.w(ROBIN); b.w('" opacity="0.14"/></pattern>');
        b.w("</defs>");
        return b.done();
    }

    // ---------------- meme rail + LED ----------------
    function rails(D calldata d) external pure returns (string memory) {
        Buf.B memory b = Buf.alloc(1600);
        string memory rw = d.eng == 7 ? "12" : "8";
        b.w('<path d="M 120 96 H 880" stroke="'); b.w(DIM); b.w('" stroke-width="'); b.w(rw); b.w('" opacity="0.8"/>');
        b.w('<path d="M 120 904 H 880" stroke="'); b.w(DIM); b.w('" stroke-width="'); b.w(rw); b.w('" opacity="0.8"/>');

        string memory meme = memeName(d.memeIdx, d.burnt);
        b.w('<text font-family="monospace" font-size="17" fill="');
        b.w(d.burnt ? "#3A4147" : ROBIN); b.w('" opacity="0.85"><textPath href="#rail" startOffset="10%">');
        b.w(meme);
        if (_memeShort(d.memeIdx, d.burnt)) {
            b.w(" "); b.w(BULL); b.w(" "); b.w(meme);
            b.w(" "); b.w(BULL); b.w(" "); b.w(meme);
        }
        if (d.anim) {
            b.w('<animate attributeName="startOffset" values="110%;-60%" dur="');
            b.wf(d.railDur100); b.w('s" begin="-'); b.wf(uint256(d.railDur100) * 45 / 100);
            b.w('s" repeatCount="indefinite"/>');
        }
        b.w("</textPath></text>");

        // status LED
        b.w('<rect x="856" y="842" width="12" height="12" fill="');
        b.w(d.burnt ? MAG : (d.palIdx == 1 ? "#00E5FF" : d.palIdx == 2 ? MAG : ROBIN));
        b.w('" filter="url(#gt)">');
        if (d.anim) {
            b.w('<animate attributeName="opacity" values="1;0.12;1" dur="');
            if (d.burnt) b.w("0.35"); else b.wf(d.ledDur100);
            b.w('s" repeatCount="indefinite"/>');
        }
        b.w('</rect><rect x="836" y="842" width="12" height="12" fill="'); b.w(DIM); b.w('"/>');
        return b.done();
    }

    // ---------------- lane words (lanes engine) ----------------
    function laneWords(uint16[16] calldata rects, uint8 count, uint32 rng, bool burnt, bool anim)
        external pure returns (string memory, uint32)
    {
        Buf.B memory b = Buf.alloc(4000);
        uint32 s = rng; uint32 v;
        for (uint256 i = 0; i < count; i++) {
            uint256 bx = rects[i * 4]; uint256 by = rects[i * 4 + 1];
            uint256 bw = rects[i * 4 + 2]; uint256 bh = rects[i * 4 + 3];
            uint256 ly100 = by * 100 + bh * 50 + 500;
            (s, v) = _rnd(s);
            string memory word = laneWord(uint8((uint256(v) * 7) / 4294967296));
            (s, v) = _rnd(s);
            uint256 dur = 800 + (uint256(v) * 600) / 4294967296;
            b.w('<defs><path id="ml'); b.wu(i); b.w('" d="M '); b.wu(bx + 10);
            b.w(" "); b.wf(ly100); b.w(" H "); b.wu(bx + bw - 10); b.w('"/></defs>');
            b.w('<text font-family="monospace" font-size="15" fill="');
            b.w(burnt ? "#3A4147" : ROBIN); b.w('" opacity="0.8"><textPath href="#ml'); b.wu(i);
            b.w('" startOffset="10%">');
            for (uint256 k = 0; k < 6; k++) { b.w(word); b.w(" "); b.w(DOT); b.w(" "); }
            if (anim) {
                b.w('<animate attributeName="startOffset" values="');
                b.w(i % 2 == 1 ? "-60%;110%" : "110%;-60%");
                b.w('" dur="'); b.wf(dur); b.w('s" begin="-'); b.wf(dur * 45 / 100);
                b.w('s" repeatCount="indefinite"/>');
            }
            b.w("</textPath></text>");
        }
        return (b.done(), s);
    }

    // ---------------- silkscreen etches ----------------
    function _txt(
        Buf.B memory b, uint256 x, uint256 y, string memory s,
        string memory fill, string memory size, string memory anchor, string memory op
    ) internal pure {
        b.w('<text x="'); b.wu(x); b.w('" y="'); b.wu(y);
        b.w('" font-family="monospace" font-size="'); b.w(size);
        b.w('" fill="'); b.w(fill); b.w('" opacity="'); b.w(op);
        if (bytes(anchor).length > 0) { b.w('" text-anchor="'); b.w(anchor); }
        b.w('">'); b.w(s); b.w("</text>");
    }

    function etches(D calldata d) external pure returns (string memory) {
        Buf.B memory b = Buf.alloc(4000);

        // lot + architecture
        b.w('<text x="120" y="118" font-family="monospace" font-size="15" fill="');
        b.w(d.golden4200 ? GOLD : INK); b.w('" opacity="0.8">FAB4200 '); b.w(DOT); b.w(" LOT ");
        b.w(string(abi.encodePacked(d.lot))); b.w("</text>");
        _txt(b, 880, 118, archName(d.archIdx), INK, "15", "end", "0.8");

        // node class (+ golden sample)
        {
            Buf.B memory nb = Buf.alloc(64);
            nb.w(nodeName(d.bin)); nb.w(" CLASS");
            if (d.bin >= 6) { nb.w(" "); nb.w(DOT); nb.w(" GOLDEN SAMPLE"); }
            _txt(b, 120, 890, nb.done(), d.bin >= 6 ? GOLD : INK, "15", "", "0.8");
        }

        // wafer coordinates (+ edge die)
        {
            Buf.B memory cb = Buf.alloc(64);
            cb.w("X"); if (d.x < 10) cb.w("0"); cb.wu(d.x);
            cb.w(DOT); cb.w("Y"); if (d.y < 10) cb.w("0"); cb.wu(d.y);
            bool edge = d.x < 4 || d.x > 62 || d.y < 4 || d.y > 62;
            if (edge) { cb.w(" "); cb.w(DOT); cb.w(" EDGE"); }
            _txt(b, 880, 890, cb.done(), INK, "15", "end", "0.8");
        }

        // overclock bars
        if (d.oc > 0) {
            Buf.B memory ob = Buf.alloc(64);
            ob.w("OC ");
            for (uint256 i = 0; i < 3; i++) ob.w(i < d.oc ? "\xe2\x96\xae" : "\xe2\x96\xaf");
            _txt(b, 880, 142, ob.done(), d.burnt ? MAG : "#FFFFFF", "14", "end", "0.9");
        }

        // status banner
        if (d.burnt) _txt(b, 500, 64, "OC PUSH FAILED \xe2\x80\x94 DIE SCARRED", MAG, "14", "middle", "0.75");
        else if (d.oc >= 3) _txt(b, 500, 64, "4200 MHz \xc2\xb7 OVERCLOCKED", "#FFFFFF", "15", "middle", "0.9");
        else if (d.eng == 3) _txt(b, 500, 64, "WEAK HANDS DETECTED", INK, "13", "middle", "0.6");

        // engine signatures
        if (d.eng == 3) {
            b.w('<text x="500" y="540" font-family="monospace" font-size="120" fill="');
            b.w(INK); b.w('" opacity="0.05" text-anchor="middle" transform="rotate(-18 500 500)">SELL?</text>');
        }
        if (d.eng == 1) _txt(b, 500, 890, "RUGPROOF PERIMETER", INK, "13", "middle", "0.6");
        if (d.eng == 7) {
            _txt(b, 142, 152, "HOLD", INK, "12", "", "0.55");
            _txt(b, 858, 152, "HOLD", INK, "12", "end", "0.55");
            _txt(b, 142, 862, "HOLD", INK, "12", "", "0.55");
            _txt(b, 858, 862, "HOLD", INK, "12", "end", "0.55");
        }

        // live fab counter — the chain's own state, etched at render time
        {
            Buf.B memory fb = Buf.alloc(96);
            fb.w("FAB "); fb.wu(d.minted); fb.w("/4200 "); fb.w(DOT); fb.w(" YIELD ");
            uint256 yield100 = d.minted == 0 ? 10000 : uint256(d.minted - d.burntCount) * 10000 / d.minted;
            fb.wf(yield100); fb.w("% "); fb.w(DOT); fb.w(" BURNT "); fb.wu(d.burntCount);
            _txt(b, 500, 918, fb.done(), INK, "13", "middle", "0.75");
        }

        return b.done();
    }

    /// Schema-locked attribute array (see metadata-schema.md). Trait names
    /// and value domains are frozen: marketplaces filter on these strings.
    function attrs(D calldata d, uint256 id) external pure returns (string memory) {
        id; // no per-id special cases: zero premint means every die is equal
        Buf.B memory b = Buf.alloc(1400);
        b.w('"attributes":[');
        b.w('{"trait_type":"Architecture","value":"'); b.w(archName(d.archIdx)); b.w('"},');
        b.w('{"trait_type":"Node Class","value":"'); b.w(nodeName(d.bin)); b.w('"},');
        b.w('{"trait_type":"Difficulty Bits","display_type":"number","value":'); b.wu(d.bits); b.w("},");
        b.w('{"trait_type":"Bin Grade","display_type":"number","value":'); b.wu(d.bin); b.w("},");
        b.w('{"trait_type":"Palette","value":"'); b.w(paletteName(d.palIdx)); b.w('"},');
        b.w('{"trait_type":"Meme Rail","value":"'); b.w(memeName(d.memeIdx, d.burnt)); b.w('"},');
        b.w('{"trait_type":"Overclock","value":"OC+'); b.wu(d.oc); b.w('"},');
        b.w('{"trait_type":"Status","value":"'); b.w(d.burnt ? "BURNT" : "STABLE"); b.w('"},');
        b.w('{"trait_type":"Wafer Site","value":"X');
        if (d.x < 10) b.w("0"); b.wu(d.x); b.w(DOT); b.w("Y"); if (d.y < 10) b.w("0"); b.wu(d.y);
        b.w('"},');
        bool edge = d.x < 4 || d.x > 62 || d.y < 4 || d.y > 62;
        b.w('{"trait_type":"Edge Die","value":"'); b.w(edge ? "Yes" : "No"); b.w('"},');
        b.w('{"trait_type":"Golden Sample","value":"');
        b.w((d.bin >= 6 || d.golden4200) ? "Yes" : "No"); b.w('"}');
        b.w("]");
        return b.done();
    }

    // ---------------- glyphs ----------------
    function glyphs(D calldata d) external pure returns (string memory) {
        Buf.B memory b = Buf.alloc(2200);
        // wafer mark: 5x5 fiducial with this die's seat blinking
        uint256 cx = uint256(d.x) * 5 / 67;
        uint256 cy = uint256(d.y) * 5 / 67;
        b.w('<g transform="translate(94 812) scale(0.44)">');
        b.w('<circle cx="32" cy="32" r="27" stroke="'); b.w(INK); b.w('" stroke-width="3" fill="none"/>');
        b.w('<path d="M28 58L32 51L36 58" stroke="'); b.w(INK); b.w('" stroke-width="3" fill="none"/>');
        b.w('<g stroke="'); b.w(INK); b.w('" stroke-width="1.5" opacity="0.4"><path d="M13 6V58M22 6V58M42 6V58M51 6V58M6 13H58M6 22H58M6 42H58M6 51H58"/></g>');
        b.w('<rect x="'); b.wf(1300 + cx * 970); b.w('" y="'); b.wf(1300 + cy * 970);
        b.w('" width="8" height="8" fill="'); b.w(d.burnt ? MAG : ROBIN); b.w('">');
        if (d.anim) {
            b.w('<animate attributeName="opacity" values="1;0.2;1" dur="');
            if (d.burnt) b.w("0.5"); else b.wf(d.ledDur100);
            b.w('s" repeatCount="indefinite"/>');
        }
        b.w("</rect></g>");

        // die crystal sigil — only on DIAMOND HANDS rails
        if (d.memeIdx == 2 && !d.burnt) {
            b.w('<g transform="translate(652 98) scale(0.42)" opacity="0.9">');
            b.w('<path d="M32 4L58 32L32 60L6 32Z" stroke="'); b.w(ROBIN); b.w('" stroke-width="4" stroke-linecap="square" fill="none"/>');
            b.w('<g stroke="'); b.w(ROBIN); b.w('" stroke-width="2.6" opacity="0.7"><path d="M32 11V24M32 40V53M13 32H24M40 32H51"/></g>');
            b.w('<rect x="25" y="25" width="14" height="14" fill="'); b.w(ROBIN); b.w('">');
            if (d.anim) { b.w('<animate attributeName="opacity" values="1;0.45;1" dur="'); b.wf(d.ledDur100); b.w('s" repeatCount="indefinite"/>'); }
            b.w("</rect>");
            b.w('<g fill="'); b.w(ROBIN); b.w('"><circle cx="32" cy="4" r="2.6"/><circle cx="58" cy="32" r="2.6"/><circle cx="32" cy="60" r="2.6"/><circle cx="6" cy="32" r="2.6"/></g></g>');
        }
        return b.done();
    }
}
