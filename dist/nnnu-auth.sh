#!/bin/sh
#===============================================================================
#  nnnu-auth.sh — 校园网门户自动认证 (OpenWrt / 任意 POSIX sh)
#
#  适配: ZAXSOFT BOSS Web 门户 (nnnu 武鸣校区, 门户 http://172.27.0.5)
#
#  已抓包验证的认证流程:
#    1) 未认证时, 网关(BRAS)会把任意 HTTP 请求 302 到:
#         http://172.27.0.5/webauth.do?wlanacip=<AC IP>&wlanacname=<AC 名>
#              &wlanuserip=<本机IP>&mac=<本机MAC>&vlan=0&url=<原始URL>
#       这四个参数是认证的全部要素, 必须从 302 里取, 不能写死。
#    2) GET  该 URL                -> 登录页 (含 pageid 等隐藏字段 + JSESSIONID)
#    3) POST 该 URL (表单)         -> 提交 userId / passwd (明文, 无 CSRF token)
#       成功页含 <input id="act" value="LOGINSUCC">
#    4) POST /getAuthResult.do     -> 运营商代拨结果 ({"check":"运营商网络拨号成功"})
#    5) 探测连通性确认真正上网
#
#  用法:
#    nnnu-auth.sh [ensure|login|status|logout|monitor|doctor] [-q]
#      ensure   默认。在线就退出, 不在线则认证一次 (适合 cron 每分钟跑)
#      login    强制走一次认证
#      status   只探测在线状态
#      logout   尝试注销下线 (实验性)
#      monitor  常驻循环: 周期性 ensure (适合 procd 守护)
#      doctor   打印诊断信息(接口/IP/MAC/302 参数/登录页字段), 不提交密码
#
#  配置: /etc/nnnu-auth.conf  (见 nnnu-auth.conf 示例), 权限建议 600
#===============================================================================

CONF="${NNNU_CONF:-/etc/nnnu-auth.conf}"
[ -r "$CONF" ] && . "$CONF"

#------------------------------------------------------------------ 配置与默认值
USERNAME="${USERNAME:-}"                     # 校园网账号 (学号)
PASSWORD="${PASSWORD:-}"                     # 校园网密码 (明文, 与浏览器一致)

# 探测地址: 未认证时会被网关劫持并 302 到门户; 认证后返回 204
PROBE_URLS="${PROBE_URLS:-http://edge-http.microsoft.com/captiveportal/generate_204 http://www.gstatic.com/generate_204 http://connect.rom.miui.com/generate_204}"
ONLINE_CODES="${ONLINE_CODES:-204}"          # 视为"已在线"的状态码

# 兜底参数: 只有在抓不到 302 时才使用 (由本机 WAN 口 IP/MAC 拼装)
PORTAL_HOST="${PORTAL_HOST:-172.27.0.5}"     # 门户地址
WLANACNAME="${WLANACNAME:-ZAXSOFT-BRAS-WM}"  # 网关(BRAS)名称
WLANACIP="${WLANACIP:-172.27.0.100}"         # 网关(BRAS)地址
DEFAULT_URL="${DEFAULT_URL:-http://edge-http.microsoft.com/captiveportal/generate_204}"
WAN_IFACE="${WAN_IFACE:-}"                   # 留空则自动取默认路由接口
WAN_MAC="${WAN_MAC:-}"                       # 留空则自动取接口 MAC
WAN_IP="${WAN_IP:-}"                         # 留空则自动取接口 IPv4
HTTP_CLIENT="${HTTP_CLIENT:-auto}"           # auto | curl | uclient-fetch | wget
HEXTOOL_OVERRIDE="${HEXTOOL_OVERRIDE:-}"     # 强制 URL 编码器: od | hexdump | awk (留空自动探测)

# 表单开关 (与浏览器里勾选一致)
BIND_MAC="${BIND_MAC:-1}"                    # 1=提交 isBindMac=bindmac (绑定MAC)
REMEMBER="${REMEMBER:-1}"                    # 1=提交 remInfo=on (记住密码)

# 时间参数(秒)
INTERVAL="${INTERVAL:-60}"                   # monitor 模式检测间隔
DIAL_WAIT="${DIAL_WAIT:-60}"                 # 等待运营商代拨的总时长
DIAL_INTERVAL="${DIAL_INTERVAL:-3}"          # 代拨结果轮询间隔
VERIFY_WAIT="${VERIFY_WAIT:-60}"             # 认证后等待真正联网的总时长
VERIFY_INTERVAL="${VERIFY_INTERVAL:-3}"
TIMEOUT="${TIMEOUT:-8}"                      # 单次 HTTP 超时
RETRY="${RETRY:-2}"                          # 一次 ensure 内最大尝试轮数
LOCK_STALE="${LOCK_STALE:-90}"               # 锁超过这么多秒未刷新视为陈旧, 可被抢占

