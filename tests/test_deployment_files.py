import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class DeploymentFilesTests(unittest.TestCase):
    def test_app_wrapper_uses_bucket_runner_not_dataset_sync(self):
        source = (PROJECT_ROOT / "app.py").read_text(encoding="utf-8")

        self.assertIn("run_hermes.py", source)
        self.assertNotIn("sync_hf.py", source)

    def test_dockerfile_builds_latest_sources_and_bucket_runtime(self):
        source = (PROJECT_ROOT / "Dockerfile").read_text(encoding="utf-8")

        self.assertIn("ARG NINEROUTER_REF=master", source)
        self.assertIn("ARG HERMES_AGENT_REF=main", source)
        self.assertIn("/opt/data/9router-data", source)
        self.assertIn("/opt/hermes-scripts/scripts/run_hermes.py", source)
        self.assertNotIn("huggingface_hub", source)
        self.assertNotIn("/opt/hermes-scripts/scripts/sync_hf.py", source)

    def test_requirements_match_bucket_runtime(self):
        source = (PROJECT_ROOT / "requirements.txt").read_text(encoding="utf-8")

        self.assertIn("requests", source)
        self.assertIn("pyyaml", source.lower())
        self.assertNotIn("huggingface_hub", source)

    def test_entrypoint_has_setup_and_agent_modes_without_dataset_sync(self):
        source = (PROJECT_ROOT / "scripts" / "entrypoint.sh").read_text(encoding="utf-8")

        self.assertIn('HERMESFACE_MODE="${HERMESFACE_MODE:-agent}"', source)
        self.assertIn('"ninerouter-setup"', source)
        self.assertIn("start_ninerouter 7860 true", source)
        self.assertIn("start_ninerouter 20128 false", source)
        self.assertIn("start_ninerouter 20128 true", source)
        self.assertIn("run_hermes.py", source)
        self.assertNotIn("sync_hf.py", source)
        self.assertNotIn("snapshot_download", source)
        self.assertNotIn("upload_folder", source)


if __name__ == "__main__":
    unittest.main()
