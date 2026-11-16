# OCI Ampere A1 を Windows に置き換える

> このページは追加情報です。実際の手順は README の
> [ステージ2](../README.md#ステージ2-ビルド環境を作る) から
> [ステージ6](../README.md#ステージ6-後片付け) を参照してください。

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

## ステージ2-A ボリュームを付け替える

OCI は「停止したインスタンスからブートボリュームを切り離し、別の
インスタンスにデータボリュームとして付ける」ことを公式に認めています。
これを使うと、live ISO も grub 細工も RAM ディスクも不要です。

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

手順の全体像は README の
[ステージ2-A](../README.md#ステージ2-a-ボリュームを付け替える) にあります。
ここでは OCI CLI の操作と容量の考え方だけを示します。

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

### 容量と無料枠

ボリュームは 50 + 50 = 100 GB で、Always Free の 200 GB に収まります。
A はビルド中に一度も起動し直さないので、失敗しても A の Ubuntu は無傷です
（ボリュームの中身は変わっていますが、付け替えれば調べられます）。

50 GB は OCI の Linux イメージの既定サイズであり、Windows の実データは
約 28 GB なので収まります。ただし Microsoft の公式要件は 64 GB なので、
Windows Update の余裕を考えるなら A だけ 64 GB にしても構いません
（50 + 64 = 114 GB で無料枠内）。

Ubuntu を 4 GiB の復旧環境として残す場合は `--keep-ubuntu` を付けます。
ESP を保持したまま p2 を作り直し、Windows Boot Manager から GRUB を
chainload します。詳細は [DUALBOOT.md](DUALBOOT.md)。

## ステージ2-B live を toram で起動する

1 インスタンスで完結させたい場合の方法です。Ubuntu のライブ ISO を
ブートボリュームの 1 パーティションに置き、grub の `loopback` で起動し、
`toram` でメモリに展開してから `/dev/sda` を丸ごと上書きします。

起動方法は **live Ubuntu を `toram` で RAM に載せる一択**です。
OCI の標準 Ubuntu は p2 が 46 GiB の root で、マウント中の ext4 は縮小
できないため、インストーラで p2 を作り直す経路は取りません。

### 24 GB で足りるか

**データボリュームは必須ではありません。** Windows ISO（6.2 GB）と
virtio-win（0.7 GB、RPM なら 0.3 GB）を `/dev/shm`（RAM）に置いても、
24 GB に収まります。

| 用途 | 目安 |
|---|---|
| ライブ ISO（`toram` で RAM に載る） | 2.5 GB |
| Windows ISO（`/dev/shm`） | 6.2 GB |
| virtio-win（`/dev/shm`、ISO / RPM） | 0.7 / 0.3 GB |
| ライブ環境の書き込み層（apt で QEMU 等を入れる） | 2〜3 GB |
| QEMU ゲスト（`--mem 6144`） | 6 GB |
| QEMU 本体・ページキャッシュ・余白 | 5 GB 程度 |

合計 23 GB 前後。`--mem 6144` なら入ります。`--mem 8192` や 16 GB に
すると足りなくなります（Windows 11 のインストールは 6 GiB で通ります）。
`--keep-ubuntu` の 4 GiB はディスク上の p2 なので、メモリは増えません。

以前の「p2 を 8 GiB にする」案は不要です。live の RAM で賄うので、
ディスク上の Ubuntu は `--keep-ubuntu` の 4 GiB だけです。

### `prepare.sh --ssh` の仕組み

`--write` は `/etc/grub.d/40_custom` に追記して `update-grub` まで
実行します（何度実行してもエントリは 1 つに保たれます）。

`--ssh` は ESP に cloud-init の seed を書き、ESP のラベルを `CIDATA` に
して、live 起動時から `authorized_keys` で SSH できるようにします。
ESP は事前に `/boot/efi` にマウントしておきます（`ESP_MNT` で変更可）。
元のラベルは ESP の `win11-arm64-oci-esp-label` に保存され、復元コマンドも
表示されます。

Ubuntu Server live には cloud-init と openssh-server が入っており、
`ssh.socket` が最初から有効です（seed 側の `systemctl enable --now ssh`
は念のためで、無くても 22 番は開きます）。sshd が上がらないときは
`sudo cloud-init status --long` を見てください。live のホスト鍵は毎回
変わるので、`known_hosts` の警告が出たら `ssh-keygen -R <ip>` で消して
ください。ESP のラベルはビルド後に戻せます（`prepare.sh` が表示する
`fatlabel` コマンド）。

`prepare.sh --ssh` の seed は、Ubuntu 24.04.5 live-server arm64 ISO を
QEMU（AAVMF + TCG）で起動して確認済みです。cloud-init が `CIDATA` を
自動検出し、`ubuntu` ユーザー作成・`authorized_keys` でのログイン・
パスワードなし sudo・22 番の listen まで通りました。TCG では systemd の
起動完了まで実時間で 15 分ほどかかります。26.04 も同じ cloud-init と
`CIDATA` の仕組みなので、seed の内容はそのまま使えます。`meta-data` の
`local-hostname` は live では効かず、ホスト名は `ubuntu-server` のままに
なります（動作に影響はありません）。

### 自動起動（`--default` / `--once`）

`GRUB_DEFAULT` に番号を書く方法はおすすめしません。番号は `update-grub` が
生成するメニューの並び順で決まり、カーネルの追加やサブメニューの有無で
ずれます（サブメニューは `1>2` のように書く必要があります）。

`prepare.sh` は live のエントリに `--id win11-live-toram` を付け、その id で
既定エントリを指定します。id はメニューの並び順に依存しません。

| フラグ | やること | 使う場面 |
|---|---|---|
| `--once` | `grub-reboot win11-live-toram`。次の 1 回だけ live を起動 | 最初の確認。失敗しても次の電源投入で Ubuntu に戻る |
| `--default` | `/etc/default/grub` の `GRUB_DEFAULT` を `win11-live-toram` に | 毎回 live で起動したいとき |

どちらも `--write` が必要です。`--default` は変更前の
`/etc/default/grub` を `/etc/default/grub.win11-arm64-oci.bak` に保存し、
戻し方を表示します。手動で戻す場合:

```bash
sudo cp -p /etc/default/grub.win11-arm64-oci.bak /etc/default/grub
sudo update-grub
```

`GRUB_TIMEOUT=0`（OCI の既定）ならメニューは出ず、そのまま既定エントリが
起動します。メニューを出したいときは `GRUB_TIMEOUT=10` と
`GRUB_TIMEOUT_STYLE=menu` にします。

id を変えたいときは `--id` を使います（英数字・`_`・`-`、先頭は数字以外）。
`--id` を変えたら `--default` / `--once` も付け直してください。

### 注意点

- `toram` で起動しても、**書き換えた瞬間に grub エントリと ISO が消えます**。
  失敗するとライブ環境に戻れず、ボリュームを別インスタンスに付けて
  復旧するしかありません
- OCI には CD-ROM デバイスが無いので、grub の `loopback` +
  `iso-scan/filename=` で起動する必要があります
  （`scripts/prepare.sh` がエントリを作ります）
- `toram` でも対象ディスクのパーティションがマウントされたままの場合があります。
  `scripts/build.sh` は `--yes` の後で自動的に解除します。解除できない場合は
  `fuser -vm <mountpoint>` で使用中プロセスを確認してください

## ISO の置き場所

Windows ISO と virtio-win の置き場所は 2 通りです。

| 置き場所 | メモリ | 失敗時の再試行 |
|---|---|---|
| `/dev/shm`（RAM） | 6.2 + 0.7 GB を使う（RPM なら 0.3 GB） | ディスクを消すと消える |
| 10 GB のデータボリューム | 使わない | 残る（推奨） |

### 10 GB のデータボリュームに置く場合

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

**Ubuntu の live ISO は Desktop ではなく Server を使ってください。** また
`--mem` を 16 GB にすると破綻します（6 GiB のままで十分です）。

ISO が `/mnt/data` にある場合、`build.sh` はコピーしません
（`/mnt/data` が `/dev/sda` 上にある場合だけ `/dev/shm` にコピーします）。

### データボリュームのデバイス名は固定ではない

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

### 一時ストレージをマウントする（おすすめ）

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

## ステージ4 ビルドの補足

仕上がりの組み合わせは次のとおりです。コマンドは README の
[ステージ4](../README.md#ステージ4-ビルド) にあります。

| 仕上がり | 追加フラグ | p2 |
|---|---|---|
| Windows のみ | なし | 消える（Windows が全体を使う） |
| Windows + 4 GiB Ubuntu | `--keep-ubuntu` | 4 GiB で作り直す |
| 既存の 4 GiB Ubuntu を残す | `--reuse-ubuntu` | そのまま（上級者向け） |

`--reuse-ubuntu` は、すでに p2 に 4 GiB 程度の Ubuntu を入れて起動して
ある場合だけ使えます。`prepare.sh` は live 起動しか登録しないので、その
Ubuntu は別途インストーラ等で入れておく必要があります。詳細は
[DUALBOOT.md](DUALBOOT.md)。

`--mem` の既定は 6144 MiB です。RAM が 24 GB の A1 で ISO を `/dev/shm`
に置く場合、`--mem 8192` は OOM の危険があります。`--mem 6144` のままに
してください。

## シリアルコンソール (SAC)

`oem/specialize.ps1` がビルド時に EMS/SAC を有効にします。完成した Windows は
COM1 (115200 bps) で `SAC>` を返すので、RDP が壊れても OCI のシリアル
コンソールから直せます。

使い方:

1. インスタンス詳細 → **Console connection** → シリアル接続を作る
2. Cloud Shell から接続する（VNC ではない）
3. `SAC>` が出たら `cmd`
4. `ch -si 1`（または `Esc`+`Tab`）でチャンネルを切り替え、Enter
5. 管理者の資格情報を入れると `C:\Windows\System32>` が出る
6. `powershell` と入力すれば PowerShell も起動できる

できること: `ipconfig` / `netsh` / `bcdedit` / `diskpart` / `sc` / `sfc` /
`chkdsk` / `shutdown` など。RDP のファイアウォールや NLA を直すには十分です。

できないこと:

- GUI。テキストのみ
- WinRE での操作（SAC は起動した OS の中で動く）
- 長い文字列の貼り付け（ターミナル側の上限）
- 対話的な TUI（VT100 非対応で表示が崩れる）

注意: SAC は管理者シェルそのものです。コンソール接続の権限を持つ人は実質
フルアクセスになります。IAM を絞ってください。

イメージには適用済みなので操作は不要ですが、手で入れた Windows に後から
足す場合は次の 2 行です。

```cmd
bcdedit /ems {current} on
bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200
```

### ブートメニュー

`--boot-menu 秒数` で `displaybootmenu yes` / `timeout` / `bootems yes` を
設定します。シリアルにも VNC にもメニューが出るので、セーフモードや
`--keep-ubuntu` の Ubuntu 復旧エントリを選べます。既定は 1 秒で、表示中に
何かキーを押せばカウントダウンが止まります。`--boot-menu 0` は Ubuntu を
残す構成では使えません（メニューが隠れて復旧エントリを選べなくなるため）。

メニューを出さない構成に戻すには:

```cmd
bcdedit /set {bootmgr} displaybootmenu no
bcdedit /set {bootmgr} bootems no
```

## ステージ6 後片付け

### バックアップと復旧

`scripts/build.sh` は対象デバイスを消します。実行前に**ブートボリュームの
バックアップ**を取ってください。

```bash
oci bv boot-volume-backup create \
  --boot-volume-id <vol> --display-name win11-pre-build
```

失敗したら、バックアップから復元するか、ボリュームを別インスタンスに
データボリュームとして付けて中身を調べます。

### コスト

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
| `setup.sh --check` / preflight が `not enough disk space` で止まる | 直接書き込みなら `build/`（staging）に約 3 GB、qcow2 なら 80 GB。`--build-dir DIR` または `BUILD_DIR=...` で空きのある場所を指定（live 環境なら `/dev/shm/build` や `/tmp/build` が候補）。`--min-free-gb N` で判定値を変更できる |
| preflight がメモリ不足を警告/失敗する | 表示される見積もり（guest `--mem` + staging + media + overhead）を確認。`--mem` を下げる、不要なプロセスを止める、ISO/ドライバを既に tmpfs に置いて重複コピーを避ける |
| live (toram) で `/` と `/dev/shm` の空きが偏る | `/`(overlay=/cow)・`/dev/shm`・`/tmp` は別 tmpfs だが RAM を共有する。ISO を `$HOME` に置くと `/cow` を圧迫しやすい。`build/` は空きのある tmpfs に自動選択される（明示するなら `--build-dir /dev/shm/build`） |
| シリアルに `SAC>` が出ない | `C:\OEM\specialize.log` に `sac-configured` があるか。コンソール接続がシリアル（VNC ではない）か |
| ビルド中にディスク不足になる | ブートボリュームを 64 GB 以上に |
| `--virtio *.rpm` で `cannot read an RPM` になる | `rpm2cpio` と `cpio` が要る。`scripts/setup.sh` か `apt-get install rpm2cpio cpio` |
| `qemu-system-aarch64: not found` | `scripts/setup.sh` |
| AAVMF が無い | `qemu-efi-aarch64` パッケージ |
| ビルドが異常に遅い | `/dev/kvm` の有無。無ければ TCG |
| `scripts/build.sh` が「ルートデバイス」で止まる | ステージ2-A に切り替える |
| 起動しない | ESP に `BOOTAA64.EFI` があるか、AnyPages パッチが当たっているか |
| RDP が繋がらない | セキュリティリスト/NSG で 3389 を許可 |
