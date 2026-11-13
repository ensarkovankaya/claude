#!/usr/bin/env python3
"""PreToolUse(Bash) hook: makineye yapay CPU yükü bindiren komutları bloklar (exit 2).

Bloklanan: gövdesi no-op olan sonsuz döngüler (`while :; do :; done`, `until false; ...`,
`for ((;;))`), boşa akan `yes` (`yes > /dev/null`, `yes &`), `stress`/`stress-ng`,
count'suz `dd if=/dev/zero of=/dev/null`, `cat /dev/zero > /dev/null`, `sha256sum /dev/zero`,
`python -c 'while True: pass'` tarzı tek satırlıklar.
Komut küçük bir shell lexer'ından geçer: tırnak içi metin, yorum ve shell olmayan heredoc'lar
kod sayılmaz (grep/echo/commit mesajı false positive vermesin); `bash -c '...'`, `eval`,
`$(...)`, backtick ve `bash <<EOF` gövdeleri ise kod olarak tekrar taranır.
İzin modundan bağımsız çalışır (auto/bypass, subagent'lar dahil). Her hatada exit 0 (fail-open):
hook hiçbir durumda Bash'i kilitlememeli.
"""
from __future__ import annotations

import json
import os
import re
import sys

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
LANG_RE = re.compile(r"^(?:python[\d.]*|pypy3?|node|perl|ruby)$")
KEYWORDS = {"!", "{", "}", "if", "then", "elif", "else", "do", "while", "until", "time",
            "nohup", "exec", "command", "builtin", "setsid", "caffeinate"}
DEVS = {"/dev/zero", "/dev/urandom", "/dev/random"}
# boru ile beslenmiyorsa sonsuz okuyan/yazan komutlar
READERS = {"cat", "pv", "tr", "base64", "gzip", "bzip2", "xz", "zstd"}
# borudan bağımsız: /dev/zero'yu sonuna kadar okumaya çalışır
DIGESTS = {"md5", "md5sum", "sha1sum", "sha224sum", "sha256sum", "sha384sum", "sha512sum",
           "shasum", "b2sum", "cksum", "wc"}

# komut pozisyonundaki while/until: koşul ; do gövde done (lookahead: iç içe döngüler de taransın)
LOOP_RE = re.compile(
    r"(?<![^\s;&|(){}`])(?=((while|until)\s+([^;\n]*?)\s*[;\n]\s*do(?=[\s;])((?:(?!\bdone\b).)*)\bdone\b))",
    re.S)
FOR_RE = re.compile(
    r"(?<![^\s;&|(){}`])(?=for\s*\(\(\s*;\s*;\s*\)\)\s*[;\n]?\s*do(?=[\s;])((?:(?!\bdone\b).)*)\bdone\b)",
    re.S)
WHILE_TRUE = re.compile(
    r"^(?::|true|/(?:usr/)?bin/true|\[\s+1\s+\]|\[\[\s+1\s+\]\]|\(\(\s*1\s*\)\)|!\s*false)$")
UNTIL_FALSE = re.compile(r"^(?:false|/(?:usr/)?bin/false|!\s*(?::|true))$")
NOOP = re.compile(r"^(?::(?:\s.*)?|true|/(?:usr/)?bin/true|continue|\(\(.*\)\)|[{}])?$")
LANG_BUSY = re.compile(
    r"while\s+(?:True|1)\s*:\s*(?:pass|continue|\.\.\.)\s*(?:$|[;#\n])"   # python
    r"|(?:while\s*\(\s*(?:true|1)\s*\)|for\s*\(\s*;\s*;\s*\))\s*(?:\{\s*\}|;)"  # js / perl
    r"|\b1\s+while\s+1\b"                                                  # perl
    r"|\bloop\s*(?:\{\s*\}|do\s+end\b)",                                   # ruby
    re.M)
SEP_RE = re.compile(r"(\|\||&&|\|&|;;|\$\(|\x01|[|;&\n()`])")
SAFE_WORD = re.compile(r"[\w./=:+@%,-]+")

MESSAGE = """BLOCKED by block-cpu-burn hook: {reason}
Yapay CPU yükü bindirmek yasak (busy-loop, boşa akan yes, stress/stress-ng, /dev/zero okuma...).
Komut çalıştırılmadı. Önceki olayda bu tür bir komut orphan kalıp saatlerce makineyi kilitledi.
- Race / flaky test yeniden üretmek için: go test -race -count=N -cpu=1,2,4 -run <Test> (veya GOMAXPROCS=N).
- Arka plan süreci başlatırsan trap ile temizle: trap 'kill $(jobs -p) 2>/dev/null' EXIT; orphan bırakma.
Kuralı farklı yazımla/script dosyasıyla aşmaya çalışma; gerçekten gerekiyorsa kullanıcıya sor."""


