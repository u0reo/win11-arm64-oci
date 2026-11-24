# Ubuntu 復旧環境を残して Windows と共存する

> このページは追加情報です。実際の手順は README の
> [ステージ4](../README.md#ステージ4-ビルド) を参照してください。

Windows 11 を同じブートボリュームに入れつつ、**4 GiB の小さな Ubuntu を
復旧用に残す**構成です。ESP の shim/GRUB を先頭ローダーにし、GRUB の
メニューから **Windows 11（既定）** と **Ubuntu (recovery)** を選びます。

ディスクの状態によって作り方が 2 つあります。

| ディスク | フラグ | レイアウト |
|---|---|---|
| 空、または中身を全部捨ててよい | `--fresh-ubuntu` | p1=ESP (100 MiB), p2=Ubuntu, p3=Windows（+ p4=Windows RE） |
| p2 の Ubuntu をそのまま使う | `--reuse-ubuntu` | p1=ESP, p2=Ubuntu, p3=Windows（上級者向け） |

`--fresh-ubuntu` は **ESP も含めて新規作成**するので、元のディスクに何も
依存しません。GPT を `sgdisk --zap-all` で消してから作り直します。

```text
fresh の最終レイアウト:
  p1  ESP (FAT32, 100 MiB)      shim/GRUB、Windows Boot Manager、BCD
  p2  Ubuntu recovery (ext4)    Ubuntu Server minimal（--ubuntu-size、既定 4 GiB）
  p3  Windows (NTFS, 残り)      wimlib-imagex で適用
  p4  Windows RE (NTFS, 1 GiB)  --winre-partition を付けた場合のみ
```

`--winre-partition` を付けると、p3 は「残り − WinRE サイズ」になり、
p4 に type `2700`（Windows RE）・NTFS のパーティションを作ります。p4 は
p3 の後ろなので、GRUB が読む p1/p2 の配置には影響しません。

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

専用の Windows RE も作る場合は `--winre-partition` を足します。

```bash
sudo ./scripts/build.sh --fresh-ubuntu --winre-partition \
  --winre-size 1G --disk /dev/sdb --iso /path/to/win11.iso \
  --virtio /path/to/virtio-win.iso --yes
```

`--winre-size` は `--winre-partition` と一緒にだけ使え、最小は 1 GiB です
（`Winre.wim` が約 795 MB あるため）。`--winre-partition` は
`--fresh-ubuntu` 専用です。この構成では約 45 GiB（Windows 40 GiB +
Ubuntu 4 GiB + WinRE 1 GiB）以上のディスクが必要です。

Windows は残り（WinRE を作る場合はその分を引いた領域）を使います。
50 GB のボリュームなら Windows は約 44 GiB です。

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
   - `--winre-partition` なら p3 を「残り − `WINRE_SIZE`」にし、p4 を
     type `2700`・NTFS・GPT 属性 `0x8000000000000001`（ドライブレターなし、
     必須パーティション）で作成する。
     p4 の番号と開始オフセットを `OEM\winre-part.txt` /
     `OEM\winre-offset.txt` に記録する
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

## Windows RE パーティション

`--winre-partition` を付けると、Windows の回復環境を C: の中ではなく専用の
p4 に置きます。Windows 自身の specialize パスが type `2700` のパーティション
を見つけて `Winre.wim` を p4 へインストールします（OEM のスクリプトより先に
動きます）。`oem/winre.ps1` はその結果を `ReAgent.xml` の開始オフセットで
確認し、まだ C: にある場合だけ `reagentc /disable` → `/setreimage` →
`/enable` で p4 へ移します。

移動に失敗した場合は、C: の WinRE を有効な状態に戻してビルドを続けます。
`C:\OEM\winre.log` に手順と `reagentc` の戻り値が残り、成功時は
`winre.done`、失敗時は `winre.failed` ができます。ビルド後の
`pipeline/inspect_image.sh` は、p4 の `Winre.wim` と `ReAgent.xml` の
実際の場所を表示します。

```text
Windows RE: p4 に Winre.wim がある      → 専用パーティションで動作
Windows RE: p4 が空、C: に Winre.wim    → C: の WinRE で動作（フォールバック）
```

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
`pipeline/manual/*.cmd` を直して再開する場合は `REBUILD_OEMDRV=1` を付けて
ください（`oemdrv.iso` を作り直すだけで、ディスクには触れません）。
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

### ファームウェアのブート順（NVRAM）

起動順はディスクではなくファームウェアの NVRAM に入っています。イメージを
初めて起動した直後は、ファームウェアのフォールバック
（`\EFI\BOOT\BOOTAA64.EFI`）が shim → GRUB を起動するため、メニューが
出ます。しかし **Windows を一度起動すると、Windows が自分用の
`Boot####`（Windows Boot Manager）を作り、Ubuntu のエントリが無い場合は
それを先頭にします**。次の電源投入では GRUB を経由せず Windows が直接
起動し、「Ubuntu が消えた」ように見えます（WORKLOG 22.47）。

復旧 Ubuntu は `oci-ubuntu-boot-order.service` を有効にしてあり、起動の
たびに `oci-ubuntu-boot-order` が以下を行います。

1. `efibootmgr -v` から `\EFI\ubuntu\grubaa64.efi`（shim があれば
   `\EFI\ubuntu\shimaa64.efi`）を指すエントリを探す
2. そのエントリのデバイスパスに含まれる **ESP の GPT GUID** が、現在の
   `/boot/efi` の PARTUUID と一致するか確認する。古いイメージの GUID の
   ままなら、ローダーが存在しても起動できないため削除する（WORKLOG 22.54）
3. 正しいエントリが無ければ ESP のパーティション番号を使って
   `efibootmgr --create` で追加する。重複した Ubuntu エントリも削除する
4. `efibootmgr --bootorder` でそのエントリだけを先頭へ移す
   （他のエントリは削除せず相対順を保つ）

ただし、この unit は **Ubuntu が一度起動できた後** の修理です。Ubuntu の
`Boot####` がまだ無い状態で Windows を先に起動すると、Windows が自分を
先頭にして GRUB に到達できず、unit も走りません（WORKLOG 22.47, 22.51）。
22.51 の対策前は、同じ順序でスクラッチビルドすると再発しました。

そのため、最終イメージの ESP には初回だけ Ubuntu を選ぶ
`next_entry=Ubuntu (recovery)` を `EFI/ubuntu/grubenv` に書きます。
`internal/build-image.sh` は `--fresh-ubuntu` のとき、Windows の準備完了
テスト（step 10）が終わった後の `finish_disk.sh`（step 12）で
`FIRST_BOOT_UBUNTU=1` を渡します。Windows の初回起動より前に Ubuntu を
既定にすると step 10 が Ubuntu で止まってしまうため、順序はこの位置で
なければなりません。`--reuse-ubuntu` の Ubuntu には unit が入っている
保証がないため、既定ではこのマーカーを書きません（必要なら
`FIRST_BOOT_UBUNTU=1` を明示します）。

1. 最初の電源投入: GRUB が `next_entry` を読み、Ubuntu を 1 回だけ起動
2. `oci-ubuntu-boot-order.service` が `Boot#### Ubuntu` を作成し先頭へ移動
3. GRUB は `next_entry` を空に戻す。次の電源投入は通常どおり Windows 11
   （Ubuntu を選びたいときはメニューで選択）

`next_entry` は GRUB 自身が消費するので、Ubuntu 側で消す処理はありません。
`FIRST_BOOT_UBUNTU=0` でこの初回起動を無効にできます。ビルドホストで
中身を確認・編集するには `pipeline/grubenv.py` を使います。

Windows 側にも保険を入れています。`oem/boot.ps1` は OEM Bootstrap タスク
（`onstart`, SYSTEM）から毎回の Windows 起動で走ります（WORKLOG 22.54）。

1. `mountvol` で ESP を一時的にマウントし、Ubuntu のローダー
   （`\EFI\ubuntu\shimaa64.efi`、無ければ `grubaa64.efi`）を確認する
2. `bcdedit /enum firmware` の Ubuntu エントリについて、**デバイスが
   `{bootmgr}` と同じ ESP か**、パスが現在のローダーかを照合する。
   古い GUID を指すエントリや重複は削除し、必要なら
   `bcdedit /create /d Ubuntu /application firmware` で作り直す
3. `bcdedit /set {fwbootmgr} displayorder <Ubuntu> /addfirst` で Ubuntu を
   ファームウェアの先頭へ移す

Ubuntu エントリを確認・作成できなかった場合だけ、以前の動作に戻して
`bcdedit /set {fwbootmgr} displayorder {bootmgr} /addlast` を実行します。
これは BlockVolume フォールバック（`\EFI\BOOT\BOOTAA64.EFI` = shim → GRUB）
を先に残す保険です。GRUB の既定は Windows 11 のままなので、既定起動自体は
変わりません（WORKLOG 22.52, 22.54）。

**UEFI BootMenu から Ubuntu を選んでも起動しない**場合は、まず
`efibootmgr -v` の `Boot#### Ubuntu` の `HD(1,GPT,...)` GUID が現在の ESP
（通常 `/dev/sda1`）の PARTUUID と一致するか確認してください。一致しなければ
古いエントリです。`sudo efibootmgr -b <num> -B` で削除した後、
`sudo /usr/local/sbin/oci-ubuntu-boot-order` を実行すると正しく作り直せます。

```bash
python3 pipeline/grubenv.py show  /mnt/esp/EFI/ubuntu/grubenv
python3 pipeline/grubenv.py unset /mnt/esp/EFI/ubuntu/grubenv next_entry
```

`efibootmgr` が無い、`efivarfs` が読み取り専用、`/boot/efi` が未マウントの
場合は説明を出して正常終了します。Ubuntu の起動を止めることはありません。
手動で同じ処理をするには:

```bash
sudo /usr/local/sbin/oci-ubuntu-boot-order
sudo efibootmgr -v
```

まだ GRUB に入れず、Ubuntu のエントリも無い場合は、ファームウェアの
EFI シェル（OCI のシリアルで Esc → Boot Manager → EFI Internal Shell）から
一度だけ登録します。

```text
Shell> fs0:
FS0:\> bcfg boot add 9 FS0:\EFI\ubuntu\grubaa64.efi Ubuntu
FS0:\> bcfg boot mv 9 0
FS0:\> reset
```

`bcfg boot mv` の 2 番目の番号は登録後のエントリ番号です。`bcfg boot dump`
で確認してください。Ubuntu が一度起動すれば、以降は上記の unit が順序を
維持します。Windows はファームウェアのブートメニューからいつでも選べます。

### Ubuntu カーネル（UKI と stubble）

Ubuntu 24.04 以降の arm64 は `/boot/vmlinuz-<version>` を **UKI** として
インストールします。UKI のエントリポイントは stubble で、GRUB の `linux`
コマンドはカーネルの EFI スタブではなく stubble へジャンプします。GRUB を
EFI シェルから起動した場合、stubble はシェルの引数をコマンドラインとして
扱い、引数が無いと UKI 内の空の `.cmdline` を選びます。その結果
`measure.c:246@tpm_log_ipl_event` の assert で停止します（WORKLOG 22.48）。

`make_recovery_ubuntu.sh` はビルド時に `pipeline/extract_uki_kernel.py` で
UKI の `.linux` セクションを取り出します。Ubuntu の `.linux` は EFI zboot
（zstd 圧縮）なので展開し、`/boot/vmlinuz-<version>.raw`（通常の arm64
`Image`）を置きます。GRUB メニューはこちらを `linux` で読みます。
stubble を経由しないため、NVRAM・ファームウェアフォールバック・
EFI シェルのどこから GRUB を起動しても同じ経路で Ubuntu が起動します。
Secure Boot は無効なので、未測定のカーネルでも問題ありません。

復旧 Ubuntu でカーネルを更新した場合は、新しい `/boot/vmlinuz-<version>` に
対して `pipeline/extract_uki_kernel.py` を実行し、`write_grub_menu.py` で
メニューを作り直してください。`.raw` が無いと GRUB は UKI を読み、
EFI シェル経由の起動で stubble の assert に戻ります。

既定の Windows 11 を選ぶと、GRUB は ESP を root にしてから
`\EFI\Microsoft\Boot\bootmgfw.efi` を chainload します。`$root` が Ubuntu の
まま chainload すると BCD を読めず `0xc00000bb` で止まるため、
`search --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi` を先に実行します。

GRUB の FAT ドライバは、先頭クラスタが 65536 以上のファイルを
`not a regular file` として開けません。対象は chainload する
`bootmgfw.efi` と、GRUB 自身が読む `grub.cfg`（`\EFI\ubuntu` と
`\EFI\BOOT` の 2 つ）です。`pipeline/finish_disk.sh` は書き込み後の
開始クラスタを検査し、65536 以上なら `pipeline/esp_compact.sh` で ESP を
作り直します。このスクリプトは新しい FAT を一時イメージに構築し、
`grub.cfg`・`bootmgfw.efi`・`BCD` を先頭にコピーして検証してから
パーティションへ書き戻します。

**ESP を再フォーマットすると FAT の volume serial（`blkid` の `UUID`）が
変わります。** 復旧 Ubuntu の `/etc/fstab` が古い UUID を指したままだと、
起動時に `/boot/efi` の device unit が 90 秒間見つからず emergency mode に
入ります。`make_recovery_ubuntu.sh` は `/boot/efi` を **PARTUUID** で
（`nofail,x-systemd.device-timeout=10s` 付き）書き、`esp_compact.sh` は
再フォーマット時に volume serial を保持します。さらに `inspect_image.sh`
が最終イメージの fstab と実際の ESP を照合し、不一致ならビルドを失敗させ、
`test_recovery_boot.sh` が QEMU で Ubuntu が emergency mode に入らないことを
確認します（TCG では 15 分程度かかります）。ディスクは一時的な qcow2
オーバーレイ経由で渡します。イメージを `readonly=on` で渡すとゲスト側で
ルートが書き込み不可になり、`systemd-remount-fs.service` の失敗から
shutdown に回ってログインプロンプトまで到達しないためです。
オーバーレイなら元イメージを一切変更せずに通常どおり起動できます。

Windows Boot Manager の BCD には Ubuntu の bootapp エントリを残しません
（ARM64 の BootMgr では bootapp を起動できないため）。GRUB が Ubuntu を
直接起動します。Ubuntu はあくまで `{fwbootmgr}`（ファームウェアの
BootMenu）と NVRAM の `Boot#### Ubuntu` にだけ置き、`{bootmgr}` の
displayorder には入れません。実験的に `{bootmgr}` へ入れると WBM の
OS メニューに Windows 11 と並んで表示されますが、Ubuntu を選ぶと失敗
します（WORKLOG 22.55）。

Windows 側の `oem/boot.ps1` は毎回の起動で次を実行します。

```cmd
bcdedit /set {bootmgr} timeout 1
bcdedit /set {bootmgr} displayorder <Ubuntu の GUID> /remove
```

したがって Windows Boot Manager 自身のメニューは Windows のエントリだけを
1 秒表示し、Ubuntu を選ぶメニューではありません。GRUB のタイムアウトも
既定で 1 秒です。

### ブートファイルの関係

```text
\EFI\BOOT\BOOTAA64.EFI            Ubuntu shim（ファームウェアのフォールバック）
\EFI\BOOT\grubaa64.efi            GRUB（shim が同じディレクトリから読む）
\EFI\ubuntu\shimaa64.efi          NVRAM の Ubuntu エントリ用 shim
\EFI\ubuntu\grubaa64.efi          GRUB（signed、prefix は /EFI/ubuntu）
\EFI\ubuntu\grub.cfg              GRUB メニュー（実際に読まれる設定）
\EFI\BOOT\grub.cfg                同じ内容のコピー
\EFI\Microsoft\Boot\bootmgfw.efi  Windows Boot Manager（署名済み stock）
\EFI\Microsoft\Boot\bootmgr.efi   bootmgfw と同じ世代の BootMgr
\EFI\Microsoft\Boot\boot.stl      bootmgfw と同じ世代の署名リスト
\EFI\Microsoft\Boot\BCD           Windows のみ
```

`bootmgfw.efi` だけを差し替えると `bootmgr.efi` / `boot.stl` と世代が
食い違い（例: 26100 と 28000）、実機 OCI では bootmgr のメニュー前に停止
します。`finish_disk.sh` は 3 つを同じ供給元から揃え、28000 系が混ざった
場合は警告します。`STOCK_BOOTMGFW` / `STOCK_BOOTMGR` / `STOCK_BOOT_STL` で
明示できます（`build-image.sh` は ISO の `efi/boot/bootaa64.efi` と
`efi/microsoft/boot/bootmgr.efi`・`boot.stl` を優先します）。

`finish_winpe.sh` は shim/GRUB と GRUB メニューを配置し、BCD から Ubuntu
bootapp を削除します。`finish_disk.sh` は `bootmgfw.efi` が stock のまま
であること、FAT の開始クラスタ、GRUB メニューを検証します。
`inspect_image.sh` は最終状態（shim/GRUB、メニュー、BCD、開始クラスタ）を
読み取り専用で表示します。

## 確認しておくこと

- **ESP**: `--fresh-ubuntu` は 100 MiB の ESP を新規作成するので、既存 ESP の
  空き容量を確認する必要はありません
- **Secure Boot**: 最終イメージの `bootmgfw.efi` は署名済み stock なので
  Secure Boot を有効にできます。`PATCH_BOOTMGFW=1` を使った場合だけ署名が
  無効になるため、Secure Boot は**無効**にしてください
- **bootmgfw は stock のまま**: `ConvertPages: failed to find range
  102000-102FFF` はファームウェアの DEBUG 出力で、bootmgfw は戻り値を見ずに
  続行します。パッチでイメージを変えると `boot.stl` / `CIPolicies` の完全性
  検査と一致せず、QEMU では bootmgr がメニュー前に終了しました。
  `finish_disk.sh` は読み取れる場合、インストール済み Windows の
  `\Windows\Boot\EFI\bootmgfw.efi` を ESP にコピーし、`bootmgr.efi` /
  `boot.stl` / `CIPolicies` と同じ世代に揃えます。実機 OCI では 26089 の
  bootmgfw と 28000 の boot chain の混成が bootmgr のメニュー前に停止した
  ため、ESP に残った古い stock をそのまま使わないでください。診断目的で
  旧パッチを試す場合だけ
  `PATCH_BOOTMGFW=1 ./pipeline/finish_disk.sh <disk>` を使ってください
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
サポートしていませんが、`bcdedit /ems` / `/emssettings` はエラーを出さずに
BCD へ要素を書き込みます。**OCI A1 で明示的な `EMSPORT:1` を設定すると
bootmgr/winload が無音でハングします**（WORKLOG 22.21-22.22）。ビルドは
`boot.ps1` で EMS を設定せず、`finish_disk.sh` が
`bcd_normalize.py` で BCD を正規化します（旧名 `bcd_disable_ems.py` は
互換エイリアス）。

- `EmsPort`/`EmsBaudRate`（15000022/15000023 など x86 COM1 前提の要素）を
  全オブジェクトから削除
- `bootems`（16000020）と `EmsEnable`（260000b0）を **0** に設定。EMS と
  通常の ConOut が同じ PL011 に書くと、シリアルで
  `WWiinnddoowwss` のように 1 文字おきに二重表示されます（WORKLOG 22.46）
- `nointegritychecks`（16000048）は **1 のまま維持**。削除すると
  `0xc0000428` で停止します
- `graphicsmodedisabled`（16000046）と `bootuxdisabled`（1600006c）は 1 の
  まま（テキストコンソールで起動）
- 診断用の `bootlog`（26000090）と `sos`（26000091）は削除

Windows の復旧は RDP / WinRM で行ってください。
