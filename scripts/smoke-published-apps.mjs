#!/usr/bin/env node
/** Chrome smoke against real published bundles and an owned P-256 devnet.
 * Only wallet discovery/events are injected; all reads and writes use the node.
 * Playwright is supplied externally, so this adds no application dependency.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const options = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(process.argv[i].startsWith('--') && process.argv[i + 1], 'usage: smoke-published-apps.mjs --config FILE');
  options[process.argv[i].slice(2)] = process.argv[i + 1];
}
assert(options.config, '--config is required');
const config = JSON.parse(await fs.readFile(options.config, 'utf8'));
const runDir = path.resolve(config.run_dir);
assert(runDir.startsWith(path.join(ROOT, 'tmp') + path.sep), 'smoke artifacts must stay under workspace tmp/');
await fs.mkdir(path.join(runDir, 'chrome'), { recursive: true });
process.env.TMPDIR = path.join(runDir, 'chrome');
process.env.TMP = process.env.TMPDIR;
process.env.TEMP = process.env.TMPDIR;
const require = createRequire(import.meta.url);
const playwrightModule = process.env.PLAYWRIGHT_MODULE
  || '/Users/kjaylee/.codex/skills/develop-web-game/node_modules/playwright';
const { chromium } = require(playwrightModule);
let chromeExecutable = config.chrome;
if (!chromeExecutable) {
  try { await fs.access(chromium.executablePath()); }
  catch {
    for (const candidate of ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser']) {
      try { await fs.access(candidate); chromeExecutable = candidate; break; } catch { /* try installed browser */ }
    }
  }
}
const requestLog = [];

