#!/usr/bin/env python3
"""
mkipk.py — 不依赖 OpenWrt SDK, 直接把包目录打成 opkg 能装的 .ipk

*格式照抄官方包*（这一点搞错的话 opkg 只会回一句 Malformed package file）:

    .ipk = gzip( tar(
                ./debian-binary      内容 "2.0\\n"
                ./data.tar.gz        正式文件树 (相对根目录)
                ./control.tar.gz     含 ./control ./postinst ./prerm ./conffiles
            ) )

注意不是 Debian 那种裸 ar 归档 —— OpenWrt 的 opkg 只认上面这个 gz+tar 结构。

用法:
    python tools/mkipk.py pkg/nnnu-auth [-o dist/]
    python tools/mkipk.py pkg/nnnu-auth --verify dist/nnnu-auth_1.2.0-1_all.ipk
    python tools/mkipk.py pkg/nnnu-auth --compare /path/to/official.ipk

包目录约定:
    pkg/<name>/control/control          必需
    pkg/<name>/control/postinst         可选 (自动 chmod 755)
    pkg/<name>/control/prerm            可选
    pkg/<name>/control/conffiles        可选
    pkg/<name>/data/**                  要装进路由器的文件树
"""
import argparse
import gzip
import io
import os
import sys
import tarfile
import time

AR_MAGIC = b"!<arch>\n"      # 只用于识别(读取)老的裸 ar 包, 打包一律用 gzip+tar


def _resolve_mode(full: str, info: tarfile.TarInfo, override) -> int:
    """
    决定打包用的权限位。
    注意: Windows 上 os.stat 看不到执行位, 不能只看 info.mode, 否则打出来的
    init.d / hotplug / uci-defaults 全是 644, 装到路由器上服务根本起不来。
    优先级: 显式覆盖 > 目录 > 有 shebang 的脚本 > 0644
    """
    if override is not None:
        return override
    if info.isdir():
        return 0o755
    try:
        with open(full, "rb") as fh:
            if fh.read(2) == b"#!":
                return 0o755
    except OSError:
        pass
    if (info.mode & 0o111) and os.name != "nt":
        return 0o755
    return 0o644


def _tar_gz(src_dir: str, files: list, epoch: int, modes: dict = None) -> bytes:
    """files 是相对 src_dir 的路径列表; 全部以 root:root 打包, 保证可复现"""
    buf = io.BytesIO()
    # mtime 固定 + 不写文件名, 让产物可重复构建
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=epoch) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for rel in sorted(files):
                full = os.path.join(src_dir, rel)
                info = tar.gettarinfo(full, arcname="./" + rel)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mtime = epoch
                info.mode = _resolve_mode(full, info, (modes or {}).get(rel))
                if info.isdir():
                    tar.addfile(info)
                else:
                    with open(full, "rb") as fh:
                        tar.addfile(info, fh)
    return buf.getvalue()


def _walk(root: str) -> list:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        for d in dirnames:
            p = os.path.relpath(os.path.join(dirpath, d), root)
            out.append(p)
        for f in filenames:
            out.append(os.path.relpath(os.path.join(dirpath, f), root))
    return out


def parse_control(path: str) -> dict:
    fields, last = {}, None
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if not line.strip():
                continue
            if line[0] in " \t" and last:      # 续行
                fields[last] += "\n" + line
                continue
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            last = k.strip()
            fields[last] = v.strip()
    return fields


def build(pkgdir: str, outdir: str) -> str:
    pkgdir = os.path.abspath(pkgdir)
    ctl_dir = os.path.join(pkgdir, "control")
    data_dir = os.path.join(pkgdir, "data")
    if not os.path.isdir(ctl_dir) or not os.path.isfile(os.path.join(ctl_dir, "control")):
        raise SystemExit("缺少 %s/control/control" % pkgdir)
    if not os.path.isdir(data_dir):
        raise SystemExit("缺少 %s/data/" % pkgdir)

    ctl = parse_control(os.path.join(ctl_dir, "control"))
    for k in ("Package", "Version", "Architecture", "Description"):
        if not ctl.get(k):
            raise SystemExit("control 里缺少必需字段: %s" % k)

    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "1700000000"))

    # ---- control.tar.gz ----
    ctl_modes = {"postinst": 0o755, "prerm": 0o755, "postrm": 0o755, "preinst": 0o755}
    ctl_files = _walk(ctl_dir)
    control_tar = _tar_gz(ctl_dir, ctl_files, epoch, ctl_modes)

    # ---- data.tar.gz ----
    data_files = _walk(data_dir)
    data_tar = _tar_gz(data_dir, data_files, epoch)

    # ---- 外层: gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz)) ----
    #
    # 关键: OpenWrt 的 opkg 只认这个"gz 包 tar"格式(官方 ipk 实测如此),
    # 传统 Debian 那种裸 ar 归档会被判成 "Malformed package file"。
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=epoch) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for member, blob in (
                ("./debian-binary", b"2.0\n"),
                ("./data.tar.gz", data_tar),
                ("./control.tar.gz", control_tar),
            ):
                info = tarfile.TarInfo(member)
                info.size = len(blob)
                info.mode = 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = epoch
                tar.addfile(info, io.BytesIO(blob))

    os.makedirs(outdir, exist_ok=True)
    name = "%s_%s_%s.ipk" % (ctl["Package"], ctl["Version"], ctl["Architecture"])
    path = os.path.join(outdir, name)
    with open(path, "wb") as fh:
        fh.write(buf.getvalue())
    return path


