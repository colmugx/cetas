'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function targetName() {
  if (process.platform === 'darwin' && process.arch === 'arm64') return 'darwin-arm64';
  if (process.platform === 'linux' && process.arch === 'x64') return 'linux-x64';
  if (process.platform === 'linux' && process.arch === 'arm64') return 'linux-arm64';
  if (process.platform === 'win32' && process.arch === 'x64') return 'windows-x64';
  return `${process.platform}-${process.arch}`;
}

function quote(value) {
  if (process.platform === 'win32') return '"' + value.replace(/"/g, '\\"') + '"';
  return "'" + value.replace(/'/g, "'\"'\"'") + "'";
}

function fail(message, output = '') {
  if (output) process.stderr.write(output);
  console.error('[cetas-native] ' + message);
  process.exit(1);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function emit(library, nativeStaticLibs) {
  const flags = [quote(library), nativeStaticLibs.trim()].filter(Boolean).join(' ');
  console.log(JSON.stringify({
    link_configs: [
      { package: 'colmugx/cetas-native/src/app', link_flags: flags },
      { package: 'colmugx/cetas-native/src/parity', link_flags: flags },
      { package: 'colmugx/cetas-native/src/cetas', link_flags: flags },
      { package: 'colmugx/cetas-native/src/validation', link_flags: flags },
    ],
  }));
}

const moduleRoot = __dirname;
const target = targetName();
const libraryName = process.platform === 'win32' ? 'cetas_tui.lib' : 'libcetas_tui.a';
const defaultPrebuilt = path.join(moduleRoot, 'native', 'cetas-tui', 'prebuilt', target);
const prebuiltDir = process.env.CETAS_TUI_PREBUILT_DIR || defaultPrebuilt;
const manifestPath = path.join(prebuiltDir, 'manifest.json');
const prebuiltLibrary = path.join(prebuiltDir, libraryName);
const prebuiltFlags = path.join(prebuiltDir, 'native-static-libs.txt');

if (fs.existsSync(manifestPath) && fs.existsSync(prebuiltLibrary) && fs.existsSync(prebuiltFlags)) {
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    fail('invalid prebuilt manifest: ' + error.message);
  }
  if (manifest.abi_version !== 2 || manifest.target !== target || manifest.library !== libraryName) {
    fail(`prebuilt manifest mismatch for ${target}`);
  }
  const actual = sha256(prebuiltLibrary);
  if (typeof manifest.sha256 !== 'string' || manifest.sha256 !== actual) {
    fail(`prebuilt static library checksum mismatch for ${target}`);
  }
  emit(prebuiltLibrary, fs.readFileSync(prebuiltFlags, 'utf8'));
  process.exit(0);
}

if (process.env.CETAS_TUI_FORCE_PREBUILT === '1') {
  fail(`prebuilt static library missing for ${target}: expected ${prebuiltDir}`);
}

const manifest = path.join(moduleRoot, 'native', 'cetas-tui', 'Cargo.toml');
const build = spawnSync(
  'cargo',
  ['rustc', '--manifest-path', manifest, '--release', '--', '--print', 'native-static-libs'],
  { encoding: 'utf8' },
);
if (build.error) fail('failed to start cargo: ' + build.error.message);
if (build.status !== 0) fail('cargo rustc failed', (build.stdout || '') + (build.stderr || ''));

const output = (build.stderr || '') + '\n' + (build.stdout || '');
const match = output.match(/native-static-libs:\s*(.+)/);
if (!match) fail('cargo did not report native-static-libs', output);

const library = path.join(moduleRoot, 'native', 'cetas-tui', 'target', 'release', libraryName);
emit(library, match[1]);
