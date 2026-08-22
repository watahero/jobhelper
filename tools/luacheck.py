"""Lightweight Lua sanity checker: tokenizes away comments/strings, then
verifies block keywords and bracket nesting balance. Not a full parser, but
it catches unbalanced `end`, unterminated strings and stray brackets."""
import sys, re

KW = re.compile(r"\b(function|if|then|do|for|while|repeat|until|end|else|elseif|return)\b")
NAME = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")


def strip(src, path):
    """Remove comments and string literals, preserving newlines for line numbers."""
    out, i, n, line = [], 0, len(src), 1
    while i < n:
        c = src[i]
        # long bracket [[ ]] / [==[ ]==]  (comment or string)
        m = re.match(r"--\[(=*)\[", src[i:]) or re.match(r"\[(=*)\[", src[i:])
        if m:
            eq = m.group(1)
            close = "]" + eq + "]"
            j = src.find(close, i + m.end())
            if j < 0:
                return None, f"{path}: unterminated long bracket at line {line}"
            chunk = src[i:j + len(close)]
            out.append("\n" * chunk.count("\n"))
            line += chunk.count("\n")
            i = j + len(close)
            continue
        if src.startswith("--", i):                       # line comment
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in "\"'":                                    # quoted string
            j, esc = i + 1, False
            while j < n:
                if esc:
                    esc = False
                elif src[j] == "\\":
                    esc = True
                elif src[j] == c:
                    break
                elif src[j] == "\n":
                    return None, f"{path}: unterminated string at line {line}"
                j += 1
            if j >= n:
                return None, f"{path}: unterminated string at line {line}"
            out.append('""')
            i = j + 1
            continue
        if c == "\n":
            line += 1
        out.append(c)
        i += 1
    return "".join(out), None


def check(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    code, err = strip(src, path)
    if err:
        return [err]

    problems = []

    # Bracket balance.
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for ln, text in enumerate(code.split("\n"), 1):
        for ch in text:
            if ch in "([{":
                stack.append((ch, ln))
            elif ch in ")]}":
                if not stack or stack[-1][0] != pairs[ch]:
                    problems.append(f"{path}:{ln}: unmatched '{ch}'")
                    return problems
                stack.pop()
    if stack:
        ch, ln = stack[-1]
        problems.append(f"{path}:{ln}: unclosed '{ch}'")

    # Block balance. Push on function/if/do/repeat; `for`/`while` are covered
    # by their own `do`. `end` pops, `until` pops a repeat.
    stack = []
    for ln, text in enumerate(code.split("\n"), 1):
        for m in KW.finditer(text):
            w = m.group(1)
            if w in ("function", "if", "do", "repeat"):
                stack.append((w, ln))
            elif w == "end":
                if not stack:
                    problems.append(f"{path}:{ln}: 'end' with no open block")
                    return problems
                if stack[-1][0] == "repeat":
                    problems.append(f"{path}:{ln}: 'end' closing a repeat (needs 'until')")
                    return problems
                stack.pop()
            elif w == "until":
                if not stack or stack[-1][0] != "repeat":
                    problems.append(f"{path}:{ln}: 'until' with no matching 'repeat'")
                    return problems
                stack.pop()
    for w, ln in stack:
        problems.append(f"{path}:{ln}: unclosed '{w}' block")
    return problems


if __name__ == "__main__":
    bad = 0
    for p in sys.argv[1:]:
        errs = check(p)
        if errs:
            bad += 1
            for e in errs:
                print("FAIL", e)
        else:
            print("ok  ", p)
    sys.exit(1 if bad else 0)