LOG_FILE="${LOG_FILE:-/var/log/nnnu-auth.log}"
LOG_QUIET="${LOG_QUIET:-0}"
RESP_DUMP="${RESP_DUMP:-/tmp/nnnu-auth-last-response.html}"   # 失败时留档门户返回页
VERSION="1.2.3"
UA="${UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"

#--------------------------------------------------------------------------------
# 内部工具
#--------------------------------------------------------------------------------
TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap 'cleanup' EXIT INT TERM HUP

init_tmp() {
    TMPD=$(mktemp -d 2>/dev/null) || TMPD=""
    if [ -z "$TMPD" ]; then
        TMPD="${TMPDIR:-/tmp}/nnnu-auth.$$"
        mkdir -p "$TMPD" || { echo "无法创建临时目录" >&2; exit 1; }
    fi
    T_BODY="$TMPD/body"
    T_HDR="$TMPD/hdr"
    T_FORM="$TMPD/form"
    T_AWK="$TMPD/extract.awk"
    cat > "$T_AWK" <<'AWKEOF'
# 抽取 HTML 里所有 <input> 标签的 name/id/value (TAB 分隔)
function attr(s, key,   m, i, k, v, q) {
    while (match(s, /[A-Za-z_:][-A-Za-z0-9_:.]*[ \t]*=[ \t]*("[^"]*"|'[^']*'|[^ \t>\/]+)/)) {
        m = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        i = index(m, "=")
        k = substr(m, 1, i - 1)
        gsub(/[ \t]/, "", k)
        v = substr(m, i + 1)
        sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        q = substr(v, 1, 1)
        if (q == "\"") { sub(/^"/, "", v); sub(/"$/, "", v) }
        else if (q == "'") { sub(/^'/, "", v); sub(/'$/, "", v) }
        if (tolower(k) == tolower(key)) return v
    }
    return ""
}
BEGIN { RS = ">" }
{
    if (match(tolower($0), /<input/)) {
        tag = substr($0, RSTART)
        sub(/\/[ \t]*$/, "", tag)          # 去掉自闭合 "/>" 的斜杠
        n = attr(tag, "name"); i = attr(tag, "id"); v = attr(tag, "value")
        ty = tolower(attr(tag, "type")); dis = attr(tag, "disabled")
        if (n != "" && dis == "" && ty != "submit" && ty != "button" && ty != "reset" && ty != "image" && ty != "file") {
            printf "name\t%s\t%s\n", n, v
        }
        if (i != "") printf "id\t%s\t%s\n", i, v
    }
}
AWKEOF
}

log() {
    [ -z "$LOG_FILE" ] || {
        if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 262144 ]; then
            tail -n 300 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
    }
    [ "$LOG_QUIET" = "1" ] || printf '%s\n' "$*" >&2
}

die() { log "错误: $*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# 选择 HTTP 客户端 (优先 curl: 支持超时/自定义头, 最稳)
CLIENT=""
pick_client() {
    case "$HTTP_CLIENT" in
        curl|uclient-fetch|wget)
            have "$HTTP_CLIENT" && CLIENT="$HTTP_CLIENT"
            [ -n "$CLIENT" ] || die "配置的 HTTP_CLIENT=$HTTP_CLIENT 不存在"
            return ;;
    esac
    if have curl; then CLIENT=curl
    elif have uclient-fetch; then CLIENT=uclient-fetch
    elif have wget; then CLIENT=wget
    else die "找不到 HTTP 客户端, 请执行: opkg update && opkg install curl"
    fi
}

# URL 编码 (application/x-www-form-urlencoded 值)
#
# 踩过的坑: 早先这里只依赖 `od -An -v -tx1`。某些 OpenWrt 固件(实测 Kwrt)的 busybox
# 没有可用的 od, 管道静默返回空串, 于是整个表单的值全变成空 —— 账号密码根本没提交出去,
# 门户只回一个不带 LOGINSUCC 的页面, 现象是"认证失败"但看不出原因。
# 现在: 启动时探测 od → hexdump → 纯 awk 三级备选, 并自检编码结果。
HEXTOOL=""
SELFTEST_OK=0

