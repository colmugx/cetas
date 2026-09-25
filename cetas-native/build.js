'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

function shellQuote(value) {
  return "'" + value.replace(/'/g, "'\"'\"'") + "'";
}

function fail(message, output) {
  if (output) process.stderr.write(output);
  console.error("[cetas-native] " + message);
  process.exit(1);
}

const moduleRoot = __dirname;
const manifest = path.join(moduleRoot, 'native', 'cetas-tui', 'Cargo.toml');

const build = spawnSync(
  'cargo',
  [
    'rustc',
    '--manifest-path',
    manifest,
    '--release',
    '--',
    '--print',
    'native-static-libs',
  ],
  { encoding: 'utf8' },
);

if (build.error) {
  fail("failed to start cargo: " + build.error.message);
}
if (build.status !== 0) {
  fail("cargo rustc failed", (build.stdout || '') + (build.stderr || ''));
}

const output = (build.stderr || '') + '\n' + (build.stdout || '');
const match = output.match(/native-static-libs:\s*(.+)/);
if (!match) {
  fail("cargo did not report native-static-libs", output);
}

const libraryName =
  process.platform === 'win32' ? 'cetas_tui.lib' : 'libcetas_tui.a';

const staticLibrary = path.join(
  moduleRoot,
  'native',
  'cetas-tui',
  'target',
  'release',
  libraryName,
);

console.log(JSON.stringify({
  link_configs: [
    {
      package: 'colmugx/cetas-native/src',
      link_flags: [shellQuote(staticLibrary), match[1].trim()].join(' '),
    },
    {
      package: 'colmugx/cetas-native/src/parity',
      link_flags: [shellQuote(staticLibrary), match[1].trim()].join(' '),
    },
  ],
}));
