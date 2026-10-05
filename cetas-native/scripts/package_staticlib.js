'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function fail(message, output = '') {
  if (output) process.stderr.write(output);
  console.error('[cetas-native] ' + message);
  process.exit(1);
}

function targetName() {
  if (process.platform === 'darwin' && process.arch === 'arm64') return 'darwin-arm64';
  if (process.platform === 'linux' && process.arch === 'x64') return 'linux-x64';
  if (process.platform === 'linux' && process.arch === 'arm64') return 'linux-arm64';
  if (process.platform === 'win32' && process.arch === 'x64') return 'windows-x64';
  return `${process.platform}-${process.arch}`;
}

const args = process.argv.slice(2);
const outAt = args.indexOf('--out');
if (outAt < 0 || !args[outAt + 1]) fail('usage: package_staticlib.js --out DIR [--target TARGET]');
const targetAt = args.indexOf('--target');
const requested = targetAt >= 0 ? args[targetAt + 1] : null;
const target = targetName();
if (requested && requested !== target) fail(`runner target mismatch: requested ${requested}, got ${target}`);

const moduleRoot = path.resolve(__dirname, '..');
const cargoManifest = path.join(moduleRoot, 'native', 'cetas-tui', 'Cargo.toml');
const build = spawnSync(
  'cargo',
  ['rustc', '--manifest-path', cargoManifest, '--release', '--', '--print', 'native-static-libs'],
  { encoding: 'utf8' },
);
if (build.error) fail('failed to start cargo: ' + build.error.message);
if (build.status !== 0) fail('cargo rustc failed', (build.stdout || '') + (build.stderr || ''));

const output = (build.stderr || '') + '\n' + (build.stdout || '');
const libs = output.match(/native-static-libs:\s*(.+)/);
if (!libs) fail('cargo did not report native-static-libs', output);

const libraryName = process.platform === 'win32' ? 'cetas_tui.lib' : 'libcetas_tui.a';
const source = path.join(moduleRoot, 'native', 'cetas-tui', 'target', 'release', libraryName);
if (!fs.existsSync(source)) fail('cargo did not produce ' + source);

const outDir = path.resolve(args[outAt + 1]);
fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });
const outputLibrary = path.join(outDir, libraryName);
fs.copyFileSync(source, outputLibrary);
fs.writeFileSync(path.join(outDir, 'native-static-libs.txt'), libs[1].trim() + '\n');

const hash = crypto.createHash('sha256').update(fs.readFileSync(outputLibrary)).digest('hex');
const rustc = spawnSync('rustc', ['--version'], { encoding: 'utf8' });
fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify({
  abi_version: 2,
  target,
  library: libraryName,
  sha256: hash,
  rustc: rustc.status === 0 ? (rustc.stdout || '').trim() : 'unknown',
}, null, 2) + '\n');
console.log(`packaged cetas-tui staticlib for ${target}: ${outDir}`);
