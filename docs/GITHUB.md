# GitHub リポジトリと Actions の設定

> このページは追加情報です。通常のビルドは README の
> [ステージ4](../README.md#ステージ4-ビルド) で `scripts/build.sh` を
> 直接実行します。このページは GitHub Actions と self-hosted runner を
> 使う場合の設定です。

## 1. リポジトリ

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

Secrets は `WIN_USERNAME` / `WIN_PASSWORD` / `COMPUTER_NAME` の 3 つです。
既定値は README の [「資格情報」](../README.md#資格情報) と同じです。Secret が
空なら Variable、それも空なら `internal/render.py` の組み込み既定値になります。

> `TIMEZONE` は `build-image.yml` では渡していないので、Actions からビルド
> すると既定の `Tokyo Standard Time` になります。変える場合は workflow の
> `env:` に `TIMEZONE` を追加してください。

### Variables

| 名前 | 説明 |
|---|---|
| `COMPUTER_NAME` | Secret より優先度は低い |
| `ISO_PATH` | runner 上の ISO パス |
| `ISO_SHA256` | ISO の期待ハッシュ |
| `VIRTIO_ISO` | virtio-win.iso のパス |

`COMPUTER_NAME` は Secret が空なら Variable、それも空なら `OCI-WIN` に
なります。

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

README の [ステージ2](../README.md#ステージ2-ビルド環境を作る) と同じです。runner でも
`sudo ./scripts/setup.sh` を実行してください。

### sudo

`qemu-nbd`、`mount`、`losetup` を非対話で使うため、NOPASSWD を設定します。

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/win11-builder
sudo chmod 440 /etc/sudoers.d/win11-builder
```

> runner は信頼できるリポジトリ専用にしてください。公共の runner に
> NOPASSWD を渡すと、リポジトリが乗っ取られた時点で root 相当です。

### ISO の配置

runner 上に ISO を置き、Variables にパスを設定します。ISO の入手方法は
README の [ステージ1](../README.md#ステージ1-準備) と
[ステージ3](../README.md#ステージ3-windows-iso-と-virtio-win) を参照して
ください。

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
ブートメニューをシリアルと VNC に出す場合は `-f boot_menu=5` を足します
（既定は 1 秒、0 で非表示）。SAC (EMS) は常に有効です。
`release` environment の承認後、runner 上でビルドが始まります。
TCG の場合、数時間かかることがあります。

ローカルで実行する場合のコマンドは README の
[ステージ4](../README.md#ステージ4-ビルド) と
[付録B](../README.md#付録b-ローカルで-qcow2-を作る) にあります。
