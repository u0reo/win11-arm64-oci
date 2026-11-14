# win11-arm64-oci

Windows 11 ARM64 を **Oracle Cloud Infrastructure の Ampere A1** でネイティブ起動し、
RDP / WinRM で操作できる状態まで自動構築するためのスクリプト集です。

検証済み: **Windows 11 26H2 Pro (ARM64)** / QEMU `virt` / virtio-scsi + netkvm。

> このリポジトリには **ISO も qcow2 も含まれません**。
> Windows の ISO は各自で用意してください。完成イメージの再配布は
> Microsoft の EULA に反するため行いません。

## 何をするか

1. Windows 11 ARM64 ISO の `install.wim` をホスト側でディスクに適用（`wimlib-imagex`）
2. WinPE を自動起動し、virtio ドライバ追加と `bcdboot` を実行
3. 初回起動で OOBE・OEM スクリプトを無人実行
4. RDP / WinRM を有効化し、準備完了を確認
5. ESP の `bootmgfw.efi` に OCI A1 向け AnyPages パッチを適用
6. 検査（qcow2 にしたい場合のみ任意で圧縮）

## 使い方は 3 つだけ

`scripts/` にあるのは入口 3 つです。内部部品は `internal/` にあり、直接は叩きません。

| やること | コマンド | いつ |
|---|---|---|
| ホストの準備と検査 | `sudo ./scripts/setup.sh` | 最初に 1 回（冪等） |
| ディスクを作る | `sudo ./scripts/build.sh --disk /dev/sdb --iso ... --yes` | ビルドするとき |
| ISO を GRUB に登録 | `sudo ./scripts/prepare.sh <iso> --write` | OCI の Ubuntu から方法 B を始めるとき |

```text
setup.sh ──> build.sh ──> 完成したディスク
                │
                ├─ --image FILE.qcow2    qcow2 を作る（ローカル検証）
                └─ --keep-ubuntu         Ubuntu 復旧環境を同居させる
```

`build.sh` は `--disk`（ブロックデバイス）か `--image`（qcow2）のどちらかを
必ず取ります。`--yes` を付けるまで実際には書き込みません。

OCI の Ubuntu から始める場合、`prepare.sh` が live ISO を GRUB に登録します。

```bash
# live を RAM に載せて起動するエントリを登録する。
# --ssh を付けると ESP を CIDATA にして、live 起動時から SSH できる。
sudo ./scripts/prepare.sh /srv/iso/ubuntu-24.04.5-live-server-arm64.iso \
  --write --ssh
```

