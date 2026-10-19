#!/usr/bin/env python3
"""
check_lua.py — 用 luaparser 给 LuCI 的 Lua 文件做真语法检查

覆盖:
  *.lua               整个文件
  *.htm               把 <% ... %> 里的 Lua 抽出来逐块检查
                      (块之间共享变量是 LuCI 的常态, 这里只查语法不查作用域)

用法: python tools/check_lua.py pkg
退出码非 0 表示有语法错误。
"""
import glob
import os
import re
import sys

try:
    from luaparser import ast as lua_ast
except ImportError:
    print("需要 luaparser: python -m pip install luaparser")
    sys.exit(2)


def check_source(src: str, label: str) -> int:
    # LuCI 模板里的 <%:翻译%> 与 <%+include%> 不是 Lua, 已在上层剥离
    try:
        lua_ast.parse(src)
        return 0
    except Exception as exc:                     # noqa: BLE001
        msg = str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
        line = ""
        m = re.search(r"line[^0-9]*([0-9]+)", str(exc))
        if m:
            n = int(m.group(1))
            rows = src.splitlines()
            if 1 <= n <= len(rows):
                line = "  → %s" % rows[n - 1].strip()
        print("SYNTAX! %s\n   %s%s" % (label, msg, ("\n" + line) if line else ""))
        return 1


def lua_str(s: str) -> str:
    """把 python 字符串写成 Lua 字面量 (保留 UTF-8, 不产生 \\u 转义)"""
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    return '"%s"' % out


def template_to_lua(raw: str) -> str:
    """
    把 LuCI 模板拼成一段等价 Lua。
    模板里的控制流经常跨块 (if 在 A 块、end 在 B 块), 所以必须拼起来查,
    单块查必然报错。这里把输出/翻译标签换成函数调用占位 (只查语法, 不查名字)。
    """
    parts = []
    for m in re.finditer(r"<%(.*?)%>", raw, re.S):
        tag = m.group(1).strip()
        if tag.startswith("-"):
            tag = tag[1:].lstrip()
        if tag.endswith("-"):
            tag = tag[:-1].rstrip()
        if not tag or tag.startswith("#"):          # 注释
            continue
        if tag.startswith("+"):                     # 包含其它模板
            continue
        if tag.startswith(":"):                     # 翻译并输出
            parts.append("__out(translate(%s))" % lua_str(tag[1:]))
            continue
        if tag.startswith("="):                     # 输出表达式
            parts.append("__out(%s)" % tag[1:].strip())
            continue
        parts.append(tag)                            # 普通 Lua
    return "\n".join(parts)


def strip_lua_comment(line: str) -> str:
    """去掉行尾 Lua 注释 (-- ...), 不处理字符串里的 --; 够用且不会误伤"""
    out, i, n = [], 0, len(line)
    quote = None
    while i < n:
        c = line[i]
        if quote:
            if c == "\\":
                out.append(c)
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "-" and i + 1 < n and line[i + 1] == "-":
            break
        out.append(c)
        i += 1
    return "".join(out)


def check_known_traps(raw: str, label: str) -> int:
    """
    这两条是踩过的坑, 语法完全合法但一上路由器就炸, 所以单独拦:
      1) s.tabs = true  后再 s:tab()/taboption()
         -> LuCI 的 AbstractSection.tab() 是 `self.tabs = self.tabs or {}`,
            布尔值会被保留, 接着当表用: cbi.lua:844 attempt to index ...
      2) <%+header%> / <%+footer%>
         -> luci-compat 的 luasrc/view/ 下只有 cbi/, 没有页面级 header/footer,
            引了会渲染失败; JS 版 LuCI 的框架由前端提供
    """
    # 先去掉模板注释块。按 `-%>` 收尾的先删, 再删普通 `%>` 收尾的 ——
    # 否则注释里提到的 <%+header%> 会让非贪婪匹配提前截断, 把注释当代码。
    body = re.sub(r"<%#.*?-%>", "", raw, flags=re.S)
    body = re.sub(r"<%#.*?%>", "", body, flags=re.S)
    body = "\n".join(strip_lua_comment(l) for l in body.splitlines())
    body = re.sub(r"<%-(.*?)-%>", "", body, flags=re.S)      # 说明性片段也不看

    bad = 0
    for i, line in enumerate(body.splitlines(), 1):
        if re.search(r"\.tabs\s*=\s*(true|1)\b", line):
            print("TRAP!   %s:%d  .tabs 被赋成布尔值; 直接用 s:tab(name, title) 建标签页" % (label, i))
            print("        %s" % line.strip())
            bad += 1
    for m in re.finditer(r"<%\+\s*(header|footer)\s*%>", body):
        ln = body.count("\n", 0, m.start()) + 1
        print("TRAP!   %s:%d  包含 header/footer 模板, luci-compat 下不存在, 请删掉" % (label, ln))
        bad += 1
    return bad


def main():
    roots = sys.argv[1:] or ["pkg"]
    files = []
    for r in roots:
        files += glob.glob(os.path.join(r, "**", "*.lua"), recursive=True)
        files += glob.glob(os.path.join(r, "**", "*.htm"), recursive=True)
    files = sorted(set(files))

    bad = 0
    checked = 0
    for f in files:
        raw = open(f, "r", encoding="utf-8").read()
        bad += check_known_traps(raw, f)
        if f.endswith(".lua"):
            checked += 1
            bad += check_source(raw, f)
            continue

        src = template_to_lua(raw)
        if not src.strip():
            print("SKIP    %s (没有 Lua 块)" % f)
            continue
        checked += 1
        bad += check_source(src, f + " (拼接后的 Lua)")

    print("检查 %d 个 Lua 源: %s" % (checked, "全部通过" if bad == 0 else "%d 处有语法错误" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
