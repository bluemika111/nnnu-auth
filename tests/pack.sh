#!/bin/sh
# 打包成上传到路由器用的一体包 (扁平结构, install.sh 可直接执行)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
NAME=nnnu-auth-1.2.3
STAGE="/tmp/$NAME.pkg"
rm -rf "$STAGE"; mkdir -p "$STAGE/$NAME"

cp dist/install.sh        "$STAGE/$NAME/"
cp dist/nnnu-auth.sh      "$STAGE/$NAME/"
cp dist/nnnu-auth.conf    "$STAGE/$NAME/"
cp dist/nnnu-auth.init    "$STAGE/$NAME/"
cp dist/nnnu-auth.hotplug "$STAGE/$NAME/"
cp README.md              "$STAGE/$NAME/"

cd "$STAGE"
mkdir -p "$HERE/dist"
tar czf "$HERE/dist/$NAME.tar.gz" "$NAME"
cd "$HERE"
rm -rf "$STAGE"

echo "生成: $HERE/dist/$NAME.tar.gz"
tar tzf "dist/$NAME.tar.gz"
