import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[2] / 'libexec' / 'run-python-tests'


class RunPythonTestsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def module(self, name, body):
        (self.root / f'{name}.py').write_text(textwrap.dedent(body))

    def run_suite(self):
        return subprocess.run([sys.executable, str(RUNNER), str(self.root), '--jobs', '2'],
                              text=True, capture_output=True, check=False)

    def test_runs_every_class_once_including_same_named_and_subclassed_classes(self):
        self.module('test_alpha', '''
            import unittest
            import helper_beside_tests
            class Base(unittest.TestCase):
                def test_one(self): self.assertTrue(helper_beside_tests.VALUE)
            class Base2(Base):
                def test_two(self): pass
        ''')
        self.module('test_alpha_more', '''
            import unittest
            class Base(unittest.TestCase):
                def test_three(self): pass
        ''')
        self.module('helper_beside_tests', 'VALUE = True\n')
        result = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 4 tests in 3 classes', result.stdout)

    def test_same_module_and_class_name_in_a_package_runs_once_each(self):
        body = '''
            import unittest
            class Base(unittest.TestCase):
                def test_one(self): pass
        '''
        self.module('test_alpha', body)
        (self.root / 'pkg').mkdir()
        (self.root / 'pkg' / '__init__.py').write_text('')
        self.module('pkg/test_alpha', body)
        result = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 2 tests in 2 classes', result.stdout)

    def test_failing_class_fails_the_run_and_shows_its_output(self):
        self.module('test_mixed', '''
            import unittest
            class Good(unittest.TestCase):
                def test_ok(self): pass
            class Bad(unittest.TestCase):
                def test_broken(self): self.assertEqual('expected-text', 'actual-text')
        ''')
        result = self.run_suite()
        self.assertEqual(result.returncode, 1)
        self.assertIn('FAIL test_mixed.Bad', result.stdout)
        self.assertIn('actual-text', result.stdout)
        self.assertIn('ok   test_mixed.Good', result.stdout)
        self.assertIn('FAILED: test_mixed.Bad', result.stderr)

    def test_import_error_fails_the_run(self):
        self.module('test_good', '''
            import unittest
            class Good(unittest.TestCase):
                def test_ok(self): pass
        ''')
        self.module('test_broken_import', 'import module_that_does_not_exist\n')
        result = self.run_suite()
        self.assertEqual(result.returncode, 1)
        self.assertIn('cannot load', result.stderr)
        self.assertIn('module_that_does_not_exist', result.stderr)

    def test_empty_directory_fails(self):
        result = self.run_suite()
        self.assertEqual(result.returncode, 1)
        self.assertIn('no tests found', result.stderr)


if __name__ == '__main__':
    unittest.main()