# 把连续的十六进制串("68656c6c6f")转义成 urlencoded
hex2url() {
    awk '{
        n = length($0)
        for (i = 1; i + 1 <= n; i += 2) {
            h = tolower(substr($0, i, 2))
            d = index("0123456789abcdef", substr(h, 1, 1)) - 1
            e = index("0123456789abcdef", substr(h, 2, 1)) - 1
            if (d < 0 || e < 0) continue
            v = d * 16 + e
            c = sprintf("%c", v)
            if (c ~ /^[A-Za-z0-9._~-]$/) printf "%s", c; else printf "%%%02X", v
        }
    }'
}

# 纯 awk 兜底: 用 1..255 的字节表反查每个字符的字节值 (LC_ALL=C 保证按字节处理)
urlencode_pure_awk() {
    LC_ALL=C awk '
        BEGIN { for (i = 1; i < 256; i++) tbl = tbl sprintf("%c", i) }
        {
            s = $0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /^[A-Za-z0-9._~-]$/) { printf "%s", c; continue }
                v = index(tbl, c)
                if (v > 0) printf "%%%02X", v; else printf "%%3F"
            }
        }'
}

hex_probe() {   # $1=候选工具; 能用返回 0
    case "$1" in
        od)      [ "$(printf 'A' | od -An -v -tx1 2>/dev/null | tr -d ' \t\n')" = "41" ] ;;
        hexdump) [ "$(printf 'A' | hexdump -v -e '/1 "%02x"' 2>/dev/null | tr -d ' \t\n')" = "41" ] ;;
        awk)     [ "$(printf 'A b' | urlencode_pure_awk)" = "A%20b" ] ;;
        *)       return 1 ;;
    esac
}

pick_hextool() {
    for _t in ${HEXTOOL_OVERRIDE:-} od hexdump awk; do
        [ "$_t" = "$HEXTOOL" ] && continue
        if hex_probe "$_t"; then HEXTOOL="$_t"; return 0; fi
    done
    return 1
}

urlencode() {
    _s="$1"
    case "$_s" in
        *[!A-Za-z0-9._~-]*) ;;                        # 含需转义字符, 走编码
        *) printf '%s' "$_s"; return 0 ;;             # 全是安全字符, 原样输出
    esac
    case "$HEXTOOL" in
        od)      printf '%s' "$_s" | od -An -v -tx1 | tr -d ' \t\n' | hex2url ;;
        hexdump) printf '%s' "$_s" | hexdump -v -e '/1 "%02x"' | tr -d ' \t\n' | hex2url ;;
        *)       printf '%s' "$_s" | urlencode_pure_awk ;;
    esac
}

# 自检: 编码器必须是"能算对"的, 不能静默返回空串
selfcheck() {
    if ! pick_hextool; then
        selfcheck_failed
        return 1
    fi
    _got=$(urlencode 'a b:c/d?&=')
    if [ "$_got" = 'a%20b%3Ac%2Fd%3F%26%3D' ]; then
        SELFTEST_OK=1
        return 0
    fi
    selfcheck_failed "$_got"
    return 1
}

selfcheck_failed() {
    SELFTEST_OK=0
    log "URL 编码自检失败: 期望 a%20b%3Ac%2Fd%3F%26%3D, 实际 '${1:-空}' (编码器=${HEXTOOL:-无})"
    log "   → 编码坏掉会让表单值全变空串, 认证必定失败(且看不出原因)"
    log "   → 处理: opkg update && opkg install coreutils-od; 或在 $CONF 里指定 HEXTOOL_OVERRIDE=awk"
}

# URL 解码 (用于还原 302 里的原始 url 参数)
urldecode() {
    printf '%s' "$1" | sed 's/+/ /g' | awk '{
        out = ""; n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "%" && i + 2 <= n) {
                h = tolower(substr($0, i + 1, 2))
                d = index("0123456789abcdef", substr(h, 1, 1)) - 1
                e = index("0123456789abcdef", substr(h, 2, 1)) - 1
                if (d >= 0 && e >= 0) { out = out sprintf("%c", d * 16 + e); i = i + 2; continue }
            }
            out = out c
        }
        printf "%s", out
    }'
}

# 从响应头取某个头的值
hdr_value() {
    awk -v want="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[ \t]+/, "", line)
            i = index(line, ":")
            if (i > 1 && tolower(substr(line, 1, i - 1)) == want) {
                v = substr(line, i + 1)
                sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
                print v
                exit
            }
        }' "$T_HDR" 2>/dev/null
}

