"""Print the JVM descriptors of methods in a .class file.

Usage: methodsig.py <file.class> [name-substring ...]
Minimal constant-pool walk - enough to answer "what does this method take?".
"""
import io
import struct
import sys

TAG_SIZES = {
    7: 2, 8: 2, 16: 2, 19: 2, 20: 2,          # Class, String, MethodType, Module, Package
    9: 4, 10: 4, 11: 4, 12: 4, 17: 4, 18: 4,  # Fieldref, Methodref, ..., Dynamic, InvokeDynamic
    3: 4, 4: 4,                                # Integer, Float
    5: 8, 6: 8,                                # Long, Double
    15: 3,                                     # MethodHandle
}


def parse(path):
    data = io.open(path, "rb").read()
    pos = 10  # magic, minor, major
    count = struct.unpack_from(">H", data, 8)[0]
    pool = {}
    index = 1
    while index < count:
        tag = data[pos]
        pos += 1
        if tag == 1:  # Utf8
            length = struct.unpack_from(">H", data, pos)[0]
            pos += 2
            pool[index] = data[pos:pos + length].decode("utf-8", "replace")
            pos += length
        else:
            pos += TAG_SIZES[tag]
            if tag in (5, 6):  # long/double take two slots
                index += 1
        index += 1

    pos += 6  # access_flags, this_class, super_class
    interfaces = struct.unpack_from(">H", data, pos)[0]
    pos += 2 + interfaces * 2

    def skip_attributes(p):
        n = struct.unpack_from(">H", data, p)[0]
        p += 2
        for _ in range(n):
            length = struct.unpack_from(">I", data, p + 2)[0]
            p += 6 + length
        return p

    def read_members(p):
        count = struct.unpack_from(">H", data, p)[0]
        p += 2
        members = []
        for _ in range(count):
            flags, name_index, desc_index = struct.unpack_from(">HHH", data, p)
            members.append((pool.get(name_index, "?"), pool.get(desc_index, "?"), flags))
            p = skip_attributes(p + 6)
        return members, p

    fields, pos = read_members(pos)
    methods, pos = read_members(pos)
    return fields, methods


# Only the modifiers that change how a method is called from Lua.
ACCESS_FLAGS = (
    (0x0008, "static"),
    (0x0001, "public"),
    (0x0002, "private"),
    (0x0004, "protected"),
    (0x0400, "abstract"),
)


def describe_flags(flags):
    return " ".join(name for bit, name in ACCESS_FLAGS if flags & bit)


if __name__ == "__main__":
    path = sys.argv[1]
    needles = [n.lower() for n in sys.argv[2:]]
    fields, methods = parse(path)

    def show(kind, members):
        rows = [m for m in sorted(members)
                if not needles or any(n in m[0].lower() for n in needles)]
        if not rows:
            return
        print("--- %s ---" % kind)
        for name, descriptor, flags in rows:
            print("%-34s %-26s %s" % (name, descriptor, describe_flags(flags)))

    # Fields matter as much as methods here: Project Zomboid's Lua binding
    # exposes public Java fields directly, so a field with no setter can still
    # be writable from Lua.
    show("fields", fields)
    show("methods", methods)
