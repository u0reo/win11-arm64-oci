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
| 4 | 実行中の Ubuntu の netplan / authorized_keys を確認（`FRESH_UBUNTU=1`） | `internal/build-image.sh` |
| 5 | ディスク作成 + `install.wim` 適用 | `pipeline/host_apply.sh` |
| 6 | 復旧用 Ubuntu を構築（`FRESH_UBUNTU=1`） | `pipeline/make_recovery_ubuntu.sh` |
| 7 | `boot.wim` に自動実行コマンドを埋込 | `pipeline/make_manual_bootwim.sh` |
| 8 | 起動用 FAT イメージ作成 | `pipeline/make_bootfat.sh` |
| 9 | WinPE でドライバ + `bcdboot`、ESP を shim/GRUB に仕上げ（自動） | QEMU phase A + `pipeline/finish_winpe.sh` |
| 10 | Windows 初回起動 + 準備完了待ち | QEMU phase B |
| 11 | ACPI シャットダウン | `internal/qmp-powerdown.py` |
| 12 | ESP ブートマネージャー検査 | `pipeline/finish_disk.sh` / `pipeline/inspect_image.sh` |
| 13 | 圧縮（`PACKAGE=1`） | `internal/package-image.sh` |

`DISK` を省略すると `build/win11-arm64.qcow2` に書き、`PACKAGE=1` のときだけ
`internal/package-image.sh` で圧縮します。`DISK=/dev/sdX` を渡すとブロック
デバイスへ直接書き込み、圧縮は行いません。

live (`toram`) で `BUILD_DIR` を省略すると、staging は `/dev/shm/build`
になります。`/dev/shm` は 100%（`SHM_SIZE`）まで再マウントされ、
Windows ISO と virtio-win は `/dev/shm/iso` に置くのが既定です。

`FRESH_UBUNTU=1`（`scripts/build.sh --fresh-ubuntu`）は、空のディスクを
丸ごと作り直します。ESP も再利用せず、`p1=ESP (100 MiB)`、
`p2=Ubuntu`（`RECOVERY_SIZE`、既定 4 GiB）、`p3=Windows`（残り）を
新規作成します。ステップ4はターゲットを読まず、実行中の Ubuntu の
`/etc/netplan/*.yaml` と `authorized_keys` を確認するだけです。ステップ6の
`make_recovery_ubuntu.sh` がその2つだけを復旧環境へコピーします。設定は
[DUALBOOT.md](DUALBOOT.md)。

`WINRE_PARTITION=1`（`--winre-partition`）を併用すると、p3 を `WINRE_SIZE`
（既定 1 GiB）だけ短くし、p4 に type `2700` の Windows RE パーティションを
作ります。Windows の specialize が `Winre.wim` を p4 に置きます。OEM の
`winre.ps1` は `OEM\winre-offset.txt` と `ReAgent.xml` を比べて実際の場所を
確認し、必要なら `reagentc` で移します。失敗時は C: の WinRE を有効なまま
残すので、ビルドは継続します。ステップ12の `inspect_image.sh` が p4 の
`Winre.wim` と `ReAgent.xml` の場所を表示します。

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
- `manual_finish.cmd` が DISM + bcdboot を実行し、進捗を
  `C:\manual-finish.log` に書いて **`wpeutil shutdown`** で VM を落とす
- QEMU 停止後、`pipeline/finish_winpe.sh` がログの `MANUAL_FINISH_OK` を
  確認し、ESP を GRUB 先頭ローダーに整える。`\EFI\BOOT\BOOTAA64.EFI` に
  shim、`\EFI\BOOT\grubaa64.efi` に GRUB を置き、`\EFI\ubuntu\grub.cfg` に
  メニューを書き、BCD から Ubuntu bootapp を削除する。Windows のみの構成
  では `\EFI\BOOT\BOOTAA64.EFI` を `bootmgfw.efi` のままにする

そのため VNC 操作は不要です。WinPE の ARM64 PL011 には Windows の
シリアルドライバーが無いため、COM1 ではなくファイルで成否を判定します。

