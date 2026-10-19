#!/bin/sh
#===============================================================================
#  install.sh — 在 OpenWrt 上安装 nnnu-auth (在解包目录里执行)
#
#    sh install.sh            安装 + 用 cron 每分钟检查(推荐, 最省心)
#    sh install.sh service    安装 + 用 procd 常驻守护
#    sh install.sh test       安装后立刻诊断一次
#    sh install.sh uninstall  卸载
#
#  安装内容:
#    /usr/bin/nnnu-auth.sh                 主脚本
#    /etc/nnnu-auth.conf                   配置(已存在则保留, 不动你的密码)
#    /etc/hotplug.d/iface/99-nnnu-auth     WAN 上线即认证
#    /etc/init.d/nnnu-auth                 procd 服务(仅 service 模式启用)
#===============================================================================
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/dist"
[ -d "$SRC" ] || SRC="$HERE"          # 也支持直接在 dist/ 里执行

MODE="${1:-cron}"
BIN=/usr/bin/nnnu-auth.sh
CONF=/etc/nnnu-auth.conf

say() { printf '%s\n' "$*"; }

need_root() {
    [ "$(id -u)" = "0" ] || { say "请用 root 执行 (sudo -i 或 ssh root@路由器)"; exit 1; }
}

do_uninstall() {
    need_root
    /etc/init.d/nnnu-auth stop 2>/dev/null || true
    /etc/init.d/nnnu-auth disable 2>/dev/null || true
    sed -i '/nnnu-auth/d' /etc/crontabs/root 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null || true
    rm -f "$BIN" /etc/hotplug.d/iface/99-nnnu-auth /etc/init.d/nnnu-auth
    rm -rf /tmp/nnnu-auth.lock
    say "已卸载 (配置文件 $CONF 保留, 需要的话自行删除)"
    exit 0
}

if [ "$MODE" = "uninstall" ]; then
    do_uninstall
fi
need_root

#---------------------------------------------------------------- 依赖
if ! command -v curl >/dev/null 2>&1; then
    if command -v uclient-fetch >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        say "提示: 没装 curl, 将使用 uclient-fetch/wget 兜底 (建议装 curl 更稳)"
    else
        say "错误: 没有任何 HTTP 客户端, 请先执行: opkg update && opkg install curl"
        exit 1
    fi
fi

#---------------------------------------------------------------- 拷文件
say "==> 安装主脚本 $BIN"
cp "$SRC/nnnu-auth.sh" "$BIN"
chmod 755 "$BIN"

if [ -f "$CONF" ]; then
    say "==> $CONF 已存在, 保留 (不覆盖你的密码)"
else
    say "==> 生成 $CONF"
    cp "$SRC/nnnu-auth.conf" "$CONF"
fi
chmod 600 "$CONF"

say "==> 安装 hotplug (WAN 上线即认证)"
mkdir -p /etc/hotplug.d/iface
cp "$SRC/nnnu-auth.hotplug" /etc/hotplug.d/iface/99-nnnu-auth
chmod 755 /etc/hotplug.d/iface/99-nnnu-auth

say "==> 安装 procd 服务脚本 /etc/init.d/nnnu-auth"
cp "$SRC/nnnu-auth.init" /etc/init.d/nnnu-auth
chmod 755 /etc/init.d/nnnu-auth

#---------------------------------------------------------------- 运行方式
case "$MODE" in
    service)
        say "==> 启用常驻守护"
        sed -i '/nnnu-auth/d' /etc/crontabs/root 2>/dev/null || true
        /etc/init.d/cron restart 2>/dev/null || true
        /etc/init.d/nnnu-auth enable
        rm -rf /tmp/nnnu-auth.lock
        /etc/init.d/nnnu-auth restart
        ;;
    cron|test|*)
        say "==> 配置 cron 每分钟检查"
        touch /etc/crontabs/root
        sed -i '/nnnu-auth/d' /etc/crontabs/root
        echo '* * * * * /usr/bin/nnnu-auth.sh ensure -q' >> /etc/crontabs/root
        /etc/init.d/cron enable 2>/dev/null || true
        /etc/init.d/cron restart 2>/dev/null || true
        ;;
esac

#---------------------------------------------------------------- 检查密码
if grep -q "这里填你的密码" "$CONF" 2>/dev/null || grep -q "填你的学号" "$CONF" 2>/dev/null; then
    say ""
    say "!!! 还没填账号密码, 请编辑 $CONF 后执行: nnnu-auth.sh login"
    say "    vi $CONF      # 改 USERNAME / PASSWORD"
fi

say ""
say "安装完成。常用命令:"
say "  /usr/bin/nnnu-auth.sh doctor        # 诊断(接口/IP/MAC/302参数/登录页)"
say "  /usr/bin/nnnu-auth.sh login         # 立即认证一次"
say "  /usr/bin/nnnu-auth.sh status        # 看在线状态"
say "  tail -f /var/log/nnnu-auth.log      # 看日志"

if [ "$MODE" = "test" ]; then
    say ""
    say "==> 诊断输出"
    "$BIN" doctor
fi
