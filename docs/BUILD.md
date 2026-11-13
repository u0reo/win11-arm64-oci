# ビルドの流れ

`scripts/build-image.sh` は次の順に実行します。
途中で失敗した場合は、その段階のスクリプトを単体で再実行できます。

## 段階一覧

| # | 処理 | 実体 |
|---|---|---|
| 1 | 設定の解決と XML 生成 | `scripts/render.py` |
| 2 | virtio-win ARM64 ドライバ展開 | `scripts/stage-drivers.sh` |
| 3 | OEMDRV ISO 作成 | `pipeline/make_oemdrv.sh` |
| 4 | Ubuntu の netplan / SSH 設定を退避（`KEEP_UBUNTU=1`） | `pipeline/save_ubuntu_config.sh` |
| 5 | ディスク作成 + `install.wim` 適用 | `pipeline/host_apply.sh` |
| 6 | 復旧用 Ubuntu を構築（`KEEP_UBUNTU=1`） | `pipeline/make_recovery_ubuntu.sh` |
| 7 | `boot.wim` に自動実行コマンドを埋込 | `pipeline/make_manual_bootwim.sh` |
| 8 | 起動用 FAT イメージ作成 | `pipeline/make_bootfat.sh` |
| 9 | WinPE でドライバ + `bcdboot`（自動） | QEMU phase A |
| 10 | Windows 初回起動 + 準備完了待ち | QEMU phase B |
| 11 | ACPI シャットダウン | `scripts/qmp-powerdown.py` |
| 12 | ESP パッチ + 検査 | `pipeline/finish_disk.sh` / `pipeline/inspect_image.sh` |
| 13 | 圧縮（`PACKAGE=1`） | `scripts/package-image.sh` |

`DISK` を省略すると `build/win11-arm64.qcow2` に書き、`PACKAGE=1` のときだけ
`scripts/package-image.sh` で圧縮します。`DISK=/dev/sdX` を渡すとブロック
デバイスへ直接書き込み、圧縮は行いません。

`KEEP_UBUNTU=1`（`direct-run.sh --keep-ubuntu`）では、ESP を残したまま
p2 を `RECOVERY_SIZE`（既定 4 GiB）の Ubuntu Server minimal として作り直し、
p3 を Windows にします。設定は [DUALBOOT.md](DUALBOOT.md)。

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
export ISO=/srv/iso/Win11_ARM64_26H2.iso
export BUILD_DIR=$PWD/build

python3 scripts/render.py --out "$BUILD_DIR/media"
scripts/stage-drivers.sh
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
シリアルログは `build/logs/*-serial.log` です。

ブロックデバイスへ書く場合は、上の `host_apply.sh` / `run-qemu.sh` の
qcow2 パスを `/dev/sdb` に置き換え、最後に
`pipeline/finish_disk.sh /dev/sdb` と `pipeline/inspect_image.sh /dev/sdb`
を実行します。`DISK=/dev/sdb` を各スクリプトに渡しても同じです。

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| WinPE が起動しない | `build/logs/finish-serial.log`、bootfat の作成ログ |
| `INACCESSIBLE_BOOT_DEVICE` | vioscsi が offline image に入っているか |
| OOBE が始まらない | `Windows/Panther/unattend.xml` の配置 |
| RDP/WinRM が上がらない | `C:\OEM\boot.log`、`specialize.log` |
| ゲストが落ちない | QMP ソケット、`build/logs/install-qemu.log` |
| ディスク不足 | `scripts/preflight.sh` の空き容量表示 |

## 既知の制約

- x86 ホストでは ARM64 ゲストに KVM が使えず、TCG になります。
  ビルドには数時間かかることがあります。
- `inspect_image.sh` の一部チェックは `python3-hivex` /
  `python3-pefile` が必要です。無い場合は警告してスキップします。