### ESP ブートマネージャーの検証

Ubuntu を残す構成では、`finish_winpe.sh` が `bcdboot` の後で
`\EFI\BOOT\BOOTAA64.EFI` を shim に置き換えます。GRUB が chainload する
`\EFI\Microsoft\Boot\bootmgfw.efi` は **Microsoft の署名済みイメージのまま**
にします。`pipeline/finish_disk.sh` はコピーを読み直し、`AllocatePages` の
サイトが stock（`mov w0, #2`）であることを確認します。`PATCH_BOOTMGFW=1`
を明示した場合だけ、従来の `#2 -> #1` パッチを当てます。

`ConvertPages: failed to find range 102000-102FFF` は OCI ファームウェアの
`DEBUG()` 出力で、`bootmgfw` は `AllocatePages` の戻り値を見ずに続行します。
一方、パッチでイメージを変更すると `boot.stl` / `CIPolicies` の完全性検査と
一致しなくなり、QEMU では bootmgr がメニュー前に終了します（stock 26089 は
同じ BCD でロック画面まで到達）。そのため stock を既定にしています。

stock コピーは、読み取れる場合は **インストール済み Windows の
`\Windows\Boot\EFI\bootmgfw.efi`** から取ります。ESP に古い stock
（例: 26089）が残っていても、`bcdboot` が書いた `bootmgr.efi` /
`boot.stl` / `CIPolicies`（例: 28000）と同じ世代に揃えるためです。
実機 OCI では 26089 の bootmgfw と 28000 の boot chain の混成が
bootmgr のメニュー前に停止しました。`STOCK_BOOTMGFW=<file>` を指定した
場合だけ、そのコピーを優先します。

GRUB の FAT ドライバは開始クラスタ 65536 以上のファイルを開けないため、
書き込み後の開始クラスタも検査します。`bootmgfw.efi` か GRUB メニューが
65536 以上になった場合は、`pipeline/esp_compact.sh` が ESP を作り直し、
GRUB が読むファイルを先頭クラスタに置きます（新しい FAT を一時イメージで
作って検証してから書き戻すので、途中で失敗しても ESP は壊れません）。

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
**ゲストは強制終了しません。** QEMU はそのまま残るので、画面とログを確認して
から次を実行してください。`build/logs/qemu-install.pid` に PID が残っており、
`FROM_STEP=11` はその QEMU に再接続して待機を続けます（新しい QEMU は
起動しません）。

```bash
sudo env FROM_STEP=11 ./scripts/build.sh ... --yes
```

待ち時間は `SHUTDOWN_TIMEOUT`（既定 5400 秒）で変更できます。KVM の無い
TCG では OOBE と初回ログオンだけで 1 時間以上かかることがあり、電源要求を
送った時点でまだ処理中だと、その完了まで電源が切れません。

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

## シリアルとブートメニュー

`--fresh-ubuntu` / `--reuse-ubuntu` 構成では、`finish_winpe.sh` が ESP を
GRUB 先頭ローダーに整えます。`\EFI\BOOT\BOOTAA64.EFI` に shim、
`\EFI\BOOT\grubaa64.efi` に GRUB を置き、`\EFI\ubuntu\grub.cfg` に
メニューを書きます。Windows のみの構成では `\EFI\BOOT\BOOTAA64.EFI` は
従来どおり `bootmgfw.efi` です。

| 設定 | 内容 | 指定 |
|---|---|---|
| 先頭ローダー | shim → GRUB → Windows 11 / Ubuntu (recovery)（Ubuntu を残す場合） | なし |
| ブートメニュー | GRUB または Windows Boot Manager の `timeout` | `--boot-menu 秒数` |
| BCD | Ubuntu bootapp とダングリング参照を削除し、Windows のみにする | なし |
| Windows RE | 専用 p4（`--winre-partition`）または C: 内 | `--winre-partition` / `--winre-size` |

