#!/usr/bin/env python3
"""
仿真校园网门户 —— 按抓包结果复刻 ZAXSOFT BOSS Web 的行为, 用于离线验证 nnnu-auth.sh

复刻要点 (全部来自 172.27.0.5.har):
  * 未认证时 /generate_204 被"网关"劫持 -> 302 到 /webauth.do?wlanacip=..&wlanacname=..&wlanuserip=..&mac=..&vlan=0&url=..
  * 裸访问 /webauth.do (无参数) -> "未知网关" 页
  * GET  /webauth.do?<参数> -> 登录页 (含 pageid 等隐藏字段 + Set-Cookie: JSESSIONID-...)
  * POST /webauth.do?<参数> -> 校验表单; 成功页含 <input id="act" value="LOGINSUCC"> 与 errMessage
  * POST /getAuthResult.do  -> {"check":"..."} 代拨结果
  * POST /webdisconn.do     -> 注销

控制面 (测试用):
  GET /__ctl?reset=1&pageid=9&dial_polls=3&redirect=0&needcookie=1&expect_mac=1
  GET /__state -> JSON: 收到的表单/次数/是否在线
"""
import json
import os
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "authenticated": False,
    "pageid": "6",
    "dial_polls": 1,          # 前 N 次 getAuthResult 返回"拨号中"
    "poll_count": 0,
    "redirect": 1,            # 网关是否做 302 劫持
    "needcookie": 0,          # POST 时是否强制要求 JSESSIONID
    "real_pages": 0,          # 1 = 用真实抓包页面(而非合成页面)响应
    "user": "2026000001",
    "passwd": "P@ssw0rd#1",
    "login_attempts": 0,
    "last_form": {},
    "last_body_len": 0,
    "last_post_path": "",
    "last_cookie": "",
    "get_login_page": 0,
    "errors": [],
}
LOCK = threading.Lock()

FIXDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def real_page(name):
    """
    读取"真实门户页面"回归用的样本。

    这些样本是从真实抓包里导出的(校方页面 + 真实 MAC/IP), 所以只放在本机、
    文件名带 .local 后缀并被 .gitignore 忽略, 不随仓库公开。
    没有样本时返回空串, 调用方会退回到合成的页面 —— 功能不受影响。
    """
    local = name.replace(".html", ".local.html")
    for candidate in (local, name):
        path = os.path.join(FIXDIR, candidate)
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    return f.read()
            except OSError:
                pass
    return ""

QUERY_TAIL = ("wlanacip=172.27.0.100&wlanacname=ZAXSOFT-BRAS-WM"
              "&wlanuserip=192.168.1.100&mac=aa:bb:cc:dd:ee:ff&vlan=0"
              "&url=http://{host}/generate_204")


def login_page(host, params, err=""):
    """登录页: 隐藏字段与真实抓包一致 (只保留脚本会用到的部分)"""
    url = params.get("url", "http://%s/generate_204" % host)
    act = '<input id="act" type="hidden" value="" disabled="disabled"/>' if not err else ""
    return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>网络认证</title></head>
