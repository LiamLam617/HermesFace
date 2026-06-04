import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = PROJECT_ROOT / "scripts" / "run_hermes.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("run_hermes", RUNNER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["run_hermes"] = module
    spec.loader.exec_module(module)
    return module


class RunHermesTests(unittest.TestCase):
    def test_configure_ninerouter_model_writes_modern_model_block(self):
        runner = load_runner()

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.yaml"
            config_path.write_text("agent:\n  name: HermesFace\n", encoding="utf-8")

            runner.configure_ninerouter_model(
                config_path,
                default_model="kr/test-model",
                api_key="sk-test",
            )

            config_text = config_path.read_text(encoding="utf-8")
            self.assertIn("model:", config_text)
            self.assertIn("provider: custom", config_text)
            self.assertIn("default: kr/test-model", config_text)
            self.assertIn("base_url: http://localhost:20128/v1", config_text)
            self.assertIn("api_key: sk-test", config_text)
            self.assertNotIn("openai_compatible", config_text)
            self.assertNotIn("\nprovider: openai-compatible", config_text)

    def test_ensure_default_config_creates_bucket_state_files(self):
        runner = load_runner()

        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / "data"
            app_dir = Path(tmp) / "app"
            app_dir.mkdir()

            runner.ensure_default_config(data_dir, app_dir, "HermesFace")

            self.assertTrue((data_dir / "config.yaml").exists())
            self.assertTrue((data_dir / ".env").exists())
            self.assertTrue((data_dir / "SOUL.md").exists())
            self.assertIn("HermesFace", (data_dir / "SOUL.md").read_text(encoding="utf-8"))

    def test_patch_web_server_cors_is_idempotent(self):
        runner = load_runner()

        with tempfile.TemporaryDirectory() as tmp:
            web_server = Path(tmp) / "hermes_cli" / "web_server.py"
            web_server.parent.mkdir(parents=True)
            web_server.write_text(
                'allow_origin_regex=r"^https?://(localhost|127\\\\.0\\\\.0\\\\.1)(:\\\\d+)?$"\n'
                'headers["X-Frame-Options", "DENY"]\n'
                "content_security_policy = \"frame-ancestors 'none'\"\n",
                encoding="utf-8",
            )

            self.assertTrue(runner.patch_web_server_cors(Path(tmp)))
            first_patch = web_server.read_text(encoding="utf-8")
            self.assertFalse(runner.patch_web_server_cors(Path(tmp)))
            second_patch = web_server.read_text(encoding="utf-8")

            self.assertEqual(first_patch, second_patch)
            self.assertIn('allow_origins=["*"]', first_patch)
            self.assertIn("ALLOWALL", first_patch)
            self.assertIn("https://huggingface.co", first_patch)

    def test_runner_has_no_dataset_sync_runtime_calls(self):
        source = RUNNER_PATH.read_text(encoding="utf-8")

        self.assertNotIn("snapshot_download", source)
        self.assertNotIn("upload_folder", source)
        self.assertNotIn("HERMES_DATASET_REPO", source)


if __name__ == "__main__":
    unittest.main()
