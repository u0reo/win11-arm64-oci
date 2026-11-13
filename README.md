# win11-arm64-oci

Windows 11 ARM64 を **Oracle Cloud Infrastructure の Ampere A1** でネイティブ起動し、
RDP / WinRM で操作できる状態まで自動構築するためのスクリプト集です。

検証済み: **Windows 11 26H2 Pro (ARM64)** / QEMU `virt` / virtio-scsi + netkvm。

> このリポジトリには **ISO も qcow2 も含まれません**。
> Windows の ISO は各自で用意してください。完成イメージの再配布は
> Microsoft の EULA に反するため行いません。

## 何をするか

1. Windows 11 ARM64 ISO の `install.wim` をホスト側で qcow2 に適用（`wimlib-imagex`）
2. WinPE を自動起動し、virtio ドライバ追加と `bcdboot` を実行
3. 初回起動で OOBE・OEM スクリプトを無人実行
4. RDP / WinRM を有効化し、準備完了を確認
5. ESP の `bootmgfw.efi` に OCI A1 向け AnyPages パッチを適用
6. 検査 → 圧縮 → MEGA へアップロード

## 必要なもの

| 項目 | 要件 |
|---|---|
| ホスト | Linux x86_64 または ARM64。**空き 100GB 以上** |
| CPU/RAM | 4 コア / 16GB 以上を推奨（TCG は遅い） |
| KVM | x86 ホストで ARM64 ゲストを動かす場合、KVM は使えない（TCG） |
| Windows ISO | Windows 11 ARM64 26H2（各自で用意） |
| virtio-win | ARM64 ドライバ入り ISO または展開済みディレクトリ |
| sudo | `qemu-nbd` / `mount` のため NOPASSWD を想定 |

### パッケージ（Debian/Ubuntu）

```bash
sudo ./scripts/bootstrap-ubuntu.sh
```

手動で入れる場合:

```bash
sudo apt-get install -y \
  qemu-system-arm qemu-utils qemu-efi-aarch64 wimtools \
  libhivex-bin python3-hivex python3-pefile \
  mtools dosfstools ntfs-3g xorriso gdisk zstd \
  curl rclone oathtool age jq
```

## OCI A1 でビルド（推奨）

GitHub ホストランナーでは作れません（14 GB SSD / 6 時間 / KVM なし）。
Ampere A1 の Ubuntu を一時的なビルド機にします。

```bash
# 1. A1 インスタンス（Ubuntu 24.04 aarch64、ブートボリューム 100 GB）
# 2. ログインして
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/bootstrap-ubuntu.sh

# 3. ISO を置いてビルド
sudo ./scripts/oci-run.sh --iso /srv/iso/Win11_ARM64_26H2.iso --deliver ssh
```

`--deliver` は `ssh` / `mega` / `rclone` / `image` / `none` から選べます。
`image` は OCI のカスタムイメージとして登録し、そのまま A1 インスタンスを
起動します（Windows 11 は OCI のサポート対象外なので注意）。
詳細は [docs/OCI.md](docs/OCI.md)。

## ローカルでビルド

```bash
export ISO=/srv/iso/Win11_ARM64_26H2.iso
export VIRTIO_ISO=/srv/iso/virtio-win.iso
scripts/build-image.sh
```

成果物:

```text
build/win11-arm64.qcow2
build/artifacts/win11-arm64.qcow2.zst
build/artifacts/win11-arm64.qcow2.zst.sha256
```

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
  python3 scripts/render.py --out build/media
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
| `build-image.yml` | **self-hosted** | イメージ生成と MEGA アップロード |

一発ビルドなら runner を登録せず、A1 上で `scripts/oci-run.sh` を直接
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
pipeline/       wimlib apply, WinPE, QEMU, 検査
scripts/        render, build, package, upload, preflight
config/         既定値
docs/           SETUP / BUILD / WORKLOG
```

## ドキュメント

- [docs/OCI.md](docs/OCI.md) — OCI A1 をビルド機にする手順と納品方法
- [docs/SETUP.md](docs/SETUP.md) — Secrets、runner、MEGA の準備
- [docs/BUILD.md](docs/BUILD.md) — パイプラインの各段階と手動フォールバック
- [docs/WORKLOG.md](docs/WORKLOG.md) — 26H2 構築までの作業ログ（サニタイズ済み）

## ライセンス

スクリプトとドキュメントは [MIT](LICENSE)。
Windows、virtio-win、Microsoft の ISO はそれぞれのライセンスに従います。
