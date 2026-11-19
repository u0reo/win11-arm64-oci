# Ubuntu 復旧環境を残して Windows と共存する

> このページは追加情報です。実際の手順は README の
> [ステージ4](../README.md#ステージ4-ビルド) を参照してください。

Windows 11 を同じブートボリュームに入れつつ、**4 GiB の小さな Ubuntu を
復旧用に残す**構成です。ESP の shim/GRUB を先頭ローダーにし、GRUB の
メニューから **Windows 11（既定）** と **Ubuntu (recovery)** を選びます。

ディスクの状態によって作り方が 2 つあります。

| ディスク | フラグ | レイアウト |
|---|---|---|
| 空、または中身を全部捨ててよい | `--fresh-ubuntu` | p1=ESP (100 MiB), p2=Ubuntu, p3=Windows |
| p2 の Ubuntu をそのまま使う | `--reuse-ubuntu` | p1=ESP, p2=Ubuntu, p3=Windows（上級者向け） |

`--fresh-ubuntu` は **ESP も含めて新規作成**するので、元のディスクに何も
依存しません。GPT を `sgdisk --zap-all` で消してから作り直します。

```text
fresh の最終レイアウト:
  p1  ESP (FAT32, 100 MiB)      shim/GRUB、Windows Boot Manager、BCD
  p2  Ubuntu recovery (ext4)    Ubuntu Server minimal（--ubuntu-size、既定 4 GiB）
  p3  Windows (NTFS, 残り)      wimlib-imagex で適用
```

## 何を引き継ぐか

`--fresh-ubuntu` が引き継ぐのは、**ビルドを実行している Ubuntu の次の 2 つ
だけ**です。

- `/etc/netplan/*.yaml`
- `authorized_keys`（`/home/ubuntu` → `/home/*` → `/root` の順で最初の
  非空ファイル）

live (`toram`) でビルドする場合、これは live 環境の設定です。
`prepare.sh --ssh` で起動した live なら、
`/home/ubuntu/.ssh/authorized_keys` には元の Ubuntu から seed された鍵が
入っています。

引き継がないもの:

- `/etc/passwd` / `/etc/shadow` / `/etc/group`（ユーザーアカウントと
  パスワードハッシュ）
- SSH ホスト鍵
- `/etc/sudoers.d`
- ホスト名、タイムゾーン
- `sshd_config`

復旧環境には `ubuntu` ユーザーを新規作成し、`sudo` グループに入れます。
パスワードはビルド時にランダム生成し、ビルドログのステップ6に表示します。
`authorized_keys` が無い場合も、このパスワードでシリアルコンソールから
ログインできます。

`/dev/shm/build/ubuntu-config` のような退避ディレクトリは作りません。
設定を残す処理も、ビルド再開時に復元する処理もありません。

SSH ホスト鍵は復旧環境で新しく生成されるため、以前の Ubuntu に接続して
いたクライアントでは `known_hosts` の警告が出ます。次のように消してから
再接続してください。

```bash
ssh-keygen -R <host>
```

## 使い方

空のディスク（例: 何も入っていない `/dev/sdb`）から作る場合は
`--fresh-ubuntu` を使います。`--ubuntu-size` を省略すると 4 GiB です。

```bash
sudo ./scripts/build.sh --fresh-ubuntu --ubuntu-size 4G \
  --disk /dev/sdb --iso /path/to/win11.iso \
  --virtio /path/to/virtio-win.iso --yes
```

`--ubuntu-size` は `--fresh-ubuntu` と一緒にだけ使えます。単独で指定すると
エラーになります（`--reuse-ubuntu` は p2 を書き換えないためサイズ指定は
無意味です）。

Windows は残り全部を使います（50 GB のボリュームなら約 45 GiB）。

RAM の内訳と、データボリュームを使う場合の注意は
[OCI.md の「24 GB で足りるか」](OCI.md#24-gb-で足りるか) にあります。

## 中で起きること

1. 設定の確認（ステップ4）
   - 実行中の Ubuntu の `/etc/netplan/*.yaml` と `authorized_keys` を
     読み取り専用で確認する。ターゲットディスクは読まない
   - 何もコピーしない。実際のコピーはステップ6で行う
2. `host_apply.sh` がパーティションを作る（ステップ5）
   - `sgdisk --zap-all` の後、p1=ESP 100 MiB、p2=Ubuntu
     （`RECOVERY_SIZE`）、p3=Windows（残り）を作成し、3 つともフォーマット
3. `make_recovery_ubuntu.sh` が復旧パーティションに minimal Ubuntu を構築
   （ステップ6）
   - live ISO が見えている場合は、ISO 内の minimal rootfs
     (`/cdrom/casper/*.squashfs`) を展開する。ネットワークは使わない
   - live ISO が無い場合だけ debootstrap（`ports.ubuntu.com`）を使う
   - 実行中の Ubuntu の netplan と `authorized_keys` をコピー
   - netplan が無ければ DHCP の `01-recovery.yaml` を書く
   - `ubuntu` ユーザーを作成し、ランダムパスワードを設定
   - SSH ホスト鍵は `ssh-keygen -A` で新規生成
   - `/etc/fstab` は新しい UUID で生成
   - GRUB は signed バイナリ (`grubaa64.efi.signed`) を `\EFI\ubuntu` に
     置き、ISO の `shim-signed` から `shimaa64.efi` も置く
   - `/boot/grub/grub.cfg` はカーネル・initrd・UUID から生成する。
     `finish_winpe.sh` が `write_grub_menu.py` で Windows エントリを足し、
     `\EFI\ubuntu\grub.cfg` と `\EFI\BOOT\grub.cfg` に配置する
4. Windows を新しい NTFS パーティションに適用
5. WinPE で `OEM\esp-part.txt` に記録した ESP 番号を選び、`bcdboot` を実行。
    `bcdboot` は既存の `\EFI\BOOT\BOOTAA64.EFI`（Ubuntu の shim）を
    上書きしないため、Windows Boot Manager を明示的にコピーする。
    QEMU 停止後、ホスト側の `pipeline/finish_winpe.sh` が
    `\manual-finish.log` を確認し、ESP を GRUB 先頭ローダーに整える:
    `\EFI\BOOT\BOOTAA64.EFI` に shim、`\EFI\BOOT\grubaa64.efi` に GRUB を置き、
    `\EFI\ubuntu\grub.cfg` にメニューを書き、BCD から Ubuntu bootapp を削除する

## 途中から再開する

ステップ5の後（Windows の適用後）に失敗した場合、`FROM_STEP` を付けると
`host_apply.sh` を飛ばして続きから再開できます。ディスクは消去されません。

```bash
# 復旧 Ubuntu の構築（ステップ6）から
sudo env FROM_STEP=6 ./scripts/build.sh --fresh-ubuntu --ubuntu-size 4G \
  --disk /dev/sdb --iso /path/to/win11.iso --virtio /path/to/virtio-win.rpm --yes

# WinPE の仕上げ（ステップ7）から
sudo env FROM_STEP=7 ./scripts/build.sh ... --yes

# 電源オフ待ち（ステップ11）から。稼働中の QEMU に再接続する
sudo env FROM_STEP=11 ./scripts/build.sh ... --yes
```

ステップ1〜3の成果物（`build/media`、`build/oemdrv.iso` など）が
`BUILD_DIR`（live では `/dev/shm/build`）に残っている必要があります。
ステップ6だけを再実行する場合も、実行中の Ubuntu の netplan と
`authorized_keys` が読める状態にしておいてください。

## 起動メニュー

再起動すると、ファームウェアは ESP の `\EFI\BOOT\BOOTAA64.EFI`（Ubuntu の
shim）を起動し、shim が GRUB を起動します。GRUB は
`\EFI\ubuntu\grub.cfg` を読み、次のメニューを 1 秒表示します。

```text
Windows 11            (default)
Ubuntu (recovery)
```

表示中に何かキーを押すとカウントダウンが止まります。矢印キーで Ubuntu を
選び、Enter で起動します。`--boot-menu 秒数` で表示時間を変更できます。
`--boot-menu 0` は Ubuntu を選べなくなるため、Ubuntu を残す構成では
指定できません。

メニューは EFI コンソールに出るため、**OCI のシリアルコンソールからも
表示・選択できます**。QEMU の AAVMF では `timeout=1` でも、メニュー表示直後に
Down + Enter を送れば Ubuntu が起動することを確認済みです。

既定の Windows 11 を選ぶと、GRUB は ESP を root にしてから
`\EFI\Microsoft\Boot\bootmgfw.efi` を chainload します。`$root` が Ubuntu の
まま chainload すると BCD を読めず `0xc00000bb` で止まるため、
`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` を先に実行します。

GRUB の FAT ドライバは、先頭クラスタが 65536 以上のファイルを
`not a regular file` として開けません。`bootmgfw.efi` は
`pipeline/finish_disk.sh` が mtools で低クラスタに置き、開始クラスタを
検査します。

Windows Boot Manager の BCD には Ubuntu の bootapp エントリを残しません
（ARM64 の BootMgr では bootapp を起動できないため）。GRUB が Ubuntu を
直接起動します。Windows Boot Manager 自身のメニューは Windows のエントリ
だけを 1 秒表示しますが、Ubuntu を選ぶメニューではありません。

### ブートファイルの関係

```text
\EFI\BOOT\BOOTAA64.EFI            Ubuntu shim（ファームウェアのフォールバック）
\EFI\BOOT\grubaa64.efi            GRUB（shim が同じディレクトリから読む）
\EFI\ubuntu\shimaa64.efi          NVRAM の Ubuntu エントリ用 shim
\EFI\ubuntu\grubaa64.efi          GRUB（signed、prefix は /EFI/ubuntu）
\EFI\ubuntu\grub.cfg              GRUB メニュー（実際に読まれる設定）
\EFI\BOOT\grub.cfg                同じ内容のコピー
\EFI\Microsoft\Boot\bootmgfw.efi  Windows Boot Manager（OCI A1 用パッチ済み）
\EFI\Microsoft\Boot\BCD           Windows のみ
```

`finish_winpe.sh` は shim/GRUB と GRUB メニューを配置し、BCD から Ubuntu
bootapp を削除します。`finish_disk.sh` は `bootmgfw.efi` だけに OCI A1 用
パッチを当て、FAT の開始クラスタと GRUB メニューを検証します。
`inspect_image.sh` は最終状態（shim/GRUB、メニュー、BCD、開始クラスタ）を
読み取り専用で表示します。

## 確認しておくこと

- **ESP**: `--fresh-ubuntu` は 100 MiB の ESP を新規作成するので、既存 ESP の
  空き容量を確認する必要はありません
- **Secure Boot**: パッチ済み `bootmgfw.efi` は署名が無効になるため、
  Secure Boot は**無効**にしてください。shim/GRUB 自体は署名済みですが、
  chainload する Windows のパッチで Secure Boot が失敗します
- **BCD**: `finish_winpe.sh` / `finish_disk.sh` が Ubuntu bootapp と、
  削除したオブジェクトへの参照を除去します。Windows の displayorder は
  Windows のみになります
- **4 GiB で足りるか**: live ISO の minimal rootfs を使う場合は
  2.2〜2.6 GiB 程度（initramfs 込み）。`apt` のリストとキャッシュは削除済み。
  `df` の結果がログに出ます
- **Windows Update**: 大型更新で ESP やブート順が書き換わる可能性があります。
  更新後に `pipeline/inspect_image.sh` で GRUB/BCD を確認してください

## 上級者向け: 既に小さな Ubuntu が入っている場合（`--reuse-ubuntu`）

`--reuse-ubuntu` は `p1=ESP, p2=Ubuntu` のレイアウト専用です。OCI の
標準 ARM64 レイアウト（p1=root, p13=BOOT, p15=ESP）には対応しません。
そのディスクを残したい場合は、必要なデータを退避してから
`--fresh-ubuntu` で作り直してください。

p2 に 4 GiB 程度の Ubuntu を**自分で入れて起動してある**なら、
`--reuse-ubuntu` で p2 を残したまま Windows を足せます。`prepare.sh` は
live 起動しか登録しないので、この Ubuntu は別のインストーラや
[ステージ2-A](../README.md#ステージ2-a-ボリュームを付け替える) で
用意しておく必要があります。通常は `--fresh-ubuntu` を使ってください。

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

Windows が起動しなくなったら、GRUB のメニューで `Ubuntu (recovery)` を
選びます。シリアルコンソールでも VNC でも同じメニューを操作できます。

ログインは `ubuntu` ユーザーです。`authorized_keys` が入っていれば、ビルドを
実行した Ubuntu で使っていた SSH 鍵でそのまま入れます。鍵が無い場合は、
ビルドログのステップ6に表示されたランダムパスワードでシリアルコンソールから
ログインしてください。

ネットワークは、実行中の Ubuntu からコピーした netplan（OCI なら DHCP）を
使います。netplan が無かった場合は `en*` 向けの DHCP 設定を書きます。IP は
同じサブネットで DHCP から取ります。Ubuntu のコンソールは
`serial-getty@ttyAMA0` で `login:` を出します。

Windows 側のシリアル復旧は期待できません。ARM64 の Windows は EMS/SAC を
サポートしておらず、`bcdedit /ems` はエラーを出さずに何もしません。
