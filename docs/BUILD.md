# ビルドの流れ

> このページは追加情報です。実際の手順は README の
> [ステージ4](../README.md#ステージ4-ビルド) を参照してください。

入口は `scripts/build.sh`（引数チェック・確認・安全検査）で、実際の
13 段階は `internal/build-image.sh` が回します。途中で失敗した場合は、
その段階のスクリプトを単体で再実行できます。

## 段階一覧

| # | 処理 | 実体 |
|---|---|---|
| 1 | 設定の解決と XML 生成 | `internal/render.py` |
| 2 | virtio-win ARM64 ドライバ展開 | `internal/stage-drivers.sh` |
| 3 | OEMDRV ISO 作成 | `pipeline/make_oemdrv.sh` |
| 4 | Ubuntu の netplan / SSH 設定を退避（`KEEP_UBUNTU=1`） | `pipeline/save_ubuntu_config.sh` |
| 5 | ディスク作成 + `install.wim` 適用 | `pipeline/host_apply.sh` |
| 6 | 復旧用 Ubuntu を構築（`KEEP_UBUNTU=1`） | `pipeline/make_recovery_ubuntu.sh` |
| 7 | `boot.wim` に自動実行コマンドを埋込 | `pipeline/make_manual_bootwim.sh` |
| 8 | 起動用 FAT イメージ作成 | `pipeline/make_bootfat.sh` |
| 9 | WinPE でドライバ + `bcdboot`（自動） | QEMU phase A |
| 10 | Windows 初回起動 + 準備完了待ち | QEMU phase B |
| 11 | ACPI シャットダウン | `internal/qmp-powerdown.py` |
| 12 | ESP パッチ + 検査 | `pipeline/finish_disk.sh` / `pipeline/inspect_image.sh` |
| 13 | 圧縮（`PACKAGE=1`） | `internal/package-image.sh` |

`DISK` を省略すると `build/win11-arm64.qcow2` に書き、`PACKAGE=1` のときだけ
`internal/package-image.sh` で圧縮します。`DISK=/dev/sdX` を渡すとブロック
デバイスへ直接書き込み、圧縮は行いません。

live (`toram`) で `BUILD_DIR` を省略すると、staging は `/dev/shm/build`
になります。`/dev/shm` は 100%（`SHM_SIZE`）まで再マウントされ、
Windows ISO と virtio-win は `/dev/shm/iso` に置くのが既定です。

`KEEP_UBUNTU=1`（`scripts/build.sh --keep-ubuntu`）では、ESP を残したまま
古い Ubuntu root と BOOT を `RECOVERY_SIZE`（既定 4 GiB）の Ubuntu Server
minimal として作り直し、残りを Windows にします。ESP は GPT の種別から探す
ため、`p1=root, p13=BOOT, p15=ESP` の OCI 標準レイアウトでも
`p1=ESP, p2=root` の古いレイアウトでも動きます。設定は
[DUALBOOT.md](DUALBOOT.md)。

## virtio-win の指定

`--virtio` は ISO と RPM のどちらも受け付けます（拡張子で判定）。

| 入力 | サイズ | 読み方 |
|---|---|---|
| `virtio-win.iso` | 837 MiB | `mount -o loop` |
| `virtio-win-*.noarch.rpm` | 283 MiB | `rpm2cpio \| cpio` で `by-driver` だけ展開 |
| `--drivers DIR` | 数 MB | 展開済み（`build/drivers/` を保存したもの） |

RPM も `drivers/by-driver/<driver>/<os>/ARM64` を持つので、ISO と同じ探索で
vioscsi / netkvm / viogpudo を取り出せます。`rpm2cpio` と `cpio` は
`scripts/setup.sh` が入れます。無い場合は `bsdtar` にフォールバックします。

## 「WinPE の仕上げ」とは

`wimlib-imagex apply` は NTFS にファイルを展開するだけで、
次の 2 つは行いません。

1. オフラインイメージへの virtio ドライバ追加（`dism /add-driver`）
2. ESP へのブートファイル作成（`bcdboot`）

これを実行するのが WinPE での「仕上げ」です。
以前は VNC で WinPE に入り、`manual_finish.cmd` を手で叩いていました。

現在は自動化しています。

- `make_manual_bootwim.sh` が `boot.wim` の
  `HKLM\SYSTEM\Setup\CmdLine` を
  `cmd.exe /c manual_start.finish.cmd` に書き換える
- `manual_start.finish.cmd` が既存の Windows を見つけ、
  `manual_finish.cmd` を呼ぶ
- `manual_finish.cmd` が DISM + bcdboot を実行し、
  **`wpeutil shutdown`** で VM を落とす

そのため VNC 操作は不要です。

### なぜ 2 回 QEMU を起動するのか

WinPE の bootfat を付けたまま再起動すると、また WinPE が起動して
ループします。そこで:

- **phase A**: bootfat + OEMDRV + disk → WinPE が仕上げてシャットダウン
- **phase B**: disk のみ → Windows が初回起動

と分けています。`manual_finish.cmd` が `reboot` ではなく `shutdown`
なのはこのためです。

## 準備完了の判定

phase B では、QEMU の hostfwd (`127.0.0.1:15985` → guest 5985) に対して
HTTP を投げ、WinRM が応答したら準備完了とみなします。

QEMU の hostfwd は起動直後から TCP accept するため、
TCP connect だけでは判定できません。HTTP 応答コードを見ます。

## シャットダウン

`system_powerdown` (ACPI) を QMP で送ります。
**強制リセットは使いません。** 以前の作業で `system_reset` が
SOFTWARE ハイブを壊したためです。

シャットダウンが完了しない場合は、スクリプトはエラーで止まります。
手動で落としてから、以降の段階を再実行してください。

## 手動フォールバック

自動化がうまくいかないときは、段階ごとに実行できます。

```bash
# live (toram) default; stage 2-A can use a data volume such as /srv/iso
export ISO=/dev/shm/iso/Win11_ARM64_26H2.iso
export VIRTIO_ISO=/dev/shm/iso/virtio-win.iso  # or VIRTIO_RPM=.../virtio-win-0.1.302-1.noarch.rpm
export BUILD_DIR=/dev/shm/build                 # live (toram)
# export BUILD_DIR=$PWD/build                   # stage 2-A

python3 internal/render.py --out "$BUILD_DIR/media"
internal/stage-drivers.sh
pipeline/make_oemdrv.sh "$ISO" 1
pipeline/host_apply.sh "$ISO" "$BUILD_DIR/win11-arm64.qcow2" 1

START_CMD=pipeline/manual_start.finish.cmd \
  pipeline/make_manual_bootwim.sh "$ISO" "$BUILD_DIR/boot-manual.wim"
BOOTWIM="$BUILD_DIR/boot-manual.wim" pipeline/make_bootfat.sh "$ISO"

NAME=finish WITH_ISO=0 \
  BOOTFAT="$BUILD_DIR/bootfat.img" OEMDRV="$BUILD_DIR/oemdrv.iso" \
  NVRAM="$BUILD_DIR/AAVMF_VARS.finish.fd" \
  pipeline/run-qemu.sh

NAME=install WITH_ISO=0 BOOTFAT="" OEMDRV="" \
  NVRAM="$BUILD_DIR/AAVMF_VARS.install.fd" \
  pipeline/run-qemu.sh
```

VNC は `127.0.0.1:1` で見られます（`VNC_DISPLAY`）。
シリアルログは `build/logs/*-serial.log`（live の既定では
`/dev/shm/build/logs/*-serial.log`）です。

ブロックデバイスへ書く場合は、上の `host_apply.sh` / `run-qemu.sh` の
qcow2 パスを `/dev/sdb` に置き換え、最後に
`pipeline/finish_disk.sh /dev/sdb` と `pipeline/inspect_image.sh /dev/sdb`
を実行します。`DISK=/dev/sdb` を各スクリプトに渡しても同じです。

## シリアル (SAC) とブートメニュー

Windows の初回起動時（specialize パス）に `oem/specialize.ps1` が
BCD を書き換えます。

| 設定 | 内容 | 指定 |
|---|---|---|
| EMS/SAC | COM1 115200 で `SAC>` を出す。常に有効 | なし（常時） |
| ブートメニュー | `displaybootmenu` / `timeout` / `bootems` | `--boot-menu 秒数` |

`--boot-menu` の既定は 1 秒です。表示中に何かキーを押すとカウントダウンが
止まるので、既定のままでもメニューを操作できます。0 はメニューを明示的に
消します（`displaybootmenu no` / `bootems no`）。Ubuntu のエントリを隠さない
よう、Ubuntu を残す構成では 0 を指定できません。`BOOT_MENU_TIMEOUT` 環境
変数でも渡せます（`internal/build-image.sh` を直接使う場合）。

SAC の使い方と制約は [OCI.md](OCI.md#シリアルコンソール-sac) を参照して
ください。

## 言語

`autounattend.xml` は言語を指定しません（`<Language>` / `<InputLocale>` /
`<SystemLocale>` / `<UILanguage>` / `<UserLocale>` はありません）。インストール
後の表示言語は、ISO の `sources/install.wim`（または `install.esd`）に含まれる
イメージの既定言語に従います。`wimlib-imagex apply` は WIM をそのまま展開し、
Setup の言語選択画面を通らないため、ビルド中に言語を選ぶ機会はありません。

使用する ISO の言語は次のように確認できます。

```bash
sudo mount -o loop,ro /srv/iso/Win11_ARM64_26H2.iso /mnt
cat /mnt/sources/lang.ini
WIM=$(ls /mnt/sources/install.wim /mnt/sources/install.esd 2>/dev/null | head -1)
wimlib-imagex info "$WIM" | grep -E 'Index|Name|Languages|Default'
sudo umount /mnt
```

このリポジトリで検証した ISO（`tiny11_arm64_26h2.iso`）の例:

```text
[Available UI Languages]
ja-jp = 3

[Fallback Languages]
ja-jp = en-us
```

```text
Index:                  1
Name:                   Windows 11 Pro
Languages:              ja-JP
Default Language:       ja-JP
```

- 日本語 ISO → インストール後も ja-JP
- 英語 ISO → en-US
- タイムゾーンは言語とは別で、`TIMEZONE` 環境変数（既定
  `Tokyo Standard Time`）で決まります
- 別の表示言語にしたい場合は、その言語の ISO を使ってください。言語パックの
  追加はこのビルドの範囲外です

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| WinPE が起動しない | `build/logs/finish-serial.log`、bootfat の作成ログ |
| `INACCESSIBLE_BOOT_DEVICE` | vioscsi が offline image に入っているか |
| OOBE が始まらない | `Windows/Panther/unattend.xml` の配置 |
| RDP/WinRM が上がらない | `C:\OEM\boot.log`、`specialize.log` |
| ゲストが落ちない | QMP ソケット、`build/logs/install-qemu.log` |
| ディスク不足 | `internal/preflight.sh` の空き容量表示。live では staging が `/dev/shm/build` にあり、`/dev/shm` は 100% に再マウント済みか確認する |

## 既知の制約

- x86 ホストでは ARM64 ゲストに KVM が使えず、TCG になります。
  ビルドには数時間かかることがあります。
- `inspect_image.sh` の一部チェックは `python3-hivex` /
  `python3-pefile` が必要です。無い場合は警告してスキップします。
