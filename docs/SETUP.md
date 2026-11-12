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
| `MEGA_USER` | — | 必須 | MEGA のログイン |
| `MEGA_PASS_OBSCURED` | — | 必須 | `rclone obscure` の出力 |
| `MEGA_2FA_SECRET` | — | 2FA 時 | TOTP の base32 |
| `AGE_RECIPIENT` | — | 任意 | age の公開鍵（暗号化する場合） |

### Variables

| 名前 | 既定 | 説明 |
|---|---|---|
| `COMPUTER_NAME` | `OCI-WIN` | Secret より優先度は低い |
| `ISO_PATH` | — | runner 上の ISO パス |
| `ISO_SHA256` | — | ISO の期待ハッシュ |
| `VIRTIO_ISO` | — | virtio-win.iso のパス |
| `MEGA_REMOTE_PATH` | `win11-arm64` | MEGA の保存先 |

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
  https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/<OWNER>/<REPO> --token <TOKEN> \
  --labels self-hosted,linux,tcg
./run.sh
```

サービス化する場合は `sudo ./svc.sh install && sudo ./svc.sh start`。

### 必要なパッケージ

```bash
sudo apt-get install -y \
  qemu-system-arm qemu-utils wimtools libguestfs-tools \
  mtools dosfstools ntfs-3g xorriso gdisk zstd \
  python3 python3-hivex python3-pefile curl rclone oathtool age \
  shellcheck libxml2-utils
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

## 4. MEGA

1. ブラウザで MEGA にログインする（rclone の前提条件）。
2. 2FA を有効にした場合、設定画面の QR から base32 の secret を控える。
3. パスワードを難読化する。

```bash
rclone obscure 'MEGAのパスワード'
# 出力を MEGA_PASS_OBSCURED に登録
```

4. `MEGA_USER` にメールアドレスを登録。
5. `MEGA_REMOTE_PATH` を `win11-arm64` などに設定。

> MEGA の無料枠は「直近 6 時間の IP あたり転送量」で制限されます。
> アップロードは転送クォータを消費しません。
> 同じファイルを最後まで 10 回ダウンロードするまでは、そのファイルの
> 転送はカウントされません。

### CI 用アカウント

既存の 50GB アカウントを CI に使うと、Secrets 漏洩時に失います。
可能なら CI 専用アカウントを用意してください。
圧縮版は約 12.8GiB なので、無料 20GB に収まります。

## 5. 実行

```bash
gh workflow run build-image.yml \
  -f iso_path=/srv/iso/Win11_ARM64_26H2.iso \
  -f iso_sha256=<sha256> \
  -f image_index=1 \
  -f virtio_iso=/srv/iso/virtio-win.iso \
  -f size=50G \
  -f upload=true
```

`release` environment の承認後、runner 上でビルドが始まります。
TCG の場合、数時間かかることがあります。

## 6. ローカル実行

```bash
export ISO=/srv/iso/Win11_ARM64_26H2.iso
export VIRTIO_ISO=/srv/iso/virtio-win.iso
export WIN_PASSWORD='strong-pass'   # 任意
scripts/build-image.sh
```
