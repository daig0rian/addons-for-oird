# addons-for-oird

OpenIRD（`daig0rian/openird`）の**アドオン**を作るリポジトリ。アドオンは、実行中の機器に
後から載せるソフト（`.ird`）で、形式・索引・インストーラ `ird-addon` の決まりは OpenIRD の
`docs/addon.md` にある。

OpenIRD の像は、チューナを chardev（`/dev/irdvideoN`）として見せるところまでで、それを読む
ソフトは入っていない。読む側は、ここからアドオンとして載せる。

| アドオン | 中身 |
|---|---|
| [recpt1](recpt1/) | recpt1（stz2012 版）を http モードで常駐させ、機器を TS サーバにする |

## 構成

```
fetch-sdk.sh                 OpenIRD の SDK の pin（URL と sha256）。取得して展開する
<name>/build.sh              ソースを取得してビルドし、.ird と索引を作る
<name>/addon/                .ird に入れるファイル（起動スクリプト・postinstall・preremove）
<name>/patches/              上流のソースに当てる修正（あれば）
.github/workflows/build.yml  GitHub Actions でのビルドと、下書きのリリース
repo/                        ビルドの出力（*.ird と索引 Packages）。git 管理外
```

`repo/` は、そのまま HTTPS で配ればアドオンリポジトリになる形をしている。GitHub では
リリースがその置き場所になる（下の「リリース」）。

## 作る

前提は x86_64 の Linux か WSL と、`git`・`curl`・`xz`。このリポジトリ自体は `/mnt/c` に
あってよい（作業は一時ディレクトリで行う）。

```
bash recpt1/build.sh        # → repo/recpt1_<version>_<arch>.ird と repo/Packages
```

pin した SDK と pin したソースから作るので、`.ird` は作り直しても同じバイト列になる
（SHA256 が変わらない）。どの機種向けになるかは SDK が決める（Arch id）。

### SDK

SDK は `build.sh` が用意する。OpenIRD はリリースごとに、Arch id 単位の SDK を GitHub Releases に
置いている（OpenIRD の `docs/addon.md` §6.1）。このリポジトリはその URL と sha256 を
[fetch-sdk.sh](fetch-sdk.sh) の先頭に pin していて、初回に取得・照合・展開する。

- **置き場所**は `~/.cache/openird-sdk/`（tarball と展開したもので 260MB ほど）。消してよい。
  次のビルドで取り直して sha256 を照合する。
- **取得**は `curl`（匿名）。取れないときは `gh`（読み取り権限のあるログイン）で取る。どちらも
  使えないときは、別の手段で取った tarball を置き場所に置いておけば、sha256 を照合して使う。
- **SDK を上げる**ときは、`fetch-sdk.sh` の `SDK_URL` と `SDK_SHA256` を、リリースの `SHA256SUMS` に
  合わせて変える。SDK の版は出自の記録で、互換の条件ではない（アドオンが動くかは Arch id で
  決まる）。新しいリリースが出ても、上げる必要は無い。
- **pin していない SDK**（手元で `make sdk` したものなど）で作るときは、先にその環境を読む:
  `. <SDK>/sdk.env`。

## GitHub Actions とリリース

[.github/workflows/build.yml](.github/workflows/build.yml) が、main への push と pull request の
たびに全アドオンをビルドし、`repo/` を成果物（artifact `repo`）に置く。

アドオンリポジトリを公開するときは、版のタグを打って push する（`-rc` を含むタグは
pre-release になる）:

```
git tag -a v26.10.1 -m "addons-for-oird 26.10.1"
git push origin v26.10.1
```

Actions がビルドし、`repo/` の中身（`Packages` と `*.ird`）を**下書きのリリース**に置く。
公開のボタンは人が押す。公開したリリースが、そのままアドオンリポジトリになる。

- 下書きの間は、機器からは取れない（404）。機器での試験は `-rc` のタグを公開して行い、
  確かめてから正式版のタグを打つ。
- 下書きの間に同じ URL を取りに行くと、公開してから 1〜2 分は 404 が返り続けることがある
  （GitHub の手前に残った応答）。待てば取れる。

## 機器に入れる

リリースから名前で入れる。`addons.conf` には次のどちらかを書く。

```
https://github.com/daig0rian/addons-for-oird/releases/latest/download     最新の正式版（pre-release は除く）
https://github.com/daig0rian/addons-for-oird/releases/download/<tag>      その版に固定
```

```
echo https://github.com/daig0rian/addons-for-oird/releases/latest/download >> /etc/openird/addons.conf
ird-addon update
ird-addon install recpt1
```

1 本だけ入れるなら、URL か機器へ運んだファイルを、SHA256 と一緒に渡す。SHA256 は
`build.sh` が表示し、`Packages` にも載る。

```
ird-addon install https://github.com/daig0rian/addons-for-oird/releases/download/<tag>/recpt1_<version>_<arch>.ird <sha256>
ird-addon install /tmp/recpt1_<version>_<arch>.ird <sha256>
```

削除は `ird-addon remove recpt1`。

## ライセンス

このリポジトリのスクリプト類は GPL-2.0-only（[LICENSE](LICENSE)）。`.ird` に入る上流の
ソフトは、それぞれのライセンスに従う（recpt1 は GPL-3.0。[recpt1/README.md](recpt1/README.md)）。
