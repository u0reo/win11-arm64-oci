# OCI Ampere A1 を Windows に置き換える

GitHub ホストランナーでは作れません（14 GB SSD / 6 時間 / KVM なし）。
OCI の Ampere A1 をビルド機にして、**ブートボリュームの中身を Windows に
置き換える**のがこのリポジトリの想定です。

配布物は作りません。qcow2 も圧縮ファイルも MEGA も使いません。
ビルドが終われば、そのボリュームがそのまま Windows ディスクになります。

## なぜ Object Storage / カスタムイメージを使わないか

OCI のカスタムイメージ取り込みは Object Storage 経由です。

- Always Free の Object Storage は Standard 10 GB（IA/Archive を含めても 20〜30 GB）
- qcow2 は 28 GB、圧縮しても 13 GB なので無料枠を超える
- さらに Windows 11 は取り込みのサポート対象外（Server 2016〜2025 のみ）
- Windows 用の公式手順は BIOS/MBR 前提で、こちらは UEFI/GPT

そこで「イメージを作って配る」のをやめ、**ブートボリュームを直接書き換える**
方針にしました。

## どの組み合わせが可能か

起動方法は **`--to-ram`（live Ubuntu を RAM に載せる）一択**です。
OCI の標準 Ubuntu は p2 が 46 GiB の root で、マウント中の ext4 は縮小
できないため、インストーラで p2 を作り直す経路は取りません。
live 環境で、仕上がりだけを選びます。

| 仕上がり | コマンド | p2 |
|---|---|---|
| Windows のみ | `--to-ram` | 消える（Windows が全体を使う） |
| Windows + 4 GiB Ubuntu | `--to-ram --keep-ubuntu` | 4 GiB で作り直す |

Windows ISO と virtio-win の置き場所は 2 通りです。

| 置き場所 | メモリ | 失敗時の再試行 |
|---|---|---|
| `/dev/shm`（RAM） | 6.2 + 0.7 GB を使う | ディスクを消すと消える |
| 10 GB のデータボリューム | 使わない | 残る（推奨） |

```bash
# RAM に置く（データボリュームなし）
sudo ./scripts/build.sh --to-ram --disk /dev/sda \
  --iso /dev/shm/Win11.iso --virtio /dev/shm/virtio-win.iso \
  --mem 6144 --yes

# 10 GB のデータボリュームから読む（/mnt/data の例は下の注意を参照）
sudo ./scripts/build.sh --to-ram --disk /dev/sda \
  --iso /mnt/data/Win11.iso --virtio /mnt/data/virtio-win.iso \
  --mem 6144 --yes

# 4 GiB の Ubuntu 復旧環境も残す
sudo ./scripts/build.sh --to-ram --keep-ubuntu --disk /dev/sda \
  --iso /dev/shm/Win11.iso --virtio /dev/shm/virtio-win.iso \
  --mem 6144 --yes
```

すでに p2 に 4 GiB 程度の Ubuntu を入れて起動してある場合だけ、
`--reuse-ubuntu` で p2 を残せます（上級者向け。
[DUALBOOT.md](DUALBOOT.md)）。`prepare.sh` は live 起動しか登録しないので、
その Ubuntu は別途インストーラ等で入れておく必要があります。

## 方法 A: ボリュームを付け替える

OCI は「停止したインスタンスからブートボリュームを切り離し、別の
インスタンスにデータボリュームとして付ける」ことを公式に認めています。
これを使うと、ライブ CD も grub 細工も RAM ディスクも不要です。

> 「ブートボリュームとブロックボリュームは変換できない」は正しいのですが、
> **変換は不要**です。ブートボリュームを停止中に detach し、ブロック
> ボリュームとして別インスタンスに attach します。OCI の公式ドキュメント
> 「Attaching a Boot Volume」に次の記述があります。
>
> "If a boot volume has been detached from the associated instance, or if the
> instance is stopped or terminated, you can attach the boot volume to another
> instance as a data volume."
>
> 「Working with Boot Volumes」にも、トラブルシュート用に
> "detach the boot volume, then attach it to another instance as a data volume"
> と明記されています。リソース種別はブートボリュームのままですが、
> データボリュームとして見える、という扱いです。

```text
1. ターゲット A を作る（Ubuntu 26.04 minimal aarch64、ブート 50 GB）
2. A を停止し、ブートボリュームを切り離す
3. ビルダー B を作る（Ubuntu、ブート 50 GB、同じ AD）
4. A のブートボリュームを B にデータボリュームとして接続する
5. B でビルドする（書き込み先は /dev/sdb など）
6. B を停止し、ボリュームを切り離して A のブートボリュームとして再接続
7. A を起動すると Windows が立ち上がる
```

