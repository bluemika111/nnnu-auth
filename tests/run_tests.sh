#!/bin/sh
# 端到端测试: 用仿真门户验证 nnnu-auth.sh 的完整认证流程
# 用法: sh tests/run_tests.sh   (需要 python3; 自动挑选空闲端口)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AUTH="$ROOT/dist/nnnu-auth.sh"
PY="${PYTHON:-python}"

PYBIN=$(command -v "$PY" || command -v python3 || command -v python)
[ -n "$PYBIN" ] || { echo "缺少 python"; exit 1; }
echo "python: $PYBIN"

PORT=$(( ($$ % 2000) + 18000 ))
WORK="${TMPDIR:-/tmp}/nnnu-test.$$"
mkdir -p "$WORK"
PASS=0
FAIL=0

cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
    rm -rf "$WORK"
    rm -rf "${TMPDIR:-/tmp}/nnnu-auth.lock"
}
trap cleanup EXIT INT TERM
rm -rf "${TMPDIR:-/tmp}/nnnu-auth.lock"   # 清掉上次遗留的锁

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_contains() { # file pattern desc
    if grep -q "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (日志里没有: $2)"; fi
}
assert_not_contains() {
    if grep -q "$2" "$1" 2>/dev/null; then bad "$3 (日志里出现了: $2)"; else ok "$3"; fi
}
assert_rc() { # actual expected desc
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (退出码 $1, 期望 $2)"; fi
}
assert_str_contains() { # haystack needle desc
    case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (实际: $1)" ;; esac
}

ctl() { "$PYBIN" -c "
import urllib.request,sys
print(urllib.request.urlopen('http://127.0.0.1:$PORT/__ctl?$1', timeout=5).read().decode())
"; }
state() { "$PYBIN" -c "
import urllib.request,json
print(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5).read().decode())
"; }
field() { # json-key  -> 从 last_form 取字段
    "$PYBIN" -c "
import urllib.request,json,sys
s=json.load(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5))
print(s.get('last_form',{}).get(sys.argv[1],''))
" "$1"
}

post_path() {
    "$PYBIN" -c "
import urllib.request,json
s=json.load(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5))
print(s.get('last_post_path',''))
"
}

mock_errors() {
    "$PYBIN" -c "
import urllib.request,json
s=json.load(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5))
print('; '.join(s.get('errors',[])))
"
}

login_attempts() {
    "$PYBIN" -c "
import urllib.request,json
s=json.load(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5))
print(s.get('login_attempts',0))
"
}

body_len() {
    "$PYBIN" -c "
import urllib.request,json
s=json.load(urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=5))
print(s.get('last_body_len',0))
"
}

run_auth() { # 参数: 动作 [额外conf行...]
    _act="$1"; shift
    CONF="$WORK/nnnu.conf"
    cat > "$CONF" <<EOF
USERNAME='2026000001'
PASSWORD='P@ssw0rd#1'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
LOG_FILE='$WORK/auth.log'
TIMEOUT=5
DIAL_INTERVAL=1
DIAL_WAIT=10
VERIFY_WAIT=10
VERIFY_INTERVAL=1
$*
EOF
    rm -f "$WORK/auth.log"
    NNNU_CONF="$CONF" sh "$AUTH" "$_act" -q
    return $?
}

echo "=== 启动仿真门户 :$PORT ==="
"$PYBIN" "$SCRIPT_DIR/mock_portal.py" "$PORT" > "$WORK/mock.log" 2>&1 &
MOCK_PID=$!
i=0
while [ $i -lt 40 ]; do
    "$PYBIN" -c "
import urllib.request
try:
    urllib.request.urlopen('http://127.0.0.1:$PORT/__state', timeout=2).read()
except Exception:
    raise SystemExit(1)
" 2>/dev/null && break
    i=$((i+1)); sleep 0.25
done
echo "  mock pid=$MOCK_PID"
echo

#---------------------------------------------------------------- 1. 已在线
echo "[1] 已在线时 ensure 应直接返回, 不做认证"
ctl "reset=1" >/dev/null
# 先让 mock 处于已认证状态
run_auth login >/dev/null 2>&1
run_auth ensure
assert_rc $? 0 "已在线 -> 退出码 0"
assert_contains "$WORK/auth.log" "已在线" "识别为已在线"
echo