http_code() {
    awk '{
        l = $0
        sub(/\r$/, "", l)
        sub(/^[ \t]+/, "", l)
        if (l ~ /^HTTP\/[0-9]/) c = $2
    } END { print c }' "$T_HDR" 2>/dev/null
}

# 取回 cookie (仅当没有 curl 时手工维护)
pick_cookie() {
    sc=$(hdr_value "set-cookie")
    [ -n "$sc" ] || return 0
    kv=$(printf '%s' "$sc" | sed 's/;.*//')
    [ -n "$kv" ] || return 0
    case "$COOKIE" in
        "") COOKIE="$kv" ;;
        *) case ";$COOKIE;" in
               *";$(printf '%s' "$kv" | cut -d= -f1)="*) ;;
               *) COOKIE="$COOKIE; $kv" ;;
           esac ;;
    esac
}

# fetch METHOD URL [DATA] -> 响应体 $T_BODY, 响应头 $T_HDR
# 用 set -- 累积参数, 避免 cookie 里的空格被字段拆分
fetch() {
    _m="$1"; _u="$2"; _d="${3:-}"
    : > "$T_BODY"; : > "$T_HDR"; : > "$TMPD/err"
    if [ "$CLIENT" = "curl" ]; then
        set -- -sS -m "$TIMEOUT" -A "$UA" -D "$T_HDR" -o "$T_BODY"
        [ -n "$COOKIE" ] && set -- "$@" -H "Cookie: $COOKIE"
        if [ "$_m" = "POST" ]; then
            set -- "$@" -H 'Content-Type: application/x-www-form-urlencoded' --data "$_d"
        fi
        curl "$@" "$_u" 2>"$TMPD/err"
        _rc=$?
    else
        set -- -q -S -T "$TIMEOUT" -U "$UA" -O "$T_BODY"
        [ -n "$COOKIE" ] && set -- "$@" --header="Cookie: $COOKIE"
        if [ "$_m" = "POST" ]; then
            set -- "$@" --header="Content-Type: application/x-www-form-urlencoded" --post-data="$_d"
        fi
        if [ "$CLIENT" = "uclient-fetch" ]; then
            uclient-fetch "$@" "$_u" 2>"$T_HDR"
        else
            wget "$@" "$_u" 2>"$T_HDR"
        fi
        _rc=$?
    fi
    pick_cookie
    [ -n "$(http_code)" ] && return 0
    [ "$_rc" -eq 0 ] && return 0
    return "$_rc"
}

# 取回页面里 client 允许提交的表单字段 (name/value)
extract_inputs() { awk -f "$T_AWK" "$T_BODY" > "$T_FORM" 2>/dev/null; }

input_value() {   # $1=kind(name|id) $2=key
    awk -v k="$1" -v key="$2" 'BEGIN { FS = "\t" }
        $1 == k && $2 == key {
            s = ""
            for (i = 3; i <= NF; i++) s = s (i > 3 ? "\t" : "") $i
            print s
            exit
        }' "$T_FORM"
}

#--------------------------------------------------------------------------------
# 失败取证: 把门户到底说了什么摊开来
#--------------------------------------------------------------------------------
html_note() {
    awk '
        { s = s $0 "\n" }
        END {
            n = 0; t = ""
            if (match(s, /command\.errors[^>]*>[^<]*/))       { n = 1; t = substr(s, RSTART, RLENGTH) }
            if (!n && match(s, /class="common2"[^>]*>[^<]*/)) { n = 1; t = substr(s, RSTART, RLENGTH) }
            if (!n && match(s, /class="error"[^>]*>[^<]*/))   { n = 1; t = substr(s, RSTART, RLENGTH) }
            if (!n && match(s, /id="errMessage"[^>]*value="[^"]*"/)) {
                n = 1; t = substr(s, RSTART, RLENGTH)
                sub(/.*value="/, "", t); sub(/"$/, "", t)
            }
            if (n) {
                if (t ~ />/) sub(/.*>/, "", t)
                gsub(/^[ \t\r\n]+/, "", t); gsub(/[ \t\r\n]+$/, "", t)
                print t
            }
        }' "${1:-$T_BODY}" 2>/dev/null
}

dump_response() {
    [ -n "$RESP_DUMP" ] || return 0
    cp "$T_BODY" "$RESP_DUMP" 2>/dev/null || return 0
    [ -s "$RESP_DUMP" ] || rm -f "$RESP_DUMP" 2>/dev/null
    return 0
}

