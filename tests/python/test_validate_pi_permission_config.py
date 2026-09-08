import importlib.machinery
import importlib.util
import pathlib
import types
import unittest


VALIDATOR_PATH = (
    pathlib.Path(__file__).resolve().parents[2] / "bin" / "validate-pi-permission-config"
)


def load_validator_module():
    loader = importlib.machinery.SourceFileLoader(
        "validate_pi_permission_config", str(VALIDATOR_PATH)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ValidationErrorOrderingTests(unittest.TestCase):
    def test_sort_key_stringifies_mixed_path_components(self):
        validator = load_validator_module()
        errors = [
            types.SimpleNamespace(path=["items", 2]),
            types.SimpleNamespace(path=["items", "10"]),
        ]

        ordered = sorted(errors, key=validator.validation_error_sort_key)

        self.assertEqual(
            [list(error.path) for error in ordered],
            [["items", "10"], ["items", 2]],
        )


if __name__ == "__main__":
    unittest.main()
