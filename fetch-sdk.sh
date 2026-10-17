#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# pin した OpenIRD の SDK を取得して展開し、その場所を標準出力に出す。
#
#   SDK="$(bash fetch-sdk.sh)" && . "$SDK/sdk.env"
#
# SDK は OpenIRD のリリースが Arch id ごとに配る（OpenIRD の docs/addon.md §6.1）。使う側は
# URL と sha256 を pin する決まりで、その pin がこのファイル。SDK の版は出自の記録で、互換の
# 条件ではない（アドオンが動くかは Arch id で決まる）。
#
# 置き場所は ${XDG_CACHE_HOME:-~/.cache}/openird-sdk/（tarball と、それを展開したもの）。
# Linux のファイルシステムであること（/mnt/c には展開できない）。消してよい＝次に呼んだ
# ときに取り直して sha256 を照合する。
#
# 前提: x86_64 の Linux/WSL、curl・xz。匿名で取れないときは gh（読み取り権限のある
#       ログイン）で取る。どちらも使えなければ、別の手段で取った tarball を置き場所に
#       置いておけばよい（sha256 を照合して使う）。
set -eu

# SDK の pin。上げるときは、リリースの SHA256SUMS の値と一緒に 2 つとも変える。
SDK_URL="https://github.com/daig0rian/openird/releases/download/v26.10-rc9/openird-sdk-26.10-rc9-emma3sep-mipseb-musl.Linux-x86_64.tar.xz"
SDK_SHA256="615c8a633d0dd167b38c7b86cf21387e59f3fac89ab4df3737fec9dc62a8eefa"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/openird-sdk"
FILE="${SDK_URL##*/}"
# tarball の中のディレクトリ名 = ファイル名から .<host>.tar.xz を取ったもの
DIR="${FILE%.tar.xz}"
DIR="${DIR%.*}"
T="$CACHE/$FILE"
D="$CACHE/$DIR"

# 標準出力は SDK の場所だけ。経過はすべて標準エラーへ
say() { echo "$*" >&2; }
pinned() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$SDK_SHA256" ]; }

if [ ! -d "$D" ]; then
	mkdir -p "$CACHE"
	if ! pinned "$T"; then
		say "→ $SDK_URL"
		rm -f "$T.part"
		if ! curl -fsSL -o "$T.part" "$SDK_URL" 2>/dev/null; then
			# https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
			rest="${SDK_URL#https://github.com/}"
			tag="${rest#*/releases/download/}"
			rm -f "$T.part"
			{ command -v gh >/dev/null &&
				gh release download "${tag%%/*}" -R "${rest%%/releases/*}" -p "$FILE" -O "$T.part" >&2; } || {
				rm -f "$T.part"
				say "✗ SDK を取得できない: $SDK_URL"
				say "  リポジトリが private の間は、読み取り権限のある gh が要る（gh auth login）。"
				say "  別の手段で取ったなら、次の場所に置いてもう一度: $T"
				exit 1
			}
		fi
		mv "$T.part" "$T"
		pinned "$T" || { say "✗ sha256 が pin と違う: $T"; exit 1; }
	fi
	# 同じファイルシステムの上で展開してから置く（途中で止まっても半端な SDK を残さない）
	X="$(mktemp -d "$CACHE/.extract.XXXXXX")"
	trap 'rm -rf "$X"' EXIT
	say "→ 展開: $D"
	tar xJf "$T" -C "$X"
	mv "$X/$DIR" "$D"
fi
# 展開した場所に合わせる（Buildroot の仕組み。済んでいれば何もしない）
( cd "$D" && ./relocate-sdk.sh ) >/dev/null
echo "$D"
