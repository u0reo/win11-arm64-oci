# Security policy

## 報告

脆弱性や秘密情報の混入を見つけた場合は、公開 Issue ではなく
リポジトリの Security タブから private vulnerability report を送ってください。

## このプロジェクトの前提（重要）

このイメージは **隔離されたラボ / プライベートネットワーク** での利用を
前提にしています。次の設定は意図的に「緩く」してあります。

| 設定 | 値 | 理由 |
|---|---|---|
| 既定パスワード | `oci-a1` | ビルドを簡単にするため |
| RDP NLA | 無効 (`UserAuthentication=0`) | 旧クライアントとの互換 |
| RDP SecurityLayer | 0 | 同上 |
| WinRM | Basic + AllowUnencrypted | 自動化のため |
| Windows Firewall | 全プロファイル無効 | ラボ用 |

そのため、**RDP (3389) / WinRM (5985) をインターネットへ公開しないでください**。
公開すると数分で総当たり攻撃を受けます。

推奨:

- OCI のセキュリティリストで 3389/5985 を自分の IP か VPN に限定する
- Tailscale / WireGuard 経由で接続する
- 本番用途では `WIN_PASSWORD` を強い値にし、NLA を有効に戻す
- 完成イメージ (qcow2) は暗号化して保管する

## 秘密情報の扱い

- `build/` は `.gitignore` 済み。`autounattend.xml` はパスワードを含むため
  0600 で生成されます。
- GitHub Secrets はログ上でマスクされますが、**完成イメージには
  パスワードが平文で入ります**。イメージの配布先に注意してください。
- `NOTES.md` 由来の作業ログはサニタイズ済みですが、公開前に
  `grep` で再確認することを推奨します。
