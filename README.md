# win11-arm64-oci

Windows 11 ARM64 を **Oracle Cloud Infrastructure の Ampere A1** でネイティブ起動し、
RDP / WinRM で操作できる状態まで自動構築するためのスクリプト集です。

検証済み: **Windows 11 26H2 Pro (ARM64)** / QEMU `virt` / virtio-scsi + netkvm。

> このリポジトリには **ISO も qcow2 も含まれません**。
> Windows の ISO は各自で用意してください。完成イメージの再配布は
> Microsoft の EULA に反するため行いません。

OCI の Ubuntu を一時的なビルド機にし、ブートボリュームの中身を Windows に
置き換えます。`build.sh` が `install.wim` の適用、WinPE でのドライバ追加と
`bcdboot`、OOBE、RDP / WinRM の有効化、署名済み `bootmgfw.efi` の検証までを
自動で行います（内部の流れは [docs/BUILD.md](docs/BUILD.md)）。

## 全体の流れ

| ステージ | やること | 詳細 |
|---|---|---|
| [ステージ1](#ステージ1-準備) | 前提を確認し、Ubuntu live ISO を入手する | — |
| [ステージ2-A](#ステージ2-a-ボリュームを付け替える) | 2 インスタンスでビルドする（付け替え） | [docs/OCI.md](docs/OCI.md#ステージ2-a-ボリュームを付け替える) |
| [ステージ2-B](#ステージ2-b-live-を-toram-で起動する) | 1 インスタンスで完結する（live `toram`） | [docs/OCI.md](docs/OCI.md#ステージ2-b-live-を-toram-で起動する) |
| [ステージ3](#ステージ3-windows-iso-と-virtio-win) | Windows ISO と virtio-win を配置する | [docs/OCI.md](docs/OCI.md#iso-の置き場所) |
| [ステージ4](#ステージ4-ビルド) | `build.sh` を実行する | [docs/BUILD.md](docs/BUILD.md) |
| [ステージ5](#ステージ5-起動と接続) | 起動して RDP / WinRM で接続する | — |
| [ステージ6](#ステージ6-後片付け) | 停止・バックアップ・後片付け | [docs/OCI.md](docs/OCI.md#ステージ6-後片付け) |
| [付録A](#付録a-github-actions-で回す) | GitHub Actions で回す | [docs/GITHUB.md](docs/GITHUB.md) |
| [付録B](#付録b-ローカルで-qcow2-を作る) | ローカルで qcow2 を作る | [docs/BUILD.md](docs/BUILD.md) |

`scripts/` の入口は次の 5 つです。内部部品は `internal/` にあり、直接は叩きません。

| スクリプト | 用途 | 使うステージ |
|---|---|---|
| `scripts/setup.sh` | ホストの準備と検査（全パッケージ。冪等） | 2-A |
| `scripts/setup-live.sh` | RAM ビルド用の最小準備（冪等） | 2-B（live 内） |
| `scripts/build.sh` | ディスクを作る唯一の入口 | 4 |
| `scripts/prepare.sh` | live ISO を GRUB に登録し、自動起動を設定する | 2-B（素の Ubuntu） |
| `scripts/prepare-live.sh` | 復旧 Ubuntu から live を起動する（ESP の GRUB を直接書く） | 2-B（復旧 Ubuntu） |

## ステージ1 準備

### 前提

| 項目 | 要件 |
|---|---|
| ホスト | Linux x86_64 または ARM64。直接書き込みなら一時ファイル用に空き 8GB、qcow2 を作るなら 80GB 以上 |
| CPU/RAM | 4 コア / 16GB 以上を推奨（TCG は遅い） |
| KVM | x86 ホストで ARM64 ゲストを動かす場合、KVM は使えない（TCG） |
| Windows ISO | Windows 11 ARM64 26H2（各自で用意） |
| virtio-win | ARM64 ドライバ入り ISO / RPM、または展開済みディレクトリ |
| sudo | `qemu-nbd` / `mount` のため NOPASSWD を想定 |

OCI の無料枠とボリューム容量は
[docs/OCI.md](docs/OCI.md#コスト) を参照してください。

パッケージの導入とホスト検査は、ステージ2でビルド機にログインしてから
`setup.sh`（2-A）または `setup-live.sh`（2-B の live セッション）で行います。

### Ubuntu live ISO を入手する

ステージ2-A では不要です。ステージ2-B では、Ubuntu Server の live ISO を
1 枚だけブートボリュームに置きます。

```bash
sudo mkdir -p /srv/iso
cd /srv/iso

# arm64 を選ぶ。live もビルド環境もこの 1 枚で足りる。
# ARM64 のイメージは releases.ubuntu.com ではなく cdimage.ubuntu.com に
# ある（releases.ubuntu.com/26.04/ は amd64 のみ）。
BASE=https://cdimage.ubuntu.com/releases/26.04/release

# SHA256SUMS から最新の live-server arm64 を選ぶ（26.04.1 など）
curl -fsSLO "$BASE/SHA256SUMS"
ISO=$(awk '/live-server-arm64\.iso$/ {print $2}' SHA256SUMS |
  sed 's/^\*//' | sort -V | tail -1)
echo "$ISO"
curl -fsSLO "$BASE/$ISO"

grep -F " *$ISO" SHA256SUMS | sha256sum -c -
```

`+largemem` 付きの ISO は大きなメモリ向けなので、通常は選ばれません。
ファイル名を固定したい場合は、上の `echo "$ISO"` で表示された名前を
そのまま使ってください（この記事の例では
`ubuntu-26.04.1-live-server-arm64.iso`）。

`--fresh-ubuntu` の 4 GiB Ubuntu は、ビルドに使う live ISO 内の minimal
rootfs から作ります。ISO が見つからない場合だけ `debootstrap` で
ネットワークから取得します。別途 minimal イメージをダウンロードする
必要はありません（[docs/DUALBOOT.md](docs/DUALBOOT.md)）。

## ステージ2 ビルド環境を作る

次のどちらか一方を選びます。作られるディスクは同じです。

- **ステージ2-A**: ターゲットとビルダーの 2 インスタンス。既存の Ubuntu を
  ビルド機にでき、live ISO も `toram` も不要です。
- **ステージ2-B**: 1 インスタンスで完結。live ISO を `toram` で RAM に載せます。

### ビルド機のパッケージ

どちらの方法でも、ビルド機にログインしたら最初に `setup.sh` を実行します
（冪等）。パッケージの導入とホスト検査をまとめて行います。

```bash
sudo ./scripts/setup.sh          # 入れてから検査（直接書き込みが既定）
./scripts/setup.sh --check       # 検査だけ（何も変更しない）

# 書き込み先まで確認する（サイズ・ルートデバイスかどうか）
./scripts/setup.sh --check --disk /dev/sdb

# qcow2 を作る場合は 80GB 必要なので、モードを指定する
./scripts/setup.sh --check --image build/win11-arm64.qcow2
```

既定は `build.sh --disk` の直接書き込みです。この場合、`build/` に置くのは
`boot.wim`・`bootfat.img`・OEMDRV などの一時ファイルだけなので、8GB で
足ります。qcow2 はディスク全体を 1 ファイルに保持するため 80GB 必要です。
一時ファイルを別の場所に置くときは `--build-dir`、判定を変えたいときは
`--min-free-gb` を使います。

live (`toram`) では `setup.sh` / `setup-live.sh` が `/dev/shm` を RAM の 100%
（`SHM_SIZE`、または `--shm-size` で変更）に再マウントします。staging は
`/dev/shm/build` が既定で、Windows ISO と virtio-win は `/dev/shm/iso`
に置きます。`--check` は何も変更しません。

**RAM ビルドなら `setup-live.sh` だけで十分です。** `setup.sh` は CI や
イメージ配布用の上位集合で、`rclone` / `age` / `jq` / `shellcheck` /
`libxml2-utils` / `debootstrap` など `build.sh` が使わないパッケージも
入ります。

```bash
sudo ./scripts/setup-live.sh          # 最小構成を入れて preflight
./scripts/setup-live.sh --check       # 検査だけ
```

最小構成は `qemu-system-arm` / `qemu-utils` / `qemu-efi-aarch64` /
`wimtools` / `xorriso` / `gdisk` / `dosfstools` / `ntfs-3g` / `mtools` /
`parted` / `zstd` / `python3-hivex` / `python3-pefile` /
`python3-winrm` / `python3-requests-ntlm` / `curl` です。
WinRM は完了判定とシャットダウンに必須なので必ず入ります。
`rpm2cpio` / `cpio`（RPM 版 virtio-win）は任意なので入りません。
必要なら別途 `apt-get install` してください。

どちらのスクリプトも、インストーラが残した `file:///cdrom` の apt ソースを
（`cdrom.sources` → `cdrom.sources.disabled` にリネームして）無効化してから
`apt-get update` します。復旧 Ubuntu では `/cdrom` が無いため、これを
しないと `E: The repository 'file:/cdrom ... Release' does not have a Release file.`
で停止します。

### ステージ2-A ボリュームを付け替える

```text
1. ターゲット A を作る（Ubuntu 26.04 minimal aarch64、ブート 50 GB）
2. A を停止し、ブートボリュームを切り離す
3. ビルダー B を作る（Ubuntu、ブート 50 GB、同じ AD）
4. A のブートボリュームを B にデータボリュームとして接続する
5. B でビルドする（ステージ3〜4）
6. B を停止し、ボリュームを切り離して A のブートボリュームとして再接続
7. A を起動すると Windows が立ち上がる
```

```bash
# B にログイン
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/setup.sh

# 書き込み先デバイスを確認する。OCI のデータボリュームは /dev/sdb とは
# 限らず、/dev/oracleoci/oraclevdb のこともある
lsblk -o NAME,SIZE,MODEL,SERIAL
```

OCI CLI での付け替え、容量の考え方、無料枠は
[docs/OCI.md](docs/OCI.md#ステージ2-a-ボリュームを付け替える) を参照してください。

### ステージ2-B live を toram で起動する

1 インスタンスで完結します。live ISO を GRUB に登録し、`toram` で RAM に
載せてから `/dev/sda` を上書きします。**起動元の Ubuntu がどちらかで手順が
異なります。**

#### A. OCI の標準 Ubuntu イメージ（素の GRUB）から起動する

`update-grub` と `grub-reboot` がある場合は、従来どおり `prepare.sh` だけで
登録できます。

```bash
# 既存の Ubuntu にログイン
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci

# live ISO を GRUB に登録する
# --ssh   は ESP を CIDATA にして、live 起動時から SSH できるようにする
# --once  は次の 1 回だけ live を自動起動する（--default なら毎回）
sudo ./scripts/prepare.sh \
  /srv/iso/ubuntu-26.04.1-live-server-arm64.iso --write --ssh --once

sudo reboot
```

#### B. このプロジェクトが作った復旧 Ubuntu から起動する

この環境の GRUB は `\EFI\ubuntu\grub.cfg` を直接読み、
`update-grub` / `grub-reboot` / `grub-common` は入っていません。
**A の `prepare.sh --write --once` だけでは live は起動しません。**
`prepare-live.sh` が cloud-init の seed と CIDATA ラベルを用意し、
メニューは `write_grub_menu.py` で ESP の grub.cfg に直接書き込みます。

```bash
# 事前に dosfstools が必要: sudo ./scripts/setup-live.sh
sudo ./scripts/prepare-live.sh /srv/iso/ubuntu-26.04.1-live-server-arm64.iso
sudo reboot
```

ルートデバイスは `findmnt -no SOURCE /` から自動検出します。ISO は
`/srv/iso` などの実ファイルシステムに置いてください（tmpfs は不可）。
`--timeout 秒数` でメニュー時間、`--no-first-boot` で「次回だけ」を
外せます。`next_entry=Ubuntu live (toram)` は 1 回だけ消費され、
その後は Windows 11 が既定に戻ります。

A の場合、`--once` / `--default` はメニューの番号ではなく、エントリの id
（`win11-live-toram`）で live を指定するので、`update-grub` でメニューの
順番が変わっても壊れません。`--once` は次の 1 回だけなので、live の起動に
失敗しても電源を入れ直せば Ubuntu に戻ります。最初は `--once` で確認し、
毎回 live で起動したいなら `--default` にしてください。

A で `--once` / `--default` を付けない場合は、GRUB のメニューで
`Ubuntu live (toram)` を選びます（`GRUB_TIMEOUT=0` だとメニューが出ないので、
その場合はどちらかを付けてください）。B では常に 30 秒のメニューが出ます。

`--ssh` を使うには ESP が `/boot/efi` にマウントされている必要があります。
`findmnt /boot/efi` で確認し、無ければ `lsblk -f` で vfat の ESP を探して
`sudo mount /dev/sda15 /boot/efi` のようにマウントしてから実行してください。

A の場合、`--default` の戻し方は `prepare.sh` が表示します。変更前の
`/etc/default/grub` は `/etc/default/grub.win11-arm64-oci.bak` にあります。

live の root は RAM 上なので、リポジトリをもう一度 clone してから
`setup-live.sh` を実行します（全パッケージ版の `setup.sh` でも動きますが、
RAM 上では不要なパッケージまで入ります）。

```bash
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/setup-live.sh
```

`setup-live.sh` は live (`toram`) を検出すると `/dev/shm` を RAM の 100% に
再マウントし、`/dev/shm/iso` と `/dev/shm/build` を作ります。`--ssh` で
起動した場合は cloud-init も起動時に同じ設定を行います。

RAM の内訳、`--ssh` の仕組み、`toram` の注意点は
[docs/OCI.md](docs/OCI.md#ステージ2-b-live-を-toram-で起動する) を参照してください。

## ステージ3 Windows ISO と virtio-win

ビルド機（ステージ2-A なら B、ステージ2-B なら live）に、Windows 11 ARM64 の
ISO と virtio-win を置きます。

live (`toram`) では `/dev/shm/iso`（RAM）が既定で推奨です。

```bash
mkdir -p /dev/shm/iso
cd /dev/shm/iso

# virtio-win（ARM64 ドライバ入り）。ISO か RPM のどちらか一方でよい。
# RPM は ISO の約 1/3（283 MiB）で、マウントせずに読める。
curl -LO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
curl -LO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302-1.noarch.rpm

# Windows 11 ARM64 ISO は Microsoft から取得するか、scp / rclone で転送
# scp Win11_ARM64_26H2.iso ubuntu@<host>:/dev/shm/iso/
```

`--virtio` は拡張子で ISO と RPM を判定します。RPM を渡すと
`internal/stage-drivers.sh` が `rpm2cpio` + `cpio` で
`by-driver/*/w11/ARM64` だけを取り出します。この 2 つは最小構成の
`setup-live.sh` には含まれないので、RPM を使う場合は
`sudo apt-get install -y rpm2cpio cpio` を追加してください（ISO なら不要）。
loop mount しないので、`umount` の後始末も要りません。

```bash
sudo ./scripts/build.sh --disk /dev/sdb \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win-0.1.302-1.noarch.rpm --yes
```

一度ビルドした後の `build/drivers/` を保存しておけば、次回は `--drivers`
で ISO も RPM も不要になります（vioscsi と netkvm だけで数 MB）。

> **言語**: `autounattend.xml` は言語を指定しません。インストール後の表示
> 言語は ISO の `install.wim` の既定（`sources/lang.ini`）に従います。
> 日本語 ISO なら ja-JP、英語 ISO なら en-US です。`wimlib-imagex apply`
> 経路では Setup の言語選択画面は出ません。確認方法と例は
> [docs/BUILD.md の「言語」](docs/BUILD.md#言語) を参照してください。

ISO が書き込み先ディスク上にある場合、`build.sh` は `--yes` の後で
`/dev/shm/iso`（RAM）にコピーしてから書き込みます。最初から `/dev/shm/iso`
や別ボリュームにあるならコピーは起きません。

live (`toram`) の既定は `/dev/shm/iso` です。再起動をまたいで再試行したい
場合だけ、10 GB のデータボリュームに置きます。置き場所の判断と、
クラウドストレージを一時的にマウントする方法は
[docs/OCI.md](docs/OCI.md#iso-の置き場所) を参照してください。

## ステージ4 ビルド

```bash
# ステージ2-A: A のブートボリュームへ書く
sudo ./scripts/build.sh --disk /dev/sdb \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win.iso --yes

# ステージ2-B: live から /dev/sda を書き換える
sudo ./scripts/build.sh --disk /dev/sda \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win.iso --mem 6144 --yes
```

`--yes` を付けるまで実際には書き込みません。`--yes` を付けると、対象デバイスの
model / serial / size を表示し、ISO のコピーとマウント解除を行ってから
書き込みを始めます。

ARM64 の Windows は EMS/SAC に対応していません。`bcdedit /ems` や
`/emssettings` は成功したように見えますが、実際には BCD へ x86 COM1 前提の
要素を書き込み、OCI では bootmgr の無音ハングやシリアルの二重表示を
引き起こします。ビルドは EMS を設定せず、`finish_disk.sh` が BCD を正規化
します。**Windows 側のシリアル復旧はできません**。Windows の復旧は
RDP / WinRM を使ってください。

`--boot-menu 秒数` は、Windows のみの構成では Windows Boot Manager の
メニュー表示時間を、`--fresh-ubuntu` / `--reuse-ubuntu`
では GRUB のメニュー表示時間を指定します。既定は **1 秒**で、表示中に
何かキーを押せばカウントダウンは止まります。`--boot-menu 0` でメニューを
消せます（Ubuntu を残す構成では復旧エントリを選べなくなるため不可）。

```bash
# 例: 5 秒に伸ばす（既定は 1 秒）
sudo ./scripts/build.sh --boot-menu 5 --disk /dev/sdb \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win.iso --yes
```

空のディスクから、ESP ごと新しく作って Windows と 4 GiB の Ubuntu 復旧環境を
入れる場合は `--fresh-ubuntu` を足します。既存の ESP は使わず、
`p1=ESP (100 MiB)`、`p2=Ubuntu (4 GiB)`、`p3=Windows (残り)` を新規作成します。
`--winre-partition` を足すと、Windows の回復用に `p4`（NTFS、既定 1 GiB）も
最初から作ります。この場合は約 45 GiB（Windows 40 GiB + Ubuntu 4 GiB +
WinRE 1 GiB）以上のディスクが必要です。

```bash
sudo ./scripts/build.sh --fresh-ubuntu --ubuntu-size 4G --disk /dev/sdb \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win.iso --yes
```

復旧 Ubuntu は、ビルドを実行している Ubuntu（live `toram` なら live 環境）の
`/etc/netplan/*.yaml` と `authorized_keys` だけを引き継ぎます。パスワード
ハッシュ、ユーザーアカウント、SSH ホスト鍵、`sudoers` はコピーしません。
`ubuntu` ユーザーを新規作成し、ランダムなパスワードをビルドログのステップ6に
表示します。`--ubuntu-size` は `--fresh-ubuntu` と一緒にだけ使えます。

専用の Windows RE パーティションも作る場合は、`--fresh-ubuntu` に
`--winre-partition` を足します。サイズは `--winre-size 1G` で変更できます
（最小 1 GiB。`Winre.wim` が約 795 MB あるため）。Windows の specialize が
WinRE を `p4` にインストールし、OEM のスクリプトが実際の配置を確認して、
まだ C: にある場合だけ `reagentc` で `p4` へ移します。移動できなかった場合は
C: の WinRE を有効なまま残してビルドを続け、`pipeline/inspect_image.sh` が
実際の配置を表示します。

```bash
sudo ./scripts/build.sh --fresh-ubuntu --winre-partition --disk /dev/sdb \
  --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
  --virtio /dev/shm/iso/virtio-win.iso --yes
```

パーティション構成、起動メニュー、`--reuse-ubuntu` は
[docs/DUALBOOT.md](docs/DUALBOOT.md) を参照してください。

`build.sh` の中で何が起きるか（13 段階、WinPE、QEMU 2 回、手動フォールバック）は
[docs/BUILD.md](docs/BUILD.md) を参照してください。

## ステージ5 起動と接続

- **ステージ2-A**: B を停止し、ボリュームを A のブートボリュームとして
  再接続して A を起動します。
- **ステージ2-B**: live から `sudo reboot` します。

起動後:

- OCI のファームウェアは UEFI です。ESP の `\EFI\BOOT\BOOTAA64.EFI` から起動します
- ネットワークは DHCP で VNIC の IP を取ります
- RDP 3389 / WinRM 5985 が開いています（NLA 無効・ファイアウォール無効）
- **OCI エージェントは入っていない**ので、コンソールのパスワードリセットは
  使えません。ビルド時のパスワードで入ってください
- `--fresh-ubuntu` / `--reuse-ubuntu` 構成では、シリアル
  コンソールと VNC に GRUB のメニュー（Windows 11 が既定、Ubuntu (recovery)
  を選択可）が 1 秒だけ表示されます（`--boot-menu 秒数` で変更、`0` で非表示）。
  Ubuntu は UEFI の BootMenu と GRUB から選びます。Windows Boot Manager の
  OS メニューは Windows 11 だけを 1 秒表示し、Ubuntu は出しません
  （ARM64 の BootMgr は bootapp から EFI アプリを起動できないため）。
  Windows のみの構成では Windows Boot Manager のメニューが表示されます
- ARM64 の Windows は EMS/SAC に対応していないため、Windows 側のシリアル
  復旧はできません。Windows の復旧は RDP / WinRM を使ってください

### 資格情報

| 項目 | 既定値 | 上書き |
|---|---|---|
| ユーザー名 | `User` | `WIN_USERNAME` |
| パスワード | `oci-a1` | `WIN_PASSWORD` |
| PC 名 | `OCI-WIN` | `COMPUTER_NAME` |
| タイムゾーン | `Tokyo Standard Time` | `TIMEZONE` |

優先順位は **環境変数 > 組み込み既定値** です。設定ファイルはありません。
GitHub Actions では Secrets / Variables が環境変数として渡されます。

対話的に決める場合は `read` を使うと、パスワードがシェル履歴に残りません。

```bash
read -rp 'ユーザー名 [User]: ' WIN_USERNAME
read -rsp 'パスワード [oci-a1]: ' WIN_PASSWORD; echo
read -rp 'PC 名 [OCI-WIN]: ' COMPUTER_NAME
read -rp 'タイムゾーン [Tokyo Standard Time]: ' TIMEZONE

# 空欄なら既定値を使う
: "${WIN_USERNAME:=User}"
: "${WIN_PASSWORD:=oci-a1}"
: "${COMPUTER_NAME:=OCI-WIN}"
: "${TIMEZONE:=Tokyo Standard Time}"
export WIN_USERNAME WIN_PASSWORD COMPUTER_NAME TIMEZONE

# 解決後の値を確認（ファイルは書かない）
python3 internal/render.py --check

# ビルド（sudo には明示的に値を渡す）
sudo env WIN_USERNAME="$WIN_USERNAME" WIN_PASSWORD="$WIN_PASSWORD" \
  COMPUTER_NAME="$COMPUTER_NAME" TIMEZONE="$TIMEZONE" \
  ./scripts/build.sh --disk /dev/sda ...
```

`sudo VAR=value command`（または `sudo env VAR=value command`）は、
`sudo -E` と違って sudoers の `env_reset` 設定に左右されず、そのコマンドに
だけ値を渡せます。`scripts/build.sh` は内部で `internal/build-image.sh` を
同じプロセスで呼ぶので、この値が `render.py` まで届きます。

> **警告**: `oci-a1` は意図的に弱い既定値です。パスワードは完成イメージに
> 平文で埋め込まれます。Secrets は「リポジトリに出さない」だけで、
> イメージを守るものではありません。RDP (3389) と WinRM (5985) を
> インターネットへ直接公開しないでください。VPN / Tailscale / OCI の
> プライベートサブネット内でのみ使用してください。

### セキュリティ

3389 を `0.0.0.0/0` に開けないでください。セキュリティリストか NSG で、
自分の IP か VPN に限定します。方針は [SECURITY.md](SECURITY.md) を参照して
ください。

## ステージ6 後片付け

- **ステージ2-A**: ビルダー B を停止します。B のブートボリュームを残すと
  その分だけ課金対象になります。
- **ステージ2-B**: `prepare.sh --ssh` / `prepare-live.sh` が ESP のラベルを
  `CIDATA` に変えています。表示された `fatlabel` コマンドで元に戻します
  （例: `sudo fatlabel /dev/sda1 SYSTEM`）。
- ビルド前のバックアップ、失敗時の復旧、コストの内訳は
  [docs/OCI.md](docs/OCI.md#ステージ6-後片付け) を参照してください。

## 付録A GitHub Actions で回す

| ワークフロー | ランナー | 用途 |
|---|---|---|
| `ci.yml` | `ubuntu-latest` | shellcheck / XML / render / 秘密情報チェック |
| `build-image.yml` | **self-hosted** | イメージ生成（qcow2 またはブロックデバイス） |

一発ビルドなら runner を登録せず、A1 上で `scripts/build.sh` を直接実行する
方が簡単です（ステージ4）。

`build-image.yml` は **GitHub ホストランナーでは動きません**。

- `/dev/kvm` がない
- 空きディスクが約 14GB（qcow2 は約 28GB）
- ジョブ上限 6 時間
- ISO を Artifact / Release に置けない（Release は 1 ファイル 2GB）

リポジトリ設定、Secrets / Variables、self-hosted runner の準備は
[docs/GITHUB.md](docs/GITHUB.md) を参照してください。

## 付録B ローカルで qcow2 を作る

```bash
sudo ./scripts/build.sh --image build/win11-arm64.qcow2 \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso --yes
```

ローカルで起動して確認する方法は [docs/BUILD.md](docs/BUILD.md) を参照して
ください。

## リポジトリ構成

```text
autounattend/   無人インストール XML テンプレート
oem/            初回起動時の PowerShell / CMD
scripts/        入口 5 つ: setup.sh / setup-live.sh / build.sh / prepare.sh / prepare-live.sh
internal/       内部部品: build-image, live, apt, render, preflight ...
pipeline/       ディスク構築の部品: wimlib apply, WinPE, QEMU, 検査
docs/           OCI / GITHUB / BUILD / DUALBOOT / SCRATCH / WORKLOG
```

## ドキュメント

- [docs/OCI.md](docs/OCI.md) — OCI 固有の判断、付け替え、データボリューム、コスト、バックアップ
- [docs/GITHUB.md](docs/GITHUB.md) — GitHub リポジトリ、Secrets、self-hosted runner
- [docs/BUILD.md](docs/BUILD.md) — パイプラインの各段階と手動フォールバック
- [docs/DUALBOOT.md](docs/DUALBOOT.md) — Ubuntu 復旧環境を残す場合の詳細
- [docs/SCRATCH.md](docs/SCRATCH.md) — 環境を消す前の確認、やり直しの入力
- [docs/WORKLOG.md](docs/WORKLOG.md) — 26H2 構築までの作業ログ（サニタイズ済み）
- [SECURITY.md](SECURITY.md) — セキュリティ方針

## ライセンス

スクリプトとドキュメントは [MIT](LICENSE)。
Windows、virtio-win、Microsoft の ISO はそれぞれのライセンスに従います。
