#!/usr/bin/env python3
"""Rewrites the LC_DYLD_ENVIRONMENT load commands of a thin arm64/x86_64 Mach-O executable in place, using the
header padding after the load commands. For bundling WebKit's XPC services inside WebKit.framework (their
build-layout paths say "@executable_path/../../..": next to the frameworks, not inside one).
    set-dyld-env.py <binary> NAME=value [NAME=value ...]   (replaces all existing LC_DYLD_ENVIRONMENT commands)
The code signature is invalid afterwards: sign again."""
import struct, sys

LC_DYLD_ENVIRONMENT = 0x27
path, env = sys.argv[1], sys.argv[2:]
data = bytearray(open(path, "rb").read())
magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, 0)
if magic != 0xFEEDFACF: sys.exit("not a thin 64-bit Mach-O")
hdr = 32
cmds, off, first_data = [], hdr, len(data)
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    cmds.append(bytes(data[off:off + size]))
    if cmd in (0x19,):  # LC_SEGMENT_64: find the first section's file offset (end of header room)
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        for s in range(nsects):
            so = off + 72 + s * 80
            sec_off = struct.unpack_from("<I", data, so + 48)[0]
            if sec_off: first_data = min(first_data, sec_off)
    off += size
kept = [c for c in cmds if struct.unpack_from("<I", c, 0)[0] != LC_DYLD_ENVIRONMENT]
def env_cmd(s):
    b = s.encode() + b"\0"
    size = (12 + len(b) + 7) // 8 * 8
    return struct.pack("<III", LC_DYLD_ENVIRONMENT, size, 12) + b + b"\0" * (size - 12 - len(b))
# Put them where the old ones were (before LC_CODE_SIGNATURE etc. order doesn't matter to dyld, but keep it tidy).
new = kept[:-1] + [env_cmd(e) for e in env] + kept[-1:] if kept else [env_cmd(e) for e in env]
blob = b"".join(new)
if hdr + len(blob) > first_data: sys.exit(f"no room: need {hdr + len(blob)}, have {first_data}")
struct.pack_into("<II", data, 16, len(new), len(blob))
data[hdr:hdr + len(blob)] = blob
data[hdr + len(blob):max(hdr + sizeofcmds, hdr + len(blob))] = b"\0" * (max(hdr + sizeofcmds, hdr + len(blob)) - hdr - len(blob))
open(path, "wb").write(data)
print(f"{path}: {len(new)} load commands, {len(blob)} bytes (room {first_data - hdr})")
