#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const romPatcherRoot = process.env.ROMPATCHER_JS;
if (!romPatcherRoot) {
  console.error("ROMPATCHER_JS must point to RomPatcher.js/rom-patcher-js");
  process.exit(2);
}
const BinFile = require(path.join(romPatcherRoot, "modules/BinFile"));
const RomPatcher = require(path.join(romPatcherRoot, "RomPatcher"));

function usage() {
  console.error("Usage: apply_bps.js <input> <patch.bps|patch.xdelta> <output>");
  process.exit(2);
}

const [inputPath, patchPath, outputPath] = process.argv.slice(2);
if (!inputPath || !patchPath || !outputPath) usage();

const input = new BinFile(inputPath);
const patchFile = new BinFile(patchPath);
const patch = RomPatcher.parsePatchFile(patchFile);
if (!patch) {
  throw new Error(`Invalid patch: ${patchPath}`);
}

const patched = RomPatcher.applyPatch(input, patch, {
  requireValidation: true,
  outputSuffix: false,
});

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, Buffer.from(patched._u8array.buffer));

console.log(`patched ${inputPath} -> ${outputPath}`);
