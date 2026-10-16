#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# recpt1（stz2012 版）を OpenIRD の SDK でビルドし、http モードで常駐するアドオン
# （.ird）にする。形式と決まりは OpenIRD の docs/addon.md。
#
#   bash recpt1/build.sh [<outdir>]
#       <outdir> の既定: <このリポジトリ>/repo
#
# 出力: <outdir>/recpt1_<version>_<arch>.ird と、<outdir> の索引 Packages。
#       <outdir> を HTTPS で配れば、それがアドオンリポジトリになる。
#
# SDK は、このリポジトリが pin したもの（../fetch-sdk.sh）を取ってきて使う。別の SDK で
# 作るときは、先にその sdk.env を読んでおく（. <SDK>/sdk.env）。
#
# 前提:
#   - x86_64 の Linux/WSL。
#   - git でネットに出られること（recpt1 を pin した commit で取得する）。
#
# recpt1 は上流のソースに patches/ の修正だけを当てて使う（どれも上流の不具合の修正）。
# libarib25 は使わない（スクランブル解除は扱わない）＝ config.h で HAVE_LIBARIB25 を
# 未定義にし、b25 を含まない 5 本だけを静的リンクする（アドオンは自己完結が前提）。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../repo}"

# recpt1（stz2012）の pin。版を上げるときはここだけ変える。
RECPT1_REPO="https://github.com/stz2012/recpt1"
RECPT1_COMMIT="77c7bce2527e1df45cc8667ede753d09de7b3e6c"   # 2025-07-29
RECPT1_VERSION="1.2.0"                                      # configure.ac の AC_INIT
# アドオン側（addon/・patches/ の中身やこのスクリプト）だけを変えたときに上げる。版が同じだと、
# 機器の ird-addon は「導入済み」とみなして入れ替えない。
ADDON_REV=2
VERSION="$RECPT1_VERSION-${RECPT1_COMMIT:0:7}-$ADDON_REV"

# SDK（CC・CROSS_COMPILE・IRD_ARCH と、PATH の ird-mkaddon）: sdk.env を読んであれば
# その SDK、無ければ pin した SDK
if [ -z "${OPENIRD_SDK:-}" ]; then
	OPENIRD_SDK="$(bash "$HERE/../fetch-sdk.sh")"
fi
. "$OPENIRD_SDK/sdk.env"
echo "SDK: $OPENIRD_SDK ($IRD_ARCH)"

# 作業はすべて一時ディレクトリ（Linux のファイルシステム）で行う。このリポジトリが
# /mnt/c（DrvFs）にあっても、実行ビットを正しく .ird に写せる。
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# --- recpt1 を pin した commit で取得 ------------------------------------------
SRC="$W/src"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$RECPT1_REPO" "$RECPT1_COMMIT" || {
	echo "✗ pin した commit を取得できない: $RECPT1_COMMIT"; exit 1; }
git -C "$SRC" checkout -q FETCH_HEAD
echo "recpt1 @ $(git -C "$SRC" log -1 --format='%h %ci')"
for p in "$HERE"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "patch: ${p##*/}"
	git -C "$SRC" apply "$p"
done

R="$SRC/recpt1"
# recpt1 の ABI（driver/pt1_ioctl.h）が OpenIRD の chardev（px4_drv 互換・magic 0x8D）と
# 同じことを確かめる（pin を上げたときに、ずれたら気付けるように）
grep -E 'SET_CHANNEL|START_REC|STOP_REC|GET_SIGNAL_STRENGTH' "$SRC/driver/pt1_ioctl.h" |
	grep -c '0x8D' | grep -qx 4 || { echo "✗ pt1_ioctl.h の ioctl が想定（magic 0x8D）と違う"; exit 1; }

# configure を回さずに済むよう、autoconf が作る 2 つだけ手で用意する
#   version.h : const char *version（recpt1 --version が出す）
#   config.h  : HAVE_LIBARIB25 を未定義（b25 を外す）
echo "const char *version = \"$RECPT1_VERSION (stz2012 ${RECPT1_COMMIT:0:12} + addons-for-oird patches, without libarib25)\";" > "$R/version.h"
printf '/* cross build without libarib25 */\n#undef HAVE_LIBARIB25\n' > "$R/config.h"

# --- b25 を含まない 5 本を静的リンク（recpt1 の Makefile.in の OBJS と同じ）------
echo "== compile ($("$CC" -dumpmachine), static) =="
( cd "$R" && "$CC" -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -I../driver -static -s \
	-o "$W/recpt1" recpt1.c recpt1core.c decoder.c mkpath.c tssplitter_lite.c \
	-lpthread -lm )
"${CROSS_COMPILE}readelf" -l "$W/recpt1" | grep -q 'interpreter' && {
	echo "✗ 動的リンクになっている（アドオンは自己完結にする）"; exit 1; }

# --- staging を組む（docs/addon.md §2）-----------------------------------------
# モードは install で明示する（checkout 先のファイルシステムに左右されない）
INIT="$HERE/addon/root/etc/init.d/S80recpt1"
grep -q $'\r' "$INIT" && { echo "✗ $INIT: 改行が CRLF（機器の sh が読めない）"; exit 1; }
ST="$W/staging"
mkdir -p "$ST/root/usr/bin" "$ST/root/etc/init.d"
install -m 0755 "$W/recpt1" "$ST/root/usr/bin/recpt1"
install -m 0755 "$INIT" "$ST/root/etc/init.d/S80recpt1"
install -m 0755 "$HERE/addon/postinstall" "$HERE/addon/preremove" "$ST/"
# Arch は書かない＝ ird-mkaddon が SDK の IRD_ARCH を入れる（同じ手順で他の機種向けも作れる）
cat > "$ST/manifest" <<EOF
Package: recpt1
Version: $VERSION
Description: recpt1 (stz2012), run as an HTTP TS server on port 12345
EOF

# --- .ird と索引 ---------------------------------------------------------------
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# 1 つのリポジトリに置けるのは Package と Arch の組ごとに 1 版だけ＝古い版をどける
rm -f "$OUT"/recpt1_*_"$IRD_ARCH".ird
ird-mkaddon build "$ST" -o "$OUT"
ird-mkaddon index "$OUT"