def split_commands(skel: str) -> list[tuple[list[str], str, str]]:
    """Skeleton'ı basit komutlara böler: (kelimeler, önceki ayraç, sonraki ayraç)."""
    s = re.sub(r"\d*[<>]&(?:\d+|-)", " ", skel)          # 2>&1, >&2, <&-
    s = re.sub(r"&>>?|>&|>\|", " > ", s)                  # &>file, >&file, >|file
    s = re.sub(r"[<>]\(", "\x01", s)                      # <(..) / >(..) process substitution
    s = re.sub(r"(\d*(?:>>|>|<))", r" \1 ", s)            # yes>/dev/null -> yes > /dev/null
    parts = SEP_RE.split(s)
    out = []
    prev = ""
    for k in range(0, len(parts), 2):
        nxt = parts[k + 1] if k + 1 < len(parts) else ""
        out.append((parts[k].split(), prev, nxt))
        prev = nxt
    return out


def strip_wrappers(words: list[str]) -> list[str]:
    i, n = 0, len(words)
    while i < n:
        w = words[i]
        if w in KEYWORDS or re.match(r"^\w+=", w):
            i += 1
        elif w in ("env", "sudo", "nice", "timeout", "gtimeout"):
            i += 1
            while i < n and (words[i].startswith("-") or re.match(r"^\w+=", words[i])):
                takes_arg = w != "env" and words[i] in ("-u", "-g", "-C", "-n", "-s", "-k")
                i += 2 if takes_arg else 1
            if w in ("timeout", "gtimeout"):
                i += 1  # süre
        else:
            break
    return words[i:]


def argv0(words: list[str]) -> str:
    return os.path.basename(words[0]) if words else ""


def current_words(prefix: str) -> list[str]:
    """Prefix'in son basit komutunun (wrapper'sız) kelimeleri."""
    cmds = split_commands(prefix)
    return strip_wrappers(cmds[-1][0]) if cmds else []


class Lexer:
    """Minimal shell lexer: kodu 'skeleton'a indirger, tırnak içini Q yapar,
    shell olarak çalışacak gömülü kodu (bash -c, eval, heredoc, backtick) ayrıca toplar."""

    def __init__(self, s: str):
        self.s, self.i, self.n = s, 0, len(s)
        self.heredocs: list[tuple[str, bool, list[str]]] = []
        self.code: list[str] = []   # tekrar shell olarak taranacak parçalar
        self.lang: list[str] = []   # python/node/perl/ruby kodu

    def parse(self, stop: str | None = None) -> str:
        s, out, depth = self.s, [], 0
        while self.i < self.n:
            c = s[self.i]
            nxt = s[self.i + 1] if self.i + 1 < self.n else ""
            if stop == ")" and c == ")" and depth == 0:
                self.i += 1
                return "".join(out)
            if c == "\\":
                out.append(" " if nxt == "\n" else nxt if (nxt.isalnum() or nxt in "/.-") else "_")
                self.i += 2
            elif c == "'":
                end = s.find("'", self.i + 1)
                end = self.n if end < 0 else end
                self.word(out, s[self.i + 1:end])
                self.i = end + 1
            elif c == "$" and nxt == "'":
                j = self.i + 2
                while j < self.n and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                self.word(out, s[self.i + 2:j])
                self.i = j + 1
            elif c == "$" and nxt == "(":
                self.i += 2
                out.append("$(" + self.parse(")") + ")")
            elif c == '"':
                self.i += 1
                self.dquote(out)
            elif c == "`":
                self.backtick(out)
            elif c == "#" and (not out or out[-1][-1:] in ("", " ", "\t", "\n", ";", "&", "|", "(", ")")):
                end = s.find("\n", self.i)
                self.i = self.n if end < 0 else end
            elif s.startswith("<<", self.i) and not s.startswith("<<<", self.i):
                self.heredoc_header(out)
            elif c == "\n":
                out.append(c)
                self.i += 1
                self.read_heredocs()
            else:
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                out.append(c)
                self.i += 1
        return "".join(out)

    def dquote(self, out: list[str]) -> None:
        s, start, subs = self.s, self.i, []
        while self.i < self.n and s[self.i] != '"':
            if s[self.i] == "\\":
                self.i += 2
            elif s.startswith("$(", self.i):
                self.i += 2
                subs.append("$(" + self.parse(")") + ")")
            elif s[self.i] == "`":
                self.backtick(subs)
            else:
                self.i += 1
        text = s[start:min(self.i, self.n)]
        self.i += 1
        self.word(out, text)
        out.extend(subs)

    def backtick(self, out: list[str]) -> None:
        s, j = self.s, self.i + 1
        while j < self.n and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        self.code.append(s[self.i + 1:j])
        out.append("Q")
        self.i = j + 1

    def word(self, out: list[str], text: str) -> None:
        """Tırnaklı metin: kod değil; ama bash -c / eval / python -c argümanıysa kod olarak sakla."""
        words = current_words("".join(out))
        a0 = argv0(words)
        last = words[-1] if len(words) > 1 else ""
        if a0 == "eval" or (a0 in SHELLS and re.match(r"^-[a-z]*c[a-z]*$", last)):
            self.code.append(text)
        elif LANG_RE.match(a0) and re.match(r"^-[a-zA-Z]*[ceE]$", last):
            self.lang.append(text)
        out.append(text if SAFE_WORD.fullmatch(text) else "Q")

    def heredoc_header(self, out: list[str]) -> None:
        s, j = self.s, self.i + 2
        strip = j < self.n and s[j] == "-"
        j += 1 if strip else 0
        while j < self.n and s[j] in " \t":
            j += 1
        m = re.compile(r"""'([^']*)'|"([^"]*)"|([^\s;&|<>()]+)""").match(s, j)
        if not m:
            out.append("<<")
            self.i += 2
            return
        delim = next(g for g in m.groups() if g is not None).replace("\\", "")
        self.heredocs.append((delim, strip, current_words("".join(out))))
        out.append(" Q ")
        self.i = m.end()

    def read_heredocs(self) -> None:
        s = self.s
        for delim, strip, words in self.heredocs:
            lines = []
            while self.i < self.n:
                end = s.find("\n", self.i)
                end = self.n if end < 0 else end
                line = s[self.i:end]
                self.i = end + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            a0 = argv0(words)
            if a0 in SHELLS and not any(w == "-c" for w in words):
                self.code.append("\n".join(lines))
            elif LANG_RE.match(a0):
                self.lang.append("\n".join(lines))
        self.heredocs = []


