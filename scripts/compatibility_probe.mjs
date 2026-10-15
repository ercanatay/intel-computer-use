import { spawn, execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import * as fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const API = 'CodexComputerUseIPC-5';
const HASHES = Object.freeze({
  'native-pipe.js': '2f1bcc0b4cd013ef3d267f6d93bd2aa29770712687c8db087d55ec9d173380e8',
  'client.js': 'ae51951e7087203d473127ccee7725fc61528682f6866d60595a963ef6da56c9',
});
const CLIENT_DIRECTORY = 'Contents/Resources/cua_node/lib/node_modules/@oai/sky/dist/project/cua/sky_js/src/targets/mac';
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const failure = (outcome, reason) => ({ outcome, reason });

export function safeEnvironment(source = process.env) {
  const result = {};
  for (const name of ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', '__CF_USER_TEXT_ENCODING']) {
    if (typeof source[name] === 'string') result[name] = source[name];
  }
  return result;
}

async function readAppVersion(app) {
  const execute = promisify(execFile);
  const read = async key => (await execute('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', path.join(app, 'Contents/Info.plist')],
    { env: safeEnvironment(), timeout: 1000, maxBuffer: 4096 })).stdout.trim();
  return { version: await read('CFBundleShortVersionString'), build: await read('CFBundleVersion') };
}

export async function inspectClient(app, versionReader = readAppVersion) {
  try {
    const version = await versionReader(app);
    if (version.version !== '26.1007.71326' || version.build !== '20398') return failure('skipped', 'unknownAppVersion');
    const directory = path.join(app, CLIENT_DIRECTORY);
    for (const [filename, expected] of Object.entries(HASHES)) {
      const filenamePath = path.join(directory, filename);
      const info = await fs.stat(filenamePath);
      if (!info.isFile() || info.size > 1_048_576) return failure('skipped', 'clientChanged');
      const hash = createHash('sha256').update(await fs.readFile(filenamePath)).digest('hex');
      if (hash !== expected) return failure('skipped', 'clientChanged');
    }
    return { outcome: 'verified', directory, appVersion: version.version, appBuild: version.build, clientHashes: HASHES };
  } catch { return failure('skipped', 'clientUnavailable'); }
}

async function validateEndpoint(record) {
  if (record?.protocol !== API || typeof record.socketPath !== 'string' || !path.isAbsolute(record.socketPath)) throw new Error();
  const endpoint = record.socketPath;
  const directory = path.dirname(endpoint);
  const temporaryRoot = process.platform === 'darwin'
    ? (await promisify(execFile)('/usr/bin/getconf', ['DARWIN_USER_TEMP_DIR'], { env: safeEnvironment(), timeout: 1000, maxBuffer: 4096 })).stdout.trim()
    : os.tmpdir();
  const root = await fs.realpath(temporaryRoot);
  const canonicalDirectory = await fs.realpath(directory);
  if (path.dirname(canonicalDirectory) !== root || !/^icu\.[a-zA-Z0-9]{6}$/.test(path.basename(directory)) || path.basename(endpoint) !== 'ipc.sock') throw new Error();
  const rootInfo = await fs.lstat(root);
  const directoryInfo = await fs.lstat(directory);
  const endpointInfo = await fs.lstat(endpoint);
  if (!rootInfo.isDirectory() || rootInfo.uid !== process.getuid() || (rootInfo.mode & 0o777) !== 0o700 ||
      !directoryInfo.isDirectory() || directoryInfo.uid !== process.getuid() || (directoryInfo.mode & 0o777) !== 0o700 ||
      !endpointInfo.isSocket() || endpointInfo.uid !== process.getuid() || (endpointInfo.mode & 0o777) !== 0o600) throw new Error();
  return endpoint;
}

function readiness(child, exit) {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    child.stdio[3].on('data', chunk => {
      if (buffer.length + chunk.length > 4096) {
        child.stdio[3].destroy();
        reject(new Error());
      } else buffer = Buffer.concat([buffer, chunk]);
    });
    child.stdio[3].on('error', () => reject(new Error()));
    child.stdio[3].on('end', () => {
      if (buffer.length === 0) return;
      try {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(buffer);
        const record = JSON.parse(text);
        validateEndpoint(record).then(resolve, reject);
      } catch { reject(new Error()); }
    });
    exit.then(code => {
      if (buffer.length === 0) resolve({ exited: true, code });
    });
  });
}

async function terminateOwnedGroup(child) {
  if (!child?.pid) return;
  const send = signal => { try { process.kill(-child.pid, signal); return true; } catch { return false; } };
  if (!send('SIGTERM')) return;
  const end = Date.now() + 1000;
  while (Date.now() < end) {
    await delay(20);
    if (!send(0)) return;
  }
  send('SIGKILL');
}