#---------------------------------------------------------------- 2. 正常认证
echo "[2] 未认证 -> 完整认证流程"
ctl "reset=1" >/dev/null
run_auth ensure
assert_rc $? 0 "认证成功 -> 退出码 0"
assert_contains "$WORK/auth.log" "认证成功" "登录页返回 LOGINSUCC"
assert_contains "$WORK/auth.log" "运营商网络拨号成功" "读到代拨结果"
assert_contains "$WORK/auth.log" "已联网" "连通性确认通过"
assert_contains "$WORK/auth.log" "门户参数: wlanacip=" "从 302 提取到了门户参数"
[ "$(field userId)" = "2026000001" ] && ok "提交了正确的 userId" || bad "userId 不对: $(field userId)"
[ "$(field passwd)" = "P@ssw0rd#1" ] && ok "提交了正确的 passwd" || bad "passwd 不对"
[ "$(field templatetype)" = "1" ] && ok "带上了 templatetype" || bad "templatetype 缺失"
[ "$(field url)" = "http://127.0.0.1:$PORT/generate_204" ] && ok "带上了原始 url" || bad "url 不对: $(field url)"
[ "$(field isBindMac)" = "bindmac" ] && ok "默认携带 isBindMac=bindmac" || bad "isBindMac 缺失"
BL=$(body_len)
if [ "$BL" -gt 400 ]; then ok "请求体长度合理 ($BL 字节, 值没被编码成空串)"; else bad "请求体只有 $BL 字节: 表单值可能全空了"; fi
echo

#---------------------------------------------------------------- 3. cookie 透传
echo "[3] 门户要求 JSESSIONID (cookie 透传)"
ctl "reset=1&needcookie=1" >/dev/null
run_auth ensure
assert_rc $? 0 "带 cookie 认证成功"
assert_not_contains "$WORK/auth.log" "账号或密码错误" "没有被门户判为会话失效"
echo

#---------------------------------------------------------------- 4. 页面 pageid 变化
echo "[4] 门户模板 pageid 改为 9 -> 必须用页面上的值"
ctl "reset=1&pageid=9" >/dev/null
run_auth ensure
assert_rc $? 0 "pageid=9 时认证成功"
[ "$(field pageid)" = "9" ] && ok "提交的 pageid 取自登录页" || bad "pageid 提交成了 $(field pageid)"
ctl "pageid=6" >/dev/null
echo

#---------------------------------------------------------------- 5. 代拨需要轮询
echo "[5] 代拨需轮询 3 次后才成功"
ctl "reset=1&dial_polls=3" >/dev/null
run_auth ensure
assert_rc $? 0 "轮询到成功"
assert_contains "$WORK/auth.log" "代拨中" "期间打印了拨号中状态"
echo

#---------------------------------------------------------------- 6. 密码错误
echo "[6] 密码错误 -> 报错且退出码非 0"
ctl "reset=1" >/dev/null
CONF="$WORK/nnnu.conf"
cat > "$CONF" <<EOF
USERNAME='2026000001'
PASSWORD='wrong-password'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
LOG_FILE='$WORK/auth.log'
RESP_DUMP='$WORK/resp.html'
TIMEOUT=5
VERIFY_WAIT=3
VERIFY_INTERVAL=1
RETRY=1
EOF
rm -f "$WORK/auth.log" "$WORK/resp.html"
NNNU_CONF="$CONF" sh "$AUTH" login -q
assert_rc $? 1 "退出码 1"
assert_contains "$WORK/auth.log" "账号或密码错误" "日志带出门户错误信息"
assert_contains "$WORK/auth.log" "认证失败: act=" "日志含完整失败取证(act/errMessage/提示)"
assert_contains "$WORK/auth.log" "门户返回页已存" "日志给出返回页留档路径"
assert_contains "$WORK/auth.log" "USERNAME / PASSWORD" "给出可操作提示"
if [ -s "$WORK/resp.html" ]; then ok "门户返回页已落盘"; else bad "返回页没有落盘"; fi
echo

#---------------------------------------------------------------- 7. 抓不到 302 时的兜底
echo "[7] 网关不劫持(无 302) -> 用本机 WAN 信息兜底"
ctl "reset=1&redirect=0" >/dev/null
cat > "$WORK/nnnu.conf" <<EOF
USERNAME='2026000001'
PASSWORD='P@ssw0rd#1'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
WAN_IP='192.168.1.100'
WAN_MAC='aa:bb:cc:dd:ee:ff'
DEFAULT_URL='http://127.0.0.1:$PORT/generate_204'
LOG_FILE='$WORK/auth.log'
TIMEOUT=5
DIAL_INTERVAL=1
DIAL_WAIT=10
VERIFY_WAIT=10
VERIFY_INTERVAL=1
EOF
rm -f "$WORK/auth.log"
NNNU_CONF="$WORK/nnnu.conf" sh "$AUTH" login -q
assert_rc $? 0 "无 302 也能靠兜底参数完成认证"
assert_contains "$WORK/auth.log" "未捕获到网关 302" "走了兜底分支"
assert_contains "$WORK/auth.log" "已联网" "兜底路径最终连通"
assert_str_contains "$(post_path)" "wlanuserip=192.168.1.100" "兜底参数用了 WAN IP"
assert_str_contains "$(post_path)" "mac=aa:bb:cc:dd:ee:ff" "兜底参数用了 WAN MAC"
ctl "redirect=1" >/dev/null
echo

