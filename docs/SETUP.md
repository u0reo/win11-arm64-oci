# セットアップ

## 1. GitHub リポジトリ

1. Public リポジトリを作成して push する。
2. `Settings > Branches` で `main` を保護する。
   - Require a pull request before merging
   - Do not allow force pushes
3. `Settings > Actions > General`
   - **Require approval for all outside collaborators**
   - Fork pull request workflows: require approval
4. `Settings > Environments` で `release` を作成し、
   **Required reviewers** に自分を追加する。
   `build-image.yml` はこの environment を使うため、実行前に承認が入る。

> `build-image.yml` に `pull_request` トリガーを追加しないこと。
> self-hosted runner 上で fork のコードが実行されます。

## 2. Secrets と Variables

`Settings > Secrets and variables > Actions` に登録します。

### Secrets

| 名前 | 既定 | 必須 | 説明 |
|---|---|---|---|
| `WIN_USERNAME` | `User` | 任意 | ローカルアカウント名 |
| `WIN_PASSWORD` | `oci-a1` | 任意 | パスワード |
| `COMPUTER_NAME` | `OCI-WIN` | 任意 | PC 名（15 文字以内） |

### Variables

| 名前 | 既定 | 説明 |
|---|---|---|
| `COMPUTER_NAME` | `OCI-WIN` | Secret より優先度は低い |
| `ISO_PATH` | — | runner 上の ISO パス |
| `ISO_SHA256` | — | ISO の期待ハッシュ |
| `VIRTIO_ISO` | — | virtio-win.iso のパス |

優先順位（render.py）:

```text
Secret (env)  >  Variable (env)  >  config/defaults.env  >  組み込み既定値
```

`COMPUTER_NAME` は Secret が空なら Variable、それも空なら `OCI-WIN` になります。

## 3. self-hosted runner

ビルド用マシンに runner を登録します。

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o runner.tar.gz \
  https://github.com/actions/runner/releases/latest/download/actions-runner-linux-arm64.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/<OWNER>/<REPO> --token <TOKEN> \
  --labels self-hosted,linux,tcg
./run.sh
```

サービス化する場合は `sudo ./svc.sh install && sudo ./svc.sh start`。

### 必要なパッケージ

```bash
sudo ./scripts/bootstrap-ubuntu.sh
```

手動で入れる場合:

```bash
sudo apt-get install -y \
  qemu-system-arm qemu-utils qemu-efi-aarch64 wimtools \
  libhivex-bin python3-hivex python3-pefile \
  mtools dosfstools ntfs-3g xorriso gdisk zstd \
  curl rclone age jq shellcheck libxml2-utils
```

### sudo

`qemu-nbd`、`mount`、`losetup` を非対話で使うため、NOPASSWD を設定します。

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/win11-builder
sudo chmod 440 /etc/sudoers.d/win11-builder
```

> runner は信頼できるリポジトリ専用にしてください。公共の runner に
> NOPASSWD を渡すと、リポジトリが乗っ取られた時点で root 相当です。

### ISO の配置

```bash
sudo mkdir -p /srv/iso
sudo cp Win11_ARM64_26H2.iso /srv/iso/
sudo cp virtio-win.iso /srv/iso/
sha256sum /srv/iso/Win11_ARM64_26H2.iso
```

`ISO_PATH` / `VIRTIO_ISO` Variable にこのパスを設定します。

## 4. 実行

```bash
gh workflow run build-image.yml \
  -f iso_path=/srv/iso/Win11_ARM64_26H2.iso \
  -f iso_sha256=<sha256> \
  -f image_index=1 \
  -f virtio_iso=/srv/iso/virtio-win.iso \
  -f size=50G
```

ブロックデバイスへ直接書く場合は `-f disk=/dev/sdb` を渡します（消去されます）。
`release` environment の承認後、runner 上でビルドが始まります。
TCG の場合、数時間かかることがあります。

## 5. ローカル実行

qcow2 を作る場合:

```bash
export ISO=/srv/iso/Win11_ARM64_26H2.iso
export VIRTIO_ISO=/srv/iso/virtio-win.iso
export WIN_PASSWORD='strong-pass'   # 任意
scripts/build-image.sh
```

ブロックデバイスへ直接書く場合（OCI のブートボリューム付け替え）:

```bash
sudo ./scripts/direct-run.sh \
  --disk /dev/sdb \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso --yes
```

手順の詳細は [OCI.md](OCI.md) を参照してください。
