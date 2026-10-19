#!/bin/sh
#===============================================================================
#  tests/test_pkg.sh — 验证 LuCI 软件包里的脚本 (不需要路由器)
#
#  覆盖:
#    * render-conf.sh  : uci → /etc/nnnu-auth.conf 的渲染与转义
#    * apply.sh        : enabled / mode(cron|service) / 未配置账号 三种分支
#===============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/pkg/nnnu-auth/data"
RENDER="$PKG/usr/share/nnnu-auth/render-conf.sh"
APPLY="$PKG/usr/share/nnnu-auth/apply.sh"
W="${TMPDIR:-/tmp}/nnnu-pkgtest.$$"
mkdir -p "$W"
PASS=0
FAIL=0

cleanup() { rm -rf "$W"; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (得到 '$1', 期望 '$2')"; fi }

# ---- 假 uci: 只支持 -q get nnnu-auth.main.<key> ------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] || exit 1
[ "$2" = "get" ] || exit 1
key="${3#nnnu-auth.main.}"
awk -F'=' -v k="$key" '
    $1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit }
    END { if (!found) exit 1 }' "$FAKE_UCI"
EOF
chmod +x "$W/bin/uci"

# ---- 假 init.d / cron, 记录被调用的动作 -------------------------------------
cat > "$W/bin/fake-init" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_INIT_LOG"
EOF
chmod +x "$W/bin/fake-init"
cat > "$W/bin/fake-crond" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_CROND_LOG"
EOF
chmod +x "$W/bin/fake-crond"

echo "=== [1] render-conf.sh: uci → conf 的取值与转义 ==="
# 故意塞进单引号/空格/美元符/中文, 验证单引号包裹是安全的
cat > "$W/uci.env" <<'EOF'
username=2026000001
password=p'wd "x" $HOME 空格 中文
probe_urls=http://a.test/generate_204 http://b.test/generate_204
interval=90
bind_mac=0
mode=service
log_file=/var/log/nnnu-auth.log
EOF
FAKE_UCI="$W/uci.env" UCI_CMD="$W/bin/uci" NNNU_CONF_OUT="$W/out.conf" \
    sh "$RENDER" > "$W/render.log" 2>&1
eq "$?" "0" "render-conf 退出码 0"
[ -s "$W/out.conf" ] && ok "生成了 conf" || bad "没生成 conf"

# source 回来, 值必须逐字一致
(
    . "$W/out.conf"
    printf '%s\n' "$USERNAME" > "$W/v.username"
    printf '%s\n' "$PASSWORD" > "$W/v.password"
    printf '%s\n' "$INTERVAL" > "$W/v.interval"
    printf '%s\n' "$BIND_MAC" > "$W/v.bindmac"
    printf '%s\n' "$PROBE_URLS" > "$W/v.probe"
)
eq "$(cat "$W/v.username")" "2026000001" "username 原样还原"
eq "$(cat "$W/v.password")" "p'wd \"x\" \$HOME 空格 中文" "带引号/美元符/中文的密码原样还原"
eq "$(cat "$W/v.interval")" "90" "interval 还原"
eq "$(cat "$W/v.bindmac")" "0" "bind_mac=0 不会被当成空值"
eq "$(cat "$W/v.probe")" "http://a.test/generate_204 http://b.test/generate_204" "多值 probe_urls 还原"
grep -q "HEXTOOL_OVERRIDE=''" "$W/out.conf" && ok "未配置的项写空值" || bad "HEXTOOL_OVERRIDE 不是空值"
grep -q "WLANACNAME='ZAXSOFT-BRAS-WM'" "$W/out.conf" && ok "未配置的项落到默认值" || bad "默认值没生效"

echo
echo "=== [2] apply.sh 分支: mode=service ==="
# 预置一条旧 cron 行, service 模式应该把它清掉
printf '# root crontab\n* * * * * /usr/bin/nnnu-auth.sh ensure -q\n' > "$W/crontab"
: > "$W/init.log"; : > "$W/crond.log"
sed 's/^mode=.*/mode=service/' "$W/uci.env" > "$W/uci.service"
FAKE_UCI="$W/uci.service" UCI_CMD="$W/bin/uci" \
FAKE_INIT_LOG="$W/init.log" FAKE_CROND_LOG="$W/crond.log" \
NNNU_CONF="$W/out.conf" NNNU_CRON="$W/crontab" NNNU_INIT="$W/bin/fake-init" \
NNNU_CROND="$W/bin/fake-crond" NNNU_RENDER="$RENDER" \
    sh "$APPLY" > "$W/apply1.log" 2>&1