`--boot-menu` の既定は 1 秒です。表示中に何かキーを押すとカウントダウンが
止まるので、既定のままでもメニューを操作できます。`0` は Ubuntu 復旧
エントリを選べなくなるため、Ubuntu を残す構成では指定できません。
`BOOT_MENU_TIMEOUT` 環境変数でも渡せます（`internal/build-image.sh` を
直接使う場合）。

GRUB のメニューは EFI コンソールに出るので、OCI のシリアルコンソールからも
VNC からも操作できます。QEMU の AAVMF では `timeout=1` でも、メニュー
表示直後に Down + Enter を送れば Ubuntu が起動することを確認済みです。

Ubuntu arm64 の `/boot/vmlinuz-<version>` は UKI で、GRUB の `linux` が
stubble にジャンプします。GRUB を EFI シェルから起動した場合は
`measure.c:246@tpm_log_ipl_event` の assert で止まるため、
`make_recovery_ubuntu.sh` は `pipeline/extract_uki_kernel.py` で `.linux`
セクションを取り出します（Ubuntu の `.linux` は EFI zboot なので zstd で
展開）。`/boot/vmlinuz-<version>.raw` の arm64 `Image` を GRUB が読みます。
理由と手動復旧は
[DUALBOOT.md](DUALBOOT.md#ubuntu-カーネルuki-と-stubble) を参照してください。

ARM64 の Windows は EMS/SAC に対応しておらず、`bcdedit /ems` や
`bcdedit /emssettings` は**エラーを返さずに BCD へ要素を書き込みます**。
OCI A1 では明示的な `EMSPORT:1`（x86 COM1 の I/O ポート 0x3F8、実機の
シリアルは PL011 MMIO @0x09000000）が bootmgr/winload の無音ハングを
引き起こすため、`boot.ps1` は EMS を設定しません。万一古いイメージから
引き継いだ場合でも `pipeline/finish_disk.sh` が
`pipeline/bcd_normalize.py` で BCD を正規化します。

- `15000022`/`15000023` などの明示的な EMS ポート・ボーレートを削除
- `16000020`（bootems）と `260000b0`（EmsEnable）を 0 に設定。EMS と
  ConOut が同じ PL011 に書くと `WWiinnddooww` のように二重表示されます
- `16000048`（nointegritychecks）は 1 に設定。削除すると `0xc0000428` で
  停止します（旧 `bcd_disable_ems.py` は削除していたため回帰しました）
- `16000046`/`1600006c` はテキストコンソール用に 1、`26000090`/`26000091`
  は診断用なので削除

`bcd_disable_ems.py` は互換エイリアスとして残しています。

Windows の復旧は RDP / WinRM を使ってください。

`build-image.sh` は ISO の `efi/boot/bootaa64.efi` を `bootmgfw.efi` として
取り出すだけでなく、同じメディアの `bootmgr.efi`（`efi/microsoft/boot/`
または ISO ルート）と `boot.stl` も `finish_disk.sh` に渡します。
`bootmgfw` だけ 26100 で `bootmgr`/`boot.stl` がインストール済み Windows の
28000、という混成を避けるためです。明示する場合は
`STOCK_BOOTMGFW` / `STOCK_BOOTMGR` / `STOCK_BOOT_STL` を使います。

復旧 Ubuntu には `efibootmgr` と `oci-ubuntu-boot-order.service` が入り、
起動のたびに Ubuntu の EFI エントリをブート順の先頭へ戻します。Windows の
初回起動が NVRAM の順序を変えても GRUB に戻れるようにするためです
（詳細は [DUALBOOT.md](DUALBOOT.md#ファームウェアのブート順nvram)）。
`efibootmgr` の .deb が ISO の pool に無い場合は警告だけ出して続行し、
EFI シェルの `bcfg` で手動登録できます。

GRUB が Windows を chainload する前に `search --file --set=root
/EFI/Microsoft/Boot/bootmgfw.efi` を実行する理由と、`bootmgfw.efi` の
開始クラスタ制限は [DUALBOOT.md](DUALBOOT.md#起動メニュー) を参照して
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
