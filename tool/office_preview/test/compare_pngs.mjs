// Compare an independently reviewed reference; never creates/updates baselines.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { PNG } from 'pngjs';

const [referencePath, actualPath, output] = process.argv.slice(2);
assert.ok(referencePath && actualPath && output, 'Usage: node compare_pngs.mjs reference.png actual.png output-directory');
const expected = PNG.sync.read(await readFile(referencePath));
const actual = PNG.sync.read(await readFile(actualPath));
await mkdir(output, { recursive: true });
assert.equal(actual.width, expected.width, 'Image widths differ; never resize a failed screenshot to fit.');
assert.equal(actual.height, expected.height, 'Image heights differ; page geometry changed.');
const diff = new PNG({ width: expected.width, height: expected.height });
const comparison = new PNG({ width: expected.width * 3, height: expected.height });
let changed = 0;
for (let y = 0; y < actual.height; y++) for (let x = 0; x < actual.width; x++) {
  const offset = (y * actual.width + x) * 4;
  let different = false;
  for (let c = 0; c < 4; c++) if (Math.abs(actual.data[offset + c] - expected.data[offset + c]) > 8) different = true;
  if (different) changed++;
  diff.data[offset] = different ? 255 : Math.round(expected.data[offset] * 0.25 + 190);
  diff.data[offset + 1] = different ? 0 : Math.round(expected.data[offset + 1] * 0.25 + 190);
  diff.data[offset + 2] = different ? 80 : Math.round(expected.data[offset + 2] * 0.25 + 190);
  diff.data[offset + 3] = 255;
  for (const [index, image] of [expected, actual, diff].entries()) {
    image.data.copy(comparison.data, (y * comparison.width + index * expected.width + x) * 4, offset, offset + 4);
  }
}
const changedRatio = changed / (actual.width * actual.height);
await writeFile(path.join(output, 'diff.png'), PNG.sync.write(diff));
await writeFile(path.join(output, 'expected-actual-diff.png'), PNG.sync.write(comparison));
const result = { width: actual.width, height: actual.height, changedPixels: changed, changedRatio, channelTolerance: 8, maximumChangedRatio: 0.005, passed: changedRatio <= 0.005 };
await writeFile(path.join(output, 'comparison.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
assert.ok(result.passed, 'Screenshot differs from its reviewed reference; inspect the artifacts, do not regenerate the baseline.');
