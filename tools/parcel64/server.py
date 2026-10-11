#!/usr/bin/env python3
"""Parcel64: temporary, resumable 64 MiB chunk uploads. Files are untrusted data, never executed."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent
STORE = Path(os.environ.get('UPLOAD_DIR', str(Path.home() / '.cache' / 'arena-uploads')))
STORE.mkdir(parents=True, exist_ok=True, mode=0o700)
LIMIT = 500 * 1024 * 1024
CHUNK = 64 * 1024 * 1024
CODE = os.environ.get('UPLOAD_CODE') or secrets.token_hex(8)
SESSIONS = {}
LOCK = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.connection.settimeout(180)

    def log_message(self, fmt, *args):
        # Do not log authorization codes or original file names.
        print('%s %s' % (self.command, self.path.split('?')[0]), flush=True)

    def reply(self, code, data, content_type='application/json; charset=utf-8'):
        raw = json.dumps(data, ensure_ascii=False).encode() if isinstance(data, dict) else data
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def error(self, code, message):
        # Discard the connection rather than interpreting an unread body as HTTP.
        self.close_connection = True
        self.reply(code, {'error': message})

    def authorized(self):
        if not secrets.compare_digest(self.headers.get('X-Upload-Code', '').encode(), CODE.encode()):
            self.error(401, 'Неверный код доступа.')
            return False
        return True

    def length(self, maximum):
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('Нужен Content-Length.')
        length = int(self.headers.get('Content-Length', '-1'))
        if not 0 <= length <= maximum:
            raise ValueError('Недопустимый размер запроса.')
        return length

    def session(self):
        match = re.fullmatch(r'/api/uploads/([a-f0-9]{32})(/complete)?', self.path)
        if not match:
            self.error(404, 'Не найдено.')
            return None
        with LOCK:
            session = SESSIONS.get(match[1])
        if session is None:
            self.error(404, 'Загрузка не найдена. Начните заново.')
        return session

    @staticmethod
    def info(s):
        return {k: s[k] for k in ('id', 'name', 'size', 'offset', 'done', 'sha256', 'saved_as')}

    def do_GET(self):
        if self.path == '/':
            return self.reply(200, (ROOT / 'index.html').read_bytes(), 'text/html; charset=utf-8')
        if self.path == '/diagnostics':
            return self.reply(200, (ROOT / 'diagnostics.html').read_bytes(), 'text/html; charset=utf-8')
        if self.path == '/favicon.ico':
            return self.reply(204, b'')
        if not self.authorized():
            return
        if self.path == '/api/config':
            return self.reply(200, {'limit': LIMIT, 'chunk': CHUNK, 'mode': 'chunked'})
        s = self.session()
        if s:
            with s['lock']:
                self.reply(200, self.info(s))

    def do_POST(self):
        if not self.authorized():
            return
        if self.path == '/api/probe-report':
            try:
                length = self.length(16384)
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict) or data.get('version') != 1:
                    raise ValueError('Invalid report')
                # Diagnostic results only; no upload payload is saved.
                report = STORE / 'probe-report.json'
                temporary = STORE / 'probe-report.tmp'
                with LOCK:
                    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2))
                    temporary.replace(report)
                return self.reply(200, {'ok': True})
            except (OSError, ValueError):
                return self.error(400, 'Не удалось сохранить отчёт.')
        try:
            length = self.length(4096)
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError('Неполный запрос.')
            if self.path == '/api/uploads':
                data = json.loads(raw)
                name, size = data.get('name'), data.get('size')
                if not isinstance(name, str) or not name or len(name) > 255:
                    raise ValueError('Недопустимое имя файла.')
                if type(size) is not int or not 0 <= size <= LIMIT:
                    raise ValueError('Максимальный размер файла — 500 МиБ.')
                with LOCK:
                    active = [s for s in SESSIONS.values() if not s['done']]
                    if len(active) >= 8:
                        return self.error(429, 'Слишком много незавершённых загрузок. Отмените лишние.')
                    reserved = sum(s['size'] - s['offset'] for s in active)
                    if shutil.disk_usage(STORE).free < size + reserved + 512 * 1024 * 1024:
                        return self.error(507, 'Недостаточно свободного места.')
                    uid = secrets.token_hex(16)
                    # Strip paths and unsafe characters. Prefix prevents overwrite.
                    safe = re.sub(r'[^\w.() -]', '_', name.replace('\\', '/').split('/')[-1])[:100].strip(' .') or 'file'
                    safe = safe.encode('utf-8')[:180].decode('utf-8', errors='ignore')
                    saved_as = uid + '_' + safe
                    path = STORE / (uid + '.part')
                    path.touch(mode=0o600, exist_ok=False)
                    s = dict(id=uid, name=name, size=size, offset=0, done=False,
                             sha256=None, saved_as=saved_as, path=path,
                             hash=hashlib.sha256(), lock=threading.Lock())
                    SESSIONS[uid] = s
                return self.reply(201, self.info(s))
            if not self.path.endswith('/complete'):
                return self.error(404, 'Не найдено.')
            s = self.session()
            if s:
                with s['lock']:
                    if not s['done']:
                        if s['offset'] != s['size']:
                            return self.error(409, 'Файл ещё не полностью получен.')
                        digest = s['hash'].hexdigest()
                        final = STORE / s['saved_as']
                        metadata = self.info(s) | {'done': True, 'sha256': digest}
                        with s['path'].open('rb') as f:
                            os.fsync(f.fileno())
                        s['path'].rename(final)
                        final.with_name(final.name + '.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
                        s['path'], s['done'], s['sha256'] = final, True, digest
                    return self.reply(200, self.info(s))
        except (ValueError, TypeError, AttributeError):
            self.error(400, 'Некорректный запрос или размер файла. Лимит — 500 МиБ.')
        except OSError:
            self.error(507, 'Ошибка записи на диск или соединение прервано.')

    def do_PUT(self):
        if not self.authorized():
            return
        if self.path == '/api/probe':
            try:
                length = self.length(LIMIT)
                remaining = length
                while remaining:
                    block = self.rfile.read(min(65536, remaining))
                    if not block:
                        raise OSError('Disconnected')
                    remaining -= len(block)
                return self.reply(200, {'received': length})
            except ValueError:
                return self.error(400, 'Недопустимый размер тестового запроса.')
            except OSError:
                return self.error(408, 'Передача тестовых данных прервана.')
        s = self.session()
        if not s:
            return
        with s['lock']:
            try:
                length = self.length(CHUNK)
                offset = int(self.headers.get('X-Offset', '-1'))
                if s['done'] or offset != s['offset']:
                    return self.error(409, 'Смещение изменилось. Проверьте принятый размер перед повтором.')
                if length == 0 or offset + length > s['size']:
                    return self.error(400, 'Недопустимый размер части или выход за границу файла.')
                digest = s['hash'].copy()
                with s['path'].open('r+b') as f:
                    f.seek(offset)
                    try:
                        remaining = length
                        while remaining:
                            block = self.rfile.read(min(65536, remaining))
                            if not block:
                                raise OSError('Disconnected')
                            f.write(block)
                            digest.update(block)
                            remaining -= len(block)
                        f.flush()
                    except BaseException:
                        f.truncate(offset)
                        raise
                s['hash'], s['offset'] = digest, offset + length
                self.reply(200, self.info(s))
            except ValueError:
                self.error(400, 'Некорректный размер запроса.')
            except OSError:
                self.error(507, 'Не удалось получить часть. Повторите её с подтверждённого смещения.')

    def do_DELETE(self):
        if not self.authorized():
            return
        s = self.session()
        if s:
            with s['lock']:
                if s['done']:
                    return self.error(409, 'Завершённый файл не удаляется этим запросом.')
                s['path'].unlink(missing_ok=True)
                with LOCK:
                    SESSIONS.pop(s['id'], None)
                self.reply(200, {'ok': True})

if __name__ == '__main__':
    print(f'Upload code: {CODE}', flush=True)
    print(f'Storage: {STORE}; limit {LIMIT} bytes; chunk {CHUNK} bytes', flush=True)
    ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('PORT', '8080'))), Handler).serve_forever()