hint_for() {
    case "$1" in
        *绑定*|*MAC*|*mac*)      log "   → 可能: 账号已绑定到别的设备。先去自助服务解绑, 或把配置里 BIND_MAC 改成 0 再试" ;;
        *已在线*|*别处*|*其他设备*|*踢*|*下线*) log "   → 可能: 同一账号已在别处在线。先在电脑/手机点下线, 再让路由器认证" ;;
        *欠费*|*余额*|*缴费*)    log "   → 可能: 账号欠费, 需要先充值" ;;
        *密码*|*账号*|*用户*|*不存在*) log "   → 检查 $CONF 里的 USERNAME / PASSWORD" ;;
    esac
}

#--------------------------------------------------------------------------------
# 在线判定 / 参数解析
#--------------------------------------------------------------------------------
probe_once() {   # $1=探测URL; 在线返回 0
    fetch GET "$1" || return 1
    c=$(http_code)
    for ok in $ONLINE_CODES; do
        [ "$c" = "$ok" ] && return 0
    done
    return 1
}

check_online() {
    for u in $PROBE_URLS; do
        probe_once "$u" && { ONLINE_URL="$u"; return 0; }
    done
    return 1
}

wan_iface() {
    [ -n "$WAN_IFACE" ] && { printf '%s' "$WAN_IFACE"; return; }
    ip route show default 2>/dev/null | awk '{ print $5; exit }'
}

wan_ip() {
    [ -n "$WAN_IP" ] && { printf '%s' "$WAN_IP"; return 0; }
    _i=$(wan_iface); [ -n "$_i" ] || return 1
    ip -4 -o addr show dev "$_i" 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | head -n1
}

wan_mac() {
    [ -n "$WAN_MAC" ] && { printf '%s' "$WAN_MAC"; return; }
    _i=$(wan_iface); [ -n "$_i" ] || return 1
    ip link show dev "$_i" 2>/dev/null | awk '/link\/ether/ { print $2; exit }' | tr 'A-Z' 'a-z'
}