#---------------------------------------------------------------- 8. status
echo "[8] status 反映在线状态"
ctl "reset=1&redirect=1" >/dev/null
run_auth status
assert_rc $? 1 "离线时 status=1"
run_auth login >/dev/null 2>&1
run_auth status
assert_rc $? 0 "在线时 status=0"
echo

#---------------------------------------------------------------- 9. 并发锁
echo "[9] 互斥锁: 第二个实例不应重复认证"
ctl "reset=1" >/dev/null
BEFORE=$(login_attempts)
( NNNU_CONF="$WORK/nnnu.conf" sh "$AUTH" login > "$WORK/a.log" 2>&1 ) &
BGPID=$!
sleep 0.5
NNNU_CONF="$WORK/nnnu.conf" sh "$AUTH" login > "$WORK/b.log" 2>&1
B_RC=$?
assert_contains "$WORK/b.log" "跳过" "第二次调用识别到锁并跳过"
assert_rc "$B_RC" 0 "被锁挡住时退出码 0"
wait $BGPID 2>/dev/null
AFTER=$(login_attempts)
if [ "$AFTER" = "$((BEFORE + 1))" ]; then ok "门户只收到 1 次登录请求"; else bad "门户收到 $((AFTER - BEFORE)) 次登录请求"; fi
echo

#---------------------------------------------------------------- 10. doctor
echo "[10] doctor 自检可运行"
run_auth doctor > "$WORK/doc.log" 2>&1
assert_rc $? 0 "doctor 退出码 0"
assert_contains "$WORK/doc.log" "门户参数" "打印了门户参数段落"

#---------------------------------------------------------------- 11. 真实页面
if [ -f "$SCRIPT_DIR/fixtures/real_login_page.local.html" ]; then
echo "[11] 用抓包里的真实门户 HTML 跑完整流程"
ctl "reset=1&real_pages=1&pageid=6" >/dev/null
run_auth ensure
assert_rc $? 0 "真实页面下认证成功"
assert_contains "$WORK/auth.log" "认证成功" "真实成功页里的 LOGINSUCC 被识别"
assert_contains "$WORK/auth.log" "运营商网络拨号成功" "真实流程代拨成功"
assert_contains "$WORK/auth.log" "已联网" "最终连通"
[ "$(field pageid)" = "6" ] && ok "真实页 pageid=6 被采用" || bad "pageid=$(field pageid)"
[ "$(field templatetype)" = "1" ] && ok "真实页 templatetype 被采用" || bad "templatetype=$(field templatetype)"
[ "$(field serverIp)" = "tomcat_server:80" ] && ok "真实页 serverIp 被采用" || bad "serverIp=$(field serverIp)"
[ "$(field hostIp)" = "http://127.0.0.1:8081/" ] && ok "真实页 hostIp 被采用" || bad "hostIp=$(field hostIp)"
[ "$(field notice_pic_loop1)" = "/portal/uploads/pc/demo2/images/logo.png" ] && ok "真实页 notice_pic_loop1 被采用" || bad "notice_pic_loop1=$(field notice_pic_loop1)"
assert_str_contains "$(mock_errors)" "" "门户侧无参数不匹配告警"
ctl "real_pages=0" >/dev/null
echo
else
echo "[11] 跳过: 没有真实页面样本"
echo "     (tests/fixtures/real_login_page.local.html 是本地私有样本, 不入库;"
echo "      想跑这一项就自己抓包导出, 见 README「真实页面回归」)"
echo
fi

#---------------------------------------------------------------- 12. 无 curl 环境
echo "[12] 没有 curl, 只有 busybox 风格的 wget"
ctl "reset=1&real_pages=0" >/dev/null
CONF="$WORK/nnnu.conf"
cat > "$CONF" <<EOF
USERNAME='2026000001'
PASSWORD='P@ssw0rd#1'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
LOG_FILE='$WORK/auth.log'
TIMEOUT=5
DIAL_INTERVAL=1
DIAL_WAIT=10
VERIFY_WAIT=10
VERIFY_INTERVAL=1
HTTP_CLIENT='wget'
EOF
rm -f "$WORK/auth.log"
PATH="$SCRIPT_DIR/fakebin:$PATH" NNNU_CONF="$CONF" sh "$AUTH" ensure -q
assert_rc $? 0 "wget 通道也能完成认证"
assert_contains "$WORK/auth.log" "认证成功" "wget 通道识别到 LOGINSUCC"
assert_contains "$WORK/auth.log" "已联网" "wget 通道最终连通"
echo

