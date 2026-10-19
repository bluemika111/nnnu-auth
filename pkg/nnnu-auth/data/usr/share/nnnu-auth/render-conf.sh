#!/bin/sh
#===============================================================================
#  /usr/share/nnnu-auth/render-conf.sh
#  把 uci 配置(/etc/config/nnnu-auth) 渲染成 nnnu-auth.sh 读取的
#  /etc/nnnu-auth.conf。uci 是唯一权威来源, 所以那个文件是生成物, 别手改。
#
#  测试时可用环境变量覆盖:
#    UCI_CMD=/path/fake-uci       换个 uci 实现
#    NNNU_CONF_OUT=/tmp/xx.conf   换个输出路径
#===============================================================================
UCI="${UCI_CMD:-uci}"
OUT="${NNNU_CONF_OUT:-/etc/nnnu-auth.conf}"

[ -x "$UCI" ] || command -v "$UCI" >/dev/null 2>&1 || {
    echo "render-conf: 找不到 uci" >&2
    exit 1
}

get() { "$UCI" -q get "nnnu-auth.main.$1" 2>/dev/null; }

# 单引号安全包裹 (值里可能带空格/引号/美元号)
sq() {
    printf "'"
    printf '%s' "$1" | tr -d '\r\n' | sed "s/'/'\\\\''/g"
    printf "'"
}

emit() {   # $1=uci键(也是shell变量名, 用大写) $2=变量名 $3=默认值
    _v=$(get "$1")
    [ -n "$_v" ] || _v="$3"
    printf '%s=' "$2"
    sq "$_v"
    printf '\n'
}

TMP="$OUT.tmp.$$"
{
    printf '# 由 %s 从 uci 生成, 请勿手改; 改配置请用 LuCI 或 uci set nnnu-auth.main.*\n' \
           "/usr/share/nnnu-auth/render-conf.sh"
    printf '# 生成时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    printf '# ---- 账号 ----\n'
    emit username USERNAME ''
    emit password PASSWORD ''

    printf '\n# ---- 探测与在线判定 ----\n'
    emit probe_urls     PROBE_URLS   'http://edge-http.microsoft.com/captiveportal/generate_204 http://www.gstatic.com/generate_204 http://connect.rom.miui.com/generate_204'
    emit online_codes   ONLINE_CODES '204'

    printf '\n# ---- 表单开关 ----\n'
    emit bind_mac   BIND_MAC   1
    emit remember   REMEMBER   1

    printf '\n# ---- 时间参数 ----\n'
    emit interval        INTERVAL        60
    emit dial_wait       DIAL_WAIT       60
    emit dial_interval   DIAL_INTERVAL   3
    emit verify_wait     VERIFY_WAIT     60
    emit verify_interval VERIFY_INTERVAL 3
    emit timeout         TIMEOUT         8
    emit retry           RETRY           2
    emit lock_stale      LOCK_STALE      90

    printf '\n# ---- 兜底门户参数 ----\n'
    emit portal_host PORTAL_HOST '172.27.0.5'
    emit wlanacname  WLANACNAME  'ZAXSOFT-BRAS-WM'
    emit wlanacip    WLANACIP    '172.27.0.100'
    emit default_url DEFAULT_URL 'http://edge-http.microsoft.com/captiveportal/generate_204'

    printf '\n# ---- WAN 口 (留空自动探测) ----\n'
    emit wan_iface WAN_IFACE ''
    emit wan_mac   WAN_MAC   ''
    emit wan_ip    WAN_IP    ''

    printf '\n# ---- 其他 ----\n'
    emit log_file   LOG_FILE   '/var/log/nnnu-auth.log'
    emit resp_dump  RESP_DUMP  '/tmp/nnnu-auth-last-response.html'
    emit http_client HTTP_CLIENT auto
    emit hextool     HEXTOOL_OVERRIDE ''
    emit ua          UA ''
} > "$TMP" || { rm -f "$TMP"; exit 1; }

mv "$TMP" "$OUT"
chmod 600 "$OUT" 2>/dev/null
exit 0
