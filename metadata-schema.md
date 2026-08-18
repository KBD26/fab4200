# FAB 4200 — Metadata Schema (LOCKED)

This is the immutable trait contract. The primary Solidity renderer MUST emit exactly these `trait_type` names and value formats; the FallbackRenderer already does. Marketplaces filter on these strings — once tokens mint, they can never change. Lock before the renderer build.

## tokenURI output
`data:application/json;base64,<base64(JSON)>` — fully on-chain, no external URIs.

## JSON shape
```json
{
  "name": "FAB 4200 · DIE #0043",
  "description": "<one-line lore + verify(id) pointer>",
  "image": "data:image/svg+xml;base64,<base64(SVG)>",
  "attributes": [ ... ]
}
```
- `name`: always `FAB 4200 · DIE #` + zero-padded 4-digit id.
- `image`: the animated SVG (SMIL animation lives inside it). `animation_url` is deliberately OMITTED: duplicating the base64 SVG in a second field inflated `tokenURI` from 11.2M to 15.8M gas for no marketplace benefit.

## attributes (exact trait_type names + value domains)

| trait_type | type | values | source |
|---|---|---|---|
| `Architecture` | string | FOMO PIPELINE · RUG · REKT · RUGGED · WEN MOON · NFT CABAL · FAKE TREASURY · FAKE CLARITY ACT · ROB THE RICH · GIVE TO POOR | seed |
| `Node Class` | string | 14nm · 10nm · 7nm · 5nm · 3nm · 2nm | difficulty bits |
| `Difficulty Bits` | number | integer (26–40+) | leading-zero bits |
| `Bin Grade` | number | 1–6 | derived from bits |
| `Palette` | string | PURE · ICE · HOT · SPECTRUM | seed |
| `Meme Rail` | string | HODL · REKT · DIAMOND HANDS · RUGPROOF SILICON · WAGMI · LIQUIDITY FLOWS · PUMP N DUMP · NGMI · SCAM · TRUST ME BRO · OFF CHAIN | seed (OFF CHAIN iff burnt) |
| `Overclock` | string | OC+0 · OC+1 · OC+2 · OC+3 | mutable state |
| `Status` | string | STABLE · BURNT | mutable state |
| `Wafer Site` | string | `X00·Y00` … `X66·Y66` | siteOf(id) |
| `Edge Die` | string | Yes · No | siteOf → border test |
| `Golden Sample` | string | Yes · No | bin 6 OR lot contains 4200 |

### Display/number hints (OpenSea)
- `Difficulty Bits`, `Bin Grade`: `"display_type":"number"`.
- No `max_value` on Bin Grade (uncapped-band philosophy) unless you want the 1–6 bar; recommend omitting.

### Rules the renderer MUST honor
1. `Status:BURNT` ⇒ `Meme Rail:OFF CHAIN` and the OC value is the last stable level (not the failed attempt).
2. `Golden Sample:Yes` is true if bin==6 OR the lot-code substring test passes — matches art gold-trim logic.
3. There is NO `Genesis`/premint trait: the collection has zero premint, so no token carries special status.
4. Every value is a literal from the domains above — no free-form strings, so filters stay clean.
5. Byte-identical trait derivation between the JS renderer, the Solidity renderer, and this schema — verified in the tape-out sweep.

## Token name format (for marketplaces/wallets)
`FAB 4200 · DIE #0043` — the descriptive subtitle (e.g. "REKT · 7nm · OC+2") lives in the SVG and can be added to `description`, not `name`, to keep names uniform and sortable.
