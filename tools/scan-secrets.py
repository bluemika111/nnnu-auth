#!/usr/bin/env python3
"""
scan-secrets.py — 提交到 GitHub 前检查仓库里有没有不该公开的东西

扫描范围:
  * 工作区里的所有文本文件 (跳过 .git / __pycache__ / *.ipk 的原始字节)
  * .ipk 包内部的文件 (gzip+tar 拆开扫, 否则藏在压缩包里看不出来)
  * .tar.gz 包内部

检查项:
  * 已知敏感串 (从本地抓包/配置里提取的真实账号、密码、MAC、IP)
  * 通用模式: 形如 PASSWORD='真实值' / 私钥 / token / 邮箱 / 家目录路径
  * 大体积的第三方页面 (校园门户原始 HTML 这类建议别公开)

用法:
  python tools/scan-secrets.py                  # 扫当前目录
  python tools/scan-secrets.py path/to/repo     # 扫指定目录
  python tools/scan-secrets.py --add 张三,8.8.8.8  # 追加要查的敏感词
退出码 0 = 干净; 1 = 命中, 需要处理。
"""
import gzip
import io
import os
import re
import sys
import fnmatch
import tarfile

# ---------------------------------------------------------------- 已知敏感串
#
# 真实值不写在这个文件里(否则文件本身上传到 GitHub 就等于把密码公开了)。
# 从 tools/known-secrets.txt 读取, 一行一个; 该文件已被 .gitignore 忽略。
# 仓库里另有 known-secrets.txt.example 说明格式。
KNOWN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "known-secrets.txt")


def load_known():
    out = []
    if os.path.isfile(KNOWN_FILE):
        with open(KNOWN_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    out.append(line)
    return out


KNOWN = load_known()
SELF = os.path.abspath(__file__)

# ---------------------------------------------------------------- 通用模式
PATTERNS = [
    (re.compile(r"PASSWORD\s*=\s*'([^']{3,})'"),        "可疑的明文密码赋值"),
    (re.compile(r"^\s*option\s+password\s+'([^']{3,})'", re.M), "uci 里的明文密码"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "私钥"),
    (re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{20,})\b"),   "GitHub token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),            "OpenAI/同类 API key"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[A-Za-z]{2,}\b"),    "邮箱地址"),
    (re.compile(r"C:\\\\?Users\\\\?[A-Za-z0-9._-]+"),   "Windows 家目录路径"),
    (re.compile(r"/home/[a-z][a-z0-9_-]+/"),            "Linux 家目录路径"),
]

# 明显是编出来的测试值, 不用管
ALLOW = {
    "P@ssw0rd#1", "wrong-password", "测试密码abc", "dummy", "test",
    "真实值", "填你的密码", "填你的学号", "这里填你的密码",
}

SKIP_DIRS = {".git", "__pycache__", ".idea", ".vscode", "node_modules"}
SKIP_EXT = {".ipk", ".gz", ".zst", ".o", ".pyc", ".lzma", ".zstd"}
MAX_TEXT = 4 * 1024 * 1024          # 单文件超过 4MB 不按文本扫
BIG_FILE = 20 * 1024                # 超过 20KB 的 HTML 视为"可能是抄来的页面"

# 本机私有、按 .gitignore 不会入库的文件: 只做提示, 不算问题
PRIVATE_GLOBS = ("*.local.html", "known-secrets.txt", "*.har")


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            yield os.path.join(dirpath, f)


def scan_text(text, label, hits, big_html_check=True, size=0):
    for i, line in enumerate(text.splitlines(), 1):
        for token in KNOWN:
            if token in line:
                hits.append((label, i, "已知敏感串 %r" % token, line.strip()[:120]))
        for pat, desc in PATTERNS:
            m = pat.search(line)
            if not m:
                continue
            value = m.group(1) if m.groups() else m.group(0)
            # 占位符/示例值/明显编的测试值不算
            if any(x in value for x in ("填你的", "这里填", "your", "xxx", "***", "example", "<", "...")):
                continue
            if value in ALLOW:
                continue
            hits.append((label, i, desc, line.strip()[:120]))