再起動して GRUB の `Ubuntu live (toram)` を選び、live 環境で
Windows ISO と virtio-win を用意して `build.sh` を実行します
（[docs/OCI.md](docs/OCI.md#方法-b-ライブ-cd-を-ram-に載せて-sda-を書き換える)）。
書き込み先ディスク上に残っている ISO は、`--yes` の後で自動的に
`/dev/shm` にコピーされます。

すでに p2 に小さな Ubuntu が入っている場合だけ `--reuse-ubuntu` も使えます
（上級者向け。[docs/DUALBOOT.md](docs/DUALBOOT.md)）。

## ISO の入手

### 先に用意するもの（Ubuntu live だけ）

方法 B では、まず Ubuntu Server の live ISO を 1 枚だけブートボリュームに
置きます。これがビルド環境になります。

```bash
sudo mkdir -p /srv/iso
cd /srv/iso

# arm64 を選ぶ。live もビルド環境もこの 1 枚で足りる
VER=24.04.5   # releases.ubuntu.com/24.04/ で最新を確認
curl -LO "https://releases.ubuntu.com/24.04/ubuntu-${VER}-live-server-arm64.iso"

curl -sLO https://releases.ubuntu.com/24.04/SHA256SUMS
grep live-server-arm64 SHA256SUMS | sha256sum -c -
```

`--keep-ubuntu` の 4 GiB Ubuntu は、`debootstrap` でネットワークから作ります。
別途 minimal イメージをダウンロードする必要はありません。

### live 環境で用意するもの（Windows / virtio-win）

Windows 11 ARM64 の ISO と virtio-win は、**live に切り替わってから**
用意します。`/dev/shm`（RAM）に置けば、これから消すディスクに依存しません。

```bash
cd /dev/shm

# virtio-win（ARM64 ドライバ入り）
curl -LO https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

# Windows 11 ARM64 ISO は Microsoft から取得するか、scp / rclone で転送
# scp Win11_ARM64_26H2.iso ubuntu@<live-host>:/dev/shm/
```

> **言語**: `autounattend.xml` は言語を指定しません。インストール後の表示
> 言語は ISO の `install.wim` の既定（`sources/lang.ini`）に従います。
> 日本語 ISO なら ja-JP、英語 ISO なら en-US です。`wimlib-imagex apply`
> 経路では Setup の言語選択画面は出ません。

ISO が書き込み先ディスク（`/dev/sda`）上にある場合、`build.sh` は
`--yes` の後で `/dev/shm`（RAM）にコピーしてから書き込みます。最初から
`/dev/shm` や別ボリュームにあるならコピーは起きません。ただし、live ISO
そのものは `toram` で RAM に載っている必要があります。

#### 一時ストレージをマウントする（おすすめ）

Windows ISO（6 GB 前後）と virtio-win（0.7 GB）の置き場だけなら、
無料枠のあるクラウドストレージをマウントするのが手軽です。
**一定期間で消えてもよい**一時用途に向くものを挙げます。

| サービス | 無料枠 | つなぎ方 | メモ |
|---|---|---|---|
| Cloudflare R2 | 10 GB | S3（rclone / s3fs） | 下り転送が無料。ISO の置き場に最適 |
| Backblaze B2 | 10 GB | S3 / B2（rclone） | 下りは容量の 3 倍/日まで無料 |
| OCI Object Storage | 10 GB 程度（Always Free） | S3 互換（rclone / OCI CLI） | 同一リージョンなら速い |
| pCloud | 10 GB | WebDAV（rclone / davfs2） | 設定が簡単 |
| Koofr | 10 GB | WebDAV | 同上 |
| InfiniCLOUD | 20 GB | WebDAV | 枠が大きい |
| Google Drive | 15 GB | rclone | 手元にあることが多い |
| MEGA | 20 GB | rclone | 枠が大きい |

R2 / B2 / OCI は S3 互換なので、rclone の `s3` バックエンド 1 つで扱えます。

```bash
# 例: R2 を rclone でマウント（ランダム読み込みに備えてキャッシュする）
rclone config            # s3 プロバイダで R2 を登録
rclone mount r2:win11-iso /mnt/iso --vfs-cache-mode full --daemon

# 例: WebDAV を davfs2 でマウント
sudo apt-get install -y davfs2
sudo mkdir -p /mnt/iso
sudo mount -t davfs https://webdav.pcloud.com /mnt/iso
```

注意点:

- **GRUB は FUSE マウントを読めません。** `prepare.sh` に渡す Ubuntu live ISO は
  実ブロックデバイス上のファイルシステム（`/srv/iso` など）に置きます。
  クラウドは live 起動後の Windows ISO / virtio-win 用です。
- QEMU は ISO をシークしながら読むため、WAN 越しの直接マウントは遅いです。
  `/dev/shm`（RAM）かデータボリュームにコピーしてからビルドします。
- ビルド中にアンマウントすると QEMU が止まります。コピーしてから外します。
- 資格情報は `~/.config/rclone/rclone.conf` や `/etc/davfs2/secrets` に残ります。
  ビルドが終わったら削除してください。
- `file.io` / `0x0.st` / `transfer.sh` のような期限付きファイル置き場は HTTP だけで、
  マウントできません。単発の受け渡しには使えますが、6 GB の ISO には向きません。

## 必要なもの

| 項目 | 要件 |
|---|---|
| ホスト | Linux x86_64 または ARM64。直接書き込みなら空き 20GB、qcow2 を作るなら 100GB 以上 |
| CPU/RAM | 4 コア / 16GB 以上を推奨（TCG は遅い） |
| KVM | x86 ホストで ARM64 ゲストを動かす場合、KVM は使えない（TCG） |
| Windows ISO | Windows 11 ARM64 26H2（各自で用意） |
| virtio-win | ARM64 ドライバ入り ISO または展開済みディレクトリ |
| sudo | `qemu-nbd` / `mount` のため NOPASSWD を想定 |

### パッケージ（Debian/Ubuntu）

```bash
sudo ./scripts/setup.sh
```

手動で入れる場合:

```bash
sudo apt-get install -y \
  qemu-system-arm qemu-utils qemu-efi-aarch64 wimtools \
  libhivex-bin python3-hivex python3-pefile \
  mtools dosfstools ntfs-3g xorriso gdisk zstd \
  curl rclone age jq
```

## OCI A1 でビルド（推奨）

GitHub ホストランナーでは作れません（14 GB SSD / 6 時間 / KVM なし）。
Ampere A1 の Ubuntu を一時的なビルド機にします。

```bash
# 1. ターゲット A（Ubuntu 26.04 minimal aarch64、ブート 50 GB）を作って停止
#    64 GB にすると Windows Update の余裕が増える（50+64=114 GB で無料枠内）
# 2. A のブートボリュームを切り離し、ビルダー B（ブート 50 GB）に
#    データボリュームとして接続
# 3. B にログインして
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/setup.sh

# 4. A のボリュームへ直接書き込む（デバイス名は lsblk で確認。
#    /dev/sdb とは限らず、/dev/oracleoci/oraclevdb のこともある）
sudo ./scripts/build.sh \
  --disk /dev/sdb \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso --yes

# 5. ボリュームを A のブートボリュームとして戻して起動
```

qcow2 も圧縮ファイルも作りません。ビルドが終わればそのボリュームが
Windows ディスクになります。付け替え手順と、1 インスタンスで完結させる
ライブ CD 方式（`toram`）は [docs/OCI.md](docs/OCI.md)。

4 GiB の Ubuntu 復旧環境を残す場合は `--keep-ubuntu` を足します
（Windows Boot Manager のメニューから起動。ネットワークと SSH の設定は
元の Ubuntu から引き継ぎます）。詳細は
[docs/DUALBOOT.md](docs/DUALBOOT.md)。

```bash
sudo ./scripts/build.sh --disk /dev/sdb \
  --iso /srv/iso/Win11_ARM64_26H2.iso --virtio /srv/iso/virtio-win.iso \
  --keep-ubuntu --ubuntu-size 4G --yes
```

ISO が書き込み先ディスクにしかない場合でも、`--yes` の後で自動的に
`/dev/shm` にコピーしてから書き込みます。組み合わせの一覧は
[docs/OCI.md](docs/OCI.md#どの組み合わせが可能か)。

## ローカルでビルド

```bash
sudo ./scripts/build.sh --image build/win11-arm64.qcow2 \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso --yes
```

成果物:

```text
build/win11-arm64.qcow2
```

`PACKAGE=1` を付けたときだけ `build/artifacts/` に zstd 圧縮版と SHA256 を
作ります。ブロックデバイスへ直接書く場合（`DISK=/dev/sdb`）は何も
パッケージしません。

## 既定の資格情報

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

## GitHub Actions

| ワークフロー | ランナー | 用途 |
|---|---|---|
| `ci.yml` | `ubuntu-latest` | shellcheck / XML / render / 秘密情報チェック |
| `build-image.yml` | **self-hosted** | イメージ生成（qcow2 またはブロックデバイス） |

一発ビルドなら runner を登録せず、A1 上で `scripts/build.sh` を直接
実行する方が簡単です（[docs/OCI.md](docs/OCI.md)）。

`build-image.yml` は **GitHub ホストランナーでは動きません**。

- `/dev/kvm` がない
- 空きディスクが約 14GB（qcow2 は約 28GB）
- ジョブ上限 6 時間
- ISO を Artifact / Release に置けない（Release は 1 ファイル 2GB）

セットアップ手順は [docs/SETUP.md](docs/SETUP.md) を参照してください。

## リポジトリ構成

```text
autounattend/   無人インストール XML テンプレート
oem/            初回起動時の PowerShell / CMD
scripts/        入口 3 つ: setup.sh / build.sh / prepare.sh
internal/       内部部品: build-image, render, preflight ...
pipeline/       ディスク構築の部品: wimlib apply, WinPE, QEMU, 検査
docs/           OCI / SETUP / BUILD / WORKLOG
```

## ドキュメント

- [docs/OCI.md](docs/OCI.md) — OCI A1 のブートボリュームを Windows にする手順
- [docs/SETUP.md](docs/SETUP.md) — Secrets、runner の準備
- [docs/BUILD.md](docs/BUILD.md) — パイプラインの各段階と手動フォールバック
- [docs/WORKLOG.md](docs/WORKLOG.md) — 26H2 構築までの作業ログ（サニタイズ済み）

## ライセンス

スクリプトとドキュメントは [MIT](LICENSE)。
Windows、virtio-win、Microsoft の ISO はそれぞれのライセンスに従います。
