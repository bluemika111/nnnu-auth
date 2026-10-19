#!/bin/sh
#===============================================================================
#  tools/build-pkgs.sh — 构建两个 .ipk (纯 Python, 不需要 OpenWrt SDK)
#    dist/nnnu-auth.sh 是唯一权威副本, 这里把它拷进程序包再打包
#  产物: dist/nnnu-auth_<ver>_all.ipk 与 dist/luci-app-nnnu-auth_<ver>_all.ipk
#===============================================================================
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PY=${PYTHON:-python}
command -v "$PY" >/dev/null 2>&1 || PY=python3

echo "== 1/4 同步主脚本到程序包 =="
mkdir -p pkg/nnnu-auth/data/usr/bin pkg/nnnu-auth/data/usr/share/nnnu-auth
mkdir -p pkg/nnnu-auth/data/etc/init.d pkg/nnnu-auth/data/etc/config
mkdir -p pkg/nnnu-auth/data/etc/hotplug.d/iface pkg/nnnu-auth/data/etc/uci-defaults
cp dist/nnnu-auth.sh pkg/nnnu-auth/data/usr/bin/nnnu-auth.sh
chmod 755 pkg/nnnu-auth/data/usr/bin/nnnu-auth.sh
chmod 755 pkg/nnnu-auth/data/usr/share/nnnu-auth/*.sh
chmod 755 pkg/nnnu-auth/data/etc/init.d/nnnu-auth
chmod 755 pkg/nnnu-auth/data/etc/hotplug.d/iface/99-nnnu-auth
chmod 755 pkg/nnnu-auth/data/etc/uci-defaults/95-nnnu-auth
chmod 755 pkg/luci-app-nnnu-auth/data/etc/uci-defaults/luci-nnnu-auth
chmod 755 pkg/nnnu-auth/control/postinst pkg/nnnu-auth/control/prerm
chmod 755 pkg/luci-app-nnnu-auth/control/postinst
echo "   完成"

echo "== 2/4 检查 Lua 语法 =="
"$PY" tools/check_lua.py pkg || exit 1

echo "== 3/4 打包 =="
"$PY" tools/mkipk.py pkg/nnnu-auth -o dist
"$PY" tools/mkipk.py pkg/luci-app-nnnu-auth -o dist

echo "== 4/4 校验产物 =="
for f in dist/nnnu-auth_*_all.ipk dist/luci-app-nnnu-auth_*_all.ipk; do
    "$PY" tools/mkipk.py pkg/nnnu-auth --verify "$f" >/dev/null && echo "   OK $f"
done
echo
echo "构建完成, 产物在 dist/"
ls -l dist/*.ipk
