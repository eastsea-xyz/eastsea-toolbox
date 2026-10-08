#!/usr/bin/env python3
"""Sanity-check the static front-ends under apps/.

For every examples/<slug>/ directory there must be an apps/<slug>/index.html
whose inline <script> blocks are syntactically valid JavaScript (node --check)
and whose manifest and EIP-1193 behavior passes an offline regression check.
No wallet key, network connection or transaction is needed. Exits non-zero on any failure.
Used by CI (.github/workflows/ci.yml) and safe to run locally.
"""

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

SMOKE_JS = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const template = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const address = (n) => '0x' + n.repeat(40);

async function boot(search = '', overrides = {}) {
  const nodes = new Map(), allNodes = [], windowListeners = new Map(), walletListeners = new Map();
  function node(tag = 'div') {
    const el = { tagName: tag, children: [], value: '', disabled: false, attrs: {}, className: '',
      appendChild(child) { this.children.push(child); return child; },
      setAttribute(name, value) { this.attrs[name] = value; },
      classList: { values: new Set(), add(v) { this.values.add(v); }, toggle(v, on) { on ? this.values.add(v) : this.values.delete(v); }, contains(v) { return this.values.has(v); } },
      set textContent(value) { this.text = String(value); this.children = []; }, get textContent() { return this.text || ''; },
    };
    allNodes.push(el); return el;
  }
  const document = { getElementById(id) { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); },
    createElement: node, createTextNode(text) { const el = node('text'); el.textContent = text; return el; },
    querySelectorAll() { return allNodes.filter((el) => 'data-native-unit' in el.attrs); } };
  const requests = [];
  const wallet = { isAether: true, chain: '0x7a69', accounts: [address('a')],
    async request(req) {
      requests.push(req);
      if (req.method === 'eth_chainId') return this.chain;
      if (req.method === 'eth_requestAccounts' || req.method === 'eth_accounts') return this.accounts;
      if (req.method === 'eth_call' && this.personal) {
        const p = this.personal, data = req.params[0].data;
        const word = (value) => BigInt(value).toString(16).padStart(64, '0');
        if (data === '0x53702e15') { const text = Buffer.from(p.mode); return '0x' + word(32) + word(text.length) + text.toString('hex').padEnd(64, '0'); }
        if (data === '0x5d6309b0') return '0x' + word(p.owner);
        if (data === '0x98a760c1') return '0x' + word(p.authority);
        if (data === '0x7c38dfd9') return '0x' + word(p.native_cap);
        if (data === '0xdcdc520c') return '0x' + word(p.token_cap);
        if (data.startsWith('0xcc809606')) return '0x' + word(p.registered ? 1 : 0);
        if (data.startsWith('0x3908af36')) return '0x' + word(p.allowed.has('0x' + data.slice(-40)) ? 1 : 0);
        throw new Error('Unexpected personal policy call');
      }
      if (req.method === 'eth_call') return '0x' + '0'.repeat(64);
      if (req.method === 'eth_sendTransaction') return '0x' + 'b'.repeat(64);
      if (req.method === 'eth_blockNumber') return '0x1';
      if (req.method === 'eth_getLogs') return [];
      throw Object.assign(new Error('Unsupported wallet method: ' + req.method), { code: 4200 });
    },
    on(name, fn) { if (!walletListeners.has(name)) walletListeners.set(name, new Set()); walletListeners.get(name).add(fn); },
    removeListener(name, fn) { walletListeners.get(name)?.delete(fn); },
    emit(name, value) { [...(walletListeners.get(name) || [])].forEach((fn) => fn(value)); },
  };
  const window = { aether: wallet, addEventListener(name, fn) { if (!windowListeners.has(name)) windowListeners.set(name, []); windowListeners.get(name).push(fn); },
    dispatchEvent(event) { (windowListeners.get(event.type) || []).forEach((fn) => fn(event)); } };
  window.addEventListener('eip6963:requestProvider', () => window.dispatchEvent({ type: 'eip6963:announceProvider', detail: { info: { uuid: 'test-wallet', name: '<b>Wallet</b>' }, provider: wallet } }));
  const manifest = { ...template, 'x-toolbox-chain-id': '0x7a69', 'x-toolbox-native-currency': { symbol: 'TEST', decimals: 6 },
    contracts: template.contracts.map((c, i) => ({ ...c, address: address(String(i + 1)) })), ...overrides };
  const context = vm.createContext({ document, window, location: { search }, URLSearchParams, TextEncoder, TextDecoder, Uint8Array,
    Event: class { constructor(type) { this.type = type; } }, setTimeout() {},
    async fetch(url) { assert.equal(url, './manifest.json'); return { ok: true, async json() { return manifest; } }; } });
  const run = (code) => vm.runInContext(code, context);
  run(source);
  await run('manifestReady');
  return { document, wallet, requests, manifest, run };
}

