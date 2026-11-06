"""Private audio-to-text worker. Audio stays on this server and is removed after processing."""
import hmac
import json
import math
import os
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

MAX_BYTES = 200 * 1024 * 1024
MAX_SECONDS = 2 * 60 * 60
BUNDLED_MODELS = '/opt/whisper'
DEFAULT_MODEL = 'large-v3-turbo'


def model_source(name, bundled=BUNDLED_MODELS):
    """The model baked into the image when it matches, so the server needs no download."""
    path = os.path.join(bundled, name)
    if os.path.isfile(os.path.join(path, 'model.bin')):
        return path
    return name


def transcript(segments):
    plain, synced = [], []
    for segment in segments:
        text = ' '.join(segment.text.split())
        if not text or not math.isfinite(segment.start) or segment.start < 0:
            continue
        ticks = round(segment.start * 100)
        minutes, remainder = divmod(ticks, 6000)
        seconds, centiseconds = divmod(remainder, 100)
        plain.append(text)
        synced.append(f'[{minutes:02d}:{seconds:02d}.{centiseconds:02d}]{text}')
        if len('\n'.join(plain).encode()) > 65536 or len('\n'.join(synced).encode()) > 131072:
            raise ValueError('transcript too large')
    if not plain:
        raise ValueError('no speech')
    return {'plain': '\n'.join(plain), 'synced': '\n'.join(synced)}


def make_handler(model, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log headers or audio contents.

        def reply(self, status, body):
            payload = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path != '/health':
                self.reply(404, {'error': 'not_found'})
            elif not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.reply(401, {'error': 'unauthorized'})
            else:
                self.reply(200, {'status': 'ready'})

        def do_POST(self):
            self.connection.settimeout(60)
            if self.path != '/transcribe':
                self.reply(404, {'error': 'not_found'})
                return
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.reply(401, {'error': 'unauthorized'})
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                size = 0
            if not 0 < size <= MAX_BYTES:
                self.reply(413, {'error': 'invalid_size'})
                return
            try:
                with tempfile.NamedTemporaryFile() as audio:
                    remaining = size
                    while remaining:
                        chunk = self.rfile.read(min(remaining, 1024 * 1024))
                        if not chunk:
                            raise ValueError('incomplete audio')
                        audio.write(chunk)
                        remaining -= len(chunk)
                    audio.flush()
                    language = os.getenv('TRANSCRIPTION_LANGUAGE', 'fa')
                    segments, info = model.transcribe(
                        audio.name, language=None if language == 'auto' else language,
                        beam_size=5, condition_on_previous_text=False, vad_filter=False,
                    )
                    if info.duration > MAX_SECONDS:
                        self.reply(413, {'error': 'audio_too_long'})
                        return
                    result = transcript(segments)
                self.reply(200, result)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:
                self.reply(422, {'error': 'transcription_failed'})

    return Handler


if __name__ == '__main__':
    from faster_whisper import WhisperModel
    secret = os.environ['TRANSCRIPTION_TOKEN']
    if len(secret) < 32:
        raise ValueError('TRANSCRIPTION_TOKEN must contain at least 32 characters')
    model = WhisperModel(model_source(os.getenv('TRANSCRIPTION_MODEL', DEFAULT_MODEL)),
                         device='cpu', compute_type='int8',
                         cpu_threads=int(os.getenv('TRANSCRIPTION_THREADS', '2')),
                         download_root='/models')
    HTTPServer(('0.0.0.0', 8090), make_handler(model, secret)).serve_forever()
