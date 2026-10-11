import hashlib
import http.client
import json
import os
from pathlib import Path
import tempfile
import socket
import threading
import unittest

TEMP = tempfile.TemporaryDirectory(prefix='parcel64-test-')
os.environ['UPLOAD_DIR'] = TEMP.name
os.environ['UPLOAD_CODE'] = 'test-code'
import server

class QuietHandler(server.Handler):
    def log_message(self, *args):
        pass

class UploadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = server.ThreadingHTTPServer(('127.0.0.1', 0), QuietHandler)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()
        TEMP.cleanup()

    def request(self, method, path, data=None, extra=None, code='test-code'):
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=30)
        headers = {'X-Upload-Code': code}
        if method == 'PUT' and path.startswith('/api/uploads/'):
            headers['X-Offset'] = '0'
        if extra:
            headers.update(extra)
        if isinstance(data, dict):
            data = json.dumps(data).encode()
        conn.request(method, path, body=data, headers=headers)
        response = conn.getresponse()
        body = response.read()
        status = response.status
        conn.close()
        return status, json.loads(body) if body.startswith(b'{') else body

    def create(self, name, size):
        status, body = self.request('POST', '/api/uploads', {'name': name, 'size': size})
        self.assertEqual(status, 201, body)
        return body['id']

    def test_auth(self):
        self.assertEqual(self.request('GET', '/api/config', code='')[0], 401)
        self.assertEqual(self.request('GET', '/api/config')[0], 200)
        self.assertEqual(self.request('GET', '/')[0], 200)

    def test_limit_and_bad_size(self):
        for size in [server.LIMIT+1, -1, True, '5']:
            self.assertEqual(self.request('POST', '/api/uploads', {'name': 'x', 'size': size})[0], 400)

    def test_upload_and_hash_and_path_safety(self):
        uid = self.create('../../тест.txt', 6)
        url = '/api/uploads/' + uid
        self.assertEqual(self.request('POST', url+'/complete', {})[0], 409)
        self.assertEqual(self.request('PUT', url, b'abc', {'X-Offset': '1'})[0], 409)
        self.assertEqual(self.request('GET', url)[1]['offset'], 0)
        self.assertEqual(self.request('PUT', url, b'abc')[0], 200)
        self.assertEqual(self.request('PUT', url, b'abc')[0], 409)
        self.assertEqual(self.request('PUT', url, b'def', {'X-Offset': '3'})[0], 200)
        self.assertEqual(self.request('GET', url)[1]['offset'], 6)
        status, info = self.request('POST', url+'/complete', {})
        self.assertEqual(status, 200)
        self.assertEqual(info['sha256'], hashlib.sha256(b'abcdef').hexdigest())
        self.assertEqual((server.STORE/info['saved_as']).read_bytes(), b'abcdef')
        self.assertEqual((server.STORE/info['saved_as']).parent, server.STORE)
        self.assertEqual(self.request('POST', url+'/complete', {})[1]['sha256'], info['sha256'])

    def test_empty_and_cancel(self):
        uid = self.create('empty', 0)
        self.assertEqual(self.request('PUT', f'/api/uploads/{uid}', b'')[0], 400)
        self.assertEqual(self.request('POST', f'/api/uploads/{uid}/complete', {})[1]['sha256'], hashlib.sha256(b'').hexdigest())
        uid = self.create('cancel', 40)
        self.assertEqual(self.request('DELETE', f'/api/uploads/{uid}')[0], 200)
        self.assertFalse((server.STORE/(uid+'.part')).exists())
        self.assertEqual(self.request('GET', f'/api/uploads/{uid}')[0], 404)

    def test_interrupted_request_can_restart(self):
        uid = self.create('interrupted', 9)
        url = '/api/uploads/' + uid
        self.assertEqual(self.request('PUT', url, b'abc')[0], 200)
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=10)
        conn.putrequest('PUT', url)
        conn.putheader('X-Upload-Code', 'test-code')
        conn.putheader('Content-Length', '6')
        conn.putheader('X-Offset', '3')
        conn.endheaders()
        conn.send(b'def')
        conn.sock.shutdown(socket.SHUT_WR)
        response = conn.getresponse()
        response.read()
        self.assertEqual(response.status, 507)
        conn.close()
        self.assertEqual(self.request('GET', url)[1]['offset'], 3)
        self.assertEqual((server.STORE/(uid+'.part')).read_bytes(), b'abc')
        self.assertEqual(self.request('PUT', url, b'defghi', {'X-Offset': '3'})[0], 200)
        self.assertEqual(self.request('POST', url+'/complete', {})[1]['sha256'], hashlib.sha256(b'abcdefghi').hexdigest())

    def test_proxy_probe_and_report(self):
        self.assertEqual(self.request('GET', '/diagnostics')[0], 200)
        self.assertEqual(self.request('PUT', '/api/probe', b'abc', code='wrong')[0], 401)
        before = set(server.STORE.iterdir())
        status, data = self.request('PUT', '/api/probe', b'x' * (5*1024*1024))
        self.assertEqual(status, 200)
        self.assertEqual(data['received'], 5*1024*1024)
        self.assertEqual(set(server.STORE.iterdir()), before)
        report = {'version': 1, 'tests': [{'bytes': 5*1024*1024, 'status': 200}]}
        self.assertEqual(self.request('POST', '/api/probe-report', report)[0], 200)
        self.assertEqual(json.loads((server.STORE/'probe-report.json').read_text()), report)

    def test_chunk_limit(self):
        self.assertEqual(self.request('GET', '/api/config')[1]['chunk'], 64*1024*1024)
        uid = self.create('oversized-chunk', server.LIMIT)
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=10)
        conn.putrequest('PUT', '/api/uploads/' + uid)
        conn.putheader('X-Upload-Code', 'test-code')
        conn.putheader('X-Offset', '0')
        conn.putheader('Content-Length', str(server.CHUNK+1))
        conn.endheaders()
        response = conn.getresponse()
        self.assertEqual(response.status, 400)
        response.read()
        conn.close()
        self.assertEqual(self.request('GET', '/api/uploads/'+uid)[1]['offset'], 0)
        self.request('DELETE', '/api/uploads/'+uid)

    def test_full_500_mib(self):
        uid = self.create('500MiB.bin', server.LIMIT)
        url = '/api/uploads/' + uid
        # Eight sequential HTTP requests: seven 64 MiB chunks, then 52 MiB.
        # Stream from a 1 MiB buffer; do not allocate the entire test file.
        block = bytes(range(256)) * (1024 * 1024 // 256)
        expected = hashlib.sha256()
        sizes = []
        for offset in range(0, server.LIMIT, server.CHUNK):
            length = min(server.CHUNK, server.LIMIT-offset)
            sizes.append(length)
            conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=30)
            conn.putrequest('PUT', url)
            conn.putheader('X-Upload-Code', 'test-code')
            conn.putheader('X-Offset', str(offset))
            conn.putheader('Content-Length', str(length))
            conn.endheaders()
            remaining = length
            while remaining:
                data = block[:min(len(block), remaining)]
                conn.send(data)
                expected.update(data)
                remaining -= len(data)
            response = conn.getresponse()
            info = json.loads(response.read())
            self.assertEqual(response.status, 200, info)
            self.assertEqual(info['offset'], offset+length)
            conn.close()
        self.assertEqual(sizes, [64*1024*1024]*7 + [52*1024*1024])
        status, info = self.request('POST', url+'/complete', {})
        self.assertEqual(status, 200)
        self.assertEqual(info['sha256'], expected.hexdigest())
        self.assertEqual((server.STORE/info['saved_as']).stat().st_size, server.LIMIT)
        print('500 MiB assembled from 8 chunks (64 MiB maximum) and SHA-256 verified:', info['sha256'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
