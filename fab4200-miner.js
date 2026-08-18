#!/usr/bin/env node
/*  FAB 4200 — native miner (open source, MIT)
    Finds a nonce whose keccak256(chainId ‖ contract ‖ minter ‖ nonce)
    has >= target leading zero bits. Multi-core. NEVER handles keys —
    it only needs your PUBLIC address. Output is a nonce + the mint
    calldata you paste into any wallet.

    Usage:
      node fab4200-miner.js --minter 0xYourAddress --target 26 \
        --contract 0xContract --chain 4663 [--threads N]

    Verify this file's hash against the one pinned on the official site
    before running. Requires: npm i js-sha3
*/
const os = require("os");
const { Worker, isMainThread, parentPort, workerData } = require("worker_threads");
const { keccak256 } = require("js-sha3");

function parseArgs() {
  const a = {}; const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i += 2) a[v[i].replace(/^--/, "")] = v[i + 1];
  return a;
}
function lz(hex) {
  let n = 0;
  for (let i = 0; i < hex.length; i++) { const c = parseInt(hex[i], 16); if (c === 0) { n += 4; continue; } n += c < 2 ? 3 : c < 4 ? 2 : c < 8 ? 1 : 0; break; }
  return n;
}
const clean = (h, len) => h.toLowerCase().replace(/^0x/, "").padStart(len, "0");
const u256 = n => n.toString(16).padStart(64, "0");

function makePreimage(chainId, contract, minter) {
  // 32-byte chainId ‖ 20-byte contract ‖ 20-byte minter ‖ 32-byte nonce = 104 bytes
  const buf = Buffer.alloc(104);
  Buffer.from(u256(BigInt(chainId)), "hex").copy(buf, 0);
  Buffer.from(clean(contract, 40), "hex").copy(buf, 32);
  Buffer.from(clean(minter, 40), "hex").copy(buf, 52);
  return buf;
}

if (isMainThread) {
  const a = parseArgs();
  const need = ["minter", "target", "contract", "chain"];
  for (const k of need) if (!a[k]) { console.error("missing --" + k + "\nusage: node fab4200-miner.js --minter 0x.. --target 26 --contract 0x.. --chain 4663 [--threads N]"); process.exit(1); }
  if (!/^0x[0-9a-fA-F]{40}$/.test(a.minter)) { console.error("minter must be a 0x address (public — never a private key)"); process.exit(1); }
  const target = parseInt(a.target, 10);
  const threads = parseInt(a.threads || String(Math.max(1, os.cpus().length - 1)), 10);
  console.error(`FAB 4200 miner · target ${target} bits · ${threads} threads · minter ${a.minter}`);
  console.error("(this tool never sees your private key)\n");

  let found = false, total = 0, t0 = Date.now();
  const workers = [];
  for (let i = 0; i < threads; i++) {
    const w = new Worker(__filename, { workerData: { ...a, target, stride: threads, offset: i, seed: (Date.now() ^ (i * 0x9e3779b1)) >>> 0 } });
    w.on("message", m => {
      if (m.hashes) { total += m.hashes; return; }
      if (m.nonce && !found) {
        found = true;
        const data = "0xa0712d68" + u256(BigInt(m.nonce));
        const secs = ((Date.now() - t0) / 1000).toFixed(1);
        console.error(`\nFOUND in ${secs}s · ${(total / 1e6).toFixed(1)}M hashes · ${lz(m.hash)} bits\n`);
        console.log(JSON.stringify({
          nonce: m.nonce, workHash: "0x" + m.hash, bits: lz(m.hash),
          mint: { to: a.contract, value: "0", data },
          note: "paste to/value/data into any wallet — value is 0, the mint is free"
        }, null, 2));
        workers.forEach(x => x.terminate());
        process.exit(0);
      }
    });
    workers.push(w);
  }
  const iv = setInterval(() => {
    const rate = total / ((Date.now() - t0) / 1000);
    process.stderr.write(`\r${(total / 1e6).toFixed(1)}M hashes · ${Math.round(rate / 1000)} kH/s`);
  }, 1000);
  iv.unref();
} else {
  const { minter, contract, chain, target, stride, offset, seed } = workerData;
  const pre = makePreimage(chain, contract, minter);
  let nonce = BigInt(seed) * BigInt(stride) + BigInt(offset) + 1n;
  const step = BigInt(stride);
  let count = 0;
  const nonceBuf = Buffer.alloc(32);
  while (true) {
    nonceBuf.write(u256(nonce), "hex");
    nonceBuf.copy(pre, 72);
    const h = keccak256(pre);
    if (lz(h) >= target) { parentPort.postMessage({ nonce: nonce.toString(), hash: h }); return; }
    nonce += step; count++;
    if ((count & 0x3fff) === 0) { parentPort.postMessage({ hashes: 16384 }); }
  }
}