# 从 302 的 Location 提取门户参数 (核心)
resolve_params() {
    QS=""
    PORTAL_URL=""
    for u in $PROBE_URLS; do
        fetch GET "$u" || continue
        c=$(http_code)
        loc=$(hdr_value "Location")
        if [ -n "$loc" ]; then
            loc=$(printf '%s' "$loc" | sed 's/&amp;/\&/g')
            case "$loc" in
                *webauth.do*)
                    case "$loc" in
                        http://*|https://*) PORTAL_URL="$loc" ;;
                        /*) PORTAL_URL="http://$PORTAL_HOST$loc" ;;
                        *)  PORTAL_URL="http://$PORTAL_HOST/$loc" ;;
                    esac
                    ;;
            esac
        fi
        # 有的网关用 200 + meta/JS 跳转
        if [ -z "$PORTAL_URL" ] && [ "$c" = "200" ]; then
            cand=$(awk 'match($0, /webauth\.do\?[^"<> ]+/){ print substr($0, RSTART, RLENGTH); exit }' "$T_BODY")
            [ -n "$cand" ] && PORTAL_URL="http://$PORTAL_HOST/$cand"
        fi
        [ -n "$PORTAL_URL" ] && break
    done

    if [ -n "$PORTAL_URL" ]; then
        case "$PORTAL_URL" in
            *\?*) QS="${PORTAL_URL#*\?}" ;;
            *)    QS="" ;;
        esac
    fi
    ORIG_URL="$(urldecode "$(qs_get url)")"

    # 兜底: 拿不到 302 时用本机 WAN 口信息拼装
    if [ -z "$QS" ]; then
        _ip=$(wan_ip); _mac=$(wan_mac)
        if [ -n "$_ip" ] && [ -n "$_mac" ]; then
            ORIG_URL="$DEFAULT_URL"
            QS="wlanacip=$WLANACIP&wlanacname=$WLANACNAME&wlanuserip=$_ip&mac=$_mac&vlan=0&url=$ORIG_URL"
            PORTAL_URL="http://$PORTAL_HOST/webauth.do?$QS"
            log "提示: 未捕获到网关 302, 改用本机 WAN 信息拼装参数 (IP=$_ip MAC=$_mac)"
        else
            return 1
        fi
    fi
    return 0
}

# 从 QS 里取某个参数值
qs_get() {
    printf '%s' "$QS" | tr '&' '\n' | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

portal_base() {
    printf '%s' "$PORTAL_URL" | sed 's#\(http://[^/]*\).*#\1#'
}

#--------------------------------------------------------------------------------
# 登录
#--------------------------------------------------------------------------------
# 表单字段默认值 (与抓包一致; 页面上取到则以页面为准)
field_default() {
    case "$1" in
        scheme)           printf 'http' ;;
        serverIp)         printf 'tomcat_server:80' ;;
        hostIp)           printf 'http://127.0.0.1:8081/' ;;
        auth_type)        printf '0' ;;
        isBindMac1)       printf '0' ;;
        pageid)           printf '6' ;;
        templatetype)     printf '1' ;;
        listbindmac)      printf '0' ;;
        recordmac)        printf '1' ;;
        isRemind)         printf '1' ;;
        url)              printf '%s' "$ORIG_URL" ;;
        notice_pic_loop1) printf '/portal/uploads/pc/demo2/images/logo.png' ;;
        notice_pic_loop2) printf '/portal/uploads/pc/demo2/images/bj.png' ;;
        *)                printf '' ;;
    esac
}

build_login_data() {
    DATA=""
    for f in scheme serverIp hostIp loginType auth_type isBindMac1 pageid templatetype \
             listbindmac recordmac isRemind loginTimes groupId distoken echostr url \
             isautoauth mobile notice_pic_loop2 notice_pic_loop1; do
        v=$(input_value name "$f")
        [ -n "$v" ] || v=$(field_default "$f")
        DATA="${DATA}${DATA:+&}$f=$(urlencode "$v")"
    done
    DATA="$DATA&userId=$(urlencode "$USERNAME")&passwd=$(urlencode "$PASSWORD")"
    [ "$REMEMBER" = "1" ] && DATA="$DATA&remInfo=on"
    [ "$BIND_MAC" = "1" ] && DATA="$DATA&isBindMac=bindmac"
}

# 查运营商代拨结果; 成功返回 0, 明确失败返回 1
poll_dial_result() {
    _pageid=$(input_value id pageid); [ -n "$_pageid" ] || _pageid=6
    _end=$(($(date +%s) + DIAL_WAIT))
    while [ "$(date +%s)" -lt "$_end" ]; do
        lock_touch
        fetch POST "$(portal_base)/getAuthResult.do" \
              "userId=$(urlencode "$USERNAME")&pageId=$_pageid" || { sleep "$DIAL_INTERVAL"; continue; }
        _chk=$(awk 'match($0, /"check"[ \t]*:[ \t]*"[^"]*"/){
                        s = substr($0, RSTART, RLENGTH)
                        sub(/.*"check"[ \t]*:[ \t]*"/, "", s)
                        sub(/"$/, "", s); print s; exit }' "$T_BODY")
        case "$_chk" in
            "") ;;
            *成功*) log "代拨结果: $_chk"; return 0 ;;
            *失败*|*错误*|*异常*) log "代拨失败: $_chk"; return 1 ;;
            *) log "代拨中: $_chk" ;;
        esac
        sleep "$DIAL_INTERVAL"
    done
    log "等待代拨结果超时, 继续按连通性判断"
    return 0
}

wait_online() {
    _end=$(($(date +%s) + VERIFY_WAIT))
    while [ "$(date +%s)" -lt "$_end" ]; do
        lock_touch
        check_online && return 0
        sleep "$VERIFY_INTERVAL"
    done
    return 1
}

do_login() {
    [ -n "$USERNAME" ] || die "未配置 USERNAME (见 $CONF)"
    [ -n "$PASSWORD" ] || die "未配置 PASSWORD (见 $CONF)"
    COOKIE=""

    resolve_params || die "无法获取门户参数 (网关没有 302 到门户, 且本机 WAN 口无 IP)"
    log "门户参数: $QS"

    fetch GET "$PORTAL_URL" || log "警告: 取登录页失败, 继续尝试提交"
    extract_inputs
    # 门户的两种"参数不对"提示: 未知网关 / 没有找到认证页面
    if grep -q '未知网关' "$T_BODY" 2>/dev/null || grep -q '没有找到认证页面' "$T_BODY" 2>/dev/null; then
        _perr=$(awk 'match($0, /command\.errors[^>]*>[^<]*/){ s = substr($0, RSTART, RLENGTH); sub(/.*>/, "", s); print s; exit }' "$T_BODY")
        log "门户拒绝参数: ${_perr:-未知网关} (wlanacname/wlanacip/wlanuserip/mac 不对, 用 doctor 检查)"
        return 1
    fi
    _pageid=$(input_value name pageid)
    log "登录页已取到 (pageid=${_pageid:-6})"

    build_login_data
    # 防御: 值被编码成空串的话立刻报错, 不要发出去白挨一次拒绝
    case "$DATA" in
        *"userId=&"*|*"&passwd=&"*)
            log "错误: 表单里 userId/passwd 为空 (编码器=$HEXTOOL, 账号=${USERNAME:-空})"
            log "   → 运行 $0 doctor 看自检结果; 或 opkg install coreutils-od"
            return 1 ;;
    esac
    [ "$LOG_QUIET" = "1" ] || log "提交认证: userId=$USERNAME ($(printf '%s' "$DATA" | wc -c) 字节)"
    fetch POST "$PORTAL_URL" "$DATA" || log "警告: 提交请求返回非零, 检查响应"
    extract_inputs
    _code=$(http_code)
    _loc=$(hdr_value Location)

    act=$(input_value id act)
    errmsg=$(input_value id errMessage)
    if [ "$act" = "LOGINSUCC" ]; then
        log "认证成功${errmsg:+ ($errmsg)}"
        case "$errmsg" in
            *拨号*|*代拨*|*外网*) poll_dial_result ;;
        esac
        if wait_online; then
            log "已联网, 完成"
            return 0
        fi
        dump_response
        log "认证通过但探测仍不通 (HTTP $_code), 可能代拨未完成或网关限速"
        log "   门户返回页: ${RESP_DUMP:-未保存}; 可把 DIAL_WAIT/VERIFY_WAIT 调大再试"
        return 1
    fi

    # 失败: 把门户的原话摊出来 (act / errMessage / 页面可见提示)
    _note=$(html_note)
    dump_response
    log "认证失败: act=${act:-无} errMessage=${errmsg:-无} 提示=${_note:-无}"
    log "   响应: HTTP ${_code:-?}${_loc:+  Location: }${_loc:-}"
    [ -n "$RESP_DUMP" ] && [ -s "$RESP_DUMP" ] && log "   门户返回页已存: $RESP_DUMP"
    hint_for "${errmsg}${_note}"
    return 1
}

