/**
 * wasm/test.node.mjs — Node.js smoke test for the WASM AVIF encoder
 *
 * Usage:
 *   node wasm/test.node.mjs
 *
 * Requires: wasm/dist/avif.node.js + avif.node.wasm
 * Build:    bash scripts/build-wasm.sh  (node variant built automatically)
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import createAvif from './dist/avif.node.js';

const __dir = dirname(fileURLToPath(import.meta.url));

let passed = 0;
let failed = 0;

function assert(cond, msg) {
  if (cond) {
    console.log(`  ✓ ${msg}`);
    passed++;
  } else {
    console.error(`  ✗ ${msg}`);
    failed++;
  }
}

// ---------------------------------------------------------------------------
// Load module
// ---------------------------------------------------------------------------
console.log('Loading WASM module...');
const Module = await createAvif();
console.log('Module loaded.\n');

// ---------------------------------------------------------------------------
// Case 1: version string
// ---------------------------------------------------------------------------
console.log('Case 1: avif_version()');
const vPtr = Module._avif_version();
const heap = Module.HEAPU8;
let end = vPtr; while (heap[end]) end++;
const version = new TextDecoder().decode(heap.subarray(vPtr, end));
console.log(`  libavif version: ${version}`);
assert(version.length > 0, 'version string non-empty');
assert(/^\d+\.\d+\.\d+/.test(version), `version format "${version}"`);

// ---------------------------------------------------------------------------
// Case 2: encode 16×16 RGBA (4 channels)
// ---------------------------------------------------------------------------
console.log('\nCase 2: encode 16×16 RGBA');
{
  const W = 16, H = 16, CH = 4;
  const pixels = new Uint8Array(W * H * CH);
  for (let i = 0; i < pixels.length; i += 4) {
    const p = (i / 4) | 0;
    pixels[i]     = p % 256;
    pixels[i + 1] = (p * 2) % 256;
    pixels[i + 2] = (p * 3) % 256;
    pixels[i + 3] = 255;
  }

  const inputPtr = Module._malloc(pixels.length);
  assert(inputPtr !== 0, 'malloc inputPtr');
  Module.HEAPU8.set(pixels, inputPtr);

  const t0 = performance.now();
  const outPtr = Module._avif_encode(inputPtr, W, H, CH, 60, 10);
  const elapsed = (performance.now() - t0).toFixed(1);
  Module._free(inputPtr);

  assert(outPtr !== 0, `avif_encode returned non-null (${elapsed} ms)`);

  if (outPtr) {
    const outSize = Module._avif_get_out_size();
    const avif = Module.HEAPU8.slice(outPtr, outPtr + outSize);
    Module._avif_free_output(outPtr);

    assert(outSize > 0, `output size ${outSize} bytes`);
    const brand = new TextDecoder().decode(avif.subarray(8, 12));
    assert(brand === 'avif' || brand === 'avis', `ftyp brand "${brand}"`);
  }
}

// ---------------------------------------------------------------------------
// Case 3: encode 16×16 RGB (3 channels)
// ---------------------------------------------------------------------------
console.log('\nCase 3: encode 16×16 RGB');
{
  const W = 16, H = 16, CH = 3;
  const pixels = new Uint8Array(W * H * CH);
  for (let i = 0; i < pixels.length; i++) pixels[i] = i % 256;

  const inputPtr = Module._malloc(pixels.length);
  Module.HEAPU8.set(pixels, inputPtr);
  const outPtr = Module._avif_encode(inputPtr, W, H, CH, 80, 10);
  Module._free(inputPtr);

  assert(outPtr !== 0, 'encode RGB succeeded');
  if (outPtr) {
    const outSize = Module._avif_get_out_size();
    const avif = Module.HEAPU8.slice(outPtr, outPtr + outSize);
    Module._avif_free_output(outPtr);
    const brand = new TextDecoder().decode(avif.subarray(8, 12));
    assert(brand === 'avif' || brand === 'avis', `ftyp brand "${brand}"`);
  }
}

// ---------------------------------------------------------------------------
// Case 4: null/invalid inputs → NULL return
// ---------------------------------------------------------------------------
console.log('\nCase 4: null/invalid inputs');
{
  // Zero width
  const buf = Module._malloc(16);
  const r1 = Module._avif_encode(buf, 0, 16, 4, 60, 10);
  assert(r1 === 0, 'zero width → NULL');

  // Invalid channels
  const r2 = Module._avif_encode(buf, 4, 4, 2, 60, 10);
  assert(r2 === 0, 'channels=2 → NULL');

  // Out-of-range quality
  const r3 = Module._avif_encode(buf, 4, 4, 4, 101, 10);
  assert(r3 === 0, 'quality=101 → NULL');

  // Out-of-range speed
  const r4 = Module._avif_encode(buf, 4, 4, 4, 60, 11);
  assert(r4 === 0, 'speed=11 → NULL');

  Module._free(buf);
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
console.log(`\n${passed + failed} tests — ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
