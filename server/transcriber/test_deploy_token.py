import os
import re
import subprocess
import tempfile
import unittest

DEPLOY = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'deploy', 'deploy.sh')


def token_block():
    with open(DEPLOY) as script:
        match = re.search(r'^# Turning transcription on.*?^fi$', script.read(), re.S | re.M)
    return match.group(0)


class DeployTokenTest(unittest.TestCase):
    def run_block(self, env):
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, '.env'), 'w') as file:
                file.write(env)
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + token_block()],
                                    cwd=folder, capture_output=True, text=True, check=True)
            with open(os.path.join(folder, '.env')) as file:
                tokens = [line.split('=', 1)[1] for line in file.read().splitlines()
                          if line.startswith('TRANSCRIPTION_TOKEN=')]
            return result.stdout, tokens

    def test_generates_a_missing_or_short_token_once(self):
        for env in ('TRANSCRIPTION_ENABLED=true\n', 'TRANSCRIPTION_ENABLED=true\nTRANSCRIPTION_TOKEN=short\n'):
            output, tokens = self.run_block(env)
            self.assertEqual(len(tokens), 1)
            self.assertRegex(tokens[0], r'^[0-9a-f]{64}$')
            self.assertNotIn(tokens[0], output)

    def test_keeps_an_existing_token_and_ignores_disabled(self):
        kept = 'k' * 40
        self.assertEqual(self.run_block(f'TRANSCRIPTION_ENABLED=true\nTRANSCRIPTION_TOKEN={kept}\n'),
                         ('', [kept]))
        self.assertEqual(self.run_block('TRANSCRIPTION_ENABLED=false\n'), ('', []))


if __name__ == '__main__':
    unittest.main()
