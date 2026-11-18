# Ubuntu 復旧環境を残して Windows と共存する

> このページは追加情報です。実際の手順は README の
> [ステージ4](../README.md#ステージ4-ビルド) を参照してください。

Windows 11 を同じブートボリュームに入れつつ、**4 GiB の小さな Ubuntu を
復旧用に残す**構成です。Ubuntu の GRUB を先に起動するのではなく、
Windows Boot Manager のメニューから Ubuntu を選ぶ形にします。

```text
ESP (FAT32)                  既存を保持。Windows と Ubuntu の両方の EFI を置く
Ubuntu recovery (ext4, 4 GiB) Ubuntu Server minimal を新規インストール
Windows (NTFS, 残り)          wimlib-imagex で適用
```

パーティション番号はディスクによって変わります。スクリプトは番号ではなく
GPT のパーティション種別（EFI System）で ESP を探します。

```text
OCI ARM64 の標準:  p1=Ubuntu root (49 GiB), p13=BOOT (923 MiB), p15=ESP
                   → 復旧 Ubuntu は p1、Windows は p2、ESP は p15 のまま
古い構成:          p1=ESP, p2=Ubuntu
                   → 復旧 Ubuntu は p2、Windows は p3、ESP は p1 のまま
```

## 何を残して何を捨てるか

- **捨てる**: OCI が入れた Ubuntu の中身（cloud-init、snap、OCI エージェント等）
- **残す**: `/etc/netplan`、`/etc/ssh`（`sshd_config` と**ホスト鍵**）、
  `authorized_keys`、ユーザーアカウント（UID とパスワードハッシュ）、
  `/etc/sudoers.d`、ホスト名、タイムゾーン
- **入れ直す**: Ubuntu Server minimal（`debootstrap --variant=minbase`）。
  snapd・cloud-init・linux-firmware は入れません（4 GiB に収めるため）

設定の退避は `pipeline/save_ubuntu_config.sh` が行い、`build/ubuntu-config/`
に置きます（live の既定は `/dev/shm/build/ubuntu-config/`）。
**`/etc/shadow` と SSH 秘密鍵を含むので git に入れないでください**
（`build/` は .gitignore 済み、`/dev/shm` は再起動で消えます）。
ビルドが終わったら削除してください。

## なぜ live 環境で Ubuntu root を作り直すのか

いま起動しているのが OCI の標準 Ubuntu（ARM64 では `p1` が 49 GiB の
root、`p13` が BOOT、`p15` が ESP）の場合、**その root は縮小できません**
（マウント中の ext4 は縮小できないため）。そこで live 環境に切り替えて、
root を作り直します。live への切り替えは README の
[ステージ2-B](../README.md#ステージ2-b-live-を-toram-で起動する) にあります。

## 使い方

README の [ステージ4](../README.md#ステージ4-ビルド) のコマンドに
`--keep-ubuntu` を足します。`--ubuntu-size` を省略すると 4 GiB です。
Ubuntu を 6 GiB にしたければ `--ubuntu-size 6G`。Windows は残り全部
（100 GB のボリュームなら約 88 GiB）を使います。

`--keep-ubuntu` は古い Ubuntu root（と OCI の BOOT パーティション）を
4 GiB（`--ubuntu-size` で変更可）の復旧環境として作り直して minimal Ubuntu を
debootstrap するので、Windows と Ubuntu が 1 回のビルドでできます。

RAM の内訳と、データボリュームを使う場合の注意は
[OCI.md の「24 GB で足りるか」](OCI.md#24-gb-で足りるか) にあります。

## 中で起きること

1. `save_ubuntu_config.sh` が既存 root（最大の ext4）をマウントし、設定を退避
2. `host_apply.sh` が GPT 種別から ESP を探し、古い root と BOOT を削除。
   空いた領域に復旧 Ubuntu と Windows を、空いている番号で作成
   （ESP はフォーマットしない。空き 40 MiB 未満なら中止）
3. `make_recovery_ubuntu.sh` が復旧パーティションに minimal Ubuntu を構築
   - live ISO が見えている場合は、ISO 内の minimal rootfs
     (`/cdrom/casper/*.squashfs`) を展開する。ネットワークは使わない
   - live ISO が無い場合だけ debootstrap（`ports.ubuntu.com`）を使う
   - netplan と SSH 設定をコピー
   - 同じ SSH ホスト鍵を使うので、既存の `known_hosts` がそのまま通る
   - `/etc/fstab` は新しい UUID で生成
   - GRUB は signed バイナリ (`grubaa64.efi.signed`) を `\EFI\ubuntu` に
     置き、回復用メニューを直接生成する（ネットワーク経路では
     `grub-install --bootloader-id=ubuntu`）
4. Windows を新しい NTFS パーティションに適用
5. WinPE で `OEM\esp-part.txt` に記録した ESP 番号を選び、`bcdboot` を実行。
    `bcdboot` は既存の `\EFI\BOOT\BOOTAA64.EFI`（Ubuntu の shim）を
    上書きしないため、Windows Boot Manager を明示的にコピーする。
    QEMU 停止後、ホスト側の `pipeline/finish_winpe.sh` が
    `\manual-finish.log` を確認し、BCD に `BOOTAPP` エントリ
    （`\EFI\ubuntu\grubaa64.efi`）を追加する

## 途中から再開する

ステップ5の後（Windows の適用後）に失敗した場合、`FROM_STEP` を付けると
`host_apply.sh` を飛ばして続きから再開できます。ディスクは消去されません。

```bash
# 復旧 Ubuntu の構築（ステップ6）から
sudo env FROM_STEP=6 ./scripts/build.sh --keep-ubuntu --ubuntu-size 4G \
  --disk /dev/sdb --iso /path/to/win11.iso --virtio /path/to/virtio-win.rpm --yes

# WinPE の仕上げ（ステップ7）から
sudo env FROM_STEP=7 ./scripts/build.sh ... --yes

# 電源オフ待ち（ステップ11）から。稼働中の QEMU に再接続する
sudo env FROM_STEP=11 ./scripts/build.sh ... --yes
```

ステップ1〜3の成果物（`build/media`、`build/oemdrv.iso` など）が
`BUILD_DIR`（live では `/dev/shm/build`）に残っている必要があります。

## 起動メニュー

再起動すると Windows Boot Manager が 1 秒のメニューを出します。表示中に
何かキーを押すとカウントダウンが止まるので、そこで Ubuntu を選べます
（`--boot-menu 秒数` で変更できます。`--boot-menu 0` は Ubuntu の
エントリを選べなくなるため指定できません）。

```text
Windows 11
Ubuntu (recovery)
```

既定は Windows です。ファームウェアが起動するのは
`\EFI\BOOT\BOOTAA64.EFI`（`finish_winpe.sh` が置く Windows Boot Manager）
なので、Ubuntu 側の GRUB が壊れても Windows は起動します。

`pipeline/bcd_add_ubuntu.py` は Ubuntu エントリと同時に
`displaybootmenu` を有効にします。`--boot-menu 1` の 1 秒間に何かキーを
押すとカウントダウンが止まり、矢印キーで Ubuntu を選べます。

`finish_winpe.sh` は `bootmgfw.efi` を `\EFI\BOOT` にコピーし直すため、
その後に `pipeline/finish_disk.sh` で OCI A1 用パッチを当てる順序が重要です。
`finish_disk.sh` は両方のファイルを読み直してパッチを検証し、失敗時は
非ゼロで終了します。

## 確認しておくこと

- **ESP の空き容量**: `bcdboot` が約 30 MiB、GRUB が約 15 MiB 使います。
  40 MiB を切ると `host_apply.sh` が中止します
- **Secure Boot**: 有効な環境では `\EFI\ubuntu\shimaa64.efi` を
  `path` に指定してください（既定は `grubaa64.efi`）
- **BCD の Ubuntu エントリ**: WinPE の `bcdedit /set {GUID} device
  partition=S:` はこの環境では通りません。そのため QEMU 停止後に
  `pipeline/finish_winpe.sh` が `pipeline/bcd_add_ubuntu.py` で
  Windows Boot Manager と同じ ESP device 要素をコピーして書き込みます。
  WinPE 側は `\manual-finish.log` に進捗を残すだけで、失敗時は
  ビルドが停止します
- **4 GiB で足りるか**: live ISO の minimal rootfs を使う場合は
  2.2〜2.6 GiB 程度（initramfs 込み）。
  `apt` のリストとキャッシュは削除済み。`df` の結果がログに出ます
- **Windows Update**: 大型更新で ESP やブート順が書き換わる可能性があります

## 上級者向け: 既に小さな Ubuntu が入っている場合（`--reuse-ubuntu`）

`--reuse-ubuntu` は `p1=ESP, p2=Ubuntu` のレイアウト専用です（OCI の
標準 ARM64 レイアウトには対応しません。その場合は `--keep-ubuntu` を
使ってください）。

p2 に 4 GiB 程度の Ubuntu を**自分で入れて起動してある**なら、
`--reuse-ubuntu` で p2 を残したまま Windows を足せます。`prepare.sh` は
live 起動しか登録しないので、この Ubuntu は別のインストーラや
[ステージ2-A](../README.md#ステージ2-a-ボリュームを付け替える) で
用意しておく必要があります。通常は `--keep-ubuntu` を使ってください。

```text
1. p2 に Ubuntu を入れる（p1 ESP は既存のまま）
   - p2 / を 4 GiB 程度
   - 残りは「未割り当て」のままにする（ここが p3 になります）
2. その Ubuntu を起動して SSH で入る
3. README ステージ4 のコマンドに --reuse-ubuntu を足して実行する
```

`--reuse-ubuntu` は p2 を**一切書き換えません**。p3 の作成と ESP への
`bcdboot` だけを行います。そのため実行中のディスクでも受け付けます
（他のモードは拒否します）。

注意点:

- p2 の後ろに **40 GiB 以上の未割り当て領域**が必要です。足りない場合は
  エラーになります。インストール時に 4 GiB だけ使うようにしてください
- 実行中の ext4 を触らないので `resize2fs` は不要ですが、**QEMU が同じ
  ディスクを開きます**。ビルド中に p2 のファイルを書き換えたり、電源を
  切ったりしないでください
- Windows のみ（p2 を消す）は**できません**。その場合は `toram` で
  live 環境から実行してください

## 復旧環境の使い方

Windows が起動しなくなったら、Boot Manager のメニューで
`Ubuntu (recovery)` を選びます。ログインは元のユーザー名・パスワード、
または退避した `authorized_keys` による SSH です。ネットワークは
元の netplan（OCI の DHCP）をそのまま使うので、IP は同じサブネットで
DHCP から取ります。OCI のコンソールからは `ubuntu` / 設定したパスワード、
または `serial-getty@ttyAMA0` で入れます。

## やらないこと

- 既存 Ubuntu の in-place 縮小（`resize2fs`）はしません。中身を作り直す方が
  小さく確実です
- XFS の Ubuntu には対応しません（縮小できないため）
- Ubuntu の GRUB から Windows を選ぶ構成にはしません（Windows 側を既定に
  するため。`GRUB_DISABLE_OS_PROBER=true` を設定しています）