function wallet(request) {
  return new Promise((resolve, reject) => {
    const child = spawn(config.wallet_command[0], config.wallet_command.slice(1), {
      cwd: ROOT,
      env: { ...process.env, PYTHONPYCACHEPREFIX: path.join(runDir, 'pycache') },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let out = '', err = '';
    child.stdout.on('data', (data) => { out += data; });
    child.stderr.on('data', (data) => { err += data; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code) reject(new Error(err.trim() || `devnet wallet exited ${code}`));
      else {
        try { resolve(JSON.parse(out)); } catch { reject(new Error(`wallet returned invalid JSON: ${out.slice(0, 300)}`)); }
      }
    });
    child.stdin.end(JSON.stringify(request));
  });
}

async function rpc(method, params = []) {
  const response = await fetch(config.rpc, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const reply = await response.json();
  if (reply.error) throw new Error(`${method}: ${JSON.stringify(reply.error)}`);
  return reply.result;
}

function command(program, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { cwd: ROOT, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '';
    child.stdout.on('data', (data) => { out += data; });
    child.stderr.on('data', (data) => { err += data; });
    child.on('error', reject);
    child.on('close', (code) => code ? reject(new Error(err || `${program} exited ${code}`)) : resolve(out.trim()));
  });
}

async function calldata(signature, args = []) { return command(config.cast || 'cast', ['calldata', signature, ...args.map(String)]); }
async function call(address, signature, args = []) {
  return rpc('eth_call', [{ from: config.from, to: address, data: await calldata(signature, args) }, 'latest']);
}
async function send(address, signature, args = [], value = '0x0') {
  return wallet({ method: 'eth_sendTransaction', params: [{ from: config.from, to: address,
    data: signature ? await calldata(signature, args) : '0x', value }] });
}
const wordAddress = (hex) => '0x' + hex.slice(26, 66);
function decimalNative(raw, decimals = 18) {
  const amount = BigInt(raw);
  const power = 10n ** BigInt(decimals);
  const fraction = (amount % power).toString().padStart(decimals, '0').replace(/0+$/, '');
  return (amount / power).toString() + (fraction ? '.' + fraction : '');
}

const mime = { '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.js': 'text/javascript', '.css': 'text/css' };
const bundleRoot = path.resolve(config.bundles);
const server = http.createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const filename = path.resolve(bundleRoot, '.' + (pathname.endsWith('/') ? pathname + 'index.html' : pathname));
    assert(filename.startsWith(bundleRoot + path.sep), 'invalid bundle path');
    const bytes = await fs.readFile(filename);
    response.writeHead(200, { 'content-type': mime[path.extname(filename)] || 'application/octet-stream' });
    response.end(bytes);
  } catch {
    response.writeHead(404); response.end('not found');
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}`;
const reports = [];
let browser;
let nodeStatus;

function contract(manifest, label) {
  const found = manifest.contracts.find((item) => item.label.toLowerCase().includes(label.toLowerCase()));
  assert(found, `no ${label} contract in published manifest`);
  return found.address;
}

async function planFor(slug, manifest, address, decimals) {
  const native = (raw) => decimalNative(raw, decimals);
  switch (slug) {
    case 'token': return { action: 'transfer', values: [config.other, '1000000000000000'] };
    case 'nft': return { action: 'createEdition', values: ['Owned devnet smoke', '10', '2', native(10n ** 16n), '0'] };
    case 'market': {
      const nft = contract(config.manifests.nft, 'OnchainNFT');
      await send(nft, 'mint(address,uint8,uint8,uint8,uint8)', [config.from, 0, 0, 0, 0]);
      await send(nft, 'approve(address,uint256)', [address, 1]);
      return { action: 'list', values: [nft, '1', native(10n ** 16n)] };
    }
    case 'amm': {
      const a = contract(config.manifests.token, 'token');
      let b = wordAddress(await call(contract(config.manifests.rewards, 'RewardDistributor'), 'stakingToken()'));
      if (a.toLowerCase() === b.toLowerCase()) {
        b = wordAddress(await call(contract(config.manifests.rewards, 'RewardDistributor'), 'rewardToken()'));
      }
      assert.notEqual(a.toLowerCase(), b.toLowerCase(), 'AMM smoke needs two distinct real tokens');
      return { action: 'createPair', values: [a, b] };
    }
    case 'launchpad': {
      const quote = wordAddress(await call(address, 'quote()'));
      await send(quote, 'approve(address,uint256)', [address, '100000000000000000']);
      return { action: 'buy', values: ['100000000000000000', '0'] };
    }
    case 'rewards': {
      const staking = wordAddress(await call(address, 'stakingToken()'));
      await send(staking, 'approve(address,uint256)', [address, '1000000000000000']);
      return { action: 'stake', values: ['1000000000000000'] };
    }
    case 'lock': return { action: 'claim', values: [] };
    case 'multisig': return { action: 'execute', values: [config.other, '0', '0x', '0', ''],
      reject: true, limitation: 'execute requires collected secp256k1 signatures; the P-256 wallet cannot manufacture them' };
    case 'escrow': return { action: 'createDeal', values: [config.other, '1'], value: native(10n ** 16n) };
    case 'subscription': return { action: 'subscribe', values: [], value: native(10n ** 16n) };
    case 'dao': return { action: 'propose', values: ['0x' + '11'.repeat(32)] };
    case 'crowdfund': return { action: 'contribute', values: [], value: native(10n ** 16n) };
    case 'airdrop': {
      const amount = BigInt(config.airdrop_amount || '1000000000000000000');
      await send(address, null, [], '0x' + amount.toString(16));
      return { action: 'claim', values: [native(amount), ''] };
    }
    case 'raffle': return { action: 'enter', values: [], value: native(BigInt(await call(address, 'ticketPrice()'))) };
    case 'names': {
      const amount = BigInt(await call(address, 'dropAmount()'));
      await send(address, null, [], '0x' + amount.toString(16));
      return { action: 'claim', values: [] };
    }
    case 'invoice': return { action: 'issue', values: [native(10n ** 16n), '3600', 'owned-devnet smoke'] };
    case 'vending': return { action: 'order', values: ['0x' + '22'.repeat(32)], value: native(BigInt(await call(address, 'price()'))) };
    default: throw new Error(`no frontend smoke plan for ${slug}`);
  }
}

function viewValues(def) {
  return def.args.map((arg) => {
    if (arg.t === 'address') return config.from;
    if (arg.t === 'bytes') return '0x';
    if (arg.t === 'bytes32') return '0x' + '00'.repeat(32);
    if (arg.n.toLowerCase().includes('nonce')) return '0';
    if (arg.t === 'uint') return '1';
    if (arg.t === 'token') return '1000000000000000';
    return '0';
  });
}

async function runForm(page, section, def, values, value, reject = false) {
  const forms = page.locator(`#${section} form`);
  const defs = await page.evaluate((which) => APP[which], section === 'views' ? 'views' : 'actions');
  const index = defs.findIndex((item) => item.f === def.f);
  assert(index >= 0, `missing ${def.f} form`);
  const form = forms.nth(index);
  for (let i = 0; i < values.length; ++i) await form.locator('input').nth(i).fill(String(values[i]));
  if (value !== undefined) await form.locator('input').nth(values.length).fill(value);
  await form.locator('button[type=submit]').click();
  await page.waitForFunction(({ which, position }) => {
    const form = document.querySelectorAll(`#${which} form`)[position];
    const out = form.querySelector('p');
    return out && out.textContent && out.textContent !== '…';
  }, { which: section, position: index }, { timeout: 90_000 });
  const outcome = await form.locator('p').last().evaluate((out) => ({ text: out.textContent, error: out.classList.contains('err') }));
  assert.equal(outcome.error, reject, `${def.f}: ${outcome.text}`);
  if (section === 'actions' && !reject) assert.match(outcome.text, /0x[0-9a-fA-F]{64}/, `${def.f} did not return a real tx hash`);
  return outcome;
}

