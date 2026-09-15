#!/usr/bin/env python3
"""
test_ci.py - Local test suite for GitHub Actions workflows (.github/workflows/ci.yml).
Ensures CI scripts pass locally before pushing to remote, preventing CI churn.

Checks:
1. YAML structural integrity & block parsing
2. Bash syntax verification (bash -n on all run blocks)
3. Portability & errexit linting (catches `set -e` subshell traps, non-POSIX flags)
4. Live execution of CI smoke tests with the local binary
5. Binary size gate verification (<= 600KB)
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CI_YML = REPO_ROOT / ".github" / "workflows" / "ci.yml"
BIN_EXE = REPO_ROOT / "zig-out" / "bin" / "zcat.exe"
BIN_POSIX = REPO_ROOT / "zig-out" / "bin" / "zcat"


def log(status: str, msg: str):
    symbols = {"PASS": "[+]", "FAIL": "[!]", "INFO": "[*]"}
    print(f"{symbols.get(status, '[ ]')} {status}: {msg}")


def find_bash() -> str:
    """Find a usable bash executable on PATH or Git for Windows."""
    candidates = [
        "bash",
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ]
    for c in candidates:
        try:
            res = subprocess.run([c, "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if res.returncode == 0:
                return c
        except Exception:
            continue
    raise RuntimeError("No bash executable found for CI shell verification")


def extract_run_blocks(yml_path: Path):
    """Extract named run steps from the workflow YAML."""
    text = yml_path.read_text(encoding="utf-8")
    blocks = []
    current_name = "unnamed"
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m_name = re.match(r'^\s*-\s*name:\s*(.+)$', line)
        if m_name:
            current_name = m_name.group(1).strip().strip("'\"")
        m_run = re.match(r'^\s*run:\s*\|\s*$', line)
        if m_run:
            indent = len(line) - len(line.lstrip())
            script_lines = []
            i += 1
            while i < len(lines):
                s_line = lines[i]
                if s_line.strip() and (len(s_line) - len(s_line.lstrip())) <= indent:
                    i -= 1
                    break
                script_lines.append(s_line[indent + 2 :] if len(s_line) > indent + 2 else s_line.lstrip())
                i += 1
            blocks.append((current_name, "\n".join(script_lines)))
        i += 1
    return blocks


def test_yaml_lint():
    """Verify workflow YAML structure and static rules."""
    log("INFO", "Checking CI workflow syntax and anti-patterns...")
    assert CI_YML.exists(), f"Workflow not found at {CI_YML}"
    content = CI_YML.read_text(encoding="utf-8")

    # Anti-pattern: subshell test under set -e without conditional
    # e.g. B="...$( [ ... ] && echo .exe )" triggers silent bash -e exits on Linux/macOS
    if re.search(r'\$\(\s*\[\s*"\$RUNNER_OS"\s*=\s*"Windows"\s*\]\s*&&', content):
        raise AssertionError("Found dangerous subshell `$( [ $RUNNER_OS = Windows ] && ... )` which fails under `set -e`!")

    # Anti-pattern: GNU-only `head -c` (macOS BSD head rejects or behaves inconsistently)
    if "head -c" in content:
        raise AssertionError("Found non-portable `head -c` in workflow! Use POSIX `head -n`.")

    log("PASS", "Static analysis & anti-pattern checks passed.")


def test_bash_syntax(bash_path: str, blocks):
    """Run `bash -n` on all multi-line bash steps in ci.yml."""
    log("INFO", "Validating bash syntax on all CI run blocks...")
    tmp_dir = REPO_ROOT / "test" / "_tmp"
    tmp_dir.mkdir(exist_ok=True)
    try:
        for name, script in blocks:
            tmp_script = tmp_dir / f"check_{re.sub(r'[^a-zA-Z0-9_]', '_', name)}.sh"
            tmp_script.write_text(script, encoding="utf-8")
            res = subprocess.run([bash_path, "-n", str(tmp_script)], capture_output=True, text=True)
            if res.returncode != 0:
                raise AssertionError(f"Syntax error in step '{name}':\n{res.stderr}")
            log("PASS", f"Step '{name}' syntax OK.")
    finally:
        for f in tmp_dir.glob("*.sh"):
            try:
                f.unlink()
            except Exception:
                pass
        try:
            tmp_dir.rmdir()
        except Exception:
            pass


def test_live_smoke(bash_path: str, blocks):
    """Execute the exact CI 'Smoke tests' block locally."""
    log("INFO", "Executing live CI Smoke tests step locally...")
    smoke_block = None
    for name, script in blocks:
        if "smoke" in name.lower():
            smoke_block = script
            break

    assert smoke_block is not None, "Smoke tests block not found in ci.yml"

    # Ensure binary exists
    active_bin = BIN_EXE if os.name == "nt" else BIN_POSIX
    if not active_bin.exists():
        log("INFO", f"Building release binary with zig...")
        res = subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=REPO_ROOT)
        assert res.returncode == 0, "zig build failed"

    # Run script with RUNNER_OS=Windows
    env = os.environ.copy()
    env["RUNNER_OS"] = "Windows" if os.name == "nt" else "Linux"

    res = subprocess.run(
        [bash_path, "-e", "-o", "pipefail", "-c", smoke_block],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        raise AssertionError(f"Live Smoke tests failed with exit code {res.returncode}")

    log("PASS", "Live Smoke tests executed and verified with code 0.")


def test_binary_size():
    """Verify binary size limit (<= 600,000 bytes)."""
    target_bin = BIN_EXE if BIN_EXE.exists() else BIN_POSIX
    assert target_bin.exists(), f"Binary {target_bin} does not exist"
    size = target_bin.stat().st_size
    log("INFO", f"Binary size is {size:,} bytes (limit: 600,000 bytes)")
    assert size <= 600_000, f"Binary size {size} exceeds 600,000 bytes limit!"
    log("PASS", "Binary size within budget.")


def main():
    print("=== CI Workflow Local Test Suite ===")
    try:
        bash_path = find_bash()
        test_yaml_lint()
        blocks = extract_run_blocks(CI_YML)
        log("INFO", f"Discovered {len(blocks)} multi-line run steps in {CI_YML.name}")
        test_bash_syntax(bash_path, blocks)
        test_live_smoke(bash_path, blocks)
        test_binary_size()
        print("\n[+] ALL CI WORKFLOW CHECKS PASSED.")
        return 0
    except Exception as e:
        print(f"\n[!] TEST SUITE FAILURE: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
