# スクラッチビルド前のチェックリスト

ビルドに必要なスクリプト、テンプレート、ドキュメント、調査履歴
（`WORKLOG.md`）はすべてこのリポジトリに入っています。会話や OpenCode の
セッション、作業ディレクトリの一次性ファイルが消えても、clone と下記の
入力があればイメージを作り直せます。

## リポジトリに無いもの（別途用意する）

- Windows 11 ARM64 のインストール ISO（`ISO=/path/to/...`）
- virtio-win ARM64 の ISO / RPM / ドライバ・ディレクトリ
  （`VIRTIO_ISO=` / `VIRTIO_RPM=` / `DRIVERS_DIR=`）
- ビルドホストのツール（`sudo ./scripts/setup.sh` で導入）
- 任意: 新しい復旧 Ubuntu に渡す SSH 公開鍵と netplan

`authorized_keys`、netplan、Windows のユーザー名 / パスワード、ビルド時に
生成される復旧 Ubuntu のパスワードは **リポジトリへ入れないでください**。
スクリプトはこれらをビルド時にホストから読み込み、イメージに書き込むだけ
です。テンプレート側にはプレースホルダだけがあります。

## 旧環境から残す必要が無いもの

- 今回の会話履歴、OpenCode のセッション DB
- `/root` に取ってある BCD・`bootmgfw.efi`・`boot.stl`・ESP のバックアップ
  （`build-image.sh` は ISO とインストール済み Windows から取り直す）
- 実機 ESP の `EFI/ubuntu/grubenv`（診断マーカー、debug copy、30 秒 timeout）
- 実機の NVRAM（OCI インスタンスに付属するもので、イメージには含まれない）

`docs/WORKLOG.md` には 22.42〜22.52 の判断理由が残っているので、消して
しまっても同じ失敗を繰り返さずに済みます。

## 手順（クリーンな Ubuntu 上）

```bash
git clone <this-repository>
cd win11-arm64-oci
sudo ./scripts/setup.sh

export ISO=/path/to/Win11_ARM64.iso
export VIRTIO_ISO=/path/to/virtio-win.iso
# ブロックデバイスへ直接書く場合は DISK=/dev/sdX も指定
./scripts/build.sh --fresh-ubuntu --boot-menu 1
```

- `--fresh-ubuntu` のときだけ ESP を作り直し、復旧 Ubuntu を入れます。
- 初回だけ Ubuntu を起動する `FIRST_BOOT_UBUNTU` は既定で有効です。
  無効にする場合は `FIRST_BOOT_UBUNTU=0` を付けてください。
- イメージの検査は `pipeline/inspect_image.sh $DISK` で行えます。

## ビルド後に見るべきポイント

1. 初回起動で `Ubuntu (recovery)` が一度だけ起動する
   （`oci-ubuntu-boot-order` が Ubuntu の EFI エントリを作るため。失敗では
   ありません）
2. その後 reboot すると GRUB メニュー → 既定 `Windows 11`（1 秒）
3. シリアルの Windows Boot Manager に `WWiinnddooww` の二重表示が出ない
4. `efibootmgr -v` に Ubuntu と Windows Boot Manager が両方ある
5. Windows 起動後も power-cycle で GRUB に戻れる
   （`oem/boot.ps1` が Windows をファームウェアの末尾へ移す）

症状が出たら `docs/OCI.md` のトラブルシューティングと WORKLOG
22.42〜22.52 を参照してください。

## プッシュ前

`git status` が clean であることを確認してから push してください。この
ドキュメントと WORKLOG には個人情報（SSH 秘密鍵、パスワード、実機の
ホスト名、固定 IP など）は入れていません。
