#!/usr/bin/env python3
"""
把浏览器导出的 .har 抓包拆成人看得懂的文本, 方便逆向认证流程。

用法:
    python har_export.py path/to/portal.har [-o 输出目录]

产出:
    <out>/urls.txt            每个请求一行 (方法/状态/URL)
    <out>/full.txt            请求头、POST 体、响应体全文
    <out>/bodies/NN.txt       每个响应的正文单独一份

注意: HAR 里通常含有明文密码与真实 MAC/IP, 所以默认输出到 out/,
      而 out/ 已在 .gitignore 里 —— 别把产物提交上去。
"""
import json, base64, os, sys, urllib.parse

if len(sys.argv) < 2:
    sys.exit(__doc__)
PATH = sys.argv[1]
if not os.path.isfile(PATH):
    sys.exit("找不到 HAR 文件: %s" % PATH)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "-o" else os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)

def text_of(content):
    if not content:
        return ""
    t = content.get("text") or ""
    if content.get("encoding") == "base64":
        try:
            t = base64.b64decode(t).decode("utf-8", "replace")
        except Exception:
            pass
    return t

har = json.load(open(PATH, "r", encoding="utf-8", errors="replace"))
entries = har["log"]["entries"]

with open(os.path.join(OUT, "urls.txt"), "w", encoding="utf-8") as f:
    for i, e in enumerate(entries):
        req, res = e["request"], e.get("response", {})
        f.write(f"[{i:02d}] {req['method']:5s} {res.get('status')} {req['url']}\n")

with open(os.path.join(OUT, "full.txt"), "w", encoding="utf-8") as f:
    for i, e in enumerate(entries):
        req, res = e["request"], e.get("response", {})
        f.write("=" * 110 + "\n")
        f.write(f"[{i}] {req['method']} {req['url']}\n")
        f.write(f"  status={res.get('status')} mime={res.get('content',{}).get('mimeType')} size={res.get('content',{}).get('size')} time={e.get('time')}\n")
        f.write(f"  started={e.get('startedDateTime')}\n")
        for k, v in req.get("headers", []):
            f.write(f"  > {k}: {v}\n")
        pd = req.get("postData")
        if pd:
            f.write(f"  > POSTDATA mime={pd.get('mimeType')} text_len={len(pd.get('text') or '')}\n")
            f.write("  > TEXT:\n" + (pd.get("text") or "") + "\n")
            for p in pd.get("params", []) or []:
                f.write(f"    param {p.get('name')} = {p.get('value')!r}\n")
        for k, v in res.get("headers", []):
            f.write(f"  < {k}: {v}\n")
        body = text_of(res.get("content"))
        f.write(f"  < BODY len={len(body)}:\n")
        f.write(body[:20000] + ("\n...[TRUNCATED]...\n" if len(body) > 20000 else "") + "\n")

# response bodies only, one file each for the big ones
os.makedirs(os.path.join(OUT, "bodies"), exist_ok=True)
for i, e in enumerate(entries):
    body = text_of(e.get("response", {}).get("content"))
    if len(body) > 200:
        open(os.path.join(OUT, "bodies", f"{i:02d}.txt"), "w", encoding="utf-8").write(body)

print("urls:", len(entries))
