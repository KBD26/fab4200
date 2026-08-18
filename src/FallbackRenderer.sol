// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  FAB 4200 — FallbackRenderer
    Ownerless, immutable emergency renderer. If the primary art renderer
    ever reverts for any seed, tokenURI degrades to this: schema-valid
    JSON metadata + a minimal recovery SVG. No admin, no dependencies,
    cannot revert (pure string assembly over bounded inputs). */

contract FallbackRenderer {
    bytes internal constant B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function tokenURI(
        uint256 id, bytes32 /*seed*/, uint8 bits, uint8 oc, bool burnt,
        uint16 x, uint16 y, uint64 /*mintedAt*/, uint16 /*minted*/, uint16 /*burntCount*/
    ) external pure returns (string memory) {
        return _render(id, bits, oc, burnt, x, y); // shed unused params early
    }

    function _render(uint256 id, uint8 bits, uint8 oc, bool burnt, uint16 x, uint16 y)
        internal pure returns (string memory)
    {
        bytes memory json = abi.encodePacked(
            _head(id),
            _attrs(id, bits, oc, burnt, x, y),
            '],"image":"data:image/svg+xml;base64,',
            _b64(_svg(id, bits, burnt)),
            '"}'
        );
        return string(abi.encodePacked("data:application/json;base64,", _b64(json)));
    }

    function _head(uint256 id) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '{"name":"FAB 4200 \u00B7 DIE #', _pad4(id),
            '","description":"Fully on-chain die on Robinhood Chain. Primary renderer unavailable \u2014 recovery metadata; all state remains verifiable via verify(', _u(id), ').",',
            '"attributes":['
        );
    }

    function _attrs(uint256 id, uint8 bits, uint8 oc, bool burnt, uint16 x, uint16 y)
        internal pure returns (bytes memory)
    {
        bytes memory statusV = burnt ? bytes("BURNT") : bytes("STABLE");

        bytes memory a = abi.encodePacked(
            '{"trait_type":"Node Class","value":"', _node(bits), '"},',
            '{"trait_type":"Difficulty Bits","value":', _u(bits), '},',
            '{"trait_type":"Overclock","value":"OC+', _u(oc), '"},'
        );
        bytes memory b = abi.encodePacked(
            '{"trait_type":"Status","value":"', statusV, '"},',
            '{"trait_type":"Wafer Site","value":"X', _pad2(x), '\u00B7Y', _pad2(y), '"}'
        );
        return abi.encodePacked(a, b);
    }

    function _svg(uint256 id, uint8 bits, bool burnt) internal pure returns (bytes memory) {
        bytes memory burntTag = burnt ? bytes(" \u00B7 BURNT") : bytes("");
        bytes memory a = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#07090B"/>',
            '<rect x="30" y="30" width="340" height="340" fill="none" stroke="#CCFF00" stroke-width="3"/>',
            '<text x="200" y="150" font-family="monospace" font-size="26" fill="#CCFF00" text-anchor="middle">FAB 4200</text>'
        );
        bytes memory b = abi.encodePacked(
            '<text x="200" y="200" font-family="monospace" font-size="30" fill="#EAF2EC" text-anchor="middle">DIE #', _pad4(id), '</text>',
            '<text x="200" y="250" font-family="monospace" font-size="16" fill="#9FB58A" text-anchor="middle">', _u(bits), ' BITS \u00B7 ', _node(bits), burntTag, '</text>'
        );
        return abi.encodePacked(
            a, b,
            '<text x="200" y="290" font-family="monospace" font-size="12" fill="#9FB58A" text-anchor="middle" opacity="0.7">RECOVERY MODE \u00B7 verify(', _u(id), ') on-chain</text></svg>'
        );
    }

    function _node(uint8 bits) internal pure returns (string memory) {
        if (bits < 28) return "14nm";
        if (bits < 30) return "10nm";
        if (bits < 32) return "7nm";
        if (bits < 34) return "5nm";
        if (bits < 36) return "3nm";
        return "2nm";
    }
    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b; while (v > 0) { b = abi.encodePacked(uint8(48 + v % 10), b); v /= 10; }
        return string(b);
    }
    function _pad4(uint256 v) internal pure returns (string memory) {
        bytes memory s = bytes(_u(v)); while (s.length < 4) s = abi.encodePacked("0", s); return string(s);
    }
    function _pad2(uint256 v) internal pure returns (string memory) {
        bytes memory s = bytes(_u(v)); while (s.length < 2) s = abi.encodePacked("0", s); return string(s);
    }
    function _b64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory tbl = B64;
        bytes memory res = new bytes(4 * ((data.length + 2) / 3));
        uint256 i; uint256 j;
        for (i = 0; i + 3 <= data.length; i += 3) {
            uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i+1])) << 8) | uint256(uint8(data[i+2]));
            res[j++] = tbl[(n >> 18) & 63]; res[j++] = tbl[(n >> 12) & 63];
            res[j++] = tbl[(n >> 6) & 63];  res[j++] = tbl[n & 63];
        }
        uint256 rem = data.length - i;
        if (rem == 1) {
            uint256 n = uint256(uint8(data[i])) << 16;
            res[j++] = tbl[(n >> 18) & 63]; res[j++] = tbl[(n >> 12) & 63]; res[j++] = "="; res[j++] = "=";
        } else if (rem == 2) {
            uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i+1])) << 8);
            res[j++] = tbl[(n >> 18) & 63]; res[j++] = tbl[(n >> 12) & 63]; res[j++] = tbl[(n >> 6) & 63]; res[j++] = "=";
        }
        return string(res);
    }
}
