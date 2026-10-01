"""No-network contract tests for the Railway startup wrapper."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]


class RailwayRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'docker/entrypoints').mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        TEST_LOG=str(self.log), PORT='4567',
                        DATABASE_URL='postgres://user:synthetic-only@db.invalid:5432/test',
                        REDIS_URL='redis://redis.invalid:6379', SECRET_KEY_BASE='synthetic-test-only')

    def tearDown(self):
        self.temp.cleanup()

    def install_stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)

    def run_wrapper(self):
        source = ROOT / 'docker/entrypoints/railway.sh'
        self.assertTrue(source.exists(), 'Railway startup wrapper is not implemented')
        target = self.root / 'docker/entrypoints/railway.sh'
        shutil.copyfile(source, target)
        return subprocess.run(['/bin/sh', str(target)], env=self.env, capture_output=True, text=True)

    def test_migrations_precede_the_two_supervised_processes(self):
        self.install_stub('bundle', 'printf "bundle %s\\n" "$*" >> "$TEST_LOG"\n')
        self.install_stub('multirun', 'printf "process %s\\n" "$@" >> "$TEST_LOG"\n')
        (self.root / 'storage').mkdir()
        (self.root / 'storage/keep-me').write_text('synthetic upload')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), [
            'bundle exec ruby docker/entrypoints/railway_wait_for_db.rb',
            'bundle exec rails db:chatwoot_prepare',
            'process bundle exec sidekiq -C config/sidekiq.yml',
            'process bundle exec rails s -b 0.0.0.0 -p 4567',
        ])
        self.assertEqual((self.root / 'storage/keep-me').read_text(), 'synthetic upload')
        self.assertNotIn('synthetic-only', result.stdout + result.stderr)

    def test_preserves_nonzero_supervisor_exit_status(self):
        self.install_stub('bundle', 'exit 0\n')
        self.install_stub('multirun', 'exit 17\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 17)

    def test_forwards_termination_and_waits_for_supervisor_shutdown(self):
        self.install_stub('bundle', 'exit 0\n')
        self.install_stub('multirun',
                          'trap \'echo stopped >> "$TEST_LOG"; exit 0\' TERM INT\n'
                          'echo ready >> "$TEST_LOG"\nwhile :; do sleep 0.1; done\n')
        target = self.root / 'docker/entrypoints/railway.sh'
        shutil.copyfile(ROOT / 'docker/entrypoints/railway.sh', target)
        process = subprocess.Popen(['/bin/sh', str(target)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not self.log.exists():
                self.assertLess(time.monotonic(), deadline, 'Supervisor did not start')
                time.sleep(0.01)
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(self.log.read_text().splitlines(), ['ready', 'stopped'])
            self.assertNotIn('synthetic-only', stdout + stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_does_not_start_web_or_worker_after_migration_failure(self):
        self.install_stub('bundle', 'case "$*" in *db:chatwoot_prepare*) exit 17;; esac\n')
        self.install_stub('multirun', 'echo started > "$TEST_LOG"\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 17)
        self.assertFalse(self.log.exists())

    def test_rejects_an_invalid_port_before_starting_processes(self):
        self.env['PORT'] = '3000;echo unsafe'
        self.install_stub('bundle', 'echo called > "$TEST_LOG"\n')
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_database_readiness_does_not_put_credentials_in_args_or_logs(self):
        self.install_stub('pg_isready', 'printf "%s\\n" "$*" > "$TEST_LOG"\n')
        result = subprocess.run(['ruby', str(ROOT / 'docker/entrypoints/railway_wait_for_db.rb')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().strip(), '--quiet --host db.invalid --port 5432')
        self.assertNotIn('synthetic-only', result.stdout + result.stderr + self.log.read_text())

    def test_database_readiness_rejects_bad_settings_without_repeating_them(self):
        self.env['DATABASE_URL'] = 'postgres://user:synthetic-only@bad host/test'
        result = subprocess.run(['ruby', str(ROOT / 'docker/entrypoints/railway_wait_for_db.rb')],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('synthetic-only', result.stdout + result.stderr)

    def test_database_readiness_times_out_instead_of_hanging_forever(self):
        self.env['DATABASE_WAIT_TIMEOUT'] = '1'
        self.install_stub('pg_isready', 'exit 1\n')
        result = subprocess.run(['ruby', str(ROOT / 'docker/entrypoints/railway_wait_for_db.rb')],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timed out', result.stderr)


if __name__ == '__main__':
    unittest.main()
