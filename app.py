import subprocess
import sys

if __name__ == "__main__":
    print("Starting HermesFace bucket runner...")
    subprocess.run([sys.executable, "scripts/run_hermes.py"], check=True)