#---------------------------------------------------------------- 13/14. 编码器降级
echo "[13] 强制纯 awk 编码器 (模拟固件没有可用的 od)"
ctl "reset=1" >/dev/null
CONF="$WORK/nnnu.conf"
cat > "$CONF" <<EOF
USERNAME='2026000001'
PASSWORD='P@ssw0rd#1'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
LOG_FILE='$WORK/auth.log'
RESP_DUMP='$WORK/resp.html'
TIMEOUT=5
DIAL_INTERVAL=1
DIAL_WAIT=10
VERIFY_WAIT=10
VERIFY_INTERVAL=1
HEXTOOL_OVERRIDE='awk'
EOF
rm -f "$WORK/auth.log"
rm -rf "${TMPDIR:-/tmp}/nnnu-auth.lock"
NNNU_CONF="$CONF" sh "$AUTH" ensure -q
assert_rc $? 0 "纯 awk 编码器下认证成功"
assert_contains "$WORK/auth.log" "认证成功" "账号密码被正确提交(含特殊字符)"
assert_str_contains "$(field passwd)" 'P@ssw0rd#1' "特殊字符密码解码后一致"
BL=$(body_len)
if [ "$BL" -gt 400 ]; then ok "请求体长度合理 ($BL 字节)"; else bad "请求体只有 $BL 字节"; fi
echo

echo "[14] od 与 hexdump 都不可用时自动降级 (复现 Kwrt 现场)"
ctl "reset=1" >/dev/null
rm -f "$WORK/auth.log"
rm -rf "${TMPDIR:-/tmp}/nnnu-auth.lock"
"$PYBIN" -c "
import json,urllib.request
print(urllib.request.urlopen('http://127.0.0.1:$PORT/__ctl?reset=1',timeout=5).read().decode())
" >/dev/null
DOC=$(PATH="$SCRIPT_DIR/fakebin-nood:$PATH" NNNU_CONF="$CONF" sh "$AUTH" doctor 2>&1)
assert_str_contains "$DOC" "URL 编码器 : " "doctor 报告编码器"
case "$DOC" in
    *"URL 编码器 : od "*) bad "od 明明被打断了却仍被选中 (探针失效)" ;;
    *"URL 编码器 : awk (自检通过)"*|*"URL 编码器 : hexdump (自检通过)"*) ok "自动跳过了坏掉的 od" ;;
    *) bad "编码器状态异常: $(printf '%s' "$DOC" | grep 'URL 编码器')" ;;
esac
PATH="$SCRIPT_DIR/fakebin-nood:$PATH" NNNU_CONF="$CONF" sh "$AUTH" ensure -q
assert_rc $? 0 "坏 od 环境下依然认证成功"
echo

echo "[15] 纯 awk 兜底 + 中文密码 (按字节百分号编码)"
# 让 mock 期望的密码 = conf 里的中文密码 (两端字节级一致才算过)
"$PYBIN" -c "
import urllib.request, urllib.parse
q = urllib.parse.urlencode({'reset': '1', 'user': '2026000001', 'passwd': '测试密码abc'})
urllib.request.urlopen('http://127.0.0.1:$PORT/__ctl?' + q, timeout=5).read()
"
cat > "$CONF" <<EOF
USERNAME='2026000001'
PASSWORD='测试密码abc'
PROBE_URLS='http://127.0.0.1:$PORT/generate_204'
PORTAL_HOST='127.0.0.1:$PORT'
LOG_FILE='$WORK/auth.log'
RESP_DUMP='$WORK/resp.html'
TIMEOUT=5
DIAL_INTERVAL=1
DIAL_WAIT=10
VERIFY_WAIT=10
VERIFY_INTERVAL=1
HEXTOOL_OVERRIDE='awk'
EOF
rm -f "$WORK/auth.log"
rm -rf "${TMPDIR:-/tmp}/nnnu-auth.lock"
NNNU_CONF="$CONF" sh "$AUTH" ensure -q
assert_rc $? 0 "中文密码认证成功(说明字节级编码正确)"
BL=$(body_len)
if [ "$BL" -gt 400 ]; then ok "请求体长度合理 ($BL 字节)"; else bad "请求体只有 $BL 字节"; fi
ctl "reset=1&user=2026000001&passwd=P%40ssw0rd%231" >/dev/null

echo
echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