export async function runDiagnostic(service, exercise, timeoutMilliseconds = 15_000) {
  let child;
  let timeout;
  try {
    try { await fs.access(service, constants.X_OK); }
    catch { return failure('skipped', 'serviceUnavailable'); }
    child = spawn(service, ['--diagnostic', '--ready-fd', '3'], {
      detached: true, env: safeEnvironment(), stdio: ['ignore', 'ignore', 'ignore', 'pipe'],
    });
    const exit = new Promise(resolve => {
      child.once('error', () => resolve(-1));
      child.once('exit', code => resolve(code));
    });
    const work = (async () => {
      const endpoint = await readiness(child, exit);
      if (endpoint?.exited) return failure(endpoint.code === 2 ? 'skipped' : 'failed', endpoint.code === 2 ? 'serviceUnavailable' : 'serviceExited');
      const checks = await exercise(endpoint);
      return { outcome: 'passed', checks };
    })();
    return await Promise.race([work, new Promise(resolve => {
      timeout = setTimeout(() => resolve(failure('failed', 'timeout')), timeoutMilliseconds);
    })]);
  } catch { return failure('failed', 'diagnosticFailed'); }
  finally {
    clearTimeout(timeout);
    child?.stdio[3]?.destroy();
    await terminateOwnedGroup(child);
  }
}

export async function probe(app, service, { versionReader = readAppVersion, timeoutMilliseconds = 15_000 } = {}) {
  const sockets = new Set();
  let cancelled = false;
  let timer;
  const deadline = performance.now() + timeoutMilliseconds;
  const timedOut = new Promise(resolve => {
    timer = setTimeout(() => { cancelled = true; resolve({ tier: 'A2', ...failure('failed', 'timeout') }); }, timeoutMilliseconds);
  });
  const attempt = async () => {
    const verified = await inspectClient(app, versionReader);
    if (cancelled) return { tier: 'A2', ...failure('failed', 'timeout') };
    if (verified.outcome !== 'verified') return { tier: 'A2', ...verified };
    const result = await runDiagnostic(service, async endpoint => {
      if (cancelled) throw new Error();
      globalThis.nodeRepl = {
        env: { SKY_CUA_SERVICE_NATIVE_PIPE_PATH: endpoint },
        nativePipe: {
          createConnection: candidate => new Promise((resolve, reject) => {
            if (cancelled || candidate !== endpoint) { reject(new Error()); return; }
            const socket = net.createConnection({ path: endpoint });
            sockets.add(socket);
            socket.once('connect', () => resolve(socket));
            socket.once('error', reject);
          }),
        },
      };
      const { MacComputerUseClient } = await import(pathToFileURL(path.join(verified.directory, 'client.js')).href);
      if (cancelled) throw new Error();
      const client = new MacComputerUseClient({ timeoutSeconds: 3, codexMetadata: { diagnostic: 'icu-synthetic-only' } });
      const transport = await client.getTransport(API);
      if (transport.isClosed) throw new Error();
      let denied = false;
      try { await client.getAppPolicy('com.apple.calculator'); }
      catch (error) { denied = error?.code === -10011; }
      if (!denied) throw new Error();
      return { versionNegotiated: true, operationalDenied: true, syntheticMetadata: true, hostIntegration: false, operationsEnabled: false };
    }, Math.max(1, deadline - performance.now()));
    return { tier: 'A2', appVersion: verified.appVersion, appBuild: verified.appBuild, clientHashes: verified.clientHashes, ...result };
  };
  try { return await Promise.race([attempt(), timedOut]); }
  finally {
    cancelled = true;
    clearTimeout(timer);
    for (const socket of sockets) socket.destroy();
    delete globalThis.nodeRepl;
  }
}

async function main() {
  const args = process.argv.slice(2);
  let report;
  if (args.length !== 4 || args[0] !== '--app' || args[2] !== '--service' || !path.isAbsolute(args[1]) || !path.isAbsolute(args[3])) {
    report = { tier: 'A2', ...failure('skipped', 'invalidArguments') };
  } else if (Number(process.versions.node.split('.')[0]) < 20) {
    report = { tier: 'A2', ...failure('skipped', 'nodeUnavailable') };
  } else {
    try { report = await probe(args[1], args[3]); }
    catch { report = { tier: 'A2', ...failure('failed', 'diagnosticFailed') }; }
  }
  process.stdout.write(JSON.stringify(report) + '\n');
  process.exitCode = report.outcome === 'passed' ? 0 : report.outcome === 'skipped' ? 2 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
