#!/usr/bin/env python3
"""Authenticated, single-session PTY console for a trusted sandbox owner.

This is remote shell access, NOT an additional security boundary. Do not expose
it without HTTPS or share its access key. Transport is same-origin HTTP polling.
"""
import base64
import binascii
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import secrets
import select
import signal
import struct
import termios
import threading
import time
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
WORKDIR = Path(os.environ.get('TERMINAL_CWD', str(ROOT.parent.parent))).resolve()
KEY = os.environ.get('TERMINAL_ACCESS_KEY') or secrets.token_hex(16)
BUFFER_SIZE = 2 * 1024 * 1024
IDLE_SECONDS = 30 * 60
SESSION = None
SESSION_LOCK = threading.Lock()
ASSETS = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/terminal.js': ('terminal.js', 'text/javascript; charset=utf-8'),
    '/xterm.js': ('node_modules/@xterm/xterm/lib/xterm.js', 'text/javascript'),
    '/fit.js': ('node_modules/@xterm/addon-fit/lib/addon-fit.js', 'text/javascript'),
    '/xterm.css': ('node_modules/@xterm/xterm/css/xterm.css', 'text/css'),
}


class Shell:
    def __init__(self):
        self.id = secrets.token_hex(16)
        self.changed = threading.Condition()
        self.io_lock = threading.Lock()
        self.buffer = bytearray()
        self.start = 0
        self.closed = False
        self.last_seen = time.monotonic()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(WORKDIR)
                os.environ.pop('TERMINAL_ACCESS_KEY', None)
                os.environ.update(TERM='xterm-256color', COLORTERM='truecolor', HISTFILE='/dev/null')
                os.execv('/bin/bash', ['bash', '--noprofile', '--norc', '-i'])
            except BaseException:
                os._exit(127)
        os.set_blocking(self.fd, False)
        self.resize(100, 28)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while not self.closed:
                if time.monotonic() - self.last_seen > IDLE_SECONDS:
                    break
                if not select.select([self.fd], [], [], 1)[0]:
                    continue
                data = os.read(self.fd, 65536)
                if not data:
                    break
                with self.changed:
                    self.buffer.extend(data)
                    extra = max(0, len(self.buffer) - BUFFER_SIZE)
                    if extra:
                        del self.buffer[:extra]
                        self.start += extra
                    self.changed.notify_all()
        except (OSError, ValueError):
            pass
        finally:
            self.close()

    def close(self):
        with self.io_lock:
            if self.closed:
                return
            self.closed = True
            # Closing the PTY sends hangup to the foreground job. Also stop
            # processes still in this shell's session (not unrelated services).
            processes = []
            for path in Path('/proc').glob('[0-9]*/stat'):
                try:
                    fields = path.read_text().rsplit(')', 1)[1].split()
                    if int(fields[3]) == self.pid:
                        processes.append(int(path.parent.name))
                except (OSError, ValueError, IndexError):
                    continue
            try:
                os.close(self.fd)
            except OSError:
                pass
            for pid in processes:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        with self.changed:
            self.changed.notify_all()

    def write(self, data):
        self.last_seen = time.monotonic()
        with self.io_lock:
            if self.closed:
                raise ValueError('Терминал закрыт.')
            view = memoryview(data)
            deadline = time.monotonic() + 5
            while view:
                if time.monotonic() > deadline:
                    raise ValueError('Ввод заблокирован процессом. Часть ввода могла быть передана.')
                if select.select([], [self.fd], [], 0.2)[1]:
                    view = view[os.write(self.fd, view[:4096]):]

    def resize(self, cols, rows):
        with self.io_lock:
            if not self.closed:
                fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def output(self, cursor):
        self.last_seen = time.monotonic()
        with self.changed:
            if cursor < 0 or cursor > self.start + len(self.buffer):
                raise ValueError('Некорректная позиция вывода.')
            if cursor == self.start + len(self.buffer) and not self.closed:
                self.changed.wait(timeout=10)
            dropped = cursor < self.start
            cursor = max(cursor, self.start)
            data = bytes(self.buffer[cursor-self.start:cursor-self.start+65536])
            return dict(data=base64.b64encode(data).decode(), cursor=cursor+len(data),
                        dropped=dropped, closed=self.closed,
                        drained=cursor+len(data) == self.start+len(self.buffer))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.connection.settimeout(20)

    def log_message(self, *args):
        # Never log keys, terminal input or output.
        pass

    def reply(self, status, value, mime='application/json; charset=utf-8'):
        data = json.dumps(value, ensure_ascii=False).encode() if isinstance(value, dict) else value
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def error(self, status, message):
        self.close_connection = True
        self.reply(status, {'error': message})

    def auth(self):
        if not secrets.compare_digest(self.headers.get('X-Terminal-Key', '').encode(), KEY.encode()):
            self.error(401, 'Неверный код доступа.')
            return False
        return True

    def current(self, session_id):
        with SESSION_LOCK:
            if SESSION is None or SESSION.id != session_id:
                raise ValueError('Сессия не найдена. Подключитесь заново.')
            return SESSION

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path in ASSETS:
            path, mime = ASSETS[url.path]
            try:
                return self.reply(200, (ROOT / path).read_bytes(), mime)
            except FileNotFoundError:
                return self.error(503, 'Не установлены ресурсы терминала. Выполните npm ci.')
        if not self.auth():
            return
        if url.path != '/api/output':
            return self.error(404, 'Не найдено.')
        try:
            query = parse_qs(url.query)
            shell = self.current(query['session'][0])
            self.reply(200, shell.output(int(query['cursor'][0])))
        except (KeyError, ValueError):
            self.error(400, 'Некорректная сессия или позиция вывода.')

    def do_POST(self):
        global SESSION
        if not self.auth():
            return
        try:
            length = int(self.headers.get('Content-Length', '-1'))
            if self.headers.get('Transfer-Encoding') or not 0 <= length <= 32768:
                raise ValueError('Недопустимый размер запроса.')
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError('Ожидается JSON-объект.')
            if self.path == '/api/open':
                with SESSION_LOCK:
                    if SESSION is None or SESSION.closed:
                        SESSION = Shell()
                    SESSION.last_seen = time.monotonic()
                    return self.reply(200, {'session': SESSION.id, 'cwd': str(WORKDIR)})
            shell = self.current(data.get('session'))
            if self.path == '/api/input':
                payload = base64.b64decode(data['data'], validate=True)
                if len(payload) > 16384:
                    raise ValueError('Слишком большой ввод.')
                shell.write(payload)
            elif self.path == '/api/resize':
                cols, rows = data.get('cols'), data.get('rows')
                if type(cols) is not int or type(rows) is not int or not (10 <= cols <= 500 and 2 <= rows <= 200):
                    raise ValueError('Некорректный размер терминала.')
                shell.resize(cols, rows)
            elif self.path == '/api/close':
                shell.close()
            else:
                return self.error(404, 'Не найдено.')
            self.reply(200, {'ok': True})
        except (ValueError, KeyError, TypeError, binascii.Error) as error:
            self.error(400, str(error))
        except OSError:
            self.error(500, 'Ошибка работы терминала.')


if __name__ == '__main__':
    if not WORKDIR.is_dir():
        raise SystemExit('TERMINAL_CWD must point to an existing directory')
    for filename, _ in ASSETS.values():
        if not (ROOT / filename).is_file():
            raise SystemExit('Missing browser assets. Run npm ci in tools/web-terminal.')
    server = ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('PORT', '8081'))), Handler)
    def stop_server(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_server)
    print(f'Terminal access key: {KEY}', flush=True)
    print(f'Initial directory: {WORKDIR}; port {server.server_port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if SESSION:
            SESSION.close()
