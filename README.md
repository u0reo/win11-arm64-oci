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
| 方法 B の GRUB エントリ | `./scripts/build.sh --grub-entry /srv/iso/ubuntu-live.iso` | `--to-ram` を使う前だけ |

```text
setup.sh ──> build.sh ──> 完成したディスク
                │
                ├─ --image FILE.qcow2    qcow2 を作る（ローカル検証）
                ├─ --to-ram              ISO を RAM に載せてから書き込む
                ├─ --keep-ubuntu         Ubuntu 復旧環境を同居させる
                ├─ --reuse-ubuntu        先に入れた Ubuntu を残して同居
                ├─ --fetch-iso            ISO をダウンロード
                └─ --grub-entry           方法 B の GRUB エントリを出力
```

`build.sh` は `--disk`（ブロックデバイス）か `--image`（qcow2）のどちらかを
必ず取ります。`--yes` を付けるまで実際には書き込みません。

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

# 4. A のボリューム（例: /dev/sdb）へ直接書き込む
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

ISO が書き込み先ディスクにしかない場合は `--to-ram` を付けます
（ISO をメモリにコピーしてから消す）。先に入れた Ubuntu をそのまま使う
場合は `--reuse-ubuntu` です。組み合わせの一覧は
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

優先順位は **環境変数 > `config/defaults.env` > 組み込み既定値** です。
GitHub Actions では Secrets / Variables が環境変数として渡されます。

```bash
WIN_USERNAME=alice WIN_PASSWORD='strong-pass' COMPUTER_NAME=MY-WIN \
  python3 internal/render.py --out build/media
```

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
scripts/        入口 3 つ: setup.sh / build.sh / live-grub.sh
internal/       内部部品: build-image, live-ram, render, preflight ...
pipeline/       ディスク構築の部品: wimlib apply, WinPE, QEMU, 検査
config/         既定値
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