try {
  assert.equal(BigInt(await rpc('eth_chainId')), 7777n, 'smoke refuses any network other than owned devnet 7777');
  nodeStatus = await rpc('aether_status');
  browser = await chromium.launch({ headless: true, ...(chromeExecutable ? { executablePath: chromeExecutable } : {}) });
  const slugs = config.slugs || Object.keys(config.manifests).sort();
  for (const slug of slugs) {
    const errors = [];
    const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
    const start = requestLog.length;
    const report = { app: slug, reads: 0, successful_transactions: 0, wallet_events: false, passed: false };
    reports.push(report);
    page.on('pageerror', (error) => errors.push(error.message));
    await page.exposeBinding('__ownedWalletRequest', async (_, req) => {
      const entry = { app: slug, ...req };
      requestLog.push(entry);
      try {
        const result = await wallet(req);
        entry.result = result;
        return result;
      } catch (error) {
        entry.error = error.message;
        throw error;
      }
    });
    await page.addInitScript(({ from, chainId }) => {
      const listeners = {};
      const provider = {
        supportedMethods: ['eth_accounts', 'eth_requestAccounts', 'eth_chainId', 'eth_call', 'eth_getLogs',
          'eth_blockNumber', 'eth_getCode', 'eth_getTransactionReceipt', 'eth_sendTransaction', 'wallet_switchEthereumChain'],
        accounts: [from], chainId,
        async request(req) {
          if (req.method === 'eth_accounts' || req.method === 'eth_requestAccounts') return [...this.accounts];
          if (req.method === 'eth_chainId') return this.chainId;
          const result = await window.__ownedWalletRequest(req);
          if (req.method === 'wallet_switchEthereumChain') {
            this.chainId = req.params[0].chainId;
            this.emit('chainChanged', this.chainId);
          }
          return result;
        },
        on(event, fn) { (listeners[event] ||= new Set()).add(fn); },
        removeListener(event, fn) { listeners[event]?.delete(fn); },
        emit(event, value) { for (const fn of listeners[event] || []) fn(value); },
      };
      window.aether = provider;
      window.__smokeProvider = provider;
      const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
        detail: { info: { uuid: 'owned-p256-devnet', name: 'Owned P-256 Devnet Wallet', rdns: 'devnet.toolbox', icon: '' }, provider },
      }));
      window.addEventListener('eip6963:requestProvider', announce);
    }, { from: config.from, chainId: '0x1e61' });
    try {
      await page.goto(`${baseUrl}/${slug}/`, { waitUntil: 'networkidle' });
      const manifest = config.manifests[slug];
      const app = await page.evaluate(() => APP);
      await page.waitForFunction(() => /^0x[0-9a-fA-F]{40}$/.test(document.getElementById('contract').value));
      const address = await page.locator('#contract').inputValue();
      assert(manifest.contracts.some((item) => item.address.toLowerCase() === address.toLowerCase()), 'contract was not read from the runtime manifest');
      assert.notEqual(address.toLowerCase(), '0x' + '00'.repeat(20), 'zero contract placeholder persisted');
      await page.locator('#wallets button').first().click();
      await page.waitForFunction((from) => document.getElementById('acct').textContent.toLowerCase().includes(from.toLowerCase()), config.from);
      await page.waitForFunction(() => document.getElementById('chain').classList.contains('ok'));
      const decimals = manifest['x-toolbox-native-currency']?.decimals ?? 18;
      const plan = await planFor(slug, manifest, address, decimals);
      const action = app.actions.find((item) => item.f === plan.action);
      assert(action, `missing planned action ${plan.action}`);

      // Wrong-chain and disconnected events must block transactions before the wallet is called.
      await page.evaluate(() => { window.__smokeProvider.chainId = '0x1'; window.__smokeProvider.emit('chainChanged', '0x1'); });
      await page.waitForFunction(() => !document.getElementById('chain').classList.contains('ok'));
      const beforeWrongChain = requestLog.filter((entry) => entry.method === 'eth_sendTransaction').length;
      await runForm(page, 'actions', action, plan.values, plan.value, true);
      assert.equal(requestLog.filter((entry) => entry.method === 'eth_sendTransaction').length, beforeWrongChain, 'wrong-chain action reached the wallet');
      await page.evaluate(() => { window.__smokeProvider.chainId = '0x1e61'; window.__smokeProvider.emit('chainChanged', '0x1e61'); });
      await page.waitForFunction(() => document.getElementById('chain').classList.contains('ok'));
      await page.evaluate(() => { window.__smokeProvider.accounts = []; window.__smokeProvider.emit('accountsChanged', []); });
      const beforeDisconnected = requestLog.filter((entry) => entry.method === 'eth_sendTransaction').length;
      await runForm(page, 'actions', action, plan.values, plan.value, true);
      assert.equal(requestLog.filter((entry) => entry.method === 'eth_sendTransaction').length, beforeDisconnected, 'disconnected action reached the wallet');
      await page.evaluate((from) => { window.__smokeProvider.accounts = [from]; window.__smokeProvider.emit('accountsChanged', [from]); }, config.from);
      await page.waitForFunction((from) => document.getElementById('acct').textContent.toLowerCase().includes(from.toLowerCase()), config.from);
      report.wallet_events = true;

      const result = await runForm(page, 'actions', action, plan.values, plan.value);
      const txHash = result.text.match(/0x[0-9a-fA-F]{64}/)[0];
      const finalized = await rpc('aether_getReceipt', [txHash]);
      assert.equal(finalized?.receipt?.success, !plan.reject, `${plan.action} finalized with unexpected success status`);
      if (plan.reject) report.limitation = plan.limitation;
      else report.transaction = txHash;
      for (const def of app.views) await runForm(page, 'views', def, viewValues(def));
      await page.locator('#load-logs').click();
      await page.waitForFunction(() => document.getElementById('logs').textContent !== '…');
      assert.equal(await page.locator('#logs .err').count(), 0, 'real event log read failed');
      const entries = requestLog.slice(start);
      report.reads = entries.filter((entry) => entry.method === 'eth_call' && !entry.error).length;
      report.successful_transactions = entries.filter((entry) => entry.method === 'eth_sendTransaction' && !entry.error).length - (plan.reject ? 1 : 0);
      assert(report.reads > 0, 'app made no successful onchain eth_call read');
      assert(entries.some((entry) => entry.method === 'eth_getLogs' && !entry.error), 'app made no successful onchain log read');
      for (const entry of entries.filter((item) => item.method === 'eth_sendTransaction')) {
        assert.equal(entry.params[0].from.toLowerCase(), config.from.toLowerCase(), 'frontend changed sender');
        assert.deepEqual(Object.keys(entry.params[0]).filter((key) => !['from', 'to', 'data', 'value', 'gas'].includes(key)), [],
          'frontend tried to specify Ethereum fee or signing assumptions');
      }
      assert.deepEqual(errors, [], 'uncaught frontend errors');
      await page.screenshot({ path: path.join(runDir, `${slug}.png`), fullPage: true });
      report.passed = true;
      console.log(`ok ${slug}: ${report.reads} real reads, ${report.successful_transactions} wallet transactions${report.limitation ? '; signature limitation checked' : ''}`);
    } catch (error) {
      report.error = error.message;
      report.console_errors = errors;
      await page.screenshot({ path: path.join(runDir, `${slug}-failure.png`), fullPage: true }).catch(() => {});
      console.error(`FAIL ${slug}: ${error.message}`);
    } finally { await page.close(); }
  }
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
  await fs.writeFile(path.join(runDir, 'frontend-smoke.json'), JSON.stringify({
    scope: config.scope || 'owned-devnet; P-256 CLI wallet; registry/names are pending-interface fixtures',
    node_status: nodeStatus,
    chrome_executable: chromeExecutable || chromium.executablePath(),
    b5_state_quote_advertised: !!nodeStatus?.base_fee?.state,
    reports, requests: requestLog,
  }, null, 2) + '\n');
}
assert(reports.length && reports.every((report) => report.passed), 'one or more frontend smokes failed; see frontend-smoke.json');
