#!/bin/sh
# 只读验证: 用脚本里的提取器解析【线上门户】返回的登录页
# 只发 GET, 不提交账号密码
#
# 用法: sh tests/check_live_portal.sh [门户地址] [查询串]
#   查询串不传时, 用下面这组示例值(会被门户回「未知网关」, 只够验证解析器能跑)
#   想真验: 把浏览器里那次 302 的 Location 后面那串参数原样贴进来,
#   或者让 nnnu-auth.sh doctor 先打印出来再复制。
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

PORTAL=${1:-${PORTAL:-http://172.27.0.5}}
QS=${2:-${QS:-'wlanacip=172.27.0.100&wlanacname=ZAXSOFT-BRAS-WM&wlanuserip=192.168.1.100&mac=aa:bb:cc:dd:ee:ff&vlan=0&url=http://edge-http.microsoft.com/captiveportal/generate_204'}}

# 1) 从 nnnu-auth.sh 里取出内嵌的 awk 提取器 (保证验证的就是脚本真正用的解析逻辑)
sed -n "/^    cat > \"\$T_AWK\" <<'AWKEOF'\$/,/^AWKEOF\$/p" dist/nnnu-auth.sh \
    | sed '1d;$d' > /tmp/live_extract.awk
echo "提取器行数: $(wc -l < /tmp/live_extract.awk)"

# 2) 取线上登录页
echo "GET $PORTAL/webauth.do?..."
curl -sS -m 10 -D /tmp/live_hdr -o /tmp/live_page.html "$PORTAL/webauth.do?$QS"
echo "HTTP $(awk '/^HTTP\//{c=$2} END{print c}' /tmp/live_hdr)  页面 $(wc -c < /tmp/live_page.html) 字节"

# 3) 解析
awk -f /tmp/live_extract.awk /tmp/live_page.html > /tmp/live_form.txt
echo "提取到属性行: $(wc -l < /tmp/live_form.txt)"

get() { awk -F'\t' -v k="$1" -v key="$2" '$1==k && $2==key { v=$3; for(i=4;i<=NF;i++) v=v"\t"$i; print v; exit }' /tmp/live_form.txt; }

echo
echo "--- 线上页面关键字段 (脚本实际提交时会用到的值) ---"
for f in scheme serverIp hostIp loginType auth_type isBindMac1 pageid templatetype \
         listbindmac recordmac isRemind loginTimes groupId distoken echostr url \
         isautoauth mobile notice_pic_loop2 notice_pic_loop1; do
    echo "  $f = $(get name "$f")"
done
echo "  act(id) = $(get id act)"
echo "  errMessage(id) = $(get id errMessage)"

echo
echo "--- 与抓包对比 ---"
fail=0
cmp_field() { # name expected
    v=$(get name "$1")
    if [ "$v" = "$2" ]; then
        echo "  OK   $1 = $v"
    else
        echo "  差异 $1: 线上='$v' 抓包='$2'"
        fail=$((fail + 1))
    fi
}
cmp_field pageid 6
cmp_field templatetype 1
cmp_field serverIp 'tomcat_server:80'
cmp_field hostIp 'http://127.0.0.1:8081/'
cmp_field scheme http
cmp_field auth_type 0
cmp_field isBindMac1 0
cmp_field recordmac 1
cmp_field listbindmac 0
cmp_field isRemind 1
cmp_field notice_pic_loop2 '/portal/uploads/pc/demo2/images/bj.png'
cmp_field notice_pic_loop1 '/portal/uploads/pc/demo2/images/logo.png'
[ "$(get name userId)" != "" ] && echo "  OK   userId 输入框存在" || { echo "  差异 userId 输入框缺失"; fail=$((fail+1)); }
[ "$(get name passwd)" != "" ] && echo "  OK   passwd 输入框存在" || { echo "  差异 passwd 输入框缺失"; fail=$((fail+1)); }

echo
if [ "$fail" -eq 0 ]; then
    echo "== 线上模板与抓包一致, 脚本的表单构造可直接使用 =="
else
    echo "== 有 $fail 处差异, 需人工确认 =="
fi
exit 0
