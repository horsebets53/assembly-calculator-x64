import base64
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

os.environ['TERMINAL_ACCESS_KEY'] = 'test-only-key'
TEMP = tempfile.TemporaryDirectory(prefix='terminal-test-')
os.environ['TERMINAL_CWD'] = TEMP.name
import server


class TerminalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        cls.worker = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        if server.SESSION:
            server.SESSION.close()
        cls.http.shutdown()
        cls.http.server_close()
        cls.worker.join()
        TEMP.cleanup()

    def request(self, method, path, body=None, key='test-only-key'):
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=15)
        headers = {'X-Terminal-Key': key}
        conn.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = conn.getresponse()
        status, raw = response.status, response.read()
        conn.close()
        return status, json.loads(raw) if raw.startswith(b'{') else raw

    def send(self, sid, value):
        status, _ = self.request('POST', '/api/input', {'session': sid, 'data': base64.b64encode(value).decode()})
        self.assertEqual(status, 200)

    def until(self, sid, cursor, token):
        output = b''
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            status, data = self.request('GET', f'/api/output?session={sid}&cursor={cursor}')
            self.assertEqual(status, 200)
            output += base64.b64decode(data['data'])
            cursor = data['cursor']
            if token in output:
                return cursor, output
        self.fail(f'Did not see expected output {token!r}, got {output!r}')

    def test_authentication(self):
        self.assertEqual(self.request('GET', '/')[0], 200)
        self.assertEqual(self.request('POST', '/api/open', {}, key='wrong')[0], 401)
        self.assertEqual(self.request('GET', '/api/output?session=x&cursor=0', key='wrong')[0], 401)

    def test_real_pty(self):
        status, data = self.request('POST', '/api/open', {})
        self.assertEqual(status, 200)
        sid = data['session']
        self.assertEqual(self.request('POST', '/api/open', {})[1]['session'], sid)
        self.send(sid, b"printf '\\nTERMINAL_OK\\n'\r")
        cursor, _ = self.until(sid, 0, b'\r\nTERMINAL_OK\r\n')
        self.send(sid, b"mkdir child; cd child; pwd\r")
        cursor, _ = self.until(sid, cursor, str(Path(TEMP.name)/'child').encode()+b'\r\n')
        status, _ = self.request('POST', '/api/resize', {'session':sid,'cols':90,'rows':27})
        self.assertEqual(status, 200)
        self.send(sid, b'stty size\r')
        cursor, _ = self.until(sid, cursor, b'27 90\r\n')
        self.send(sid, b"printf '\\nWAITING\\n'; sleep 30\r")
        cursor, _ = self.until(sid, cursor, b'\r\nWAITING\r\n')
        self.send(sid, b'\x03')
        self.send(sid, b"printf '\\nINTERRUPTED_OK\\n'\r")
        cursor, _ = self.until(sid, cursor, b'\r\nINTERRUPTED_OK\r\n')
        self.assertEqual(self.request('POST', '/api/input', {'session':'stale','data':''})[0], 400)
        self.assertEqual(self.request('POST', '/api/close', {'session':sid})[0], 200)
        self.assertTrue(server.SESSION.closed)
        self.assertEqual(self.request('GET', f'/api/output?session={sid}&cursor={cursor}')[1]['closed'], True)

    def test_static_assets_and_bounds(self):
        for url in ['/xterm.js', '/fit.js', '/terminal.js', '/xterm.css']:
            self.assertEqual(self.request('GET', url)[0], 200)
        sid = self.request('POST', '/api/open', {})[1]['session']
        self.assertEqual(self.request('POST', '/api/resize', {'session':sid,'cols':1,'rows':1})[0], 400)
        self.assertEqual(self.request('POST', '/api/input', {'session':sid,'data':'not-base64'})[0], 400)
        self.request('POST', '/api/close', {'session':sid})


if __name__ == '__main__':
    unittest.main(verbosity=2)
