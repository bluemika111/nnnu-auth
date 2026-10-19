#!/bin/sh
#===============================================================================
#  /usr/share/nnnu-auth/apply.sh
#  把 uci 配置真正落地:
#    1) 渲染 /etc/nnnu-auth.conf
#    2) 按 mode (cron|service) 与 enabled 开关, 调整定时任务/守护进程
#    3) 清掉可能残留的互斥锁
#
#  LuCI 保存后、包安装后都会调用它; 手动改 uci 后也可以直接跑一次。
#===============================================================================
UCI="${UCI_CMD:-uci}"
# 路径可通过环境变量覆盖, 方便在路由器之外做测试
CONF="${NNNU_CONF:-/etc/nnnu-auth.conf}"
CRON="${NNNU_CRON:-/etc/crontabs/root}"
CRON_LINE='* * * * * /usr/bin/nnnu-auth.sh ensure -q'
INIT="${NNNU_INIT:-/etc/init.d/nnnu-auth}"
RENDER="${NNNU_RENDER:-/usr/share/nnnu-auth/render-conf.sh}"
CROND="${NNNU_CROND:-/etc/init.d/cron}"

log() { logger -t nnnu-auth "$*" 2>/dev/null || echo "$*"; }

cron_add() {
    touch "$CRON" 2>/dev/null
    if ! grep -q 'nnnu-auth\.sh' "$CRON" 2>/dev/null; then
        echo "$CRON_LINE" >> "$CRON"
    fi
    "$CROND" enable 2>/dev/null
    "$CROND" restart 2>/dev/null
}

cron_del() {
    [ -f "$CRON" ] && sed -i '/nnnu-auth\.sh/d' "$CRON" 2>/dev/null
    "$CROND" restart 2>/dev/null
}

# 0) 确保 uci 里的 main 段存在 —— LuCI 的 NamedSection 绑的是 "main",
#    段不存在的话设置页会"能显示但保存不进去"
if [ -n "$("$UCI" -q show nnnu-auth 2>/dev/null)" ] || [ -f /etc/config/nnnu-auth ]; then
    if ! "$UCI" -q get nnnu-auth.main >/dev/null 2>&1; then
        "$UCI" -q set nnnu-auth.main=auth 2>/dev/null
        "$UCI" -q commit nnnu-auth 2>/dev/null
        log "补建了 uci 段 nnnu-auth.main"
    fi
fi

# 1) 渲染配置
if [ -x "$RENDER" ]; then
    NNNU_CONF_OUT="$CONF" "$RENDER" || log "渲染 $CONF 失败"
fi

# 2) 运行方式
rm -rf /tmp/nnnu-auth.lock

if [ "$("$UCI" -q get nnnu-auth.main.enabled 2>/dev/null)" = "0" ]; then
    log "已禁用, 停止认证"
    cron_del
    [ -x "$INIT" ] && { "$INIT" stop 2>/dev/null; "$INIT" disable 2>/dev/null; }
    exit 0
fi

# 没填账号就别定时跑, 免得每分钟在日志里刷一条"未配置"
if [ -z "$("$UCI" -q get nnnu-auth.main.username 2>/dev/null)" ] && \
   ! grep -q "^USERNAME='..*'" "$CONF" 2>/dev/null; then
    log "还没配置账号密码, 暂不启用 (LuCI → 服务 → 校园网认证)"
    cron_del
    [ -x "$INIT" ] && { "$INIT" stop 2>/dev/null; "$INIT" disable 2>/dev/null; }
    exit 0
fi

case "$("$UCI" -q get nnnu-auth.main.mode 2>/dev/null)" in
    service)
        cron_del
        if [ -x "$INIT" ]; then
            "$INIT" enable 2>/dev/null
            "$INIT" restart 2>/dev/null
        fi
        log "运行方式: procd 常驻守护"
        ;;
    *)
        [ -x "$INIT" ] && "$INIT" disable 2>/dev/null
        cron_add
        log "运行方式: cron 每分钟检查"
        ;;
esac

exit 0