ボリュームは 50 + 50 = 100 GB で、Always Free の 200 GB に収まります。
A は手順 7 まで一度も起動し直さないので、失敗しても A の Ubuntu は無傷です
（ボリュームの中身は変わっていますが、付け替えれば調べられます）。

50 GB は OCI の Linux イメージの既定サイズであり、Windows の実データは
約 28 GB なので収まります。ただし Microsoft の公式要件は 64 GB なので、
Windows Update の余裕を考えるなら A だけ 64 GB にしても構いません
（50 + 64 = 114 GB で無料枠内）。

Ubuntu を 4 GiB の復旧環境として残す場合は `--keep-ubuntu` を付けます。
ESP を保持したまま p2 を作り直し、Windows Boot Manager から GRUB を
chainload します。手順と注意点は [DUALBOOT.md](DUALBOOT.md)。

### 手順

```bash
# B にログイン
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<OWNER>/win11-arm64-oci.git
cd win11-arm64-oci
sudo ./scripts/setup.sh

# 書き込み先デバイスを確認（OCI のデータボリュームは /dev/sdb か
# /dev/oracleoci/oraclevdb）
lsblk -o NAME,SIZE,MODEL,SERIAL

sudo ./scripts/build.sh \
  --disk /dev/sdb \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso \
  --yes
```

`scripts/build.sh` は次を確認してから `internal/build-image.sh` を呼びます。

- ブロックデバイスであること（`--image` のときは qcow2 を作る）
- マウントされていないこと
- 実行中のルートデバイスでないこと
- 40 GiB 以上あること

`--yes` を付けないと、対象デバイスの model / serial / size を表示して止まります。

### OCI CLI で付け替える

```bash
# 1. A を停止してブートボリュームを切り離す
oci compute instance action --instance-id <A> --action STOP
oci compute boot-volume-attachment detach \
  --boot-volume-attachment-id <A のアタッチメント OCID>

# 2. B にデータボリュームとして接続する。
#    --volume-id には「ブートボリュームの OCID」を渡す（変換はしない）。
#    ブートボリュームは consistent device path の対象外なので --device は付けない。
oci compute volume-attachment attach \
  --instance-id <B> --volume-id <A のブートボリューム OCID> \
  --type paravirtualized

# 3. ビルド後、B から切り離して A にブートボリュームとして接続
oci compute volume-attachment detach --volume-attachment-id <...>
oci compute boot-volume-attachment attach \
  --instance-id <A> --boot-volume-id <A のブートボリューム OCID>

oci compute instance action --instance-id <A> --action START
```

`boot-volume-attachment detach` は**アタッチメントの OCID**、
`boot-volume-attachment attach` は**ブートボリュームの OCID** を取ります。
混同しやすいので注意してください。コンソールでも同じことができます。

## 方法 B: ライブ CD を RAM に載せて sda を書き換える

1 インスタンスで完結させたい場合の方法です。Ubuntu のライブ ISO を
ブートボリュームの 1 パーティションに置き、grub の `loopback` で起動し、
`toram` でメモリに展開してから `/dev/sda` を丸ごと上書きします。

### 24 GB で足りるか

**データボリュームは必須ではありません。** Windows ISO（6.2 GB）と
virtio-win（0.7 GB）を `/dev/shm`（RAM）に置いても、24 GB に収まります。

| 用途 | 目安 |
|---|---|
| ライブ ISO（`toram` で RAM に載る） | 2.5 GB |
| Windows ISO（`/dev/shm`） | 6.2 GB |
| virtio-win（`/dev/shm`） | 0.7 GB |
| ライブ環境の書き込み層（apt で QEMU 等を入れる） | 2〜3 GB |
| QEMU ゲスト（`--mem 6144`） | 6 GB |
| QEMU 本体・ページキャッシュ・余白 | 5 GB 程度 |

合計 23 GB 前後。`--mem 6144` なら入ります。`--mem 8192` や 16 GB に
すると足りなくなります（Windows 11 のインストールは 6 GiB で通ります）。
`--keep-ubuntu` の 4 GiB はディスク上の p2 なので、メモリは増えません。

以前の「p2 を 8 GiB にする」案は不要です。live の RAM で賄うので、
ディスク上の Ubuntu は `--keep-ubuntu` の 4 GiB だけです。

#### 手順

