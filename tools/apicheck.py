"""Check every Java method the mod calls actually exists.

Lua gives no warning for a method that is not there - the call throws at
runtime, and inside a pcall it vanishes without a trace. That cost two bugs
found only by playing: `getForwardDirectionX()` never existed (only
`getForwardDirection()` does, returning a Vector2), and `setHearing()` was a
field, not a setter.

Checking a name against the whole jar is not enough, and worse than useless:
`getForwardDirectionX` IS declared somewhere in there, just not on anything a
player variable holds, so a jar-wide check passed it and the bug shipped. The
receiver has to be part of the question.

There is no type inference here. Instead the mod names its variables
consistently - `zombie`, `player`, `square`, `weapon` - so RECEIVERS maps those
names to a class, and the call is checked against that class and everything it
inherits. Calls on any other receiver are checked jar-wide, which still catches
an outright invented name.

    python tools/apicheck.py

Exit code is 1 if anything is unknown, so it can gate a deploy.
"""

import os
import re
import struct
import sys
import zipfile

JAR = r"D:\SteamLibrary\steamapps\common\ProjectZomboid\projectzomboid.jar"
VANILLA_LUA = r"D:\SteamLibrary\steamapps\common\ProjectZomboid\media\lua"
LUA_ROOT = os.path.join("SZedPlus", "42", "media", "lua")

# Variable name -> the class it holds, for the receivers the mod uses often.
# Wrong only if a name is reused for something else, which the naming rules in
# CLAUDE.md already rule out.
RECEIVERS = {
    "zombie": "zombie/characters/IsoZombie",
    "player": "zombie/characters/IsoPlayer",
    "nearby": "zombie/characters/IsoPlayer",
    "attacker": "zombie/characters/IsoGameCharacter",
    "wielder": "zombie/characters/IsoGameCharacter",
    "square": "zombie/iso/IsoGridSquare",
    "weapon": "zombie/inventory/types/HandWeapon",
    # Clothing, not InventoryItem: every `item` the mod touches is a garment,
    # and getCoveredParts / getWaterResistance / setDirtiness live there. As
    # Clothing extends InventoryItem this accepts strictly more, so it can miss
    # a clothing method called on a plain item - the safe direction to err.
    "item": "zombie/inventory/types/Clothing",
    "visual": "zombie/core/skinnedmodel/visual/ItemVisual",
    "object": "zombie/iso/IsoObject",
    "part": "zombie/characters/BodyDamage/BodyPart",
}

# Lua's own methods, and ours: not Java, so not the jar's job to know them.
IGNORE = {
    # Lua string/table library, reached with ':'
    "format", "gsub", "sub", "find", "len", "rep", "upper", "lower", "byte",
    "char", "match", "gmatch", "insert", "remove", "concat", "sort",
}


def java_method_names(jar_path):
    """Every method name declared by any class in the jar."""
    names = set()
    with zipfile.ZipFile(jar_path) as jar:
        for entry in jar.namelist():
            if not entry.endswith(".class"):
                continue
            try:
                names |= _method_names(jar.read(entry))
            except Exception:
                continue
    return names


def _method_names(data):
    """Method names from one class file, read straight from the constant pool.

    Every method name is a Utf8 entry, so collecting all of them over-collects
    (field names and descriptors come too). That is the right trade here: this
    check only ever reports a name found NOWHERE, so a wider pool means fewer
    false alarms and never a missed real method.
    """
    count = struct.unpack_from(">H", data, 8)[0]
    pos, index, names = 10, 1, set()

    while index < count:
        tag = data[pos]
        if tag == 1:
            length = struct.unpack_from(">H", data, pos + 1)[0]
            text = data[pos + 3:pos + 3 + length].decode("utf8", "replace")
            if text.isidentifier():
                names.add(text)
            pos += 3 + length
        elif tag in (7, 8, 16, 19, 20):
            pos += 3
        elif tag == 15:
            pos += 4
        elif tag in (3, 4):
            pos += 5
        elif tag in (5, 6):
            pos += 9
            index += 1
        else:
            pos += 5
        index += 1

    return names


def class_methods(jar, internal_name, cache):
    """Methods declared by a class and by everything it inherits."""
    if internal_name in cache:
        return cache[internal_name]

    cache[internal_name] = set()          # guards a cycle
    try:
        data = jar.read(internal_name + ".class")
    except KeyError:
        return cache[internal_name]

    names, super_name = _declared_methods(data)
    if super_name and super_name != "java/lang/Object":
        names |= class_methods(jar, super_name, cache)

    cache[internal_name] = names
    return names


