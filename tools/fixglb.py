"""Rewrite a GLB so Project Zomboid can build its skeleton.

Three differences separate a mesh the engine imports correctly from one it does
not, found by diffing an itch.io model against the dinosaur mod's Velociraptor:

  1. The skin declares no `skeleton` root, so the engine does not know where the
     hierarchy starts and ends up one bone short.
  2. The mesh node sits inside the armature. Working models keep the mesh as a
     separate root of the scene, with the skin binding them.
  3. The skeleton root sits under a Blender `Armature` node carrying a scale and
     a translation. The engine does not apply that parent transform when it
     builds the skeleton, so the whole rig comes out squashed. Working models
     have the skeleton root directly at the scene root.
  4. The skin declares trailing joints that no vertex is ever weighted to.
     Blender exports every bone in the armature, including helpers and IK
     targets. The engine sizes its animation tracks from what the mesh actually
     uses and then indexes by declared joint, so a joint nobody references
     becomes an out-of-bounds read.

All three are structural, so all three can be fixed in the glTF JSON without
touching a single vertex. The binary chunk is copied through untouched.

Usage: fixglb.py <in.glb> <out.glb>
"""
import io
import json
import struct
import sys


def read_glb(path):
    data = io.open(path, "rb").read()
    magic, version, _ = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise SystemExit("not a GLB: %s" % path)

    chunks = []
    pos = 12
    while pos < len(data):
        length, ctype = struct.unpack_from("<II", data, pos)
        chunks.append((ctype, data[pos + 8:pos + 8 + length]))
        pos += 8 + length
    return version, chunks


def write_glb(path, version, chunks):
    body = b""
    for ctype, payload in chunks:
        pad = b"\x20" if ctype == 0x4E4F534A else b"\x00"
        while len(payload) % 4:
            payload += pad
        body += struct.pack("<II", len(payload), ctype) + payload

    total = 12 + len(body)
    io.open(path, "wb").write(struct.pack("<III", 0x46546C67, version, total) + body)


def fix(js):
    nodes = js["nodes"]
    skins = js.get("skins", [])
    if not skins:
        raise SystemExit("no skin: nothing to fix")

    changes = []

    # Map every node to its parent, so roots can be identified.
    parent = {}
    for index, node in enumerate(nodes):
        for child in node.get("children", []):
            parent[child] = index

    for skin in skins:
        joints = skin["joints"]

        # 1. Declare the skeleton root: the joint that has no parent among the
        #    joints. That is where the hierarchy actually begins.
        if "skeleton" not in skin:
            joint_set = set(joints)
            roots = [j for j in joints if parent.get(j) not in joint_set]
            root = roots[0] if roots else joints[0]
            skin["skeleton"] = root
            changes.append("skeleton root set to node %d ('%s')"
                           % (root, nodes[root].get("name", "?")))

    # 2. Lift the skeleton root out of its armature wrapper, folding that
    #    wrapper's transform into it so the pose is preserved.
    for skin in skins:
        root = skin.get("skeleton")
        if root is None:
            continue
        owner = parent.get(root)
        if owner is None:
            continue

        wrapper = nodes[owner]
        bone = nodes[root]

        ws = wrapper.get("scale", [1.0, 1.0, 1.0])
        wt = wrapper.get("translation", [0.0, 0.0, 0.0])
        bs = bone.get("scale", [1.0, 1.0, 1.0])
        bt = bone.get("translation", [0.0, 0.0, 0.0])

        # No rotation on either in practice; refuse rather than silently
        # mangling the pose if one appears.
        if wrapper.get("rotation") or wrapper.get("matrix"):
            changes.append("WARNING: '%s' carries a rotation - left in place"
                           % wrapper.get("name", "?"))
            continue

        bone["scale"] = [ws[i] * bs[i] for i in range(3)]
        bone["translation"] = [wt[i] + ws[i] * bt[i] for i in range(3)]

        nodes[owner]["children"] = [c for c in wrapper.get("children", [])
                                    if c != root]
        if not nodes[owner]["children"]:
            del nodes[owner]["children"]
        del parent[root]

        changes.append("skeleton root '%s' lifted out of '%s' (scale %.4f folded in)"
                       % (bone.get("name", "?"), wrapper.get("name", "?"), ws[0]))

    # 3. Move every skinned mesh node out of the armature and make it a root of
    #    the scene. The skin keeps the binding, so nothing is lost.
    scene = js["scenes"][js.get("scene", 0)]
    scene_nodes = scene.setdefault("nodes", [])

    # The skeleton root belongs at the scene root too, now that it is detached.
    for skin in skins:
        root = skin.get("skeleton")
        if root is not None and parent.get(root) is None and root not in scene_nodes:
            scene_nodes.append(root)
            changes.append("skeleton root %d added as a scene root" % root)

    for index, node in enumerate(nodes):
        if "mesh" not in node or "skin" not in node:
            continue

        owner = parent.get(index)
        if owner is not None:
            nodes[owner]["children"] = [c for c in nodes[owner].get("children", [])
                                        if c != index]
            if not nodes[owner]["children"]:
                del nodes[owner]["children"]
            changes.append("mesh node %d ('%s') detached from '%s'"
                           % (index, node.get("name", "?"),
                              nodes[owner].get("name", "?")))

        if index not in scene_nodes:
            scene_nodes.append(index)
            changes.append("mesh node %d added as a scene root" % index)

    return changes


def prune_joints(js, binchunk):
    """Drop trailing joints that no vertex is weighted to.

    Only trailing ones: removing a joint in the middle would renumber every
    index in JOINTS_0 and mean rewriting the binary chunk. Trailing joints can
    simply be cut, because no index points past the last used one.
    """
    changes = []
    component = {5121: ("B", 1), 5123: ("H", 2), 5125: ("I", 4)}

    for skin in js.get("skins", []):
        joints = skin["joints"]

        used = set()
        for mesh in js.get("meshes", []):
            for prim in mesh["primitives"]:
                index = prim["attributes"].get("JOINTS_0")
                if index is None:
                    continue
                acc = js["accessors"][index]
                view = js["bufferViews"][acc["bufferView"]]
                fmt, _ = component[acc["componentType"]]
                offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
                values = struct.unpack_from("<%d%s" % (acc["count"] * 4, fmt),
                                            binchunk, offset)
                used.update(values)

        if not used:
            continue

        keep = max(used) + 1
        if keep >= len(joints):
            continue

        dropped = len(joints) - keep
        skin["joints"] = joints[:keep]

        # The inverse bind matrices are parallel to the joint list.
        if "inverseBindMatrices" in skin:
            js["accessors"][skin["inverseBindMatrices"]]["count"] = keep

        changes.append("pruned %d unweighted trailing joint(s): %d -> %d"
                       % (dropped, len(joints), keep))

    return changes


if __name__ == "__main__":
    source, target = sys.argv[1], sys.argv[2]
    version, chunks = read_glb(source)

    binchunk = next((p for t, p in chunks if t == 0x004E4942), b"")

    out = []
    for ctype, payload in chunks:
        if ctype == 0x4E4F534A:  # JSON
            js = json.loads(payload.decode("utf-8"))
            for line in fix(js) + prune_joints(js, binchunk):
                print("  " + line)
            payload = json.dumps(js, separators=(",", ":")).encode("utf-8")
        out.append((ctype, payload))

    write_glb(target, version, out)
    print("written: %s" % target)
