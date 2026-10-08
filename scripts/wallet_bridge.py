#!/usr/bin/env python3
"""Loopback EIP-1193 relay. The user's browser wallet owns keys and B5 fees.

No browser is launched. Requests are delivered once; a timeout closes the
relay because a transaction may still be awaiting approval in the wallet.
"""

from __future__ import annotations

from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import re
import secrets
import sys
import threading
import time


class WalletBridgeError(RuntimeError):
    def __init__(self, message, code=-32603, *, outcome_unknown=False):
        super().__init__(message)
        self.code = code
        self.outcome_unknown = outcome_unknown


_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
_METHODS = frozenset({"eth_accounts", "eth_chainId", "eth_sendTransaction"})
_UNSET = object()


def _chain_id(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError("chain_id must be a positive integer or hex quantity")
    if isinstance(value, str) and not re.fullmatch(r"(?:0x[0-9a-fA-F]+|[0-9]+)", value):
        raise ValueError("chain_id must be a positive integer or hex quantity")
    result = int(value, 16 if isinstance(value, str) and value.startswith("0x") else 10) if isinstance(value, str) else value
    if not 0 < result < 2 ** 256:
        raise ValueError("chain_id must fit a positive 256-bit integer")
    return hex(result)


_PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="same-origin"><title>Toolbox wallet connection</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:760px;margin:32px auto;padding:0 16px}button{font:inherit;padding:8px 14px;margin:4px}pre{white-space:pre-wrap;overflow-wrap:anywhere;border:1px solid #bbb;padding:12px}#status{min-height:3em}</style></head>
<body><h1>Connect your wallet</h1><p>This local publisher uses your own account. Test coins only. AS IS; publishing is your responsibility.</p>
<pre id="identity"></pre><div id="wallets">Finding wallet providers…</div><p id="status">Choose a wallet, then approve its account connection.</p>
<h2>Current request</h2><pre id="request">Waiting for the publisher.</pre>
<script nonce="__NONCE__">
'use strict';
const CONFIG = __CONFIG__;
const TOKEN = new URLSearchParams(location.hash.slice(1)).get('token');
const identity = document.getElementById('identity'), status = document.getElementById('status'), summary = document.getElementById('request');
identity.textContent = 'Requested account: ' + CONFIG.sender + '\nRequested chain: ' + CONFIG.chain_id + '\nSignatures and B5 fee approval stay in your wallet.';
const discovered = [];
let provider = null, connected = false, running = false, stopped = false, connecting = false, awaitingResponse = false;
const normalizeChain = (value) => '0x' + BigInt(value).toString(16);
const failure = (code, message) => Object.assign(new Error(message), { code });

function announce(detail) {
  if (!detail?.provider || typeof detail.provider.request !== 'function') return;
  if (discovered.some((d) => d.provider === detail.provider)) return;
  discovered.push(detail); renderWallets();
}
function renderWallets() {
  const box = document.getElementById('wallets'); box.textContent = '';
  if (!discovered.length) { box.textContent = 'No wallet found. Open this URL in your wallet-enabled browser.'; return; }
  discovered.forEach((d) => {
    const button = document.createElement('button'); button.textContent = d.info?.name || 'Injected wallet';
    button.onclick = () => connect(d.provider); box.appendChild(button);
  });
}
window.addEventListener('eip6963:announceProvider', (event) => announce(event.detail));
window.dispatchEvent(new Event('eip6963:requestProvider'));
function injected() {
  if (window.aether) announce({ provider: window.aether, info: { name: 'EastSea wallet' } });
  if (window.ethereum) announce({ provider: window.ethereum, info: { name: 'Injected wallet' } });
  renderWallets();
}
setTimeout(injected, 150);
window.addEventListener('aether#initialized', injected);
window.addEventListener('ethereum#initialized', injected);

async function validateWallet(selected) {
  const accounts = await selected.request({ method: 'eth_accounts' });
  if (!Array.isArray(accounts) || typeof accounts[0] !== 'string' || accounts[0].toLowerCase() !== CONFIG.sender) throw failure(4100, 'Select the requested account in your wallet, then reconnect.');
  const chain = normalizeChain(await selected.request({ method: 'eth_chainId' }));
  if (chain !== CONFIG.chain_id) throw failure(4901, 'Wallet chain differs from the publisher. Change the network in your wallet, then reconnect.');
  return { accounts, chain };
}
async function connect(selected) {
  if (connecting || (running && !stopped)) { status.textContent = 'A request session is already running. Its wallet cannot be changed here.'; return; }
  if (!TOKEN) { status.textContent = 'This URL has no session token. Use the complete URL printed by the publisher.'; return; }
  connecting = true;
  try {
    await selected.request({ method: 'eth_requestAccounts' });
    await validateWallet(selected);
    provider = selected; connected = true; stopped = false;
    status.textContent = 'Connected. The wallet will ask you to approve each transaction.';
    await poll();
  } catch (error) { status.textContent = error.message || String(error); }
  finally { connecting = false; }
}
async function post(path, payload) {
  const response = await fetch(path, { method: 'POST', credentials: 'omit', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN }, body: JSON.stringify(payload) });
  if (!response.ok) throw new Error('Local publisher refused the relay (' + response.status + '). Do not resend an uncertain transaction; inspect your wallet.');
  return response.json();
}
async function handle(request) {
  const selected = provider;
  const params = request.params || [];
  const tx = request.method === 'eth_sendTransaction' ? params[0] : null;
  summary.textContent = JSON.stringify(tx ? { id: request.id, method: request.method, from: tx.from, chain: CONFIG.chain_id,
    to: tx.to || '(contract creation)', value: tx.value || '0x0', data: { bytes: (tx.data.length - 2) / 2, prefix: tx.data.slice(0, 258) } }
    : { id: request.id, method: request.method, from: CONFIG.sender, chain: CONFIG.chain_id }, null, 2);
  status.textContent = tx ? 'Waiting for your wallet approval. Check the account, chain, transaction and B5 fee in your wallet.' : 'Checking wallet connection…';
  let current;
  try {
    current = await validateWallet(selected);
    if (request.method === 'eth_sendTransaction' && (!tx || tx.from?.toLowerCase() !== CONFIG.sender || Object.keys(tx).some((key) => !['from', 'to', 'value', 'data'].includes(key)))) throw failure(-32602, 'Invalid publisher transaction.');
    if (!['eth_accounts', 'eth_chainId', 'eth_sendTransaction'].includes(request.method)) throw failure(4200, 'The local publisher does not support this wallet method.');
  } catch (error) {
    // No send was dispatched: the publisher can safely clear this intent and retry.
    return { id: request.id, error: { code: -32602, message: error.message || String(error) } };
  }
  if (request.method === 'eth_accounts') return { id: request.id, result: current.accounts };
  if (request.method === 'eth_chainId') return { id: request.id, result: current.chain };
  try {
    const result = await selected.request({ method: 'eth_sendTransaction', params: [tx] });
    return { id: request.id, result };
  } catch (error) { return { id: request.id, error: { code: Number.isInteger(error.code) ? error.code : -32603, message: error.message || String(error) } }; }
}
async function poll() {
  if (running) return;
  running = true;
  try {
    while (connected && !stopped) {
      const reply = await post('/poll', {});
      if (reply.request) {
        awaitingResponse = true;
        const result = await handle(reply.request);
        await post('/result', result);
        awaitingResponse = false;
        status.textContent = result.error ? result.error.message : 'Response returned to the publisher. Waiting for its next request.';
      } else if (reply.state === 'delivered') {
        awaitingResponse = true;
        status.textContent = 'A request was already delivered to a page. Refreshing cannot deliver it again. Keep that page open and inspect your wallet if the publisher times out.';
      }
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  } catch (error) {
    stopped = true; connected = false;
    status.textContent = 'Relay stopped: ' + (error.message || error) + (awaitingResponse ? ' Transaction outcome may be unknown. Never approve a duplicate without checking your wallet.' : ' Check the publisher terminal for its result. No request is retried.');
  } finally { running = false; }
}
if (!TOKEN) status.textContent = 'Use the complete URL printed by the publisher, including its session token.';
</script></body></html>"""


class BrowserWallet:
    """A temporary, user-opened browser connection implementing request()."""

    def __init__(self, sender, chain_id, timeout=300):
        if not isinstance(sender, str) or not _ADDRESS.fullmatch(sender) or int(sender, 16) == 0:
            raise ValueError("sender must be a nonzero 20-byte account address")
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("timeout must be positive and finite")
        self.sender, self.chain_id, self.timeout = sender.lower(), _chain_id(chain_id), float(timeout)
        self._token, self._nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(18)
        self._condition, self._queue, self._closed = threading.Condition(), deque(), False
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._server.daemon_threads = True
        self._host = f"127.0.0.1:{self._server.server_port}"
        self.origin = f"http://{self._host}"
        self.url = f"{self.origin}/#token={self._token}"
        config = json.dumps({"sender": self.sender, "chain_id": self.chain_id}, separators=(",", ":"))
        self._page = _PAGE.replace("__NONCE__", self._nonce).replace("__CONFIG__", config).encode("utf-8")
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self._thread.start()
        print(f"Open this URL in your wallet-enabled browser (no browser is launched):\n{self.url}", file=sys.stderr, flush=True)

    def _handler(self):
        wallet = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(5)

            def log_message(self, *_args):
                pass  # Never log the session credential or transaction data.

            def reply(self, code, value=None, *, html=False):
                body = wallet._page if html else json.dumps(value, separators=(",", ":")).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "text/html; charset=utf-8" if html else "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Referrer-Policy", "same-origin")
                self.send_header("Connection", "close")
                if html:
                    self.send_header("Content-Security-Policy", f"default-src 'none'; script-src 'nonce-{wallet._nonce}' chrome-extension: safari-web-extension:; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
                self.end_headers()
                self.wfile.write(body)

            def allowed(self, *, authenticated):
                hosts, origins = self.headers.get_all("Host", []), self.headers.get_all("Origin", [])
                if hosts != [wallet._host] or (origins != [wallet.origin] if authenticated else origins not in ([], [wallet.origin])):
                    self.reply(403, {"error": "Invalid local origin"}); return False
                if authenticated:
                    auth = self.headers.get_all("Authorization", [])
                    if len(auth) != 1 or not secrets.compare_digest(auth[0], "Bearer " + wallet._token):
                        self.reply(403, {"error": "Invalid local session"}); return False
                return True

            def do_GET(self):
                if not self.allowed(authenticated=False):
                    return
                if self.path != "/":
                    self.reply(404, {"error": "Not found"}); return
                self.reply(200, html=True)

            def do_POST(self):
                if not self.allowed(authenticated=True):
                    return
                if self.path not in {"/poll", "/result"}:
                    self.reply(404, {"error": "Not found"}); return
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 65536 or self.headers.get("Transfer-Encoding") or self.headers.get("Content-Type") != "application/json":
                    self.reply(400, {"error": "Invalid JSON request"}); return
                try:
                    message = json.loads(self.rfile.read(int(lengths[0])))
                except (ValueError, UnicodeError, OSError):
                    self.reply(400, {"error": "Invalid JSON request"}); return
                if not isinstance(message, dict):
                    self.reply(400, {"error": "Expected a JSON object"}); return
                with wallet._condition:
                    if wallet._closed:
                        self.reply(410, {"error": "Wallet relay closed"}); return
                    pending = wallet._queue[0] if wallet._queue else None
                    if self.path == "/poll":
                        if message:
                            self.reply(400, {"error": "Poll must be empty"}); return
                        if pending and not pending["delivered"]:
                            pending["delivered"] = True
                            self.reply(200, {"request": pending["request"], "state": "delivered"})
                        else:
                            self.reply(200, {"request": None, "state": "delivered" if pending else "idle"})
                        return
                    if not pending or not pending["delivered"] or message.get("id") != pending["request"]["id"]:
                        self.reply(409, {"error": "No matching delivered request"}); return
                    if set(message) not in ({"id", "result"}, {"id", "error"}):
                        self.reply(400, {"error": "Provide exactly one result or error"}); return
                    error = message.get("error")
                    if "error" in message and (not isinstance(error, dict) or not isinstance(error.get("code"), int) or isinstance(error["code"], bool) or not isinstance(error.get("message"), str)):
                        self.reply(400, {"error": "Invalid wallet error"}); return
                    pending["reply"] = message
                    wallet._queue.popleft()
                    wallet._condition.notify_all()
                    self.reply(200, {"accepted": True})

        return Handler

    def request(self, method, params=None):
        if method not in _METHODS:
            raise WalletBridgeError(f"Browser wallet relay does not support {method}", code=4200)
        if params is None:
            params = []
        if not isinstance(params, list):
            raise WalletBridgeError("Wallet params must be an array", code=-32602)
        if method == "eth_sendTransaction":
            if len(params) != 1 or not isinstance(params[0], dict):
                raise WalletBridgeError("eth_sendTransaction requires one transaction", code=-32602)
            tx = params[0]
            if set(tx) - {"from", "to", "data", "value"} or str(tx.get("from", "")).lower() != self.sender:
                raise WalletBridgeError("Transaction must use the requested sender and wallet-owned fees/signing", code=-32602)
            if "to" in tx and (not isinstance(tx["to"], str) or not _ADDRESS.fullmatch(tx["to"])):
                raise WalletBridgeError("Invalid transaction recipient", code=-32602)
            if not isinstance(tx.get("data"), str) or len(tx["data"]) > 2 * 1024 * 1024 or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", tx["data"]):
                raise WalletBridgeError("Transaction data must be hex bytes within 1 MiB", code=-32602)
            if "to" not in tx and tx["data"] == "0x":
                raise WalletBridgeError("Contract creation requires init code", code=-32602)
            if "value" in tx and (not isinstance(tx["value"], str) or not re.fullmatch(r"0x[0-9a-fA-F]+", tx["value"]) or int(tx["value"], 16) >= 2 ** 256):
                raise WalletBridgeError("Transaction value must be a 256-bit hex quantity", code=-32602)
        elif params:
            raise WalletBridgeError(f"{method} takes no parameters", code=-32602)
        # Snapshot the transaction; a caller cannot mutate an intent after queueing it.
        params = json.loads(json.dumps(params))
        pending = {"request": {"id": secrets.token_hex(16), "method": method, "params": params}, "delivered": False, "reply": _UNSET}
        deadline = time.monotonic() + self.timeout
        with self._condition:
            if self._closed:
                raise WalletBridgeError("Browser wallet relay is closed")
            self._queue.append(pending)
            while pending["reply"] is _UNSET and not self._closed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._condition.wait(remaining)
            reply = pending["reply"]
            closed = self._closed
        if reply is _UNSET:
            self.close()
            reason = "closed" if closed else "timed out"
            raise WalletBridgeError(f"Browser wallet request {method} {reason}; outcome unknown. Inspect your wallet before recovery; the request will never be redelivered.", code=-32000, outcome_unknown=True)
        if "error" in reply:
            raise WalletBridgeError(reply["error"]["message"], code=reply["error"]["code"])
        return reply["result"]

    def close(self):
        with self._condition:
            if self._closed:
                return
            self._closed = True
            self._condition.notify_all()
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
