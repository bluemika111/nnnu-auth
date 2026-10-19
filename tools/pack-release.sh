#!/bin/sh
#===============================================================================
#  tools/pack-release.sh — 打 Release 用的源码包
#
#  说明: 两个 .ipk 是已构建好的二进制, 原样作为 Release 资产上传, 不再重打;
#        这个脚本只把"脚本/源码部分"打成一个 tar.gz, 作为第三个资产。
#
#  产物: dist/nnnu-auth-<ver>-src.tar.gz
#  排除: .git、已构建的 ipk/tar.gz、本机私有的真实抓包页面与敏感清单
#===============================================================================
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VER=${1:-1.2.3}
NAME="nnnu-auth-$VER"
OUT="dist/$NAME-src.tar.gz"

mkdir -p dist
rm -f "$OUT"

tar czf "$OUT" \
    --exclude='.git' \
    --exclude='.git/*' \
    --exclude='dist/*.ipk' \
    --exclude='dist/*.tar.gz' \
    --exclude='tools/known-secrets.txt' \
    --exclude='*.local.html' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='probe' \
    --exclude='out' \
    --transform "s,^\.,$NAME," \
    .

echo "生成: $OUT  ($(wc -c < "$OUT") 字节)"
echo "内容:"
tar tzf "$OUT" | sed 's/^/  /'