def scan_ipk(path, hits):
    """把 ipk 拆开, 逐个文件扫(否则敏感内容藏在 gzip 里查不到)"""
    raw = open(path, "rb").read()
    if raw[:2] != b"\x1f\x8b":
        hits.append((path, 0, "不是 gzip+tar 的 ipk, 无法检查内部", ""))
        return
    try:
        outer = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw)), mode="r:")
    except Exception as e:
        hits.append((path, 0, "拆包失败: %s" % e, ""))
        return
    for m in outer.getmembers():
        if not m.isfile():
            continue
        blob = outer.extractfile(m).read()
        inner_name = "%s!%s" % (os.path.basename(path), m.name)
        if m.name.endswith(".tar.gz"):
            try:
                itf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
            except Exception:
                continue
            for im in itf.getmembers():
                if im.isfile():
                    data = itf.extractfile(im).read()
                    scan_text(data.decode("utf-8", "replace"),
                              "%s!%s" % (inner_name, im.name), hits)
        else:
            scan_text(blob.decode("utf-8", "replace"), inner_name, hits)


def scan_tarball(path, hits):
    try:
        tf = tarfile.open(path, mode="r:gz")
    except Exception:
        return
    for m in tf.getmembers():
        if m.isfile():
            data = tf.extractfile(m).read()
            if len(data) > MAX_TEXT:
                continue
            scan_text(data.decode("utf-8", "replace"),
                      "%s!%s" % (os.path.basename(path), m.name), hits)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    for a in sys.argv[1:]:
        if a.startswith("--add"):
            extra = a.split("=", 1)[1] if "=" in a else ""
            KNOWN.extend(x.strip() for x in extra.split(",") if x.strip())

    hits, big, private = [], [], []
    for path in sorted(iter_files(root)):
        rel = os.path.relpath(path, root)
        size = os.path.getsize(path)
        ext = os.path.splitext(path)[1].lower()

        # 敏感词清单本身既不用扫, 也不该跟着仓库走
        if os.path.abspath(path) in (SELF, os.path.abspath(KNOWN_FILE)):
            continue

        # 本机私有文件(.gitignore 里那些): 内容含真实数据很正常, 只提示不入库
        if any(fnmatch.fnmatch(os.path.basename(path), g) for g in PRIVATE_GLOBS):
            private.append(rel)
            continue

        if ext == ".ipk":
            scan_ipk(path, hits)
            continue
        if rel.endswith(".tar.gz"):
            scan_tarball(path, hits)
            continue
        if ext in SKIP_EXT or size > MAX_TEXT:
            continue

        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        scan_text(text, rel, hits, size=size)
        if ext in (".html", ".htm") and size > BIG_FILE:
            big.append((rel, size))

    print("扫描目录: %s" % os.path.abspath(root))
    print("检查了 %d 个文件" % len(list(iter_files(root))))
    print()

    if big:
        print("【体积较大的网页文件】(多半是抄来的第三方页面, 公开前请确认是否该放上去)")
        for rel, size in big:
            print("  %-58s %6.1f KB" % (rel, size / 1024))
        print()

    if private:
        print("【本机私有文件, 按 .gitignore 不会入库】(只提示, 不算问题)")
        for rel in private:
            print("  %s" % rel)
        print()

    if not hits:
        print("未发现敏感信息, 可以上传。")
        return 0

    print("【命中 %d 处】" % len(hits))
    for label, line, desc, snippet in hits:
        print("  %s:%s" % (label, line) if line else "  %s" % label)
        print("      %s" % desc)
        if snippet:
            print("      > %s" % snippet)
    return 1


if __name__ == "__main__":
    sys.exit(main())
