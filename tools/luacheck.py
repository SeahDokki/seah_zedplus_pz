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

    if problems:
        failed = True
        print("FAIL %s : %s" % (path, ", ".join(problems)))
    else:
        print("ok   %s (%d blocks)" % (path, opens))

sys.exit(1 if failed else 0)