def read_ipk(path: str) -> dict:
    """
    读取 ipk 的外层成员。OpenWrt 的 ipk = gzip(tar(...)), 这里也兼容老的裸 ar,
    方便对着官方包做对比。
    """
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        blob = gzip.decompress(raw)
        fmt = "gzip+tar"
    elif raw.startswith(AR_MAGIC):
        blob = raw
        fmt = "ar"
    else:
        return {"fmt": "未知", "members": {}, "raw": raw}

    members = {}
    if fmt == "gzip+tar":
        tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:")
        for m in tf.getmembers():
            if m.isfile():
                members[m.name.lstrip("./")] = tf.extractfile(m).read()
    else:
        pos = len(AR_MAGIC)
        while pos + 60 <= len(raw):
            header = raw[pos:pos + 60]
            if header[58:60] != b"\x60\n":
                break
            name = header[0:16].decode().strip()
            size = int(header[48:58].decode().strip())
            pos += 60
            members[name] = raw[pos:pos + size]
            pos += size + (size % 2)
    return {"fmt": fmt, "members": members, "raw": raw}


def verify(path: str) -> int:
    """把生成的 ipk 拆回来检查, 确认 opkg 会看到什么"""
    info = read_ipk(path)
    raw, members, fmt = info["raw"], info["members"], info["fmt"]

    ok = True
    print("== %s ==" % os.path.basename(path))
    print("  外层格式: %s (官方 opkg 认的是 gzip+tar)" % fmt)
    if fmt != "gzip+tar":
        print("!! 外层不是 gzip+tar, opkg 会报 Malformed package file")
        ok = False

    for want in ("debian-binary", "data.tar.gz", "control.tar.gz"):
        if want not in members:
            print("!! 缺少成员 %s" % want)
            ok = False
    if members.get("debian-binary") != b"2.0\n":
        print("!! debian-binary 内容不对: %r" % members.get("debian-binary"))
        ok = False
    if not members.get("data.tar.gz", b"").startswith(b"\x1f\x8b"):
        print("!! data.tar.gz 不是 gzip")
        ok = False
    if not members.get("control.tar.gz", b"").startswith(b"\x1f\x8b"):
        print("!! control.tar.gz 不是 gzip")
        ok = False

    print("  大小: %d 字节" % len(raw))

    def _list(blob, label):
        tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
        return [(m.name, m.mode, m.uid, m.gid, m.size) for m in tf.getmembers()]

    if "control.tar.gz" in members and "data.tar.gz" in members:
        print("  [control.tar.gz]")
        for name, mode, uid, gid, size in _list(members["control.tar.gz"], "control"):
            print("    %-28s %04o %d:%d %d" % (name, mode, uid, gid, size))
        print("  [data.tar.gz]")
        for name, mode, uid, gid, size in _list(members["data.tar.gz"], "data"):
            print("    %-52s %04o %d:%d %d" % (name, mode, uid, gid, size))

        ctl = parse_control_from_tar(members["control.tar.gz"])
        print("  [control 字段]")
        for k in ("Package", "Version", "Architecture", "Depends", "Section", "Installed-Size"):
            if k in ctl:
                print("    %-16s %s" % (k, ctl[k].splitlines()[0]))

        # 脚本类文件必须是 755, 否则装上去服务起不来
        for name, mode, uid, gid, size in _list(members["data.tar.gz"], "data"):
            base = name.rsplit("/", 1)[-1]
            if base.endswith((".sh",)) or "/init.d/" in name or "/hotplug.d/" in name or "/uci-defaults/" in name:
                if mode & 0o111:
                    pass
                else:
                    print("!! %s 没有执行位 (mode=%04o)" % (name, mode))
                    ok = False

    print("  => %s" % ("结构 OK" if ok else "结构有问题"))
    return 0 if ok else 1


def parse_control_from_tar(blob: bytes) -> dict:
    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
    for m in tf.getmembers():
        if m.name.lstrip("./") == "control":
            data = tf.extractfile(m).read().decode("utf-8")
            tmp = io.StringIO(data)
            fields, last = {}, None
            for line in data.splitlines():
                if not line.strip():
                    continue
                if line[0] in " \t" and last:
                    fields[last] += "\n" + line
                    continue
                if ":" in line:
                    k, v = line.split(":", 1)
                    last = k.strip()
                    fields[last] = v.strip()
            return fields
    return {}


def compare(mine: str, official: str) -> int:
    """对着官方包核对外层布局, 免得再踩格式的坑"""
    a, b = read_ipk(mine), read_ipk(official)
    print("%-24s %s" % ("我们:", mine))
    print("  外层=%s 成员=%s" % (a["fmt"], sorted(a["members"])))
    print("%-24s %s" % ("官方:", official))
    print("  外层=%s 成员=%s" % (b["fmt"], sorted(b["members"])))
    ok = a["fmt"] == b["fmt"] and sorted(a["members"]) == sorted(b["members"])
    print("=> %s" % ("外层布局与官方一致" if ok else "外层布局与官方不一致"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="手工打 .ipk (不需要 OpenWrt SDK)")
    ap.add_argument("pkgdir", help="包目录, 例如 pkg/nnnu-auth")
    ap.add_argument("-o", "--outdir", default="out", help="输出目录 (默认 out/)")
    ap.add_argument("--verify", metavar="IPK", help="校验一个已存在的 ipk")
    ap.add_argument("--compare", metavar="OFFICIAL_IPK", help="和一个官方 ipk 对比外层布局")
    a = ap.parse_args()
    if a.verify:
        return verify(a.verify)
    p = build(a.pkgdir, a.outdir)
    print("生成: %s (%d 字节)" % (p, os.path.getsize(p)))
    if a.compare:
        return compare(p, a.compare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
