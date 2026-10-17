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
# 作るときは、先にその sdk.env を読んでおく（. <SDK>/sdk.env）。C++（g++・libstdc++.a）が
# 要る（libarib25 の multi2 が C++）。OpenIRD の SDK は v26.10-rc9 以降に入っている。
#
# 前提:
#   - x86_64 の Linux/WSL。
#   - git でネットに出られること（recpt1 と libarib25 を pin した版で取得する）。
#
# recpt1 は上流のソースに patches/ の修正だけを当てて使う（どれも上流の不具合の修正）。
# libarib25 を静的リンクして B-CAS に対応する。これは、所有者が自分の機器で、自分が正規に
# 発行された B-CAS カードを使い、受信を許可された放送を受けるためのもの。libarib25 はカードに
# 復号させるだけで、鍵の抽出・配布はしない（起動スクリプトの既定は b25 なし。使うときだけ有効）。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../repo}"

# recpt1（stz2012）の pin。版を上げるときはここだけ変える。
RECPT1_REPO="https://github.com/stz2012/recpt1"
RECPT1_COMMIT="77c7bce2527e1df45cc8667ede753d09de7b3e6c"   # 2025-07-29
RECPT1_VERSION="1.2.0"                                      # configure.ac の AC_INIT
# libarib25（stz2012）の pin。タグで取る。
ARIB25_REPO="https://github.com/stz2012/libarib25"
ARIB25_TAG="v0.2.5-20220902"                                # 93ff3af
# アドオン側（addon/・patches/ の中身やこのスクリプト）だけを変えたときに上げる。版が同じだと、
# 機器の ird-addon は「導入済み」とみなして入れ替えない。
ADDON_REV=5
VERSION="$RECPT1_VERSION-${RECPT1_COMMIT:0:7}-$ADDON_REV"

# SDK（CC・CXX・CROSS_COMPILE・IRD_ARCH・SYSROOT と、PATH の ird-mkaddon）: sdk.env を
# 読んであればその SDK、無ければ pin した SDK
if [ -z "${OPENIRD_SDK:-}" ]; then
	OPENIRD_SDK="$(bash "$HERE/../fetch-sdk.sh")"
fi
. "$OPENIRD_SDK/sdk.env"
echo "SDK: $OPENIRD_SDK ($IRD_ARCH)"
command -v "${CXX:-}" >/dev/null 2>&1 || {
	echo "✗ この SDK に C++（\$CXX）が無い。libarib25 には C++ が要る（OpenIRD v26.10-rc9 以降の SDK）"; exit 1; }

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

# --- libarib25 を pin したタグで取得し、静的ライブラリにする --------------------
A="$W/arib25"
git init -q "$A"
git -C "$A" fetch -q --depth 1 "$ARIB25_REPO" "refs/tags/$ARIB25_TAG" || {
	echo "✗ libarib25 の pin を取得できない: $ARIB25_TAG"; exit 1; }
git -C "$A" checkout -q FETCH_HEAD
echo "libarib25 @ $(git -C "$A" log -1 --format='%h %ci')"

# recpt1 は <arib25/...> で include する。arib25_api.h はふだん CMake の
# generate_export_header が作る。静的ライブラリで使うマクロは ARIB25_API_EXPORT だけで、空でよい。
INC="$W/include"
mkdir -p "$INC/arib25"
cp "$A/src"/*.h "$INC/arib25/"
printf '#ifndef ARIB25_API_H\n#define ARIB25_API_H\n#define ARIB25_API_EXPORT\n#endif\n' > "$INC/arib25/arib25_api.h"

# PC/SC は SDK の sysroot から（libarib25 の b_cas_card.c が pcscd と話す）
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
PCSC_CFLAGS="$(pkg-config --cflags libpcsclite)"
PCSC_LIBS="$(pkg-config --libs --static libpcsclite)"

echo "== libarib25 ($("$CC" -dumpmachine), static) =="
AO="$W/arib25-obj"; mkdir -p "$AO"
# ライブラリに要る 4 本だけ。td.c（b25 コマンド本体）・getopt.c（Windows 用）・
# version.c（共有ライブラリ用に .interp 文字列を置く）は入れない。
for f in arib_std_b25 b_cas_card ts_section_parser; do
	"$CC" -c -O2 -I"$INC/arib25" $PCSC_CFLAGS -o "$AO/$f.o" "$A/src/$f.c"
done
# multi2 は C++（上流は C++98）
"$CXX" -c -O2 -std=gnu++98 -I"$INC/arib25" $PCSC_CFLAGS -o "$AO/multi2.o" "$A/src/multi2.cc"
"${CROSS_COMPILE}ar" rcs "$W/libarib25.a" "$AO"/*.o

# --- recpt1 を libarib25 付きでビルド ------------------------------------------
# configure を回さずに済むよう、autoconf が作る 2 つだけ手で用意する
#   version.h : const char *version（recpt1 --version が出す）
#   config.h  : HAVE_LIBARIB25 を定義（b25 を入れる）
echo "const char *version = \"$RECPT1_VERSION (stz2012 ${RECPT1_COMMIT:0:12} + addons-for-oird patches, with libarib25 ${ARIB25_TAG})\";" > "$R/version.h"
printf '/* cross build with libarib25 (B-CAS) */\n#define HAVE_LIBARIB25 1\n' > "$R/config.h"

echo "== compile recpt1 ($("$CC" -dumpmachine), static, with libarib25) =="
RO="$W/recpt1-obj"; mkdir -p "$RO"
for f in recpt1 recpt1core decoder mkpath tssplitter_lite; do
	"$CC" -c -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -I"$SRC/driver" -I"$INC" \
		-o "$RO/$f.o" "$R/$f.c"
done
# libarib25 は C++ を含むので、g++ でリンクして libstdc++ を（静的に）引き込む
"$CXX" -static -s -o "$W/recpt1" "$RO"/*.o "$W/libarib25.a" $PCSC_LIBS -lpthread -lm
"${CROSS_COMPILE}readelf" -l "$W/recpt1" | grep -q 'interpreter' && {
	echo "✗ 動的リンクになっている（アドオンは自己完結にする）"; exit 1; }
"${CROSS_COMPILE}readelf" -h "$W/recpt1" | grep -q 'big endian' || {
	echo "✗ big-endian でない"; exit 1; }

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
Description: recpt1 (stz2012) with libarib25, run as an HTTP TS server on port 12345
EOF

# --- .ird と索引 ---------------------------------------------------------------
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# 1 つのリポジトリに置けるのは Package と Arch の組ごとに 1 版だけ＝古い版をどける
rm -f "$OUT"/recpt1_*_"$IRD_ARCH".ird
ird-mkaddon build "$ST" -o "$OUT"
ird-mkaddon index "$OUT"
