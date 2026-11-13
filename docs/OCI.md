# OCI Ampere A1 でビルドする

GitHub ホストランナーではこのイメージは作れません（14 GB SSD、6 時間上限、
`/dev/kvm` なし）。**OCI の Ampere A1 インスタンスを一時的なビルド機にする**のが
一番現実的です。ここでは self-hosted runner を使わず、クローンして直接実行する
手順を説明します。

## runner と手動実行のどちらにするか

**手動実行を推奨します。**

| | 手動クローン＋実行 | self-hosted runner |
|---|---|---|
| 準備 | clone して 1 コマンド | runner 登録 + Secrets + environment |
| 認証情報 | GitHub トークンをクラウドに置かない | runner 登録トークンが必要 |
| 失敗時 | その場でログとシェルが見られる | ログはジョブ画面越し |
| 実行上限 | なし（自分のシェル） | 1 ジョブ 5 日 |
| 再現性・来歴 | 手元のログ | GitHub に記録が残る |
| 向いている用途 | 一度作ればよい | 定期的に作り直す |

迷ったら手動で始めてください。`scripts/oci-run.sh` も
`.github/workflows/build-image.yml` も最終的に `scripts/build-image.sh` を
呼ぶので、後から runner を足しても二重実装にはなりません。

## 1. インスタンスを用意する

| 項目 | 推奨値 |
|---|---|
| シェイプ | `VM.Standard.A1.Flex`（4 OCPU / 24 GB） |
| イメージ | Ubuntu 24.04 (aarch64) |
| ブートボリューム | **100 GB 以上**（50 GB では足りない） |
| ネットワーク | パブリックサブネット + パブリック IP |

Always Free のブロックボリュームは 200 GB までなので、100 GB のブートボリューム
なら無料枠に収まります。50 GB のままだと `preflight.sh` が停止します。

## 2. セットアップ

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/bootstrap-ubuntu.sh
```

`bootstrap-ubuntu.sh` は QEMU、wimlib、hivex、AAVMF ファームウェアなどを入れ、
`/dev/kvm` と空き容量を確認します。

### KVM はあるか

```bash
ls -l /dev/kvm
```

- 存在して読み書きできる → `run-qemu.sh` が自動で `-accel kvm -cpu host` を使う
- 無い → TCG。A1 がネスト仮想化を公開していない場合はこちら。ビルドに数時間

`ACCEL=kvm` / `ACCEL=tcg` で明示的に上書きできます。

## 3. ISO を置く

```bash
# 手元から送る
scp Win11_ARM64_26H2.iso ubuntu@<ip>:/srv/iso/

# または MEGA / OneDrive などから直接
rclone copyto mega:win11/Win11_ARM64_26H2.iso /srv/iso/Win11_ARM64_26H2.iso
```

`--iso` にはローカルパス、`https://`、rclone のリモート
（`mega:...` など）を渡せます。SHA256 を渡すと検証します。

## 4. ビルドする

```bash
sudo ./scripts/oci-run.sh \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --deliver ssh
```

`--deliver` で納品方法を選びます。

| 値 | 動作 |
|---|---|
| `ssh` | `build/artifacts/` に置き、`scp` コマンドを表示（既定） |
| `mega` | `MEGA_USER` / `MEGA_PASS_OBSCURED` で MEGA へ |
| `rclone` | `RCLONE_TARGET=remote:path` へ |
| `image` | OCI のカスタムイメージとして登録（＋任意で起動） |
| `none` | ビルドだけ |

### 途中から再開する

```bash
sudo ./scripts/oci-run.sh --skip-build --deliver image \
  -- --compartment ocid1.compartment.oc1..xxxx \
     --subnet ocid1.subnet.oc1..xxxx --launch
```

`--` 以降は `scripts/oci-image.sh` にそのまま渡ります。

## 5. OCI カスタムイメージとして登録する

```bash
sudo ./scripts/oci-image.sh \
  --image build/win11-arm64.qcow2 \
  --compartment ocid1.compartment.oc1..xxxx \
  --subnet ocid1.subnet.oc1..xxxx \
  --launch
```

やること:

1. qcow2 を Object Storage のバケットへアップロード（一時オブジェクト）
2. `oci compute image import from-object` でインポート
3. `AVAILABLE` まで待つ
4. ファームウェアを `UEFI_64` に、シェイプ互換に `VM.Standard.A1.Flex` を追加
5. `--launch` なら A1 インスタンスを起動し、パブリック IP を表示

### 認証

`OCI_AUTH` で選びます。

- `auto`（既定）: `~/.oci/config` があれば API キー、無ければインスタンス・プリンシパル
- `instance_principal`: ダイナミック・グループのポリシーで許可（ビルド機に向く）

インスタンス・プリンシパルを使う場合、テナンシ側で次が必要です。

```text
# ダイナミック・グループ（例: コンパートメント単位）
ALL {instance.compartment.id = 'ocid1.compartment.oc1..xxxx'}

# ポリシー
Allow dynamic-group win11-builders to manage compute-images in compartment <C>
Allow dynamic-group win11-builders to manage object-family in compartment <C>
Allow dynamic-group win11-builders to manage instances in compartment <C>
Allow dynamic-group win11-builders to use subnets in compartment <C>
Allow dynamic-group win11-builders to use vnics in compartment <C>
Allow dynamic-group win11-builders to read availability-domains in tenancy
```

コンパートメント単位のダイナミック・グループは範囲が広いので、専用の
コンパートメントか、インスタンス OCID を列挙する形にしてください。

### 先に確認する

`--dry-run` で実行されるコマンドだけ表示できます。

```bash
./scripts/oci-image.sh --image build/win11-arm64.qcow2 \
  --compartment ocid1.compartment.oc1..xxxx --dry-run
```

## 重要: 未検証と制約

OCI のカスタムイメージ取り込みは、公式には **Windows Server 2016〜2025 のみ**
が対象です。Windows 11 は対象外で、動いても Oracle のサポートは受けられません。

さらに公式ドキュメントには次の記述があります。

| 記述 | 影響 |
|---|---|
| 「BIOS ブート用に設定されていること」 | こちらは UEFI（ARM64 に BIOS は無い）。取り込み後のファームウェア変更で対応する想定 |
| 「MBR とブートローダーが必要」 | こちらは GPT + ESP。取り込み時に弾かれる可能性がある |
| 「最小ブートボリューム 256 GB」（Windows 取り込みページ） | 一般的なカスタムイメージの記述は 50 GB。実際の下限は要確認 |
| ライセンスは自己責任 | Windows 11 のライセンスは各自で |

つまり **`--deliver image` は「動けば儲けもの」** です。確実なのは
`ssh` / `mega` / `rclone` で qcow2 を取り出し、手元の手順
（[SETUP.md](SETUP.md) とリポジトリ外のランブック）で扱う方法です。

インポートが `IMPORTING` のまま失敗する場合、まず疑うのは:

1. qcow2 が 50 GB 仮想ディスクのまま（256 GB 下限説）
2. UEFI/GPT が受け付けられない
3. Object Storage の読み取り権限（同一テナンシなら通常問題なし）

## コスト

| 項目 | 無料枠 | 超えた場合 |
|---|---|---|
| A1 4 OCPU / 24 GB | 常時無料 | — |
| ブートボリューム 100 GB | 200 GB まで無料 | $0.0255/GB/月 |
| Object Storage（一時） | 20〜30 GB | 取り込み後に削除すればほぼ 0 |
| 下り転送 | 10 TB/月 | — |

ビルドが終わったらインスタンスを終了してください。ブートボリュームを
残すとその分だけ課金対象になります。

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| `preflight.sh` がディスク不足で止まる | ブートボリュームを 100 GB に |
| `qemu-system-aarch64: not found` | `bootstrap-ubuntu.sh` を実行 |
| AAVMF が無い | `qemu-efi-aarch64` パッケージ |
| ビルドが異常に遅い | `/dev/kvm` の有無。無ければ TCG |
| `oci: not found` | OCI CLI を導入（`--deliver image` のみ） |
| インポートが失敗 | 上記「重要: 未検証と制約」 |
| 起動したが RDP が繋がらない | セキュリティリスト/NSG で 3389 を自分の IP に許可 |
