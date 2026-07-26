import { createHash } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const directory = path.resolve(process.argv[2] ?? 'release');
const outputName = process.argv[3] ?? 'checksums.txt';
const outputPath = path.join(directory, outputName);
const names = (await readdir(directory, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name !== outputName)
  .map((entry) => entry.name)
  .sort();
if (!names.length) throw new Error(`No release files found in ${directory}.`);
const lines = [];
for (const name of names) {
  const digest = createHash('sha256').update(await readFile(path.join(directory, name))).digest('hex');
  lines.push(`${digest}  ${name}`);
}
await writeFile(outputPath, `${lines.join('\n')}\n`);
console.log(`Wrote ${names.length} SHA-256 checksums to ${outputPath}.`);
