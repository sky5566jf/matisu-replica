#!/bin/bash
# MatisuAuto 引擎 deb 手工组装（绕过 theos package 的二次签名丢 entitlements 问题）
# 用法: package_deb.sh <rootful|rootless> <ARCHS> <输出文件名>
set -e
MODE=$1; ARCHS=$2; OUT=$3

make clean
make FINALPACKAGE=1 ARCHS="$ARCHS"

BIN=.theos/obj/MatisuAuto.app/MatisuAuto
[ -f "$BIN" ] || { echo "!! binary missing: $BIN"; exit 1; }

# 签名必须在包组装之后不再被任何步骤覆盖 —— 手工 dpkg-deb 保证这一点
LDID="$THEOS/bin/ldid"; [ -x "$LDID" ] || LDID=$(command -v ldid || true)
if [ -n "$LDID" ]; then
  "$LDID" -SEntitlements.plist "$BIN"
  echo "ldid signed with Entitlements.plist"
else
  echo "!! ldid not found"; exit 1
fi

PREFIX=""
ARCH_NAME=iphoneos-arm
if [ "$MODE" = "rootless" ]; then
  PREFIX=/var/jb
  ARCH_NAME=iphoneos-arm64
fi

STAGE=/tmp/debstage
rm -rf "$STAGE"
mkdir -p "$STAGE$PREFIX/Applications/MatisuAuto.app" "$STAGE/DEBIAN"
cp "$BIN" Info.plist Entitlements.plist "$STAGE$PREFIX/Applications/MatisuAuto.app/"
cp layout/DEBIAN/postinst layout/DEBIAN/prerm "$STAGE/DEBIAN/"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: com.matisu.auto
Name: MatisuAuto
Version: 0.1.0
Architecture: $ARCH_NAME
Description: MatisuAuto iOS automation engine (daemon mode, control server :18182)
Maintainer: Matisu
Section: Utilities
EOF

mkdir -p ../dist
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -b "$STAGE" "../dist/$OUT"
elif [ -x "$THEOS/bin/dm.pl" ]; then
  "$THEOS/bin/dm.pl" -b -Zgzip "$STAGE" "../dist/$OUT"
else
  echo "!! no dpkg-deb or dm.pl"; exit 1
fi
echo "built ../dist/$OUT"
