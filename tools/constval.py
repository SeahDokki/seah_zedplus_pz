"""Read the ConstantValue of static final fields in a .class file."""
import io, struct, sys

SIZES = {7:2,8:2,16:2,19:2,20:2,9:4,10:4,11:4,12:4,17:4,18:4,3:4,4:4,5:8,6:8,15:3}

def parse(path):
    data = io.open(path,"rb").read()
    pos = 10
    count = struct.unpack_from(">H", data, 8)[0]
    utf, ints = {}, {}
    i = 1
    while i < count:
        tag = data[pos]; pos += 1
        if tag == 1:
            n = struct.unpack_from(">H", data, pos)[0]; pos += 2
            utf[i] = data[pos:pos+n].decode("utf-8","replace"); pos += n
        elif tag == 3:
            ints[i] = struct.unpack_from(">i", data, pos)[0]; pos += 4
        else:
            pos += SIZES[tag]
            if tag in (5,6): i += 1
        i += 1
    pos += 6
    pos += 2 + struct.unpack_from(">H", data, pos)[0]*2

    nfields = struct.unpack_from(">H", data, pos)[0]; pos += 2
    out = []
    for _ in range(nfields):
        flags, ni, di = struct.unpack_from(">HHH", data, pos)
        pos += 6
        nattr = struct.unpack_from(">H", data, pos)[0]; pos += 2
        value = None
        for _ in range(nattr):
            ani = struct.unpack_from(">H", data, pos)[0]
            alen = struct.unpack_from(">I", data, pos+2)[0]
            if utf.get(ani) == "ConstantValue":
                vi = struct.unpack_from(">H", data, pos+6)[0]
                value = ints.get(vi)
            pos += 6 + alen
        out.append((utf.get(ni,"?"), utf.get(di,"?"), value))
    return out

if __name__ == "__main__":
    needles = [n.lower() for n in sys.argv[2:]]
    for name, desc, value in sorted(parse(sys.argv[1])):
        if value is not None and (not needles or any(n in name.lower() for n in needles)):
            print("%-34s %-4s = %s" % (name, desc, value))
