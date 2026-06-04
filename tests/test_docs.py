import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class DocumentationTests(unittest.TestCase):
    def test_readme_describes_storage_bucket_and_9router_modes(self):
        readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")

        self.assertNotIn("\ndatasets:", readme)
        for old_variable in ("HF_TOKEN", "HERMES_DATASET_REPO", "AUTO_CREATE_DATASET", "SYNC_INTERVAL"):
            self.assertNotIn(old_variable, readme)
        self.assertIn("Storage Bucket", readme)
        self.assertIn("/opt/data", readme)
        self.assertIn("HERMESFACE_MODE=ninerouter-setup", readme)
        self.assertIn("HERMESFACE_MODE=agent", readme)
        self.assertIn("/opt/data/9router-data/db/data.sqlite", readme)

    def test_env_example_uses_bucket_and_9router_variables(self):
        env_example = (PROJECT_ROOT / ".env.example").read_text(encoding="utf-8")

        for old_variable in ("HF_TOKEN", "HERMES_DATASET_REPO", "AUTO_CREATE_DATASET", "SYNC_INTERVAL"):
            self.assertNotIn(old_variable, env_example)
        self.assertIn("HERMESFACE_MODE=agent", env_example)
        self.assertIn("NINEROUTER_PASSWORD=", env_example)
        self.assertIn("NINEROUTER_JWT_SECRET=", env_example)
        self.assertIn("NINEROUTER_DEFAULT_MODEL=kr/claude-sonnet-4.5", env_example)
        self.assertIn("NINEROUTER_API_KEY=sk-local", env_example)


if __name__ == "__main__":
    unittest.main()