(async () => {
  const page = await boot();
  const { run, document, wallet, requests, manifest } = page;
  const app = run('APP');
  const primary = manifest.contracts.find((c) => c.label === app.contract);
  assert.ok(primary, 'the frontend primary contract must exist in the source manifest');
  assert.equal(document.getElementById('contract').value, primary.address);
  assert.equal(run('expectedChainId'), '0x7a69');
  assert.equal(document.getElementById('wallets').children.length, 1, 'EIP-6963 discovers the bridge');
  await run('connect(discovered[0])');
  assert.equal(run('chainOk'), true);
  assert.equal(BigInt('0x' + run("toAmount('0.1', 'test')")), 100000n, 'manifest currency precision is used');
  assert.throws(() => run("toAmount('0.0000001', 'test')"), 'excess precision must fail instead of truncating');
  assert.throws(() => run("tailOfBytes('0x1')"), 'odd bytes must fail instead of sending malformed calldata');
  await run("sendTx(contractAddr(), '0x12345678', toAmount('0', 'test'))");
  const sent = requests.filter((r) => r.method === 'eth_sendTransaction');
  assert.equal(sent[0].params[0].value, '0x0', 'zero value is a valid hex quantity');
  assert.deepEqual(Object.keys(sent[0].params[0]).sort(), ['data', 'from', 'to', 'value'], 'signing and fee fields belong to the wallet');
  wallet.chain = '0x7a6a'; wallet.emit('chainChanged', wallet.chain);
  await assert.rejects(run("sendTx(contractAddr(), '0x12345678')"));
  assert.equal(requests.filter((r) => r.method === 'eth_sendTransaction').length, 1, 'wrong chain must block transaction requests');
  assert.equal(document.getElementById('fixchain').classList.contains('hidden'), true, 'the EastSea bridge cannot switch chains');
  wallet.chain = '0x7a69'; wallet.accounts = [address('c')]; wallet.emit('accountsChanged', wallet.accounts);
  await run("sendTx(contractAddr(), '0x12345678')");
  assert.equal(requests.filter((r) => r.method === 'eth_sendTransaction')[1].params[0].from, address('c'));
  await document.getElementById('load-logs').onclick();
  assert.equal(requests.find((r) => r.method === 'eth_getLogs').params[0].fromBlock, '0x0', 'young devnets need a nonnegative log range');
  wallet.emit('disconnect', { code: 4900 });
  await assert.rejects(run("sendTx(contractAddr(), '0x12345678')"), 'disconnect must require reconnecting');
  await run('connect(discovered[0])');
  assert.equal(run('account'), address('c'));
  assert.equal(requests.some((r) => /sign|gasPrice|maxFee|sendRawTransaction/i.test(r.method)), false);
  const manual = await boot('?contract=' + address('d'));
  assert.equal(manual.document.getElementById('contract').value, address('d'), 'query address overrides the manifest');
  const zero = await boot('', { contracts: template.contracts });
  assert.ok(zero.run('manifestError'), 'template placeholders must not become transaction targets');
  const invalid = await boot('', { 'x-toolbox-chain-id': undefined });
  assert.ok(invalid.run('manifestError'), 'missing chain configuration must fail closed');
  const policy = { schema: 'eastsea.personal-test/1', owner: address('a'), authority: address('f'),
    native_cap: '10000000000000000', token_cap: '5000000000000000000', initial_allowlist: [address('a')], protocol_fee_bps: 0 };
  const personalConfig = { 'x-toolbox-mode': 'personal-test', 'x-toolbox-network': 'mainnet',
    'x-toolbox-personal-policy': policy, 'x-toolbox-local-only': true, noindex: true };
  const personal = await boot('', personalConfig);
  assert.equal(personal.document.getElementById('contract').readOnly, true);
  await personal.run('connect(discovered[0])');
  personal.wallet.personal = { ...policy, mode: 'personal-test', registered: true, allowed: new Set([policy.owner]) };
  await personal.run("sendTx(contractAddr(), '0x12345678')");
  const sends = () => personal.requests.filter((r) => r.method === 'eth_sendTransaction').length;
  assert.equal(sends(), 1, 'own verified personal copy can be used');
  for (const [field, bad] of [['mode', 'testnet'], ['owner', address('b')], ['authority', address('b')], ['native_cap', '1'], ['token_cap', '1'], ['registered', false]]) {
    const saved = personal.wallet.personal[field]; personal.wallet.personal[field] = bad;
    await assert.rejects(personal.run("sendTx(contractAddr(), '0x12345678')"), field + ' mismatch must block submission');
    personal.wallet.personal[field] = saved;
  }
  personal.wallet.accounts = [address('c')];
  await assert.rejects(personal.run("sendTx(contractAddr(), '0x12345678')"), 'unlisted second account cannot send');
  assert.equal(sends(), 1, 'personal failures do not reach wallet submission');
  personal.wallet.personal.allowed.add(address('c'));
  await personal.run("sendTx(contractAddr(), '0x12345678')");
  assert.equal(sends(), 2, 'an explicitly added own account may use the same instance');
  const override = await boot('?contract=' + address('d'), personalConfig);
  assert.ok(override.run('manifestError'), 'personal query override cannot substitute a public target');
  const unsafeMainnet = await boot('', { 'x-toolbox-network': 'mainnet' });
  assert.ok(unsafeMainnet.run('manifestError'), 'mainnet bundle requires personal-test mode');
  const invalidAuthority = await boot('', { ...personalConfig, 'x-toolbox-personal-policy': { ...policy, authority: address('0') } });
  assert.ok(invalidAuthority.run('manifestError'), 'personal authority must be configured');
  personal.document.getElementById('contract').value = address('d');
  await assert.rejects(personal.run("sendTx(contractAddr(), '0x12345678')"), 'manual edits cannot escape the declared graph');
  assert.equal(sends(), 2);
})().catch((err) => { console.error(err); process.exitCode = 1; });
"""


def main() -> int:
    slugs = sorted(p.name for p in (ROOT / "examples").iterdir() if p.is_dir())
    if not slugs:
        print("error: no examples/ directories found", file=sys.stderr)
        return 2
    node = shutil.which("node")
    if not node:
        print("error: node is required to check frontend JavaScript", file=sys.stderr)
        return 2

    tmp_root = ROOT / "tmp"
    tmp_root.mkdir(exist_ok=True)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="check-apps-", dir=tmp_root) as task_tmp:
        work = pathlib.Path(task_tmp)
        harness = work / "smoke.cjs"
        harness.write_text(SMOKE_JS, encoding="utf-8")
        for slug in slugs:
            app = ROOT / "apps" / slug / "index.html"
            if not app.exists():
                print(f"FAIL {slug}: missing apps/{slug}/index.html")
                failures += 1
                continue
            html = app.read_text(encoding="utf-8")
            scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
            if not scripts:
                print(f"FAIL {slug}: no <script> block")
                failures += 1
                continue
            path = work / f"{slug}.js"
            path.write_text("\n".join(scripts), encoding="utf-8")
            ok = True
            checks = ([node, "--check", str(path)], [node, str(harness), str(path), str(ROOT / "examples" / slug / "manifest.json")])
            for command in checks:
                result = subprocess.run(command, capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"FAIL {slug}: frontend check failed:\n{result.stderr[:1000]}")
                    ok = False
                    break
            if ok:
                print(f"ok   {slug}")
            else:
                failures += 1

    total = len(slugs)
    print(f"\n{total - failures}/{total} front-ends valid")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