<body>
<form id="goLoginForm" method="post">
<input id="scheme" name="scheme" type="hidden" value="http" />
<input id="serverIp" name="serverIp" type="hidden" value="tomcat_server:80" />
<input id="hostIp" name="hostIp" type="hidden" value="http://127.0.0.1:8081/" />
<input id="loginType" name="loginType" type="hidden" value="" />
<input id="auth_type" name="auth_type" type="hidden" value="0" />
<input id="isBindMac1" name="isBindMac1" type="hidden" value="0" />
<input id="pageid" type="hidden" name="pageid" value="{pageid}" />
<input id="userid1" type="hidden" value="nnnuwm" disabled="disabled" />
<input id="listqqauth" type="hidden" name="listqqauth" value="" disabled="disabled"/>
<input id="terminalType" type="hidden" name="templatetype" value="1"/>
<input id="listbindmac" type="hidden" name="listbindmac" value="0"/>
<input id="recordmac" type="hidden" name="recordmac" value="1"/>
<input type="hidden" id="isRemind" name="isRemind" value="1"/>
<input id="urlParameter" type="hidden" name="urlParameter" value="{qs}" disabled="disabled"/>
{act}
<input id="loginTimes" type="hidden" name="loginTimes" value=""/>
<input id="groupId" type="hidden" name="groupId" value=""/>
<input id="wlanuserip" name="wlanuserip" type="hidden" value="192.168.1.100" disabled="disabled"/>
<input id="wlanacname" name="wlanacname" type="hidden" value="ZAXSOFT-BRAS-WM" disabled="disabled"/>
<input id="distoken" name="distoken" type="hidden" value="" />
<input id="echostr" type="hidden" name="echostr" value=""/>
<input id="wlanacip" name="wlanacip" type="hidden" value="172.27.0.100" disabled="disabled"/>
<input id="initUrl" type="hidden" value="{url}" name="url"/>
<input id="errMessage" type="hidden" value="{err}"/>
<input id="isautoauth" name="isautoauth" type="hidden" value="" />
<input id="mobile" name="mobile" type="hidden" value="" />
<input type="hidden" value="/portal/uploads/pc/demo2/images/bj.png" name="notice_pic_loop2" />
<input type="hidden" value="/portal/uploads/pc/demo2/images/logo.png" name="notice_pic_loop1" />
<input type="text" id="userId" value="" name="userId">
<input type="password" id="passwd" value="" name="passwd">
<input type="checkbox" name="remInfo" id="remInfo">
<input type="checkbox" id="isBindMac" name="isBindMac" value="bindmac" checked="checked">
</form>
<p class="common2">{err}</p>
</body></html>""".format(pageid=STATE["pageid"], qs=urllib.parse.urlencode(params),
                       url=url, err=err, act=act)


SUCCESS_PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>网络认证</title></head>
<body><form id="goLoginForm" method="post">
<input id="act" type="hidden" value="LOGINSUCC" disabled="disabled"/>
<input id="errMessage" type="hidden" value="正在进行外网拨号请稍候..."/>
<input id="logoutgourl" type="hidden" value="" />
<input id="urlParameter" type="hidden" name="urlParameter" value="{qs}" disabled="disabled"/>
<input id="pageid" type="hidden" name="pageid" value="{pageid}" />
</form>
<p class="common2">正在进行外网拨号请稍候...</p>
<div class="submit btn-yellow is-active" id="online">下线</div>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body="", ctype="text/html;charset=utf-8", cookie=None, location=None):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    # ---------------------------------------------------------------- helpers
    def _qs(self):
        return urllib.parse.urlsplit(self.path).query

    def _params(self):
        return dict(urllib.parse.parse_qsl(self._qs(), keep_blank_values=True))

    def _form(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        self._raw_len = len(raw.encode("utf-8"))
        return dict(urllib.parse.parse_qsl(raw, keep_blank_values=True))

    # ---------------------------------------------------------------- routing
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        host = self.headers.get("Host", "127.0.0.1")

        if path == "/__ctl":
            q = self._params()
            with LOCK:
                if q.get("reset") == "1":
                    STATE["authenticated"] = False
                    STATE["poll_count"] = 0
                    STATE["login_attempts"] = 0
                    STATE["last_form"] = {}
                    STATE["errors"] = []
                    STATE["get_login_page"] = 0
                for k in ("pageid", "dial_polls", "redirect", "needcookie", "real_pages", "user", "passwd"):
                    if k in q:
                        STATE[k] = q[k]
            return self._send(200, json.dumps({"ok": True}), "application/json")

        if path == "/__state":
            with LOCK:
                return self._send(200, json.dumps(STATE), "application/json")

        if path == "/generate_204" or path == "/generate_204/":
            with LOCK:
                if STATE["authenticated"]:
                    return self._send(204, "")
                if str(STATE["redirect"]) != "1":
                    return self._send(200, "captive but no redirect")
                loc = "http://%s/webauth.do?%s" % (host, QUERY_TAIL.format(host=host))
                return self._send(302, "", location=loc)

        if path == "/webauth.do":
            p = self._params()
            cookie = "JSESSIONID-BOSS-1=TESTCOOKIE123; Path=/; HttpOnly"
            if not p:
                return self._send(200, "<html><body><span id=\"command.errors\">未知网关，请检查接入设备是否配置正确!</span></body></html>")
            with LOCK:
                STATE["get_login_page"] += 1
                real = str(STATE["real_pages"]) == "1"
            if real:
                html = real_page("real_login_page.html")
                if html:
                    return self._send(200, html, cookie=cookie)
            return self._send(200, login_page(host, p), cookie=cookie)

        return self._send(404, "not found")

    def do_POST(self):
        split = urllib.parse.urlsplit(self.path)
        path = split.path
        host = self.headers.get("Host", "127.0.0.1")

        if path == "/webauth.do":
            form = self._form()
            p = self._params()
            with LOCK:
                STATE["login_attempts"] += 1
                STATE["last_form"] = form
                STATE["last_body_len"] = getattr(self, "_raw_len", 0)
                STATE["last_post_path"] = self.path
                STATE["last_cookie"] = self.headers.get("Cookie", "")
                need_cookie = str(STATE["needcookie"]) == "1"
                want_user = STATE["user"]
                want_pass = STATE["passwd"]
                want_pageid = STATE["pageid"]
            if need_cookie and "JSESSIONID" not in STATE["last_cookie"]:
                with LOCK:
                    STATE["errors"].append("POST 未带 JSESSIONID cookie")
                return self._send(200, login_page(host, p, err="会话已失效, 请重新登录"))
            if not p:
                with LOCK:
                    STATE["errors"].append("POST 缺少门户查询参数")
                return self._send(200, login_page(host, p, err="未知网关"))
            if form.get("userId") != want_user or form.get("passwd") != want_pass:
                return self._send(200, login_page(host, p, err="账号或密码错误"))
            if form.get("pageid") != want_pageid:
                with LOCK:
                    STATE["errors"].append("pageid 不匹配: %r != %r" % (form.get("pageid"), want_pageid))
                return self._send(200, login_page(host, p, err="页面参数失效, 请刷新"))
            with LOCK:
                STATE["poll_count"] = 0
                real = str(STATE["real_pages"]) == "1"
            if real:
                html = real_page("real_success_page.html")
                if html:
                    return self._send(200, html)
            return self._send(200, SUCCESS_PAGE.format(qs=urllib.parse.urlencode(p), pageid=want_pageid))

        if path == "/getAuthResult.do":
            form = self._form()
            with LOCK:
                STATE["poll_count"] += 1
                n = STATE["poll_count"]
                dial = int(STATE["dial_polls"])
                if n > dial:
                    STATE["authenticated"] = True
                    body = {"check": "运营商网络拨号成功"}
                else:
                    body = {"check": "正在进行外网拨号请稍候..."}
                user_ok = form.get("userId") == STATE["user"]
            if not user_ok:
                body = {"check": "参数错误"}
            return self._send(200, json.dumps(body, ensure_ascii=False), "application/json")

        if path == "/webdisconn.do":
            self._form()
            with LOCK:
                STATE["authenticated"] = False
            return self._send(200, "<html><body>下线成功</body></html>")

        return self._send(404, "not found")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("mock portal on http://127.0.0.1:%d" % port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