def check_skeleton(skel: str) -> str | None:
    for m in LOOP_RE.finditer(skel):
        kw, cond, body = m.group(2), m.group(3).strip(), m.group(4)
        infinite = WHILE_TRUE.match(cond) if kw == "while" else UNTIL_FALSE.match(cond)
        if infinite and all(NOOP.match(p.strip()) for p in re.split(r"[;\n]", body)):
            return "gövdesi boş sonsuz döngü (busy-loop): " + " ".join(m.group(1).split())
    for m in FOR_RE.finditer(skel):
        if all(NOOP.match(p.strip()) for p in re.split(r"[;\n]", m.group(1))):
            return "gövdesi boş sonsuz for döngüsü (busy-loop)"

    for words, prev, nxt in split_commands(skel):
        words = strip_wrappers(words)
        argv, stdout, stdin = [], None, None
        k = 0
        while k < len(words):
            w = words[k]
            if re.match(r"^\d*(?:>>|>|<)$", w):
                target = words[k + 1] if k + 1 < len(words) else ""
                if w in (">", ">>", "1>", "1>>"):
                    stdout = target
                elif w in ("<", "0<"):
                    stdin = target
                k += 2
            else:
                argv.append(w)
                k += 1
        a0 = argv0(argv)
        if not a0 or (len(words) == 1 and nxt == ")" and prev != "$("):
            continue  # boş ya da `case` deseni (`yes)`)
        piped = nxt in ("|", "|&") or prev == "\x01"
        reads_dev = stdin in DEVS or any(a in DEVS for a in argv[1:])
        if a0 == "yes" and not piped:
            return "boşa akan `yes` (pipe'a bağlı değil)"
        if a0 in ("stress", "stress-ng"):
            return "`%s` yük üretici" % a0
        if a0 == "dd" and not any(a.startswith("count=") for a in argv):
            src = next((a[3:] for a in argv if a.startswith("if=")), stdin)
            dst = next((a[3:] for a in argv if a.startswith("of=")), stdout)
            if src in DEVS and (dst == "/dev/null" or (dst is None and not piped)):
                return "count'suz `dd if=%s` (sonsuz kopyalama)" % src
        if a0 in READERS and reads_dev and not piped:
            return "`%s` ile %s sonsuz okuma" % (a0, "/dev/zero|urandom")
        if a0 in DIGESTS and reads_dev:
            return "`%s` ile sonsuz cihaz okuma" % a0
    return None


def analyze(cmd: str, depth: int = 0) -> str | None:
    if depth > 4 or not cmd:
        return None
    lx = Lexer(cmd)
    skel = lx.parse()
    reason = check_skeleton(skel)
    if reason:
        return reason
    for frag in lx.code:
        reason = analyze(frag, depth + 1)
        if reason:
            return reason
    for code in lx.lang:
        if LANG_BUSY.search(code):
            return "tek satırlık betikte boş sonsuz döngü"
    return None


def main() -> int:
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command")
    if not isinstance(cmd, str):
        return 0
    reason = analyze(cmd)
    if reason:
        sys.stderr.write(MESSAGE.format(reason=reason) + "\n")
        return 2
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception:
        code = 0
    sys.exit(code)