# 一次完整的"确保在线"
do_ensure() {
    if check_online; then
        log "当前已在线 ($ONLINE_URL)"
        return 0
    fi
    _n=0
    while [ "$_n" -lt "$RETRY" ]; do
        _n=$((_n + 1))
        [ "$_n" -gt 1 ] && { log "第 $_n 次尝试..."; sleep 3; }
        do_login && return 0
    done
    return 1
}

do_status() {
    if check_online; then
        log "在线 ($ONLINE_URL)"
        return 0
    fi
    log "未认证 / 离线"
    return 1
}

# 实验性: 注销下线
do_logout() {
    check_online || { log "当前未在线, 无需注销"; return 0; }
    resolve_params || die "无法获取门户参数"
    _pageid=$(input_value name pageid); [ -n "$_pageid" ] || _pageid=6
    fetch POST "$(portal_base)/webdisconn.do?$QS" "userId=$(urlencode "$USERNAME")&pageId=$_pageid"
    if grep -qE '下线成功|注销成功|退出成功' "$T_BODY" 2>/dev/null; then
        log "已注销下线"
        return 0
    fi
    log "注销请求已发送, 结果未确认 (门户返回 $(wc -c < "$T_BODY" 2>/dev/null) 字节)"
    return 0
}

do_monitor() {
    log "monitor 启动: 每 ${INTERVAL}s 检测一次 (配置 $CONF)"
    while :; do
        do_ensure || log "本次认证未成功, ${INTERVAL}s 后重试"
        sleep "$INTERVAL"
    done
}