def _declared_methods(data):
    """The methods a class declares, and the name of its superclass."""
    count = struct.unpack_from(">H", data, 8)[0]
    pos, index, pool = 10, 1, {}

    while index < count:
        tag = data[pos]
        if tag == 1:
            length = struct.unpack_from(">H", data, pos + 1)[0]
            pool[index] = data[pos + 3:pos + 3 + length].decode("utf8", "replace")
            pos += 3 + length
        elif tag == 7:
            pool[index] = ("class", struct.unpack_from(">H", data, pos + 1)[0])
            pos += 3
        elif tag in (8, 16, 19, 20):
            pos += 3
        elif tag == 15:
            pos += 4
        elif tag in (3, 4):
            pos += 5
        elif tag in (5, 6):
            pos += 9
            index += 1
        else:
            pos += 5
        index += 1

    pos += 2                                          # access flags
    pos += 2                                          # this class
    super_index = struct.unpack_from(">H", data, pos)[0]
    pos += 2

    super_name = None
    entry = pool.get(super_index)
    if isinstance(entry, tuple):
        super_name = pool.get(entry[1])

    pos += 2 + struct.unpack_from(">H", data, pos)[0] * 2   # interfaces

    names = set()
    for section in ("fields", "methods"):
        total = struct.unpack_from(">H", data, pos)[0]
        pos += 2
        for _ in range(total):
            name = pool.get(struct.unpack_from(">H", data, pos + 2)[0])
            if section == "methods" and isinstance(name, str):
                names.add(name)
            pos += 6
            attributes = struct.unpack_from(">H", data, pos)[0]
            pos += 2
            for _ in range(attributes):
                length = struct.unpack_from(">I", data, pos + 2)[0]
                pos += 6 + length

    return names, super_name


def lua_defined_methods(*roots):
    """Method names defined in Lua rather than Java.

    The UI framework is Lua: ISPanel:render, ISCollapsableWindow:titleBarHeight
    and the rest are never in the jar, and neither are our own. Without this the
    check reports them all and becomes noise nobody reads.
    """
    names = set()
    patterns = [
        re.compile(r"function\s+[\w.]+[:.](\w+)\s*\("),
        re.compile(r"[\w.]+[:.](\w+)\s*=\s*function"),
    ]

    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for directory, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".lua"):
                    continue
                try:
                    with open(os.path.join(directory, name),
                              encoding="utf-8", errors="replace") as handle:
                        text = handle.read()
                except OSError:
                    continue
                for pattern in patterns:
                    names |= set(pattern.findall(text))
    return names


def lua_calls(root):
    """Every `:name(` call in the mod, with where it appears."""
    calls = {}
    pattern = re.compile(r"(\w*)\s*:\s*([A-Za-z_]\w*)\s*\(")

    for directory, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".lua"):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, 1):
                    code = line.split("--", 1)[0]
                    for receiver, method in pattern.findall(code):
                        calls.setdefault((receiver, method), []).append((path, number))
    return calls


def main():
    if not os.path.exists(JAR):
        print("jar not found: %s" % JAR)
        return 2
    if not os.path.isdir(LUA_ROOT):
        print("run this from the repo root")
        return 2

    anywhere = java_method_names(JAR)
    anywhere |= lua_defined_methods(VANILLA_LUA, LUA_ROOT)
    calls = lua_calls(LUA_ROOT)

    unknown = []
    typed = 0

    with zipfile.ZipFile(JAR) as jar:
        cache = {}
        for (receiver, method), sites in sorted(calls.items()):
            if method in IGNORE or method.startswith("SZedPlus"):
                continue

            internal = RECEIVERS.get(receiver)
            if internal:
                typed += 1
                # A Lua-side helper can be attached to anything, so those still
                # count as known even on a typed receiver.
                if method in class_methods(jar, internal, cache):
                    continue
                if method in lua_defined_methods(LUA_ROOT):
                    continue
                unknown.append((receiver, method, internal.split("/")[-1], sites))
            elif method not in anywhere:
                unknown.append((receiver or "?", method, "any class", sites))

    if not unknown:
        print("api  %d call site(s), %d against a known receiver, all resolve"
              % (len(calls), typed))
        return 0

    print("api  %d NOT FOUND:" % len(unknown))
    for receiver, method, where, sites in unknown:
        path, number = sites[0]
        print("  %s:%s  not on %s  (%s:%d)" % (receiver, method, where, path, number))
    return 1


if __name__ == "__main__":
    sys.exit(main())
