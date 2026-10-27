import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("consumer", pathlib.Path(__file__).parents[1] / "fixtures/dev/config-consumer.py")
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


class SyntheticConfigTest(unittest.TestCase):
    def test_rotation_and_unresolved_reference(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "api/synthetic_token"
            consumer.consume("synthetic-v1", destination)
            self.assertEqual(destination.read_text(), "synthetic-v1")
            consumer.consume("synthetic-v2", destination)
            self.assertEqual(destination.read_text(), "synthetic-v2")
            with self.assertRaises(ValueError):
                consumer.consume("{{resolve:secretsmanager:/chico/dev/api/SYNTHETIC_TOKEN}}", destination)
            self.assertEqual(destination.read_text(), "synthetic-v2")

    def test_empty_secret_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "api/synthetic_token"
            with self.assertRaises(ValueError):
                consumer.consume("", destination)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
