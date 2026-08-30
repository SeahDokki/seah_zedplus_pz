"""Rough balance check for the ZED+ Lua files.

Not a parser: it strips comments and strings, then checks that brackets and
block keywords balance. Enough to catch a truncated edit before deploying.
"""
import glob
import io
import re
import sys

LONG_COMMENT = re.compile(r"--\[\[.*?\]\]", re.S)
LINE_COMMENT = re.compile(r"--[^\n]*")
DQ_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
SQ_STRING = re.compile(r"'(?:[^'\\]|\\.)*'")
# 'do' after for/while is part of the same block, so it is not counted twice.
OPENERS = re.compile(r"\b(function|if|for|while)\b")
ENDS = re.compile(r"\bend\b")

failed = False

for path in sorted(glob.glob("SZedPlus/42/media/lua/**/*.lua", recursive=True)):
    src = io.open(path, encoding="utf-8").read()

    code = LONG_COMMENT.sub("", src)
    code = LINE_COMMENT.sub("", code)
    code = DQ_STRING.sub('""', code)
    code = SQ_STRING.sub("''", code)

    pairs = {
        "()": (code.count("("), code.count(")")),
        "{}": (code.count("{"), code.count("}")),
        "[]": (code.count("["), code.count("]")),
    }
    opens = len(OPENERS.findall(code))
    ends = len(ENDS.findall(code))

    problems = [name for name, (a, b) in pairs.items() if a != b]
    if opens != ends:
        problems.append("blocks %d open / %d end" % (opens, ends))

    # A local declared after the line that calls it is nil at that point. Lua
    # says nothing; the call throws at runtime, and inside a pcall it vanishes.
    # That is how logOnce shipped defined below the function using it - the
    # Stalker threw on every sweep and its behaviour never changed.
    lines = code.splitlines()
    declared = {}
    for number, line in enumerate(lines, 1):
        # Module level only. A `local` inside a function is scoped to it, and
        # treating one as file-wide reports every other function that happens
        # to reuse the name.
        match = re.match(r"local (?:function )?(\w+)", line)
        if match and match.group(1) not in declared:
            declared[match.group(1)] = number

    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        for name, where in declared.items():
            if number < where and re.search(r"\b%s\s*\(" % re.escape(name), line):
                problems.append("%s used at line %d, declared at %d"
                                % (name, number, where))

    if problems:
        failed = True
        print("FAIL %s : %s" % (path, ", ".join(problems)))
    else:
        print("ok   %s (%d blocks)" % (path, opens))

sys.exit(1 if failed else 0)
