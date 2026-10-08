#!/usr/bin/env python3
"""Generate apps/<slug>/index.html for all 17 toolbox examples.

One static, dependency-free EIP-1193 front-end per example:
wallet discovery via EIP-6963 with a window.aether / window.ethereum
fallback, chainId and deployed addresses from ./manifest.json, hand-rolled ABI
encoding for the small type surface the examples use, eth_call views,
eth_sendTransaction actions and eth_getLogs event tails.

Selectors and event topics are precomputed constants -- no keccak at
runtime, no bundled libraries. Run from the repo root: python3 scripts/gen-apps.py
"""

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------
# shared inline CSS
# --------------------------------------------------------------------------
CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#08131d;color:#d7e7ee;font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif}
main{max-width:760px;margin:0 auto;padding:0 16px 64px}
header{max-width:760px;margin:0 auto;padding:36px 16px 8px}
.brand{color:#4dd6c1;font-size:12px;letter-spacing:.14em;text-transform:uppercase}
h1{margin:.15em 0 .1em;font-size:26px}
h2{margin:0 0 12px;font-size:15px;color:#9fc4d4;font-weight:600;letter-spacing:.04em}
.sub{margin:0 0 4px;color:#8aa7b6}
.card{background:#0d1f2e;border:1px solid #1b3648;border-radius:12px;padding:18px;margin:16px 0}
button{background:#123243;color:#d7f3ec;border:1px solid #2b5a70;border-radius:8px;padding:8px 14px;font:inherit;cursor:pointer}
button:hover{background:#174060}
button:disabled{opacity:.45;cursor:default}
input,textarea{width:100%;background:#081722;border:1px solid #24455a;border-radius:8px;color:#d7e7ee;padding:8px 10px;font:inherit;margin:3px 0 10px}
textarea{min-height:56px;resize:vertical}
.row{display:flex;gap:8px;flex-wrap:wrap}
.row>*{flex:1;min-width:140px}
.hint{color:#6d8aa0;font-size:12.5px;margin:2px 0 10px}
.ok{color:#5fe6c2}.warn{color:#ffb86b}.err{color:#ff7b72}.dim{color:#6d8aa0}
.txhash{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;word-break:break-all}
.wallets{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.wallets button{display:flex;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:#4dd6c1;display:inline-block}
.log{border-left:2px solid #1b3648;padding:4px 0 4px 10px;margin:8px 0;font-size:13px}
.log b{color:#4dd6c1}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:12.5px;word-break:break-all}
footer{max-width:760px;margin:0 auto;padding:0 16px 48px;color:#4d6a7d;font-size:12.5px}
a{color:#4dd6c1}
.actions form{border-top:1px solid #14293a;padding-top:12px;margin-top:12px}
.actions form:first-child{border-top:0;padding-top:0}
label{display:block;font-size:13px;color:#9fc4d4;margin-top:4px}
.hidden{display:none}
"""

# --------------------------------------------------------------------------
# shared inline JS (uses the APP object injected per example)
# --------------------------------------------------------------------------
JS = r"""
'use strict';
const query = new URLSearchParams(location.search);
const addrInput = document.getElementById('contract');
const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const isDeployedAddress = (a) => addressPattern.test(a) && !/^0x0{40}$/i.test(a);
let manifestError = null, expectedChainId = null, nativeCurrency = null, personalPolicy = null;
function chainId(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new Error('잘못된 chain ID');
  if (!/^(0x[0-9a-fA-F]+|[0-9]+)$/.test(String(value))) throw new Error('잘못된 chain ID');
  const id = BigInt(value);
  if (id <= 0n) throw new Error('잘못된 chain ID');
  return '0x' + id.toString(16);
}

async function loadManifest() {
  try {
    const response = await fetch('./manifest.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('manifest.json HTTP ' + response.status);
    const config = await response.json();
    expectedChainId = chainId(config['x-toolbox-chain-id'] ?? config.chain_id ?? config.chainId ?? config.network?.chain_id);
    const currency = config['x-toolbox-native-currency'];
    if (!currency || typeof currency.symbol !== 'string' || !currency.symbol.trim() || !Number.isInteger(currency.decimals) || currency.decimals < 0 || currency.decimals > 77) throw new Error('manifest의 x-toolbox-native-currency가 필요합니다');
    const primary = (config.contracts || []).find((c) => c.label === (config['x-toolbox-primary-contract'] || APP.contract));
    const override = query.get('contract');
    if (config['x-toolbox-network'] === 'mainnet' && config['x-toolbox-mode'] !== 'personal-test') throw new Error('Mainnet requires a personal test instance.');
    if (config['x-toolbox-mode'] === 'personal-test') {
      const policy = config['x-toolbox-personal-policy'];
      if (!policy || policy.schema !== 'eastsea.personal-test/1' || !isDeployedAddress(policy.owner) || !isDeployedAddress(policy.authority)
          || !/^[1-9][0-9]*$/.test(String(policy.native_cap)) || !/^[1-9][0-9]*$/.test(String(policy.token_cap))
          || BigInt(policy.native_cap) >= 2n ** 256n || BigInt(policy.token_cap) >= 2n ** 256n
          || policy.protocol_fee_bps !== 0 || config['x-toolbox-local-only'] !== true || config.noindex !== true) throw new Error('Invalid personal test policy.');
      if (override && override.toLowerCase() !== primary?.address?.toLowerCase()) throw new Error('Personal test addresses are fixed to your instance.');
      personalPolicy = { ...policy, contracts: (config.contracts || []).map((c) => c.address.toLowerCase()),
        readOnly: (config['x-toolbox-read-only-contracts'] || []).map((a) => a.toLowerCase()) };
      addrInput.readOnly = true;
    }
    if (!isDeployedAddress(override || primary?.address)) throw new Error('manifest의 ' + APP.contract + ' 배포 주소가 필요합니다 (?contract=0x…로 재정의 가능)');
    addrInput.value = override || primary.address;
    nativeCurrency = { symbol: currency.symbol.trim(), decimals: currency.decimals };
    note('deployment', (personalPolicy ? 'Personal test instance · ' : override ? '주소 재정의: ' : '배포 주소: ') + (primary?.label || APP.contract) + ' · chain ' + expectedChainId, 'ok');
    document.querySelectorAll('[data-native-unit]').forEach((el) => { el.textContent = nativeCurrency.symbol; });
    return config;
  } catch (err) {
    manifestError = new Error('배포 설정을 읽지 못했습니다: ' + errorText(err));
    note('deployment', manifestError.message, 'err');
    return null;
  }
}
const manifestReady = loadManifest();

// ---------------------------------------------------------------- wallet discovery (EIP-6963 + legacy fallbacks)
const discovered = [];
let provider = null, account = null, chainOk = false;
let detachProvider = () => {};
window.addEventListener('eip6963:announceProvider', (e) => {
  const d = e.detail;
  if (!d?.provider || typeof d.provider.request !== 'function' || !d.info?.uuid) return;
  if (!discovered.some((known) => known.info.uuid === d.info.uuid || known.provider === d.provider)) { discovered.push(d); renderWallets(); }
});
window.dispatchEvent(new Event('eip6963:requestProvider'));
function discoverInjected() {
  [window.aether, window.ethereum].forEach((p, i) => {
    if (p && typeof p.request === 'function' && !discovered.some((d) => d.provider === p)) discovered.push({ info: { uuid: 'injected-' + i, name: i === 0 ? 'EastSea wallet' : 'Injected wallet' }, provider: p });
  });
  renderWallets();
}
setTimeout(discoverInjected, 150);
window.addEventListener('aether#initialized', discoverInjected);
window.addEventListener('ethereum#initialized', discoverInjected);

function renderWallets() {
  const el = document.getElementById('wallets');
  if (!discovered.length) { el.textContent = '지갑을 찾지 못했습니다 — EastSea 지갑(aether)이 설치된 브라우저에서 여세요.'; return; }
  el.textContent = '';
  discovered.forEach((d) => {
    const b = document.createElement('button');
    const dot = document.createElement('span'); dot.className = 'dot'; b.appendChild(dot);
    b.appendChild(document.createTextNode(d.info.name || 'Wallet'));
    b.onclick = () => connect(d);
    el.appendChild(b);
  });
}

async function connect(d) {
  detachProvider();
  provider = d.provider;
  account = null; chainOk = false;
  const selected = provider;
  const onAccounts = (accounts) => { if (selected !== provider) return; setAccount(accounts); chainOk = false; checkChain(); };
  const onChain = () => { if (selected !== provider) return; chainOk = false; checkChain(); };
  const onDisconnect = (err) => {
    if (selected !== provider) return;
    detachProvider(); provider = null;
    account = null; chainOk = false;
    note('acct', '지갑 연결이 끊겼습니다. 다시 연결하세요. ' + errorText(err), 'warn');
    note('chain', '', 'dim');
    document.getElementById('fixchain').classList.add('hidden');
  };
  if (typeof selected.on === 'function') {
    selected.on('accountsChanged', onAccounts);
    selected.on('chainChanged', onChain);
    selected.on('disconnect', onDisconnect);
  }
  detachProvider = () => {
    if (typeof selected.removeListener !== 'function') return;
    selected.removeListener('accountsChanged', onAccounts);
    selected.removeListener('chainChanged', onChain);
    selected.removeListener('disconnect', onDisconnect);
  };
  try {
    const accts = await selected.request({ method: 'eth_requestAccounts' });
    if (selected !== provider) return;
    setAccount(accts);
    if (!account) throw new Error('지갑에서 공유한 계정이 없습니다');
    await checkChain();
  } catch (err) { if (selected === provider) { account = null; chainOk = false; note('acct', '연결 실패: ' + errorText(err), 'err'); } }
}

function setAccount(accounts) {
  account = Array.isArray(accounts) && addressPattern.test(accounts[0]) ? accounts[0] : null;
  note('acct', account ? '연결됨: ' + account : '공유된 계정이 없습니다. 지갑을 다시 연결하세요.', account ? 'ok mono' : 'warn');
}

async function checkChain() {
  const el = document.getElementById('chain'); const fix = document.getElementById('fixchain');
  chainOk = false; fix.classList.add('hidden');
  const selected = provider;
  try {
    await manifestReady;
    if (manifestError) throw manifestError;
    if (!selected) throw new Error('먼저 지갑을 연결하세요');
    const id = chainId(await selected.request({ method: 'eth_chainId' }));
    if (selected !== provider) return false;
    chainOk = (id === expectedChainId);
    el.className = chainOk ? 'ok' : 'warn';
    el.textContent = chainOk ? '체인: ' + id : '배포 체인과 다릅니다 (현재 ' + id + ', 필요 ' + expectedChainId + '). 지갑의 네트워크 설정을 변경하세요.';
    const supported = selected.supportedMethods;
    const canSwitch = !selected.isAether && (!Array.isArray(supported) || supported.includes('wallet_switchEthereumChain'));
    fix.classList.toggle('hidden', chainOk || !canSwitch);
    return chainOk;
  } catch (err) { if (selected === provider) { el.textContent = '체인 조회 실패: ' + errorText(err); el.className = 'err'; } return false; }
}

document.getElementById('fixchain').onclick = async () => {
  try {
    await manifestReady;
    if (manifestError) throw manifestError;
    if (!provider) throw new Error('먼저 지갑을 연결하세요');
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: expectedChainId }] });
    await checkChain();
  } catch (err) { note('chain', '전환 실패: ' + errorText(err) + ' 지갑에서 네트워크를 직접 변경하세요.', 'err'); }
};

function note(id, msg, cls) { const el = document.getElementById(id); el.textContent = msg; el.className = cls || 'dim'; }
function errorText(err) {
  const messages = { 4001: '사용자가 요청을 취소했습니다.', 4100: '지갑에 연결 권한을 허용하세요.', 4200: '이 지갑은 요청한 기능을 지원하지 않습니다.', 4900: '지갑이 네트워크에 연결되어 있지 않습니다.', 4901: '지갑이 배포 체인에 연결되어 있지 않습니다.', '-32002': '지갑의 기존 요청을 먼저 확인하세요.' };
  const detail = err?.message || (err == null ? '' : String(err));
  return messages[err?.code] ? messages[err.code] + (detail ? ' ' + detail : '') : detail;
}

// ---------------------------------------------------------------- ABI encoding (types used by the toolbox examples only)
const strip = (s) => String(s).replace(/^0x/, '').toLowerCase();
function need64(h, what) { h = strip(h); if (!/^[0-9a-f]+$/.test(h) || h.length !== 64) throw new Error(what + ': 0x로 시작하는 64자리 hex가 필요합니다'); return h; }
function pad32hex(h, what) { h = strip(h); if (!/^[0-9a-f]*$/.test(h) || h.length > 64) throw new Error(what + ': 올바른 hex가 아닙니다'); return h.padStart(64, '0'); }
function padAddr(a, what) { a = strip(a); if (!/^[0-9a-f]{40}$/.test(a)) throw new Error(what + ': 0x로 시작하는 40자리 주소가 필요합니다'); return a.padStart(64, '0'); }
function toAmount(s, what) { // decimal native coin -> ABI integer; precision comes from the manifest
  if (!nativeCurrency) throw new Error('manifest의 기본 코인 설정을 먼저 읽어야 합니다');
  s = String(s).trim();
  if (!/^\d*(\.\d*)?$/.test(s) || s === '' || s === '.') throw new Error(what + ': 숫자를 입력하세요 (예: 0.2)');
  const [i, f = ''] = s.split('.');
  const decimals = nativeCurrency.decimals;
  if (f.length > decimals) throw new Error(what + ': 소수점 이하 ' + decimals + '자리까지만 입력하세요');
  const frac = f.padEnd(decimals, '0');
  return pad32hex((BigInt(i || '0') * 10n ** BigInt(decimals) + BigInt(frac || '0')).toString(16), what);
}
function toUint(s, what) {
  s = String(s).trim();
  if (s.startsWith('0x')) { if (!/^[0-9a-fA-F]+$/.test(s.slice(2))) throw new Error(what + ': 올바른 hex가 아닙니다'); return pad32hex(s, what); }
  if (!/^\d+$/.test(s)) throw new Error(what + ': 10진 양의 정수를 입력하세요');
  return pad32hex(BigInt(s).toString(16), what);
}
const utf8hex = (str) => Array.from(new TextEncoder().encode(str)).map((b) => b.toString(16).padStart(2, '0')).join('');
const hexToUtf8 = (h) => new TextDecoder().decode(Uint8Array.from((h.match(/.{1,2}/g) || []).map((x) => parseInt(x, 16))));

// one tail blob (length word + data right-padded to a 32-byte boundary) for bytes / string
function tailOfBytes(dataHex) {
  const h = strip(dataHex);
  if (!/^(?:[0-9a-f]{2})*$/.test(h)) throw new Error('bytes: 짝수 자리 hex가 필요합니다');
  const byteLen = h.length / 2;
  const paddedLen = Math.ceil(byteLen / 32) * 32; // ABI: every tail blob occupies whole 32B words
  return byteLen.toString(16).padStart(64, '0') + h.padEnd(paddedLen * 2, '0');
}

function argWord(spec, raw) { // static head word, or null for dynamic types
  const t = spec.t;
  if (t === 'address') return padAddr(raw, spec.n);
  if (t === 'bytes32') return need64(raw, spec.n);
  if (t === 'uint' || t === 'token') return toUint(raw, spec.n);
  if (t === 'native') return toAmount(raw, spec.n);
  return null; // string | bytes | bytes32[] | bytes[]
}

function argTail(spec, raw) {
  const t = spec.t;
  if (t === 'string') return tailOfBytes(utf8hex(String(raw)));
  if (t === 'bytes') { const h = strip(raw); if (!/^[0-9a-f]*$/.test(h)) throw new Error(spec.n + ': 올바른 hex가 아닙니다'); return tailOfBytes(h); }
  const items = String(raw).split(/[\s,]+/).filter((x) => x !== '');
  if (t === 'bytes32[]') return items.length.toString(16).padStart(64, '0') + items.map((x) => need64(x, spec.n)).join('');
  if (t === 'bytes[]') { // length + per-elem offsets (relative to array payload start, after the length word) + elem blobs
    const blobs = items.map((x) => { const h = strip(x); if (!/^[0-9a-f]*$/.test(h)) throw new Error(spec.n + ': 올바른 hex가 아닙니다'); return tailOfBytes(h); });
    const offBase = items.length * 32; // offsets section size
    let off = 0; const offs = [];
    blobs.forEach((b) => { offs.push((offBase + off).toString(16).padStart(64, '0')); off += b.length / 2; });
    return items.length.toString(16).padStart(64, '0') + offs.join('') + blobs.join('');
  }
  throw new Error('지원하지 않는 타입: ' + t);
}

function encodeCall(selector, specs, values) {
  const heads = specs.map((s, i) => argWord(s, values[i]));
  const headLen = specs.length * 32;
  let tail = '';
  const offs = [];
  specs.forEach((s, i) => {
    if (heads[i] === null) { offs.push((headLen + tail.length / 2).toString(16).padStart(64, '0')); tail += argTail(s, values[i]); }
  });
  return '0x' + strip(selector) + heads.map((h, i) => h === null ? offs.shift() : h).join('') + tail;
}

// ---------------------------------------------------------------- decoding (eth_call results)
const rstrip = (r) => strip(r || '');
function decAt(hex, i) { return BigInt('0x' + hex.slice(i * 64, (i + 1) * 64)); }
function fmtResult(hex, kind) {
  const h = rstrip(hex);
  if (h === '') return '(빈 응답)';
  try {
    if (kind === 'uint' || kind === 'uint-token') return decAt(h, 0).toString() + (kind === 'uint-token' ? ' (토큰 기본 단위)' : '');
    if (kind === 'uint-native') {
      const v = decAt(h, 0), scale = 10n ** BigInt(nativeCurrency.decimals);
      const f = nativeCurrency.decimals ? (v % scale).toString().padStart(nativeCurrency.decimals, '0').replace(/0+$/, '') : '';
      return (v / scale).toString() + (f ? '.' + f : '') + ' ' + nativeCurrency.symbol;
    }
    if (kind === 'bool') return decAt(h, 0) !== 0n ? 'true' : 'false';
    if (kind === 'address') return '0x' + h.slice(24, 64);
    if (kind === 'bytes32') return '0x' + h.slice(0, 64);
    if (kind === 'string') { const off = Number(decAt(h, 0) / 32n); const len = Number(decAt(h, off)); return hexToUtf8(h.slice((off + 1) * 64, (off + 1) * 64 + len * 2)); }
  } catch (e) { /* fall through to raw */ }
  const words = []; for (let i = 0; i < h.length; i += 64) words.push('0x' + h.slice(i, i + 64));
  return words.join('\n');
}

// ---------------------------------------------------------------- RPC plumbing
async function walletForRequest(isWrite) {
  await manifestReady;
  if (manifestError) throw manifestError;
  const selected = provider;
  if (!selected) throw new Error('먼저 지갑을 연결하세요');
  if (isWrite) {
    const accounts = await selected.request({ method: 'eth_accounts' });
    if (selected !== provider) throw new Error('지갑이 변경되었습니다. 다시 시도하세요');
    setAccount(accounts);
    if (!account) throw new Error('먼저 지갑 계정을 연결하세요');
  }
  if (!await checkChain() || selected !== provider) throw new Error('지갑을 배포 체인 ' + expectedChainId + '에 연결하세요');
  return { selected, from: account };
}
async function call(to, data) {
  const { selected, from } = await walletForRequest(false);
  const tx = { to, data }; if (from) tx.from = from;
  return selected.request({ method: 'eth_call', params: [tx, 'latest'] });
}
async function sendTx(to, data, valueHex) {
  const { selected, from } = await walletForRequest(true);
  if (personalPolicy) {
    await verifyPersonalInstance(selected, from, to);
    const accounts = await selected.request({ method: 'eth_accounts' });
    const currentChain = chainId(await selected.request({ method: 'eth_chainId' }));
    if (selected !== provider || accounts?.[0]?.toLowerCase() !== from.toLowerCase() || currentChain !== expectedChainId) throw new Error('Wallet account or network changed. Reconnect to your personal instance.');
  }
  const params = { from, to, data };
  if (valueHex != null) params.value = '0x' + BigInt('0x' + strip(valueHex)).toString(16);
  // The wallet signs its own account envelope and quotes B5 fees. The page never supplies Ethereum fee fields or signing keys.
  const hash = await selected.request({ method: 'eth_sendTransaction', params: [params] });
  return hash;
}

async function verifyPersonalInstance(selected, from, to) {
  const policy = personalPolicy;
  const target = to.toLowerCase();
  if (!policy.contracts.includes(target) || policy.readOnly.includes(target)) throw new Error('Use your declared personal instance.');
  const read = async (destination, data) => selected.request({ method: 'eth_call', params: [{ from, to: destination, data }, 'latest'] });
  const word = (raw) => { if (!/^0x[0-9a-fA-F]{64}$/.test(raw)) throw new Error('Invalid personal instance response.'); return strip(raw); };
  if (fmtResult(await read(target, '0x53702e15'), 'string') !== 'personal-test') throw new Error('This contract is not a personal test instance.');
  if ('0x' + word(await read(target, '0x5d6309b0')).slice(24) !== policy.owner.toLowerCase()
      || '0x' + word(await read(target, '0x98a760c1')).slice(24) !== policy.authority.toLowerCase()
      || BigInt('0x' + word(await read(target, '0x7c38dfd9'))) !== BigInt(policy.native_cap)
      || BigInt('0x' + word(await read(target, '0xdcdc520c'))) !== BigInt(policy.token_cap)) throw new Error('Personal instance owner or caps differ from the local bundle.');
  const registered = word(await read(policy.authority, '0xcc809606' + padAddr(target, 'instance')));
  const allowed = word(await read(target, '0x3908af36' + padAddr(from, 'account')));
  if (BigInt('0x' + registered) !== 1n || BigInt('0x' + allowed) !== 1n) throw new Error('This account is not allowed in your personal instance.');
}

// ---------------------------------------------------------------- contract address
function contractAddr() { const a = addrInput.value.trim(); if (!isDeployedAddress(a)) throw new Error('배포된 컨트랙트 주소를 입력하세요 (0x…40자리) — ?contract=0x… 링크로도 전달할 수 있습니다'); return a; }

// ---------------------------------------------------------------- views
function fieldInput(id, spec) {
  const el = document.createElement('input');
  el.id = id; el.placeholder = spec.p || ''; el.autocomplete = 'off'; el.spellcheck = false;
  return el;
}

function buildForm(container, def, isWrite) {
  const form = document.createElement('form');
  const title = document.createElement('label'); title.innerHTML = '<b>' + def.label + '</b> <span class="mono dim">' + def.sig + '</span>'; form.appendChild(title);
  const specs = []; const inputs = [];
  def.args.forEach((spec, i) => {
    const id = def.f + '_' + i;
    const lab = document.createElement('label'); lab.textContent = spec.n + ' — ' + (spec.t === 'token' ? '토큰 기본 단위 (정수)' : spec.t === 'native' ? '기본 코인 ' : spec.t); form.appendChild(lab);
    if (spec.t === 'native') { const unit = document.createElement('span'); unit.setAttribute('data-native-unit', ''); lab.appendChild(unit); }
    const inp = fieldInput(id, spec); form.appendChild(inp);
    specs.push(spec); inputs.push(inp);
  });
  let valueInput = null;
  if (isWrite && def.value === 'native') {
    const lab = document.createElement('label'); lab.textContent = 'msg.value — 함께 송금할 금액 '; form.appendChild(lab);
    const unit = document.createElement('span'); unit.setAttribute('data-native-unit', ''); lab.appendChild(unit);
    valueInput = document.createElement('input'); valueInput.placeholder = '0.0'; form.appendChild(valueInput);
  }
  const btn = document.createElement('button'); btn.textContent = isWrite ? '트랜잭션 전송' : '조회 (eth_call)'; btn.type = 'submit'; form.appendChild(btn);
  const out = document.createElement('p'); out.className = 'dim'; form.appendChild(out);
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    if (btn.disabled) return;
    btn.disabled = true;
    out.className = 'dim'; out.textContent = '…';
    try {
      await manifestReady;
      if (manifestError) throw manifestError;
      const to = contractAddr();
      const values = inputs.map((inp) => inp.value.trim());
      const data = encodeCall(def.sel, specs, values);
      if (isWrite) {
        const vhex = valueInput ? toAmount(valueInput.value.trim() || '0', 'msg.value') : null;
        const hash = await sendTx(to, data, vhex);
        out.className = 'ok txhash'; out.textContent = '전송됨: ' + hash;
      } else {
        if (!provider) throw new Error('먼저 지갑을 연결하세요 (조회에도 RPC가 필요합니다)');
        const res = await call(to, data);
        out.className = 'mono'; out.textContent = fmtResult(res, def.decode);
      }
    } catch (err) { out.className = 'err'; out.textContent = errorText(err); }
    finally { btn.disabled = false; }
  };
  container.appendChild(form);
}

if (APP.views.length) { const c = document.getElementById('views'); APP.views.forEach((v) => buildForm(c, v, false)); }
else { document.getElementById('views-card').classList.add('hidden'); }
{ const c = document.getElementById('actions'); APP.actions.forEach((a) => buildForm(c, a, true)); }
if (APP.signatureNotice) note('signature-note', APP.signatureNotice, 'warn');

// ---------------------------------------------------------------- events
document.getElementById('load-logs').onclick = async () => {
  const out = document.getElementById('logs'); out.textContent = '…'; out.className = 'dim';
  try {
    const { selected } = await walletForRequest(false);
    const to = contractAddr();
    const head = BigInt(await selected.request({ method: 'eth_blockNumber' }));
    const from = '0x' + (head > 5000n ? head - 5000n : 0n).toString(16);
    const topics = [APP.events.map((e) => e.topic)];
    const logs = await selected.request({ method: 'eth_getLogs', params: [{ address: to, topics, fromBlock: from, toBlock: 'latest' }] });
    out.textContent = '';
    if (!logs.length) { out.innerHTML = '<p class="dim">최근 5,000블록에 이벤트가 없습니다.</p>'; return; }
    logs.slice(-25).reverse().forEach((lg) => {
      const ev = APP.events.find((e) => e.topic === lg.topics[0]) || { label: lg.topics[0] };
      const div = document.createElement('div'); div.className = 'log';
      let html = '<b>' + ev.label + '</b> <span class="dim">block ' + parseInt(lg.blockNumber, 16) + '</span><br>';
      lg.topics.slice(1).forEach((t, i) => {
        const h = strip(t); let shown = t;
        if (/^0{24}[0-9a-f]{40}$/.test(h)) shown = '0x' + h.slice(24); // indexed address
        else if (/^[0-9a-f]{64}$/.test(h) && !/^0{48}/.test(h)) { try { shown = BigInt('0x' + h).toString(); } catch (e) {} }
        html += '<span class="mono">topic' + (i + 1) + ': ' + shown + '</span><br>';
      });
      const d = strip(lg.data);
      if (d.length > 64) { const words = []; for (let i = 0; i < d.length; i += 64) words.push('0x' + d.slice(i, i + 64)); html += '<span class="mono dim">data: ' + words.join(' · ') + '</span><br>'; }
      div.innerHTML = html; out.appendChild(div);
    });
  } catch (err) { out.textContent = errorText(err); out.className = 'err'; }
};
"""

HTML_TEMPLATE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ — EastSea Toolbox</title>
<style>__CSS__</style>
</head>
<body>
<header>
  <div class="brand">EastSea Toolbox · 예제 __NUM__</div>
  <h1>__NAME__</h1>
  <p class="sub">__SUB__</p>
</header>
<main>
  <section class="card">
    <h2>1 · 지갑 연결</h2>
    <div class="wallets" id="wallets"><span class="dim">지갑을 찾는 중…</span></div>
    <p id="acct" class="dim">지갑을 선택하세요 (EIP-6963 자동 감지 · 폴백 window.aether).</p>
    <p id="chain" class="dim"></p>
    <button id="fixchain" class="hidden">배포 체인으로 전환</button>
  </section>
  <section class="card">
    <h2>2 · 컨트랙트 주소</h2>
    <input id="contract" placeholder="0x…" autocomplete="off" spellcheck="false">
    <p id="deployment" class="dim">manifest.json에서 배포 설정을 읽는 중…</p>
    <p class="hint">__NAME__ 배포 주소. 링크로 전달할 수 있습니다: <span class="mono">apps/__SLUG__/?contract=0x…</span></p>
  </section>
  <section class="card" id="views-card">
    <h2>3 · 조회 (eth_call · 무료)</h2>
    <div id="views"></div>
  </section>
  <section class="card">
    <h2 id="views-card-toggle">4 · 실행 (트랜잭션 · 상태 비용 발생)</h2>
    <p id="signature-note" class="hint"></p>
    <div class="actions" id="actions"></div>
  </section>
  <section class="card">
    <h2>5 · 최근 이벤트</h2>
    <button id="load-logs">최근 5,000블록 로그 불러오기</button>
    <p class="hint">__EVENTS__</p>
    <div id="logs"></div>
  </section>
</main>
<footer>예제 문서: <a href="../../examples/__SLUG__/README.md">examples/__SLUG__/</a> · 가스·상태 비용: <a href="../../examples/__SLUG__/GAS.md">GAS.md</a> · 보안: <a href="../../examples/__SLUG__/SECURITY.md">SECURITY.md</a><br>
테스트 코인만 사용하세요. AS IS — 실행 결과는 사용자 책임입니다. 배포 주소·체인·코인은 manifest.json에서 읽으며, 계정 서명과 B5 수수료 확인은 연결한 지갑이 담당합니다.</footer>
<script>
const APP = __APP__;
__JS__
</script>
</body>
</html>
"""

# --------------------------------------------------------------------------
# per-example metadata
# --------------------------------------------------------------------------

def A(f, sig, sel, label, args=(), value=None):
    d = {"f": f, "sig": sig, "sel": sel, "label": label, "args": list(args)}
    if value: d["value"] = value
    return d

def V(f, sig, sel, label, args=(), decode="raw"):
    return {"f": f, "sig": sig, "sel": sel, "label": label, "args": list(args), "decode": decode}

def E(topic, label): return {"topic": topic, "label": label}

APPS = {
    "escrow": {
        "contract": "MilestoneEscrow",
        "views": [V("dealInfo", "dealInfo(uint256)", "0xf5c94ea7", "딜 조회", [
            {"n": "dealId", "t": "uint", "p": "1"}])],
        "actions": [
            A("createDeal", "createDeal(address,uint64)", "0x92a23398", "딜 생성 (총액 송금)", [
                {"n": "seller", "t": "address", "p": "0x…"}, {"n": "milestoneCount", "t": "uint", "p": "3"}], "native"),
            A("approveMilestone", "approveMilestone(uint256,uint64,uint256)", "0x2b3660d0", "마일스톤 승인", [
                {"n": "dealId", "t": "uint", "p": "1"}, {"n": "index", "t": "uint", "p": "0"}, {"n": "amount", "t": "native", "p": "0.1"}]),
            A("sellerWithdraw", "sellerWithdraw(uint256)", "0x864ae8cd", "판매자 인출", [
                {"n": "dealId", "t": "uint", "p": "1"}]),
            A("buyerRefund", "buyerRefund(uint256)", "0x06379826", "구매자 전액 환불", [
                {"n": "dealId", "t": "uint", "p": "1"}])],
        "events": [E("0x13995a1d69ea226e6c065c8c4d7bd04e4f75a481b685c6c31c6b201bae237cda", "DealCreated"),
                    E("0xfcdcba16587474c4a2d6a3b2c004dbc533fcfb4121a16dcc48c78b8a1df85919", "MilestoneApproved")],
    },
    "lock": {
        "contract": "LinearVesting",
        "views": [V("claimable", "claimable()", "0xaf38d757", "지금 청구 가능액", [], "uint-token"),
                  V("vested", "vested()", "0xfea5657c", "현재까지 베스팅 누적액", [], "uint-token")],
        "actions": [A("claim", "claim()", "0x4e71d92d", "청구", [])],
        "events": [E("0xd8138f8a3f377c5259ca548e70e4c2de94f129f5a11036a15b69513cba2b426a", "Claimed")],
    },
    "market": {
        "contract": "FixedPriceMarket",
        "views": [V("listingOf", "listingOf(uint256)", "0xe3404981", "리스팅 조회", [
            {"n": "listingId", "t": "uint", "p": "1"}])],
        "actions": [
            A("list", "list(address,uint256,uint256)", "0xdda342bb", "NFT 판매 등록 (컨트랙트가 먼저 escrow로 전송해야 합니다)", [
                {"n": "token", "t": "address", "p": "0x… ERC721"}, {"n": "tokenId", "t": "uint", "p": "1"}, {"n": "price", "t": "native", "p": "0.05"}]),
            A("buy", "buy(uint256)", "0xd96a094a", "구매 (price와 동일한 msg.value)", [
                {"n": "listingId", "t": "uint", "p": "1"}], "native"),
            A("cancel", "cancel(uint256)", "0x40e58ee5", "등록 취소", [{"n": "listingId", "t": "uint", "p": "1"}]),
            A("withdraw", "withdraw()", "0x3ccfd60b", "판매대금·로열티 인출", [])],
        "events": [E("0x723f73331eaee88eec7fc68ef60ab6ed15e4b90d0472b55eb92fa43910bab6dd", "Listed"),
                    E("0xcd1c39d27a443bebce7f2cf1cb49519e7586ec24d1a7a7c9fcc00f57cd8efbfb", "Sold")],
    },
    "multisig": {
        "contract": "SimpleMultisig",
        "signatureNotice": "이 예제는 65바이트 secp256k1/ecrecover 서명을 요구합니다. P-256 계정 서명으로 대체할 수 없으며 EastSea 지갑은 personal_sign을 지원하지 않습니다. 해시 조회와 외부에서 수집한 유효 서명의 트랜잭션 중계만 가능합니다.",
        "views": [V("getTransactionHash", "getTransactionHash(address,uint256,bytes,uint256)", "0xb98a34de", "트랜잭션 해시 계산 (서명 대상)", [
            {"n": "to", "t": "address", "p": "0x…"}, {"n": "value", "t": "native", "p": "0"}, {"n": "data", "t": "bytes", "p": "0x"}, {"n": "nonce", "t": "uint", "p": "0"}], "bytes32")],
        "actions": [A("execute", "execute(address,uint256,bytes,uint256,bytes[])", "0xdbac0f6c", "서명 모아 실행", [
            {"n": "to", "t": "address", "p": "0x…"}, {"n": "value", "t": "native", "p": "0"},
            {"n": "data", "t": "bytes", "p": "0x"}, {"n": "nonce", "t": "uint", "p": "0"},
            {"n": "signatures", "t": "bytes[]", "p": "0x…65B 서명들 (공백/콤마 구분)"}])],
        "events": [E("0xf7432a6dbcfd03be57afcf821adebe4700917f3095e05986071a910357cecd8d", "Executed")],
    },
    "nft": {
        "contract": "Editions1155 sales",
        "views": [V("editionOf", "editionOf(uint256)", "0x4be185f0", "에디션 조회", [{"n": "editionId", "t": "uint", "p": "1"}]),
                  V("withdrawable", "withdrawable(uint256)", "0xf11988e0", "인출 가능 정산액", [{"n": "editionId", "t": "uint", "p": "1"}], "uint-native")],
        "actions": [
            A("createEdition", "createEdition(string,uint256,uint256,uint256,uint16)", "0xbfa27adc", "에디션 생성 (크리에이터)", [
                {"n": "name_", "t": "string", "p": "Reef Poster #1"}, {"n": "cap", "t": "uint", "p": "100"},
                {"n": "maxPerWallet", "t": "uint", "p": "2"}, {"n": "price", "t": "native", "p": "0.01"}, {"n": "feeBps", "t": "uint", "p": "500"}]),
            A("mint", "mint(uint256)", "0xa0712d68", "민트 (price를 msg.value로)", [{"n": "editionId", "t": "uint", "p": "1"}], "native"),
            A("withdraw", "withdraw(uint256)", "0x2e1a7d4d", "크리에이터 인출", [{"n": "editionId", "t": "uint", "p": "1"}])],
        "events": [E("0x23e3ab16b57cfad3270187f8f51d19f69419e3ab3d5dfdbb181fa94ba1d1ee76", "EditionCreated"),
                    E("0xc9d0543a84d3510329c0783b91576878ceb484e8699944cb5610c3436b3b8e39", "Minted")],
    },
    "rewards": {
        "contract": "RewardDistributor",
        "views": [V("earned", "earned(address)", "0x008cc262", "내 보상 조회", [{"n": "user", "t": "address", "p": "내 주소"}], "uint-token")],
        "actions": [
            A("fundRewards", "fundRewards(uint256,uint256)", "0x28662551", "보상 예치 (운영자 — reward 토큰을 먼저 approve하세요)", [
                {"n": "amount", "t": "token", "p": "100000000000000000000"}, {"n": "durationSec", "t": "uint", "p": "604800"}]),
            A("stake", "stake(uint256)", "0xa694fc3a", "스테이크 (staking 토큰 approve 후)", [{"n": "amount", "t": "token", "p": "10000000000000000000"}]),
            A("unstake", "unstake(uint256)", "0x2e17de78", "언스테이크", [{"n": "amount", "t": "token", "p": "10000000000000000000"}]),
            A("claim", "claim()", "0x4e71d92d", "보상 청구", [])],
        "events": [E("0x9e71bc8eea02a63969f509818f2dafb9254532904319f9dbda79b67bd34a5f3d", "Staked"),
                    E("0xd8138f8a3f377c5259ca548e70e4c2de94f129f5a11036a15b69513cba2b426a", "Claimed")],
    },
    "token": {
        "contract": "IslandCoin token",
        "views": [V("name", "name()", "0x06fdde03", "토큰 이름", [], "string"),
                  V("symbol", "symbol()", "0x95d89b41", "심볼", [], "string"),
                  V("totalSupply", "totalSupply()", "0x18160ddd", "총 공급량", [], "uint-token"),
                  V("balanceOf", "balanceOf(address)", "0x70a08231", "잔액 조회", [{"n": "owner", "t": "address", "p": "내 주소"}], "uint-token")],
        "actions": [
            A("transfer", "transfer(address,uint256)", "0xa9059cbb", "전송", [
                {"n": "to", "t": "address", "p": "0x…"}, {"n": "amount", "t": "token", "p": "1500000000000000000"}]),
            A("approve", "approve(address,uint256)", "0x095ea7b3", "지출 승인", [
                {"n": "spender", "t": "address", "p": "0x…"}, {"n": "amount", "t": "token", "p": "10000000000000000000"}])],
        "events": [E("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "Transfer")],
    },
    "amm": {
        "contract": "AmmFactory",
        "views": [V("allPairsLength", "allPairsLength()", "0x574f2ba3", "생성된 페어 수", [], "uint")],
        "actions": [A("createPair", "createPair(address,address)", "0xc9c65396", "페어 생성", [
            {"n": "tokenA", "t": "address", "p": "0x…"}, {"n": "tokenB", "t": "address", "p": "0x…"}])],
        "events": [E("0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9", "PairCreated")],
    },
    "launchpad": {
        "contract": "BondingLaunchpad",
        "views": [V("getBuyQuoteOut", "getBuyQuoteOut(uint256)", "0x8ea8354f", "구매 견적", [{"n": "quoteIn", "t": "token", "p": "100000000000000000"}], "uint")],
        "actions": [
            A("buy", "buy(uint256,uint256)", "0xd6febde8", "구매 (quote 토큰 approve 후)", [
                {"n": "quoteIn", "t": "token", "p": "100000000000000000"}, {"n": "minTokensOut", "t": "uint", "p": "0"}]),
            A("sell", "sell(uint256,uint256)", "0xd79875eb", "판매 (토큰 approve 후)", [
                {"n": "tokenIn", "t": "token", "p": "100000000000000000000"}, {"n": "minQuoteOut", "t": "uint", "p": "0"}]),
            A("graduate", "graduate()", "0xd3618cca", "졸업 (페어 시드 + LP 록)", [])],
        "events": [E("0x27330bd7589580547b6437e08f9c60653de63691d2d2b2c13bff9ee67da2a68d", "Bought"),
                    E("0xcb64f2436060c9575db20c5dcf9cdc11657017ee5b0301949f531b3dd7da6b19", "Graduated")],
    },
    "subscription": {
        "contract": "SubscriptionManager",
        "views": [V("isSubscribed", "isSubscribed(address)", "0xb92ae87c", "구독 중 여부", [{"n": "user", "t": "address", "p": "내 주소"}], "bool"),
                  V("claimableRevenue", "claimableRevenue()", "0x367403f3", "운영자 인출 가능액", [], "uint-native")],
        "actions": [
            A("subscribe", "subscribe()", "0x8f449a05", "구독 (가격을 msg.value로)", [], "native"),
            A("cancel", "cancel()", "0xea8a1af0", "구독 취소 (미사용 기간 환불)", []),
            A("claimRevenue", "claimRevenue()", "0x564f4f76", "운영자 수익 인출", [])],
        "events": [E("0xb30e29159fb9cc7df9e4b7378aae4e009b003662ce36f37585c08f257e8d1cd0", "Subscribed"),
                    E("0xfc6d819d2e7b6316531fecd79c0ff206ae35d6d5992008cbd2a23b5c35d4e52f", "Cancelled")],
    },
    "dao": {
        "contract": "SimpleDAO",
        "signatureNotice": "투표 실행은 65바이트 secp256k1/ecrecover 서명을 요구합니다. P-256 계정 서명으로 대체할 수 없으며 EastSea 지갑은 personal_sign을 지원하지 않습니다. 조회·제안과 외부에서 수집한 유효 서명의 트랜잭션 중계만 가능합니다.",
        "views": [V("state", "state(uint256)", "0x3e4f49e6", "제안 상태 (0=대기 1=실행가능 2=만료)", [{"n": "proposalId", "t": "uint", "p": "1"}], "uint"),
                  V("getVoteHash", "getVoteHash(uint256)", "0x9ce7424a", "투표 해시 (오프체인 서명 대상)", [{"n": "proposalId", "t": "uint", "p": "1"}], "bytes32")],
        "actions": [
            A("propose", "propose(bytes32)", "0x99882cdb", "제안 (실행 콜의 해시 커밋)", [
                {"n": "executionHash", "t": "bytes32", "p": "0x… cast keccak로 계산"}]),
            A("execute", "execute(uint256,address,uint256,bytes,bytes[])", "0xac53a4f9", "제안 실행 (가중치 서명 모아)", [
                {"n": "proposalId", "t": "uint", "p": "1"}, {"n": "target", "t": "address", "p": "0x…"},
                {"n": "value", "t": "native", "p": "0"}, {"n": "data", "t": "bytes", "p": "0x"},
                {"n": "signatures", "t": "bytes[]", "p": "0x…65B 서명들 (공백/콤마 구분)"}])],
        "events": [E("0xd51021895c7e4f6fe327beb5e9d1dc4c9c1615833045445a444e098dfb28a4cf", "Proposed"),
                    E("0xb2d783b5c2b716ac8e75390b340e75396d05ee6cd49313588c4c3b96c7e8550f", "Executed")],
    },
    "crowdfund": {
        "contract": "AllOrNothingCrowdfund",
        "views": [V("state", "state()", "0xc19d93fb", "캠페인 상태 (0=진행 1=성공 2=실패)", [], "uint")],
        "actions": [
            A("contribute", "contribute()", "0xd7bb99ba", "후원", [], "native"),
            A("refund", "refund()", "0x590e1ae3", "실패 시 전액 환불", []),
            A("withdraw", "withdraw()", "0x3ccfd60b", "성공 시 주최자 인출", [])],
        "events": [E("0x873586e42301845135c112cca311b51ce11603e512ea259a4d609b88e431d122", "Contributed"),
                    E("0xab48b3d59a240196dc5bdd7f7a638fca310f8194c7d350c3dd7765861311ddf8", "Withdrawn"),
                    E("0x297271698596ec863518fd4ce414920510df3ca64d7f90241104ef2b612e6bdd", "Refunded")],
    },
    "airdrop": {
        "contract": "MerkleAirdrop",
        "views": [V("totalClaimed", "totalClaimed()", "0xd54ad2a1", "지급 누적액", [], "uint-native")],
        "actions": [
            A("claim", "claim(uint256,bytes32[])", "0x2f52ebb7", "머클 청구 (증명 필요)", [
                {"n": "amount", "t": "native", "p": "10"}, {"n": "proof", "t": "bytes32[]", "p": "0x… 형제 해시들 (공백/콤마 구분)"}]),
            A("sweep", "sweep()", "0x35faa416", "마감 후 미청구 몰수 (배포자)", [])],
        "events": [E("0xd8138f8a3f377c5259ca548e70e4c2de94f129f5a11036a15b69513cba2b426a", "Claimed"),
                    E("0xc36b5179cb9c303b200074996eab2b3473eac370fdd7eba3bec636fe35109696", "Swept")],
    },
    "raffle": {
        "contract": "CommitRevealRaffle",
        "views": [V("playerCount", "playerCount()", "0x302bcc57", "참가자 수", [], "uint")],
        "actions": [
            A("enter", "enter()", "0xe97dcb62", "참가 (티켓값을 msg.value로)", [], "native"),
            A("reveal", "reveal(bytes32)", "0x701fd0f1", "시드 공개 (커밋 시 사용한 seed)", [
                {"n": "seed", "t": "bytes32", "p": "0x… commit 때와 동일한 seed"}]),
            A("drawWithoutSeed", "drawWithoutSeed()", "0x737da0f8", "미공개 참가자 제외 추첨", [])],
        "events": [E("0x089d0daa5e8466fdfdab1113e8fdd98c06ef26711cafc429dabce354d007364e", "Entered"),
                    E("0xf25e8de88cdf25a77442552670ccb69d1575dd8a51a42c5d607ea2f6bf273c58", "Drawn")],
    },
    "names": {
        "contract": "NameGatedDrop",
        "views": [V("dropAmount", "dropAmount()", "0x05748be2", "이름당 청구액", [], "uint-native")],
        "actions": [
            A("claim", "claim()", "0x4e71d92d", "청구 (primary name 보유자만)", []),
            A("sweep", "sweep()", "0x35faa416", "마감 후 회수 (배포자)", [])],
        "events": [E("0x4ef887714b6ae4b4e5b624f78fb37bc493b148ca911452610d6ef8bffc0704e2", "Claimed"),
                    E("0xc36b5179cb9c303b200074996eab2b3473eac370fdd7eba3bec636fe35109696", "Swept")],
    },
    "invoice": {
        "contract": "InvoiceBook",
        "views": [V("invoiceCount", "invoiceCount()", "0x1346f0c4", "발행된 청구서 수", [], "uint")],
        "actions": [
            A("issue", "issue(uint128,uint48,string)", "0xf8132e3a", "청구서 발행 (payee 전용)", [
                {"n": "amount", "t": "native", "p": "0.5"}, {"n": "payBy (유효 기간, 초)", "t": "uint", "p": "3600"}, {"n": "memo", "t": "string", "p": "INV-2026-001"}]),
            A("settle", "settle(uint256)", "0x8df82800", "결제 (amount와 동일한 msg.value)", [
                {"n": "id", "t": "uint", "p": "1"}], "native"),
            A("void", "void(uint256)", "0x5ea2145b", "폐기 (payee 전용)", [{"n": "id", "t": "uint", "p": "1"}]),
            A("purge", "purge(uint256)", "0xf34b618a", "만료 청구서 정리 (누구나)", [{"n": "id", "t": "uint", "p": "1"}])],
        "events": [E("0xd670f28c17040efc5ef68c71303495ba525819f38ca572481b815aa0e5b3ca8e", "Issued"),
                    E("0x2c35d68fdf40b18e913bb877373b4a4fc67810e2546dc5c9f9208eb8494057cb", "Settled"),
                    E("0xa0add9b3f251e0c65ca063f300e2f04bc423f4b29b11f0149bd33d75f0160172", "Voided")],
    },
    "vending": {
        "contract": "AgentVending",
        "views": [V("price", "price()", "0xa035b1fe", "주문 가격", [], "uint-native")],
        "actions": [
            A("order", "order(bytes32)", "0xe80160ab", "주문 (정가를 msg.value로 · specHash는 명세의 keccak)", [
                {"n": "specHash", "t": "bytes32", "p": "0x… cast keccak \"명세 원문\""}], "native"),
            A("deliver", "deliver(uint256,bytes32)", "0xd9b42a7f", "배달 (agent 전용 · 기한 내 결과 해시 등록)", [
                {"n": "id", "t": "uint", "p": "1"}, {"n": "resultHash", "t": "bytes32", "p": "0x… 결과물 해시"}]),
            A("refund", "refund(uint256)", "0x278ecde1", "환불 (주문자 전용 · 기한 경과 후)", [
                {"n": "id", "t": "uint", "p": "1"}])],
        "events": [E("0xcdf0b73875ae825ef2fac8eab8256de2027b324e18a8ebe82732242a020dcfb6", "Ordered"),
                    E("0x59fcfbc25d00e982e0bbd62937d18ff4f7c7ac667e13256d51154645e74484ab", "Delivered"),
                    E("0x3d2a04f53164bedf9a8a46353305d6b2d2261410406df3b41f99ce6489dc003c", "Refunded")],
    },
}

def main():
    for slug, meta in APPS.items():
        manifest_path = ROOT / "examples" / slug / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        m = re.search(r"Example (\d+)", manifest.get("description", ""))
        num = m.group(1) if m else "?"
        name = manifest.get("name", slug)
        sub = manifest.get("subtitle", "")

        app_json = json.dumps({
            "slug": slug, "num": num, "name": name, "sub": sub,
            "contract": meta["contract"],
            "signatureNotice": meta.get("signatureNotice"),
            "views": meta["views"], "actions": meta["actions"], "events": meta["events"],
        }, ensure_ascii=False, indent=2)

        events_hint = ", ".join(e["label"] for e in meta["events"])
        html = (HTML_TEMPLATE
                .replace("__TITLE__", name)
                .replace("__NUM__", num)
                .replace("__NAME__", name)
                .replace("__SUB__", sub)
                .replace("__SLUG__", slug)
                .replace("__EVENTS__", events_hint)
                .replace("__CSS__", CSS)
                .replace("__APP__", app_json)
                .replace("__JS__", JS))
        out = ROOT / "apps" / slug / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(html, encoding="utf-8")
        print(f"wrote {out.relative_to(ROOT)} ({len(html)} bytes)")

    # apps index (catalog page)
    rows = []
    for slug in sorted(APPS, key=lambda s: int(re.search(r"Example (\d+)", json.loads((ROOT / "examples" / slug / "manifest.json").read_text())["description"]).group(1))):
        manifest = json.loads((ROOT / "examples" / slug / "manifest.json").read_text(encoding="utf-8"))
        num = re.search(r"Example (\d+)", manifest["description"]).group(1)
        rows.append(f'<tr><td class="dim">{num}</td><td><a href="./{slug}/">{manifest["name"]}</a></td><td>{manifest.get("subtitle","")}</td><td class="mono dim">{slug}</td></tr>')
    index = """<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>EastSea Toolbox — 앱 카탈로그</title>
<style>
body{background:#08131d;color:#d7e7ee;font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;margin:0}
main{max-width:860px;margin:0 auto;padding:24px 16px 64px}
.brand{color:#4dd6c1;font-size:12px;letter-spacing:.14em;text-transform:uppercase}
h1{font-size:26px;margin:.15em 0 .4em}
table{border-collapse:collapse;width:100%}
td,th{border-bottom:1px solid #1b3648;padding:10px 8px;text-align:left}
th{color:#9fc4d4;font-size:13px}
a{color:#4dd6c1;text-decoration:none}a:hover{text-decoration:underline}
.dim{color:#6d8aa0}.mono{font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
p{color:#8aa7b6}
</style></head>
<body><main>
<div class="brand">EastSea Toolbox</div>
<h1>앱 카탈로그</h1>
<p>17개 예제의 정적 프론트엔드입니다. 자신의 계정으로 배포한 주소·체인·코인 설정을 각 앱의 <span class="mono">manifest.json</span>에서 읽습니다. 컨트랙트 주소는 <span class="mono">?contract=0x…</span> 쿼리로 재정의할 수 있습니다. 테스트 코인 전용, AS IS — 실행 결과는 사용자 책임입니다.</p>
<table><tr><th>#</th><th>앱</th><th>설명</th><th>폴더</th></tr>
__ROWS__
</table></main></body></html>"""
    out = ROOT / "apps" / "index.html"
    out.write_text(index.replace("__ROWS__", "\n".join(rows)), encoding="utf-8")
    print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
