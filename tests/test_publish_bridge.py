"""Loopback browser-wallet ownership and single-delivery regressions."""

import contextlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
import json
from pathlib import Path
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('wallet_bridge', ROOT / 'scripts/wallet_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BrowserWalletTests(unittest.TestCase):
    def wallet(self, timeout=2):
        with contextlib.redirect_stderr(io.StringIO()):
            wallet = bridge.BrowserWallet('0x' + 'a' * 40, '0x7a69', timeout=timeout)
        self.addCleanup(wallet.close)
        return wallet

    def post(self, wallet, path='/poll', body=None, **overrides):
        token = parse_qs(urlsplit(wallet.url).fragment)['token'][0]
        headers = {'Origin': wallet.origin, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', **overrides}
        data = json.dumps({} if body is None else body).encode()
        request = Request(wallet.origin + path, data=data, headers=headers)
        with urlopen(request, timeout=2) as response:
            self.assertIsNone(response.headers.get('Access-Control-Allow-Origin'))
            return json.load(response)

    def delivered(self, wallet):
        for _ in range(100):
            message = self.post(wallet)
            if message['request']:
                return message['request']
            time.sleep(0.005)
        self.fail('no request was delivered')

    def test_boundaries_and_page(self):
        wallet = self.wallet()
        with urlopen(wallet.origin + '/', timeout=2) as page:
            html = page.read().decode()
            self.assertNotIn(parse_qs(urlsplit(wallet.url).fragment)['token'][0], html)
            self.assertIn('frame-ancestors', page.headers['Content-Security-Policy'])
        for headers in ({'Origin': 'https://foreign.invalid'}, {'Authorization': 'Bearer wrong'}, {'Host': 'evil.invalid'}, {'Origin': 'null'}):
            with self.assertRaises(HTTPError) as caught:
                self.post(wallet, **headers)
            self.assertEqual(caught.exception.code, 403)
        with self.assertRaises(HTTPError) as caught:
            self.post(wallet, path='/etc/passwd')
        self.assertEqual(caught.exception.code, 404)
        with self.assertRaises(HTTPError) as caught:
            urlopen(Request(wallet.origin + '/poll', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=2)
        self.assertEqual(caught.exception.code, 403)

    def test_one_delivery_and_one_response(self):
        wallet = self.wallet()
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(wallet.request, 'eth_accounts')
            request = self.delivered(wallet)
            self.assertIsNone(self.post(wallet)['request'])
            self.assertEqual(self.post(wallet)['state'], 'delivered')
            with self.assertRaises(HTTPError) as caught:
                self.post(wallet, '/result', {'id': 'wrong', 'result': []})
            self.assertEqual(caught.exception.code, 409)
            response = {'id': request['id'], 'result': [wallet.sender]}
            self.assertEqual(self.post(wallet, '/result', response), {'accepted': True})
            self.assertEqual(future.result(timeout=2), [wallet.sender])
            with self.assertRaises(HTTPError) as caught:
                self.post(wallet, '/result', response)
            self.assertEqual(caught.exception.code, 409)

    def test_sequential_queue_and_error(self):
        wallet = self.wallet()
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(wallet.request, 'eth_chainId')
            request = self.delivered(wallet)
            second = pool.submit(wallet.request, 'eth_accounts')
            self.assertIsNone(self.post(wallet)['request'])
            self.post(wallet, '/result', {'id': request['id'], 'result': '0x7a69'})
            self.assertEqual(first.result(timeout=2), '0x7a69')
            request2 = self.delivered(wallet)
            self.assertNotEqual(request['id'], request2['id'])
            self.post(wallet, '/result', {'id': request2['id'], 'error': {'code': 4001, 'message': 'User rejected'}})
            with self.assertRaises(bridge.WalletBridgeError) as caught:
                second.result(timeout=2)
            self.assertEqual(caught.exception.code, 4001)

    def test_rejects_wrong_sender_and_fee_signing_fields(self):
        wallet = self.wallet()
        valid = {'from': wallet.sender, 'to': '0x' + 'b' * 40, 'data': '0x1234', 'value': '0x0'}
        for patch in ({'from': '0x' + 'c' * 40}, {'gasPrice': '0x1'}, {'nonce': '0x1'}, {'privateKey': 'fake'}, {'data': '0x1'}, {'value': '0x' + 'f' * 65}):
            with self.assertRaises(bridge.WalletBridgeError) as caught:
                wallet.request('eth_sendTransaction', [{**valid, **patch}])
            self.assertEqual(caught.exception.code, -32602)
        with self.assertRaises(bridge.WalletBridgeError) as caught:
            wallet.request('personal_sign', [])
        self.assertEqual(caught.exception.code, 4200)
        self.assertIsNone(self.post(wallet)['request'])

    def test_timeout_closes_server_and_never_redelivers(self):
        wallet = self.wallet(timeout=0.15)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(wallet.request, 'eth_sendTransaction', [{'from': wallet.sender, 'data': '0x1234'}])
            self.delivered(wallet)
            with self.assertRaises(bridge.WalletBridgeError) as caught:
                future.result(timeout=2)
            self.assertTrue(caught.exception.outcome_unknown)
            self.assertIn('outcome unknown', str(caught.exception))
        with self.assertRaises((URLError, OSError)):
            self.post(wallet)
        wallet.close()


if __name__ == '__main__':
    unittest.main()
