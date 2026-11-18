- In all interactions and commit messages, be extremely concise and sacrifice grammar for the sake of concision.
- If user says only "analyze" (or "analiz et" / "incele" / "review" without action verb), only analyze — do not take action, edit files, or commit. Wait for explicit action request.

## System load

- Never put artificial CPU/system load on the machine: no busy-loops (`while :; do :; done`, `while true; do true; done`), `yes > /dev/null`, `stress`/`stress-ng`, endless `dd`/`cat` from `/dev/zero` or `/dev/urandom`, `while True: pass` one-liners. The `block-cpu-burn` hook blocks these; do not try to bypass it (other spelling, script file, etc.) — if load is really needed, ask the user.
- To reproduce races / flaky tests use `go test -race -count=N -cpu=1,2,4` or `GOMAXPROCS=N`, not load generators.
- Every background process you start must be cleaned up (`trap 'kill $(jobs -p) 2>/dev/null' EXIT`); never leave orphans.

## Plans

- At the end of each plan, give me a list of unresolved questions to answer, if any. Make the questions extremely concise. Sacrifice grammar for the sake of concision.