1. Ubuntu live ISO をブートボリュームに置き、GRUB エントリを作る
   （ISO の入手は [README の「ISO の入手」](../README.md#iso-の入手)）

   ```bash
   sudo ./scripts/prepare.sh \
     /srv/iso/ubuntu-24.04-live-server-arm64.iso --write --ssh
   ```

   `--write` は `/etc/grub.d/40_custom` に追記して `update-grub` まで
   実行します（何度実行してもエントリは 1 つに保たれます）。
   `--ssh` は ESP に cloud-init の seed を書き、ESP のラベルを `CIDATA` に
   して、live 起動時から `authorized_keys` で SSH できるようにします。
   元のラベルは ESP の `win11-arm64-oci-esp-label` に保存され、復元コマンドも
   表示されます。

2. 再起動し、GRUB で `Ubuntu live (toram)` を選ぶ

3. live 環境で Windows ISO と virtio-win を `/dev/shm` に用意する
   （取得方法は README の「ISO の入手」）

4. ビルドする

   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/<OWNER>/win11-arm64-oci.git
   cd win11-arm64-oci
   sudo ./scripts/setup.sh
   sudo ./scripts/build.sh --to-ram --disk /dev/sda \
     --iso /dev/shm/Win11_ARM64_26H2.iso \
     --virtio /dev/shm/virtio-win.iso --mem 6144 --yes
   ```

   `--keep-ubuntu` を足すと 4 GiB の Ubuntu 復旧環境も一緒に作ります。

`--to-ram` は `internal/live-ram.sh` に引き継がれ、次を行います。

1. 実行中の環境が `/dev/sda` に依存していないか確認（していなければ中止。
   ルート、ライブメディア（`/run/live/medium` か `/cdrom`）、ISO の
   いずれかが `/dev/sda` 上にあり、かつ `losetup -a` に RAM 上の
   loop が無ければ中止します）
2. `MemAvailable` と `/dev/shm` の空きを確認し、足りなければ中止
3. Windows ISO と virtio-win.iso を `/dev/shm` にコピー（まだそこに
   無い場合だけ）
4. `/dev/sda` のマウントをすべて解除し、`scripts/build.sh` に引き継ぐ

**`--mem 6144` を明示してください。** `--to-ram` の既定も 6144 ですが、
`build.sh` 単体の既定は 8192 で、コピー後の空きメモリが足りず QEMU が
OOM で落ちることがあります。

#### 10 GB のデータボリュームに置く場合

ISO をディスクに残せるので、失敗時の再試行が楽です。

| 用途 | 目安 |
|---|---|
| ライブ ISO（`toram`） | 2.5 GB |
| ライブ環境の書き込み層 | 2〜3 GB |
| QEMU ゲスト（`--mem 6144`） | 6 GB |
| QEMU 本体・ページキャッシュ | 残り 10 GB 以上 |

**Windows ISO は 10 GB のブロックボリュームに置き、
`--iso /mnt/data/Win11_ARM64_26H2.iso` を渡します。** このボリュームは
`/dev/sda` の書き換えの影響を受けません。100 GB（ブート）+ 10 GB
（ISO）= 110 GB で無料枠に収まります。

**Desktop ISO は使わず Server ISO にしてください。** また `MEM` を 16 GB に
すると破綻します（6 GiB のままで十分です）。

#### データボリュームのデバイス名は固定ではない

OCI のデータボリュームは `/dev/sdb` になるとは限りません
（`/dev/oracleoci/oraclevdb` のこともあります）。再起動や付け替えで
名前が変わることもあります。**`/dev/sdb` を決め打ちせず、UUID で
`/etc/fstab` に書いて `/mnt/data` で参照**してください。

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
sudo blkid

# 初回だけ: フォーマットしてマウント
sudo mkfs.ext4 -L data /dev/sdX          # 中身が消えます
sudo mkdir -p /mnt/data
UUID=$(sudo blkid -s UUID -o value /dev/sdX)
echo "UUID=$UUID /mnt/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
findmnt /mnt/data
```

以降は `/dev/sdb` ではなく `/mnt/data` を渡します。デバイス名を確認
したいときは `findmnt -no SOURCE /mnt/data` です。

`--to-ram` は ISO が `/mnt/data` にあっても、書き込み先 `/dev/sda` 上に
無ければコピーしません。`/mnt/data` が `/dev/sda` 上にある場合だけ
`/dev/shm` にコピーします。

### 注意点

- `toram` で起動しても、**書き換えた瞬間に grub エントリと ISO が消えます**。
  失敗するとライブ環境に戻れず、ボリュームを別インスタンスに付けて
  復旧するしかありません
- OCI には CD-ROM デバイスが無いので、grub の `loopback` +
  `iso-scan/filename=` で起動する必要があります
  （`scripts/prepare.sh` がエントリを作ります）
- ライブ環境の操作は基本シリアルコンソールです。`prepare.sh --ssh` を
  付けておくと、ESP を `CIDATA` にして cloud-init の seed を置くので、
  live 起動時から `authorized_keys` で SSH できます（Ubuntu Server live は
  cloud-init 入り）。live のホスト鍵は毎回変わるので、`known_hosts` の
  警告が出たら `ssh-keygen -R <ip>` で消してください。ESP のラベルは
  ビルド後に戻せます（`prepare.sh` が表示する `fatlabel` コマンド）
- `toram` でも ISO のパーティションがマウントされたままの場合があります。
  `scripts/build.sh` はマウント中のデバイスを拒否するので、先に
  `sudo umount /dev/sda1` などで外してください

ISO を別ボリューム（`/mnt/data`）に置く場合も、`--to-ram` を付けたままで
構いません。書き込み先 `/dev/sda` 上に無ければコピーは起きず、RAM
起動かどうかの安全確認だけが行われます。

方法 A（別インスタンスのビルダーから書き込む）と方法 B（1 インスタンスで
完結）は、どちらも同じディスクを作ります。ビルド機を分けたいなら方法 A、
1 インスタンスで済ませたいなら方法 B です。

方法 B で完了した場合は、付け替えは不要です。ライブ環境から
`sudo reboot` すると、`/dev/sda` の Windows が起動します。

## ビルドの流れ（共通）

`scripts/build.sh` は `internal/build-image.sh` に `DISK` を渡すだけです。

1. `render.py` で autounattend / OEM スクリプトを生成
2. virtio-win の ARM64 ドライバを展開
3. OEMDRV ISO を作成
4. `wimlib-imagex apply` で対象ディスクへ展開
5. `boot.wim` の `Setup\CmdLine` を書き換えて WinPE を自動実行
6. **phase A**: WinPE がドライバ追加と `bcdboot` を行い、`wpeutil shutdown`
7. **phase B**: ディスクから Windows が初回起動し、OOBE と OEM スクリプト
8. WinRM の応答を確認して QMP で正常シャットダウン
9. ESP の `bootmgfw.efi` / `bootaa64.efi` に AnyPages パッチ
10. 検査

qcow2 を作りたいときは `DISK` を省略します（ローカル検証用）。

```bash
sudo ./scripts/build.sh --image build/win11-arm64.qcow2 \
  --iso /srv/iso/Win11_ARM64_26H2.iso \
  --virtio /srv/iso/virtio-win.iso --yes
```

## 起動後

- OCI のファームウェアは UEFI です。ESP の `\EFI\BOOT\BOOTAA64.EFI` から
  起動します
- ネットワークは DHCP で VNIC の IP を取ります
- RDP 3389 / WinRM 5985 が開いています（NLA 無効・ファイアウォール無効）
- **OCI エージェントは入っていない**ので、コンソールのパスワードリセットは
  使えません。ビルド時のパスワードで入ってください
- シリアルコンソールに Windows の出力は出ません。RDP で接続します

### セキュリティ

3389 を `0.0.0.0/0` に開けないでください。セキュリティリストか NSG で
自分の IP か VPN に限定します。

## バックアップと復旧

`scripts/build.sh` は対象デバイスを消します。実行前に**ブートボリュームの
バックアップ**を取ってください。

```bash
oci bv boot-volume-backup create \
  --boot-volume-id <vol> --display-name win11-pre-build
```

失敗したら、バックアップから復元するか、ボリュームを別インスタンスに
データボリュームとして付けて中身を調べます。

## コスト

| 項目 | 無料枠 | 超えた場合 |
|---|---|---|
| A1 4 OCPU / 24 GB | 常時無料 | — |
| ブートボリューム 100 GB（A 50 + B 50） | 200 GB まで無料 | $0.0255/GB/月 |
| 下り転送 | 10 TB/月 | — |

ビルドが終わったら B は終了してください。B のブートボリュームを残すと
その分だけ課金対象になります。

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| `preflight.sh` がディスク不足で止まる | ブートボリュームを 64 GB 以上に |
| `qemu-system-aarch64: not found` | `scripts/setup.sh` |
| AAVMF が無い | `qemu-efi-aarch64` パッケージ |
| ビルドが異常に遅い | `/dev/kvm` の有無。無ければ TCG |
| `scripts/build.sh` が「ルートデバイス」で止まる | 方法 A に切り替える |
| 起動しない | ESP に `BOOTAA64.EFI` があるか、AnyPages パッチが当たっているか |
| RDP が繋がらない | セキュリティリスト/NSG で 3389 を許可 |