eq "$?" "0" "apply 退出码 0"
grep -q 'nnnu-auth.sh' "$W/crontab" && bad "service 模式下 cron 行还在" || ok "service 模式清掉了 cron 行"
grep -q '^enable' "$W/init.log" && ok "调用了 init enable" || bad "没调用 init enable"
grep -q '^restart' "$W/init.log" && ok "调用了 init restart" || bad "没调用 init restart"

echo
echo "=== [3] apply.sh 分支: mode=cron ==="
printf '# root crontab\n' > "$W/crontab"
: > "$W/init.log"; : > "$W/crond.log"
sed 's/^mode=.*/mode=cron/' "$W/uci.env" > "$W/uci.cron"
FAKE_UCI="$W/uci.cron" UCI_CMD="$W/bin/uci" \
FAKE_INIT_LOG="$W/init.log" FAKE_CROND_LOG="$W/crond.log" \
NNNU_CONF="$W/out.conf" NNNU_CRON="$W/crontab" NNNU_INIT="$W/bin/fake-init" \
NNNU_CROND="$W/bin/fake-crond" NNNU_RENDER="$RENDER" \
    sh "$APPLY" > "$W/apply2.log" 2>&1
eq "$?" "0" "apply 退出码 0"
grep -q '^\* \* \* \* \* /usr/bin/nnnu-auth.sh ensure -q$' "$W/crontab" && ok "写入了 cron 行" || bad "cron 行没写入"
grep -c 'nnnu-auth.sh' "$W/crontab" > "$W/cnt"; eq "$(cat "$W/cnt")" "1" "cron 行不会重复添加"
grep -q '^disable' "$W/init.log" && ok "cron 模式关掉了常驻服务" || bad "没关常驻服务"
grep -q '^restart' "$W/crond.log" && ok "重启了 cron" || bad "没重启 cron"
# 再跑一次, 仍然只有一行
FAKE_UCI="$W/uci.cron" UCI_CMD="$W/bin/uci" \
FAKE_INIT_LOG="$W/init.log" FAKE_CROND_LOG="$W/crond.log" \
NNNU_CONF="$W/out.conf" NNNU_CRON="$W/crontab" NNNU_INIT="$W/bin/fake-init" \
NNNU_CROND="$W/bin/fake-crond" NNNU_RENDER="$RENDER" sh "$APPLY" >/dev/null 2>&1
grep -c 'nnnu-auth.sh' "$W/crontab" > "$W/cnt2"; eq "$(cat "$W/cnt2")" "1" "重复 apply 也不会重叠加行"

echo
echo "=== [4] apply.sh 分支: enabled=0 / 未填账号 ==="
printf '# root crontab\n* * * * * /usr/bin/nnnu-auth.sh ensure -q\n' > "$W/crontab"
: > "$W/init.log"
sed 's/^username=.*/username=/' "$W/uci.cron" | sed 's/^mode=.*/mode=cron/' > "$W/uci.noauth"
FAKE_UCI="$W/uci.noauth" UCI_CMD="$W/bin/uci" \
FAKE_INIT_LOG="$W/init.log" FAKE_CROND_LOG="$W/crond.log" \
NNNU_CONF="$W/out.conf" NNNU_CRON="$W/crontab" NNNU_INIT="$W/bin/fake-init" \
NNNU_CROND="$W/bin/fake-crond" NNNU_RENDER="$RENDER" \
    sh "$APPLY" > "$W/apply3.log" 2>&1
grep -q 'nnnu-auth.sh' "$W/crontab" && bad "没填账号却仍装了 cron" || ok "没填账号就不启用 cron"
grep -q '暂不启用' "$W/apply3.log" && ok "给出了原因" || bad "没有说明原因"

printf '# root crontab\n* * * * * /usr/bin/nnnu-auth.sh ensure -q\n' > "$W/crontab"
: > "$W/init.log"
{ cat "$W/uci.cron"; echo "enabled=0"; } > "$W/uci.off"
FAKE_UCI="$W/uci.off" UCI_CMD="$W/bin/uci" \
FAKE_INIT_LOG="$W/init.log" FAKE_CROND_LOG="$W/crond.log" \
NNNU_CONF="$W/out.conf" NNNU_CRON="$W/crontab" NNNU_INIT="$W/bin/fake-init" \
NNNU_CROND="$W/bin/fake-crond" NNNU_RENDER="$RENDER" \
    sh "$APPLY" > "$W/apply4.log" 2>&1
grep -q 'nnnu-auth.sh' "$W/crontab" && bad "enabled=0 却仍有 cron" || ok "enabled=0 清掉了 cron"
grep -q '^stop' "$W/init.log" && ok "enabled=0 停掉了服务" || bad "enabled=0 没停服务"

echo
echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
