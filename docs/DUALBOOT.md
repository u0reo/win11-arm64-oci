# Ubuntu を残して Windows と共存する（設計）

> 状態: **設計のみ。`--keep-ubuntu` は未実装です。**
> 実ディスクで試す前に、必ずブートボリュームのバックアップを取ってください。

Windows 11 を同じブートボリュームに入れ、**Windows Boot Manager のメニューから
Ubuntu を選べる**ようにする案です。Ubuntu の GRUB を先に起動するのではなく、
Windows Boot Manager が Ubuntu の GRUB（EFI アプリ）を chainload します。

## なぜ可能か

- Windows Boot Manager は BCD の `BOOTAPP` エントリで任意の EFI アプリを
  起動できます。Ubuntu 側の `\EFI\ubuntu\grubaa64.efi` を指定します
- OCI のファームウェアは ESP の `\EFI\BOOT\BOOTAA64.EFI` を起動します。
  `bcdboot` はここに Windows Boot Manager を置くので、既定は Windows になります
- Secure Boot が無効なら `grubaa64.efi` を直接 chainload できます。
  有効な場合は `shimaa64.efi` を指定してください

## パーティション案（100 GB）

| # | 内容 | サイズ | 扱い |
|---|---|---|---|
| 1 | ESP (FAT32) | 512 MB | **既存を保持** |
| 2 | Ubuntu root (ext4) | 約 49 GB | **既存を保持** |
| 3 | Windows (NTFS) | 50 GB | 新規作成 |
| 4 | 共有データ (exFAT/NTFS) | 任意 | 任意 |

`host_apply.sh` の通常モードは `sgdisk --zap-all` で全消しします。
共存モードでは ESP と Ubuntu root を残し、**未割り当て領域に p3 を作る**
必要があります。

### 未割り当て領域をどう作るか

一番安全なのは、**最初から growpart を無効にして起動する**方法です。

OCI の Ubuntu イメージは、ブートボリュームを大きくすると cloud-init の
`growpart` が root をディスク全体まで広げます。これを止めれば、イメージ
既定の約 50 GB の root と、残り約 50 GB の未割り当て領域が残ります。

```yaml
#cloud-config
growpart:
  mode: off
```

100 GB で起動し、この user-data を渡しておけば、あとから live 環境で
p3 を 50 GB で作るだけです。**実行中の root を縮小する必要がありません。**

すでに root が 100 GB まで拡張済みの場合は、live 環境で
`e2fsck -f` → `resize2fs` → `parted resizepart` の順に縮小します。
PARTUUID が変わると `/etc/fstab` や GRUB が壊れるため、`sgdisk -d` +
`-n` ではなく `parted resizepart` を使います（要バックアップ）。

## 手順

```text
1. A を 100 GB で作成し、growpart を無効にする
2. A に Ubuntu の live ISO と Windows ISO を置く
   - live ISO: /boot/iso/ubuntu-26.04-live-server-arm64.iso
   - Windows ISO: /var/tmp/Win11_ARM64_26H2.iso
3. GRUB の loopback + toram で live Ubuntu を起動
4. live 環境で未割り当て領域に p3 を作り、NTFS でフォーマット
5. Windows ISO を p2（Ubuntu root）から read-only でマウントして
   wimlib-imagex apply
6. WinPE で bcdboot を既存 ESP に対して実行
7. BCD に Ubuntu の BOOTAPP エントリを追加
8. 再起動 → Windows Boot Manager のメニューから Windows / Ubuntu
```

### 4. パーティション作成

```bash
# 未割り当て領域の開始セクタを確認
sudo sgdisk -p /dev/sda

# 例: 空き領域の先頭から 50 GB の p3 を作る
sudo sgdisk -n 3:0:+50G -t 3:0700 -c 3:Windows /dev/sda
sudo partprobe /dev/sda
sudo mkfs.ntfs -f -F -L Windows /dev/sda3
```

ESP と Ubuntu root には触れません。`host_apply.sh` に
`KEEP_UBUNTU=1` を渡したときは、この「p3 だけを作る」経路にします。

### 6. bcdboot（WinPE 内）

```cmd
bcdboot C:\Windows /s S: /f UEFI
```

`S:` は既存 ESP のドライブレターです。`bcdboot` は
`\EFI\Microsoft\Boot\` と `\EFI\BOOT\BOOTAA64.EFI` を更新しますが、
`\EFI\ubuntu\` は消しません。

### 7. BCD に Ubuntu を追加（WinPE 内・要検証）

```cmd
bcdedit /store S:\EFI\Microsoft\Boot\BCD /create /d "Ubuntu" /application bootapp
rem 表示された GUID を {GUID} として使う
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {GUID} device partition=S:
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {GUID} path \EFI\ubuntu\grubaa64.efi
bcdedit /store S:\EFI\Microsoft\Boot\BCD /displayorder {GUID} /addlast
```

`device` は `partition=S:` で通らない場合、
`partition=\Device\HarddiskVolume1` や ESP のボリューム GUID を試します。
Secure Boot 有効時は `path` を `\EFI\ubuntu\shimaa64.efi` にします。

## メモリ

Windows ISO は **Ubuntu root（p2）に置いたまま** read-only でマウントするので、
RAM に載りません。

| 用途 | 目安 |
|---|---|
| live ISO（`toram`） | 2.5 GB |
| live 環境の書き込み層 | 2〜3 GB |
| QEMU ゲスト（`MEM=8192`） | 8 GB |
| ページキャッシュ | 残り |

合計 13〜14 GB。24 GB で余裕があります。

## リスク

- **ESP の空き容量**: Windows のブートファイル（約 30 MB）と Ubuntu の
  GRUB（約 15 MB）が同居できるか。Ubuntu の ESP が 100 MB しかない場合は
  `bcdboot` が失敗する可能性があります
- **PARTUUID の変化**: root を縮小すると `/etc/fstab` の `PARTUUID=` が
  壊れることがあります。`parted resizepart` を使い、事前にバックアップ
- **Windows Update**: 大型更新でブート順や ESP が書き換わる可能性
- **BCD の BOOTAPP**: コマンドは要検証。最悪の場合は OCI のシリアル
  コンソールから GRUB を直接起動して復旧します
- **Secure Boot**: 有効なら shim 経由。無効なら grub 直接

## 実装に必要な変更

1. `pipeline/host_apply.sh`: `KEEP_UBUNTU=1` で「p3 だけ作成」経路
2. `pipeline/manual_finish.cmd`: ESP を既存のものから探す（ラベル依存を外す）
3. `pipeline/manual_finish.cmd`: `bcdedit` で Ubuntu エントリを追加
4. `scripts/direct-run.sh`: `--keep-ubuntu` と未割り当て領域の検査
5. `scripts/preflight.sh`: ESP の空き容量チェック

まずは `growpart: off` で 100 GB の A を作り、live 環境で
`sgdisk -p` と `df -h /boot/efi` を確認するところから始めてください。
