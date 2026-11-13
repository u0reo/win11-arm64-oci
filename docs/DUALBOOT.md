# Ubuntu 復旧環境を残して Windows と共存する

Windows 11 を同じブートボリュームに入れつつ、**4 GiB の小さな Ubuntu を
復旧用に残す**構成です。Ubuntu の GRUB を先に起動するのではなく、
Windows Boot Manager のメニューから Ubuntu を選ぶ形にします。

```text
p1  ESP (FAT32, 512 MB)      既存を保持。Windows と Ubuntu の両方の EFI を置く
p2  Ubuntu (ext4, 4 GiB)     Ubuntu Server minimal を新規インストール
p3  Windows (NTFS, 残り)      wimlib-imagex で適用
```

## 何を残して何を捨てるか

- **捨てる**: OCI が入れた Ubuntu の中身（cloud-init、snap、OCI エージェント等）
- **残す**: `/etc/netplan`、`/etc/ssh`（`sshd_config` と**ホスト鍵**）、
  `authorized_keys`、ユーザーアカウント（UID とパスワードハッシュ）、
  `/etc/sudoers.d`、ホスト名、タイムゾーン
- **入れ直す**: Ubuntu Server minimal（`debootstrap --variant=minbase`）。
  snapd・cloud-init・linux-firmware は入れません（4 GiB に収めるため）

設定の退避は `pipeline/save_ubuntu_config.sh` が行い、`build/ubuntu-config/`
に置きます。**`/etc/shadow` と SSH 秘密鍵を含むので git に入れないでください**
（`build/` は .gitignore 済み）。ビルドが終わったら削除してください。

## OCI の Ubuntu から始める

ISO の取得方法は [README の「ISO の入手」](../README.md#iso-の入手) を
参照してください（Ubuntu Server の live-server-arm64 ISO 1 枚で、
方法 B とインストーラの両方に使えます）。

いま起動しているのが OCI の標準 Ubuntu（`/dev/sda2` が 46 GiB の root）
の場合、**その p2 を縮小することはできません**（マウント中の ext4 は
縮小できないため）。次のどちらかに進みます。

### A. 4 GiB の Ubuntu を先に入れる

Ubuntu Server のインストーラを GRUB に登録して再起動します。

```bash
sudo ./scripts/prepare.sh --installer \
  /srv/iso/ubuntu-24.04-live-server-arm64.iso --write
sudo reboot
```

GRUB で `Ubuntu Server installer (toram)` を選び、パーティションを

```text
p1  ESP     既存のまま（100 MiB〜1 GiB）
p2  /       4 GiB, ext4
残り        未割り当て（Windows 用に空ける）
```

にしてインストールします。swap は作りません（Windows の場所が減るため）。
インストール後に新しい Ubuntu へ再起動し、SSH で入って
`--reuse-ubuntu` を実行します（下の節）。

`toram` を付けているのは、インストーラが**自分が起動したディスク**を
再分区するためです。RAM に載っていないと p2 を消せません。

### B. RAM に載せて一気に作る

`--keep-ubuntu` を使う方法です。p2 を作り直して minimal を debootstrap
するので、4 GiB の Ubuntu と Windows が 1 回のビルドでできます。

```bash
sudo ./scripts/prepare.sh --toram \
  /srv/iso/ubuntu-24.04-live-server-arm64.iso --write
sudo reboot
# GRUB で "Ubuntu live (toram)" を選び、live 環境で
sudo ./scripts/build.sh --to-ram --keep-ubuntu --disk /dev/sda \
  --iso /dev/shm/Win11.iso --virtio /dev/shm/virtio-win.iso \
  --mem 6144 --yes
```

`--to-ram` は ISO を RAM にコピーしてから書き込みます。ISO がすでに
`/dev/shm` にあればコピーは起きません。

## 使い方

```bash
sudo ./scripts/build.sh \
  --disk /dev/sdb \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso \
  --keep-ubuntu --ubuntu-size 4G --yes
```

`--ubuntu-size` を省略すると 4 GiB です。Ubuntu を 6 GiB にしたければ
`--ubuntu-size 6G`。Windows は残り全部（100 GB のボリュームなら約 88 GiB）
を使います。

## インストール済みの Ubuntu を使う（`--reuse-ubuntu`）

live 環境を使わず、**先に Ubuntu minimal を p2 に入れて起動する**方法です。
RAM に ISO を載せないのでメモリに余裕があり、ビルドをやり直しやすいです。

```text
1. Ubuntu Server minimal をインストーラで入れる
   - p1 ESP (512 MB〜1 GB)
   - p2 / を 4 GiB（4 GiB を超えると Windows の余地が減ります）
   - 残りは「未割り当て」のままにする（ここが p3 になります）
2. その Ubuntu を起動して SSH で入る
3. sudo ./scripts/build.sh --reuse-ubuntu --disk /dev/sda \
     --iso /home/ubuntu/Win11_ARM64_26H2.iso --yes
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
- Windows のみ（p2 を消す）は**できません**。その場合は `--to-ram` で
  live 環境から実行してください

## 中で起きること

1. `save_ubuntu_config.sh` が既存 p2 を read-only でマウントし、設定を退避
2. `host_apply.sh` が p2 を削除して 4 GiB で作り直し、p3 を残り全部で作成
   （ESP はフォーマットしない。空き 40 MiB 未満なら中止）
3. `make_recovery_ubuntu.sh` が p2 に debootstrap で minimal Ubuntu を構築
   - netplan と SSH 設定をコピー
   - 同じ SSH ホスト鍵を使うので、既存の `known_hosts` がそのまま通る
   - `/etc/fstab` は新しい PARTUUID で生成
   - `grub-install --bootloader-id=ubuntu` → `\EFI\ubuntu\grubaa64.efi`
4. Windows を p3 に適用
5. WinPE で `bcdboot` を ESP に実行し、BCD に
   `BOOTAPP` エントリ（`\EFI\ubuntu\grubaa64.efi`）を追加

再起動すると Windows Boot Manager が 5 秒のメニューを出します。

```text
Windows 11
Ubuntu (recovery)
```

既定は Windows です。ファームウェアが起動するのは
`\EFI\BOOT\BOOTAA64.EFI`（`bcdboot` が置く Windows Boot Manager）なので、
Ubuntu 側の GRUB が壊れても Windows は起動します。

## 確認しておくこと

- **ESP の空き容量**: `bcdboot` が約 30 MiB、GRUB が約 15 MiB 使います。
  40 MiB を切ると `host_apply.sh` が中止します
- **Secure Boot**: 有効な環境では `\EFI\ubuntu\shimaa64.efi` を
  `path` に指定してください（既定は `grubaa64.efi`）
- **BCD の `device partition=S:`**: 環境によっては通らないことがあります。
  WinPE のログに `WARN: could not add the Ubuntu entry` が出たら、
  手動で `bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {GUID} device partition=S:`
  を試し、それでも駄目なら `partition=\Device\HarddiskVolume1` にします。
  失敗しても Windows は起動します
- **4 GiB で足りるか**: minimal + カーネル + initramfs で 1.6〜2.2 GiB 程度。
  `apt` のリストとキャッシュは削除済み。`df` の結果がログに出ます
- **Windows Update**: 大型更新で ESP やブート順が書き換わる可能性があります

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
