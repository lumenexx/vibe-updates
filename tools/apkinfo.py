"""What an APK is, read without the Android SDK: python3 -I tools/apkinfo.py <apk>

Prints JSON: package, versionCode, versionName, debuggable, signerSha256 (the SHA-256 of the first v2/v3 signer
certificate, as `keytool -exportcert ... | sha256sum` prints it for the key), sha256 and size of the file.
Exits 1 when the APK cannot be read.
"""
import hashlib
import json
import struct
import sys
import zipfile

ANDROID_NS = "http://schemas.android.com/apk/res/android"


def signer_cert_sha256(data):
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        return None
    cd_off = struct.unpack("<I", data[eocd + 16:eocd + 20])[0]
    if data[cd_off - 16:cd_off] != b"APK Sig Block 42":
        return None
    size = struct.unpack("<Q", data[cd_off - 24:cd_off - 16])[0]
    pos, end = cd_off - size - 8 + 8, cd_off - 24
    while pos < end:
        length = struct.unpack("<Q", data[pos:pos + 8])[0]
        block_id = struct.unpack("<I", data[pos + 8:pos + 12])[0]
        value = data[pos + 12:pos + 8 + length]
        if block_id in (0x7109871A, 0xF05368C0):  # v2, v3
            signer_len = struct.unpack("<I", value[4:8])[0]
            signer = value[8:8 + signer_len]
            signed_len = struct.unpack("<I", signer[0:4])[0]
            signed = signer[4:4 + signed_len]
            digests_len = struct.unpack("<I", signed[0:4])[0]
            p = 4 + digests_len + 4
            cert_len = struct.unpack("<I", signed[p:p + 4])[0]
            return hashlib.sha256(signed[p + 4:p + 4 + cert_len]).hexdigest()
        pos += 8 + length
    return None


def read_string_pool(data, pos, header_size):
    count, _styles, flags, strings_start, _styles_start = struct.unpack_from("<IIIII", data, pos + 8)
    utf8 = bool(flags & (1 << 8))
    offsets = struct.unpack_from("<%dI" % count, data, pos + header_size)
    base = pos + strings_start
    out = []
    for off in offsets:
        p = base + off
        if utf8:
            n = data[p]
            p += 2 if n & 0x80 else 1  # UTF-16 length, skipped
            n = data[p]
            if n & 0x80:
                n = ((n & 0x7F) << 8) | data[p + 1]
                p += 2
            else:
                p += 1
            out.append(data[p:p + n].decode("utf-8", "replace"))
        else:
            n = struct.unpack_from("<H", data, p)[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", data, p)[0]
                p += 2
            out.append(data[p:p + 2 * n].decode("utf-16-le", "replace"))
    return out


def manifest_facts(xml):
    """package / versionCode / versionName from <manifest>, debuggable from <application> (binary AndroidManifest)."""
    typ, header_size, _size = struct.unpack_from("<HHI", xml, 0)
    if typ != 0x0003:
        raise ValueError("not a binary XML manifest")
    pos = header_size
    strings = []
    facts = {"package": None, "versionCode": None, "versionName": None, "debuggable": False}
    while pos + 8 <= len(xml):
        ctype, chsize, csize = struct.unpack_from("<HHI", xml, pos)
        if csize <= 0:
            break
        if ctype == 0x0001:
            strings = read_string_pool(xml, pos, chsize)
        elif ctype == 0x0102:  # start element
            _ns, name_idx, attr_start, attr_size, attr_count = struct.unpack_from("<iIHHH", xml, pos + 16)
            element = strings[name_idx] if 0 <= name_idx < len(strings) else ""
            if element in ("manifest", "application"):
                a = pos + 16 + attr_start
                for i in range(attr_count):
                    _ans, aname, raw, _tsize, _res0, dtype, dval = struct.unpack_from("<iIIHBBI", xml, a + i * attr_size)
                    key = strings[aname] if aname < len(strings) else ""
                    text = strings[raw] if raw != 0xFFFFFFFF and raw < len(strings) else None
                    if dtype == 0x03 and text is None and dval < len(strings):
                        text = strings[dval]
                    if element == "manifest" and key == "package":
                        facts["package"] = text
                    elif element == "manifest" and key == "versionCode":
                        facts["versionCode"] = dval if dtype in (0x10, 0x11) else (int(text) if text else None)
                    elif element == "manifest" and key == "versionName":
                        facts["versionName"] = text
                    elif element == "application" and key == "debuggable":
                        facts["debuggable"] = dtype == 0x12 and dval != 0
        pos += csize
    return facts


def apk_info(path):
    data = open(path, "rb").read()
    with zipfile.ZipFile(path) as z:
        facts = manifest_facts(z.read("AndroidManifest.xml"))
    facts["signerSha256"] = signer_cert_sha256(data)
    facts["sha256"] = hashlib.sha256(data).hexdigest()
    facts["size"] = len(data)
    return facts


if __name__ == "__main__":
    try:
        print(json.dumps(apk_info(sys.argv[1]), indent=2))
    except Exception as e:  # noqa: BLE001 - any unreadable APK is one answer
        print("apkinfo: cannot read %s: %s" % (sys.argv[1] if len(sys.argv) > 1 else "(no file)", e), file=sys.stderr)
        sys.exit(1)