do_doctor() {
    echo "=== nnnu-auth 诊断 (v$VERSION) ==="
    echo "配置文件   : $CONF $([ -r "$CONF" ] && echo '(已读取)' || echo '(不存在)')"
    echo "HTTP 客户端: $CLIENT"
    selfcheck >/dev/null 2>&1
    echo "URL 编码器 : $HEXTOOL $([ "$SELFTEST_OK" = "1" ] && echo '(自检通过)' || echo '(自检失败! 见下方告警)')"
    [ "$SELFTEST_OK" = "1" ] || echo "  编码器坏掉会导致表单值变成空串, 认证必定失败; 装 coreutils-od 可解"
    _i=$(wan_iface)
    echo "WAN 接口   : ${_i:-未知}"
    echo "WAN IP     : $(wan_ip 2>/dev/null || echo 未知)"
    echo "WAN MAC    : $(wan_mac 2>/dev/null || echo 未知)"
    echo "账号       : ${USERNAME:-未配置}"
    echo
    echo "--- 探测 (未认证时应 302 到门户) ---"
    for u in $PROBE_URLS; do
        if fetch GET "$u"; then
            echo "$u -> HTTP $(http_code)  Location: $(hdr_value Location)"
        else
            echo "$u -> 请求失败"
        fi
    done
    echo
    echo "--- 门户参数解析 ---"
    if resolve_params; then
        echo "门户 URL : $PORTAL_URL"
        echo "参数     : $QS"
        fetch GET "$PORTAL_URL"
        echo "登录页   : HTTP $(http_code), $(wc -c < "$T_BODY") 字节"
        extract_inputs
        echo "pageid            = $(input_value name pageid)"
        echo "templatetype      = $(input_value name templatetype)"
        echo "serverIp          = $(input_value name serverIp)"
        echo "表单字段数        = $(wc -l < "$T_FORM")"
        grep -q '未知网关' "$T_BODY" && echo "!! 门户返回【未知网关】"
        grep -q '没有找到认证页面' "$T_BODY" && echo "!! 门户返回【没有找到认证页面】"
    else
        echo "解析失败: 未捕获到门户 302, 且本机 WAN 口无 IPv4 地址"
    fi
    echo
    echo "--- 在线状态 ---"
    check_online && echo "在线 ($ONLINE_URL)" || echo "不在线"
    echo
    echo "--- 最近日志 ---"
    if [ -r "$LOG_FILE" ]; then
        tail -n 12 "$LOG_FILE"
    else
        echo "($LOG_FILE 不存在)"
    fi
    if [ -s "$RESP_DUMP" ]; then
        echo
        echo "--- 上次失败时门户返回页: $RESP_DUMP ($(wc -c < "$RESP_DUMP") 字节) ---"
        echo "提取到的提示: $(html_note "$RESP_DUMP" | head -n1)"
    fi
}

#--------------------------------------------------------------------------------
# 入口
#--------------------------------------------------------------------------------
ACTION="ensure"
for a in "$@"; do
    case "$a" in
        -q|--quiet) LOG_QUIET=1 ;;
        ensure|login|status|logout|monitor|doctor) ACTION="$a" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $a (用 --help 查看用法)" >&2; exit 2 ;;
    esac
done

init_tmp
pick_client

# 互斥锁: 避免 cron / hotplug / monitor 同时认证
# 判定: 持锁进程还活着 -> 占用; 进程查不到但锁很新(MSYS/容器里 kill -0 可能失效) -> 仍算占用; 过期才抢占
LOCK="${TMPDIR:-/tmp}/nnnu-auth.lock"

# 心跳: 长等待时刷新锁的时间戳, 让"锁很新"判定不会误伤正在跑的实例
lock_touch() { [ -n "$LOCK" ] && echo "$(date +%s)" > "$LOCK/ts" 2>/dev/null; }

lock_acquire() {
    _now=$(date +%s)
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ > "$LOCK/pid"; echo "$_now" > "$LOCK/ts"
        return 0
    fi
    _old=$(cat "$LOCK/pid" 2>/dev/null)
    _ts=$(cat "$LOCK/ts" 2>/dev/null)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        log "已有实例在运行 (pid=$_old), 跳过"
        return 1
    fi
    case "$_ts" in
        ''|*[!0-9]*) ;;                                              # 无时间戳: 视为陈旧
        *) [ $((_now - _ts)) -lt "$LOCK_STALE" ] && { log "锁仍很新 (${_ts}), 可能有实例刚启动, 跳过"; return 1; } ;;
    esac
    rm -rf "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ > "$LOCK/pid"; echo "$_now" > "$LOCK/ts"
        return 0
    fi
    log "无法获取互斥锁, 跳过"
    return 1
}

if [ "$ACTION" != "doctor" ] && [ "$ACTION" != "status" ]; then
    # 编码器自检: 宁可响亮地失败, 也不要静默提交空账号密码
    selfcheck || exit 1
    if lock_acquire; then
        trap 'cleanup; rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP
    else
        exit 0
    fi
fi

case "$ACTION" in
    ensure)  do_ensure ;;
    login)   do_login ;;
    status)  do_status ;;
    logout)  do_logout ;;
    monitor) do_monitor ;;
    doctor)  do_doctor ;;
esac
exit $?
