import unittest
from types import SimpleNamespace
from service import transcript, make_handler, model_source
from http.client import HTTPConnection
from http.server import HTTPServer
from threading import Thread
import os
import tempfile

class TranscriptTest(unittest.TestCase):
    def test_persian_timing_and_multiline_cleanup(self):
        result = transcript([SimpleNamespace(start=61.25, text=' یا حسین\n سلام '),
                             SimpleNamespace(start=0, text=' ')])
        self.assertEqual(result['plain'], 'یا حسین سلام')
        self.assertEqual(result['synced'], '[01:01.25]یا حسین سلام')

    def test_empty_and_oversized_results(self):
        for segments in ([], [SimpleNamespace(start=0, text='ا' * 40000)]):
            with self.assertRaises(ValueError):
                transcript(segments)

class ModelSourceTest(unittest.TestCase):
    def test_prefers_bundled_model_and_falls_back_to_download(self):
        with tempfile.TemporaryDirectory() as bundled:
            os.makedirs(os.path.join(bundled, 'small'))
            self.assertEqual(model_source('small', bundled), 'small')
            open(os.path.join(bundled, 'small', 'model.bin'), 'wb').close()
            self.assertEqual(model_source('small', bundled), os.path.join(bundled, 'small'))
            self.assertEqual(model_source('medium', bundled), 'medium')

class PrivateServiceTest(unittest.TestCase):
    def test_authentication_temporary_audio_and_health(self):
        class Model:
            path = None
            def transcribe(self, path, **options):
                self.path = path
                with open(path, 'rb') as audio:
                    self.assert_audio = audio.read()
                self.language = options['language']
                return [SimpleNamespace(start=2.5, text='یا حسین')], SimpleNamespace(duration=10)
        model = Model()
        server = HTTPServer(('127.0.0.1', 0), make_handler(model, 'x' * 32))
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            def call(method, path, token='', body=None):
                conn = HTTPConnection(*server.server_address, timeout=2)
                conn.request(method, path, body=body, headers={'Authorization': token})
                response = conn.getresponse()
                status, data = response.status, response.read()
                conn.close()
                return status, data
            self.assertEqual(call('POST', '/transcribe', body=b'audio')[0], 401)
            self.assertIsNone(model.path)
            self.assertEqual(call('GET', '/health', 'Bearer ' + 'x' * 32)[0], 200)
            status, body = call('POST', '/transcribe', 'Bearer ' + 'x' * 32, b'audio')
            self.assertEqual(status, 200)
            self.assertIn('یا حسین'.encode(), body)
            self.assertEqual(model.assert_audio, b'audio')
            self.assertEqual(model.language, 'fa')
            self.assertFalse(os.path.exists(model.path))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

if __name__ == '__main__':
    unittest.main()
