#!/usr/bin/env python3
"""Table tests for block-cpu-burn.py. Run: python3 hooks/test_block_cpu_burn.py

Commands are NEVER executed; they are only fed to the hook as JSON.
"""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "block-cpu-burn.py"
spec = importlib.util.spec_from_file_location("block_cpu_burn", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

BLOCKED = [
    "while :; do :; done",
    "while true; do :; done",
    "while true; do true; done",
    "until false; do :; done",
    "while :;do :;done",
    "while  true ;  do  : ;  done &",
    "while :\ndo\n  :\ndone",
    "while true; do continue; done",
    "while [ 1 ]; do :; done",
    "while /usr/bin/true; do /bin/true; done",
    "until ! :; do :; done",
    "for ((;;)); do :; done",
    "(while true; do true; done) &",
    "while true; do sleep 1; while :; do :; done; done",
    # 2026-11-13 incident
    "for i in $(seq 1 24); do (while :; do :; done) & pids=\"$pids $!\"; done; go test -run TestRace ./...; kill $pids",
    "timeout 2 bash -c 'while :; do :; done'",
    "bash -c \"while true; do :; done\" &",
    "nohup sh -c 'until false; do :; done' >/dev/null 2>&1 &",
    "bash -lc 'yes > /dev/null'",
    "eval 'while :; do :; done'",
    "echo \"$(while :; do :; done)\"",
    "x=`while :; do :; done`",
    "bash <<'EOF'\nwhile :; do :; done\nEOF",
    "yes > /dev/null",
    "yes >/dev/null &",
    "yes>/dev/null",
    "yes",
    "nohup yes > /dev/null 2>&1 &",
    "yes &> /dev/null &",
    "/usr/bin/yes y >/dev/null",
    "for i in 1 2 3 4; do yes > /dev/null & done",
    "stress --cpu 8 --timeout 60",
    "stress-ng --cpu 0 -t 30s",
    "sudo -u root stress-ng --cpu 4",
    "nice -n 19 stress --cpu 2",
    "dd if=/dev/zero of=/dev/null",
    "dd if=/dev/urandom of=/dev/null bs=1M &",
    "dd if=/dev/zero > /dev/null",
    "cat /dev/zero > /dev/null",
    "cat /dev/urandom > /dev/null &",
    "cat < /dev/zero > /dev/null",
    "sha256sum /dev/zero",
    "python3 -c 'while True: pass'",
    "python3 - <<'EOF'\nwhile True:\n    pass\nEOF",
    "node -e 'while(true){}'",
    "perl -e '1 while 1'",
    "ruby -e 'loop {}'",
]

ALLOWED = [
    "while true; do curl -sf localhost:8080/health && break; sleep 5; done",
    "until pg_isready -h localhost; do sleep 1; done",
    "while :; do sleep 1; done",
    "while read -r line; do echo \"$line\"; done < file.txt",
    "for i in $(seq 1 5); do go test -run TestX ./...; done",
    "yes | npx create-foo",
    "yes y | ./install.sh",
    "yes | head -n 5",
    "yes 2>/dev/null | sudo apt-get install foo",
    "installer < <(yes)",
    "case $a in\n  yes) echo ok ;;\n  no) echo no ;;\nesac",
    "npm install --yes",
    "echo ${yes} > /dev/null",
    "grep -rn 'while :; do :; done' .",
    "grep -rn \"yes > /dev/null\" hooks/",
    "echo 'stress-ng --cpu 4'",
    "rg \"dd if=/dev/zero of=/dev/null\" docs/",
    "git commit -m \"block while true; do :; done loops\"",
    "ls -la  # while :; do :; done",
    "gh pr create --title t --body \"$(cat <<'EOF'\nBlocks `while :; do :; done`, `yes > /dev/null` and stress-ng.\nDon't worry, it's fine.\nEOF\n)\"",
    "cat > notes.md <<'EOF'\nwhile :; do :; done\nyes > /dev/null\nEOF",
    "ssh host 'uptime'",
    "dd if=/dev/zero of=/tmp/x bs=1M count=10",
    "dd if=/dev/zero of=/dev/null bs=1M count=100",
    "head -c 32 /dev/urandom | base64",
    "cat /dev/urandom | tr -dc a-z | head -c 16",
    "LC_ALL=C tr -dc a-z < /dev/urandom | head -c 16",
    "go test -race -count=50 -cpu=1,2,4 ./...",
    "GOMAXPROCS=1 go test ./...",
    "python3 -c 'while True: print(q.get())'",
    "python3 -c 'import sys; print(sys.version)'",
    "node -e 'console.log(1)'",
    "docker run --rm alpine true",
    "",
]


def run_hook(payload: str):
    return subprocess.run([sys.executable, str(SCRIPT)], input=payload,
                          capture_output=True, text=True, timeout=10)


class TestDetect(unittest.TestCase):
    def test_blocked(self):
        for cmd in BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(hook.analyze(cmd))

    def test_allowed(self):
        for cmd in ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertIsNone(hook.analyze(cmd))


class TestProcess(unittest.TestCase):
    def test_block_exit2_with_guidance(self):
        p = run_hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "yes > /dev/null &"}}))
        self.assertEqual(p.returncode, 2)
        self.assertIn("-race -count=N -cpu=1,2,4", p.stderr)
        self.assertIn("trap", p.stderr)

    def test_allow_exit0_silent(self):
        p = run_hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls -la"}}))
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, "", ""))

    def test_fail_open(self):
        for payload in ("", "not json", "[]", '{"tool_input": null}', '{"tool_input": {"command": 5}}'):
            with self.subTest(payload=payload):
                self.assertEqual(run_hook(payload).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
