import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "render-platform.py"
spec = importlib.util.spec_from_file_location("render_platform", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RenderTest(unittest.TestCase):
    def test_missing_output_cannot_reach_apply(self):
        with self.assertRaises(ValueError):
            module.render_text("region: ${AWS_REGION}", {})

    def test_output_cannot_inject_yaml_or_python(self):
        with self.assertRaises(ValueError):
            module.render_text("region: ${AWS_REGION}", {"AWS_REGION": "us-east-1\nkind: Secret"})

    def test_valid_arn_and_region_render(self):
        self.assertEqual(module.render_text("region: ${AWS_REGION}", {"AWS_REGION": "us-east-1"}), "region: us-east-1")


if __name__ == "__main__":
    unittest.main()
