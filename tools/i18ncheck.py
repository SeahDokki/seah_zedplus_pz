"""Check the ZED+ translations.

- every locale defines the same keys as EN
- every `translation =` / `page =` in sandbox-options.txt has an EN entry
- no stray legacy .txt file is left behind (B42 loads .json only)
"""
import glob
import io
import json
import os
import re
import sys

ROOT = "SZedPlus/42/media/lua/shared/Translate"
# CN is Simplified Chinese, contributed by a player. Vanilla uses CN for
# Simplified and CH for Traditional - do not swap them.
LANGS = ("EN", "FR", "ES", "DE", "CN")

OPT_TRANSLATION = re.compile(r"^\s*translation\s*=\s*(\w+)\s*,", re.M)
OPT_PAGE = re.compile(r"^\s*page\s*=\s*(\w+)\s*,", re.M)

failed = False

# B42 dropped the .txt translation format entirely.
stale = glob.glob(os.path.join(ROOT, "*", "*.txt"))
if stale:
    failed = True
    print("FAIL legacy .txt files still present: %s" % sorted(stale))

# ---------------------------------------------------------------- locales --
for name in ("Sandbox", "IG_UI"):
    keys_by_lang = {}
    for lang in LANGS:
        path = os.path.join(ROOT, lang, "%s.json" % name)
        if not os.path.exists(path):
            failed = True
            print("FAIL missing %s" % path)
            continue
        try:
            data = json.load(io.open(path, encoding="utf-8"))
        except ValueError as exc:
            failed = True
            print("FAIL invalid JSON in %s : %s" % (path, exc))
            continue
        keys_by_lang[lang] = set(data)

    if "EN" not in keys_by_lang:
        continue
    reference = keys_by_lang["EN"]
    for lang, keys in sorted(keys_by_lang.items()):
        missing = reference - keys
        extra = keys - reference
        if missing or extra:
            failed = True
            print("FAIL %s/%s : missing=%s extra=%s"
                  % (name, lang, sorted(missing), sorted(extra)))
    print("%-8s %d keys x %d locales" % (name, len(reference), len(keys_by_lang)))

# ------------------------------------------------------- sandbox coverage --
options = io.open("SZedPlus/42/media/sandbox-options.txt", encoding="utf-8").read()
en_keys = set(json.load(io.open(os.path.join(ROOT, "EN", "Sandbox.json"), encoding="utf-8")))

referenced = {"Sandbox_" + n for n in OPT_TRANSLATION.findall(options)}
referenced |= {"Sandbox_" + n for n in set(OPT_PAGE.findall(options))}

undefined = referenced - en_keys
if undefined:
    failed = True
    print("FAIL options with no translation: %s" % sorted(undefined))
else:
    print("sandbox  all %d option/page keys translated" % len(referenced))

unused = {k for k in en_keys if not k.endswith("_tooltip")} - referenced
if unused:
    print("note: translated but unreferenced: %s" % sorted(unused))

# ------------------------------------------------- getText() coverage -----
en_igui = set(json.load(io.open(os.path.join(ROOT, "EN", "IG_UI.json"), encoding="utf-8")))
GETTEXT = re.compile(r'getText\(\s*"(IGUI_SZedPlus_\w+)"')
LABELFIELD = re.compile(r'label\s*=\s*"(IGUI_SZedPlus_\w+)"')

used = set()
for lua in glob.glob("SZedPlus/42/media/lua/**/*.lua", recursive=True):
    text = io.open(lua, encoding="utf-8").read()
    used |= set(GETTEXT.findall(text))
    used |= set(LABELFIELD.findall(text))

missing = used - en_igui
if missing:
    failed = True
    print("FAIL getText keys with no IG_UI entry: %s" % sorted(missing))
else:
    print("getText  all %d IGUI_SZedPlus keys used in Lua are defined" % len(used))

sys.exit(1 if failed else 0)
