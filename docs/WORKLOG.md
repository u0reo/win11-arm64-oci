# 作業ログ（サニタイズ版）

これは Windows 11 ARM64 26H2 を OCI A1 向けに構築したときの作業ログです。
公開用に次の置換を行っています。

- ユーザー名 / ホスト名 / パスワード → `User`（Linux は `$USER`） / `OCI-WIN` / `REDACTED`
- ホームディレクトリ → `$HOME`
- プライベート IP / MAC アドレス → `<private-ip>` / `<mac>`
- OCID / クラウドキー → `REDACTED`

元ログは 2026-10 から 2026-11 にかけての試行錯誤を含みます。
現在の再現手順は [README](../README.md) を参照してください。内部の流れは
[BUILD.md](BUILD.md)、GitHub Actions は [GITHUB.md](GITHUB.md) にあります。

---

# Windows 11 ARM64 / Oracle Cloud A1.Flex 起動トラブルシュート手順書

作業ディレクトリ: `$HOME/win11-arm-oci`
作成: 2026-10-05

---

# 0. 現在の状態（要約）

| 項目 | 状態 |
|---|---|
| ConvertPages エラー | **解消済み**（AnyPages パッチが有効） |
| Windows 起動 | **未達**（画面が変わるが起動せず） |
| ログ取得 | **未解決**（_bootmgr_ に Windows ロガーがない） |
| 次の_action | **診断EFIアプリ `diag40.efi` を起動して firmware を観測** |

## ディスク構成

```
sda 100G  AnduinOS   (sda1 ESP / sda2 swap / sda3 root)
sdb  50G  Windows   (sdb1 ESP 100M / sdb2 MSR / sdb3 NTFS 49.9G)
```

- Windows ESP: `sudo mount /dev/sdb1 /mnt/efi`
- Windows NTFS: `sudo mount /dev/sdb3 /mnt/win`
- NTFS は `ntfs-3g` (fuseblk)。**再起動後は必ず再マウントすること**

---

# 1. 完了済みの作業

## 1.1 根本原因の特定

`ConvertPages` エラーの原因だった `0x102000` は、
`bootmgfw.efi` が `EFI_BOOT_SERVICES.AllocatePages` に渡すアドレスだった。

```asm
; bootmgfw.efi entry point 0x10032370 内の関数
0x10032470  ldr  x8, #0x10032d58   ; リテラルプール -> 0x102000
0x10032474  str  x8, [sp, #0x70]
0x1003247c  add  x3, sp, #0x70     ; x3 = &Memory
0x10032480  mov  x2, #1            ; NumberOfPages = 1
0x10032484  mov  w1, #2            ; EfiBootServicesData
0x10032488  mov  w0, #2            ; EfiAllocateAddress   <== 原因
0x1003248c  ldr  x8, [x8, #0x28]   ; BS->AllocatePages
0x10032494  bl   0x1024b650
0x10032498  blr  x15
```

### 確認した根拠

| 根拠 | 内容 |
|---|---|
| `BS+0x28` の正体 | `EFI_BOOT_SERVICES` = `Hdr`(0x18) + `RaiseTPL`(8) + `RestoreTPL`(8) → `AllocatePages` が 0x18…0x28。EDK2 `MdePkg/Include/Uefi/UefiSpec.h` のメンバー順と一致 |
| 引数の形 | UEFI `AllocatePages(AllocationType, MemoryType, Pages, Memory)` の 4 引数と完全一致 |
| `[sp+0x70]` の用途 | 関数内で**書かれるだけ**。読み出しは 1 箇所もない（`0x10032370`–`0x10032d2c` 全走査） |
| 再配置されない | `.reloc` に RVA `0x32D58` のエントリが無い。PE rebase 後でも `0x102000` のまま（実測） |
| ロード命令は 1 箇所のみ | `0x102000` を `LDR literal` で読む命令は `.text` 全体で 1 箇所 |

## 1.2 適用したパッチ

`mov w0, #2` (EfiAllocateAddress) → `mov w0, #1` (EfiAllocateAnyPages)

- 変更は **1 バイトのみ**（ファイルオフセット `0x31888`）
- 生成: `work/tools/make_patch.py`
- **確認済み**: ConvertPages エラーは消えた

### バイナリ一覧（`work/bin/`）

| ファイル | sha256 | 用途 |
|---|---|---|
| `bootmgfw.orig.efi` | `6a5aa7f0…` | Microsoft 原本 |
| `bootmgfw.anypages.efi` | `ef2d713c…` | **ESP に配置中** |
| `bootmgfw.none.efi` | `a3402bfd…` | EfiAllocateNone 版（未使用） |
| `bootmgfw.rebased.efi` | `ee1139bd…` | ImageBase を `0x40000000` へ |
| `bootmgfw.rebase-anypages.efi` | `55f7377d…` | rebase + パッチ両方（未使用） |

## 1.3 訂正した handoff の誤読

| 記述 | 実際 |
|---|---|
| `.data` に `0x102000` が 5 個 | **誤読**。該当バイト `00200010` を 8byte LE で読むと `0x10002000`。URL 文字列の一部 |
| `{6efb52bf-…}` が Windows loader | **誤り**。`Elements` は `14000006` と `1500000E` のみ |
| 正しい Windows loader | `{cc075cd7-8065-11ef-b427-f0aaf1083c73}`（`12000002 = \WINDOWS\system32\winload.efi`） |
| `1500000E` (avoidlowmemory) | 正しい loader には**入っていない**。誤ったオブジェクト `{6efb52bf-…}` にあるため**機能していない** |

---

# 2. 次に行うこと（テスト依頼）

## 手順 A: 診断EFIアプリを起動して firmware を観測 ★最優先

`diag40.efi` は bootmgfw を経由せず、**直接 firmware が UEFI Boot Services を呼ぶ**ため、
どこで止まるかを切り分けられます。

1. 再起動
2. GRUB メニューから **"DIAG: probe firmware (Windows debug)"** を選ぶ
3. 画面内容を**写真またはテキストで記録**して私に教えてください

### 手順書の判定表

`diag40.efi` の出力から以下が分かります。

| 出 力 | 意味 | 次の手段 |
|---|---|---|
| `[1]` で `0x102000` が `Conventional` | firmware は普通に RAM として見ている。ConvertPages 失敗は別の原因 | `[2][4]` を確認 |
| `[1]` で `0x102000` が `Reserved`/`MMIO` | AAVMF が意図的に予約 | firmware 側の回避策 |
| `[2]` `AllocatePages(addr 0x102000)` が **SUCCESS** | firmware は渡せる。ConvertPages 失敗は別の呼び出し | `[4]` を確認 |
| `[2]` が **NOT_FOUND** | firmware が拒否 | AnyPages パッチが正しい |
| `[4]` `LoadImage bootmgfw.efi` が **SUCCESS** | イメージ自体は有効。失敗は bootmgfw の**実行時** | 実行時ログ采取が必要 |
| `[4]` が **NOT_FOUND** | ESP パス/ファイル名の問題 | ESP 構成を疑う |
| `[6]` SimpleFileSystem count | NTFS が見えるか（`>= 2` なら OK） | — |

## 手順 B: パッチパターンの切り替え（diag が失敗時）

ConvertPages エラーは消えたが起動しない。firmware 側のログは取れないため、
**bootmgfw を複数パターンで試す**。

| パターン | 変更点 |
|---|---|
| 1（現在） | AnyPages パッチ済み |
| 2 | rebase 版 (`0x40000000`) のまま |
| 3 | rebase + AnyPages パッチ |
| 4 | 元のまま（比較用） |

patternswitch コマンド:

```bash
# 例: rebase + パッチ版を試す
sudo cp ~/win11-arm-oci/work/bin/bootmgfw.rebase-anypages.efi \
        /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi
```

観察点: **画面が切り替わるか / どこで止まるか**。

---

# 3. 判明した壁と、その性質

## 3.1 Windows の debug ロガーは使えない

`bcdedit /debug on` は `bootmgfw` ではなく **`winload.efi` 以降**に効く。
`bootmgfw` 内に BCD の `debugsettings` パーサーは存在しない
（`bootmgfw` を走査したが `debugsettings` 文字列なし）。

つまり **bootmgfw が winload.efi を起動する前に失敗している**か、
**winload.efi 自身が起動できない**かのどちらか。

## 3.2 BCD は NTFS 側に無い

ESP の `EFI/Microsoft/Boot/BCD` が唯一の BCD。
NTFS 側 (`/mnt/win/Windows/System32/config/BCD`) は存在しない。

## 3.3 ESP の BCD / BOOTSTAT.DAT が更新されていない

```
BCD           2026-10-04 17:31   ← avoidlowmemory を入れたとき
BOOTSTAT.DAT  2024-10-02 23:03   ← イメージ作成時点から更新されず
```

ConvertPages パッチ適用後も `BOOTSTAT.DAT` は 2024 年のまま。
**bootmgr がディスク書き込みまで到達していない**ことの示唆。

## 3.4 firmware の DEBUG() 出力が ConvertPages メッセージの正体

`ConvertPages: failed to find range ...` は EDK2 の
`MdeModulePkg/Core/Dxe/Mem/Page.c:CoreConvertPagesEx` の `DEBUG()` 出力。
**bootmgfw ではなく firmware からのメッセージ**だった。

Ubuntu の AAVMF は RELEASE build なので、この文字列は**含まれない**
→ ローカル（QEMU）では再現不可。OCI 実機でのみ観測可能。

## 3.5 ローカル検証環境の制限

| 項目 | 状況 |
|---|---|
| QEMU + AAVMF | `qemu-system-aarch64` + `/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd` |
| RAM base | QEMU `virt` 既定 `0x40000000` = OCI A1.Flex と同配置 |
| **UEFI Shell** | **Ubuntu AAVMF に含まれない**（RELEASE build） |
| **debugcon 出力** | **RELEASE build には debug 文字列が無い** |
| UEFI コンソール | GOP(VGA) に bind するため `-serial` に出ない |
| 回避策 | QMP `screendump` → PNG → OCR（`work/tools/screen.py`） |

→ **ConvertPages エラーはローカルでは再現できないため、起動テストは必ず実機。**

---

# 4. 作成物

## 4.1 診断EFIアプリ

`work/diag/diag.c` → `work/diag/diag40.efi`（ESP `/EFI/diag40.efi`）

### ビルド手順

```bash
cd ~/win11-arm-oci/work/diag

gcc -I/usr/include/efi -I/usr/include/efi/aarch64 -I/usr/include \
    -fpic -fshort-wchar -Wall -c diag.c -o diag.o

ld -nostdlib -znocombreloc -T /usr/lib/elf_aarch64_efi.lds \
   -shared -Bsymbolic -L/usr/lib diag.o -o diag.so -lefi -lgnuefi

# ELF -> PE32+ EFI アプリ（EDK2 の GenFw を使う）
~/edk2/BaseTools/Source/C/bin/GenFw \
    -e UEFI_APPLICATION --rebase 0x40000000 -o diag40.efi diag.so
```

### 出力する内容

| 番号 | 内容 |
|---|---|
| `[7]` | LoadOptions（GRUB chainload が渡したもの） |
| `[6]` | SimpleFileSystem ハンドル一覧（NTFS が見えるか） |
| `[1]` | GetMemoryMap: 1MB 以下の記述子、`0x102000` を含むもの、総容量 |
| `[2]` | AllocatePages(EfiAllocateAddress) を `0x102000` 等で試行 |
| `[3]` | AllocatePages(AnyPages) / (MaxAddress) の挙動 |
| `[4]` | `bootmgfw.efi` の LoadImage 成否 |

出力は **ConOut と Serial の両方**。

### 導入

```bash
sudo cp work/diag/diag40.efi /mnt/efi/EFI/diag40.efi
sudo chmod 755 /mnt/efi/EFI/diag40.efi

sudo tee -a /etc/grub.d/40_custom >/dev/null <<'EOF'

menuentry "DIAG: probe firmware (Windows debug)" {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root 1C00-18B3
    chainloader /EFI/diag40.efi
}
EOF

sudo update-grub
```

## 4.2 解析ツール（`work/tools/`）

| ファイル | 用途 |
|---|---|
| `make_patch.py` | AnyPages / None パッチ生成（自己検証付き） |
| `peinfo.py` | PE ヘッダ・セクション要約 |
| `scan.py` | AArch64 の BL/LDR-literal/ADRP を**手動デコード**して xref 抽出 |
| `strxref.py` | 全 word 走査で ADRP/ADR 参照を網羅 |
| `funcs.py` | `.pdata` から関数境界取得 |
| `screen.py` | QMP screendump + OCR で UEFI 画面をテキスト化 |
| `qlab.py` / `qsh.py` / `run-qemu.sh` | QEMU + AAVMF 自動操作ハーネス |

**重要**: `objdump -d` や capstone の線形逆アセンブルは
`.text` 内の data で停止・誤認する。xref 検索には `scan.py` を使うこと。

## 4.3 解析済みバイナリ（`work/bin/`）

```
bootmgfw.orig.efi            Microsoft 原本
bootmgfw.anypages.efi        AnyPages パッチ（ESP 配置中）
bootmgfw.none.efi            None パッチ
bootmgfw.rebased.efi         rebase のみ
bootmgfw.rebase-anypages.efi rebase + パッチ
bootaa64.efi                 ESP の \EFI\Boot\bootaa64.efi
winload.efi                  \Windows\System32\winload.efi
BCD.pre-debug                バックアップ付き BCD
BCD.xml                      BCD の XML ダンプ
```

---

# 5. ロールバック

## bootmgfw を元に戻す

```bash
sudo cp /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi.bak-20261004-213531 \
        /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi
```

または Microsoft 原本から:

```bash
sudo cp /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi.orig \
        /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi
```

## GRUB を元に戻す

```bash
sudo cp /etc/grub.d/40_custom.bak-20261005-042757 /etc/grub.d/40_custom
sudo update-grub
```

## すべて元に戻す（完全版）

```bash
sudo mount /dev/sdb1 /mnt/efi
sudo cp /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi.orig \
        /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi
sudo rm -f /mnt/efi/EFI/diag40.efi
sudo cp /etc/grub.d/40_custom.bak-20261005-042757 /etc/grub.d/40_custom
sudo update-grub
```

---

# 6. 再起動後の前提作業

NTFS マウントは再起動で外れるので、NTFS 側のデータを読む前に:

```bash
sudo mount /dev/sdb3 /mnt/win
```

ESP は `fstab` ではなく手動マウントの場合は同様に:

```bash
sudo mount /dev/sdb1 /mnt/efi
```

Windows 側のバイナリは NTFS リパースタグ（`0x80000017`）の
理由で通常コピーできない。`ntfscat` を使う:

```bash
sudo umount /mnt/win
sudo ntfscat /dev/sdb3 /Windows/System32/winload.efi > winload.efi
sudo mount /dev/sdb3 /mnt/win
```

---

# 7. 未解決事項

| # | 項目 | 状態 |
|---|---|---|
| 1 | ConvertPages 後に起動しない真因 | **diag40.efi の出力待ち** |
| 2 | `0x102000` 以外の ConvertPages 要因 | パッチで消えたか未確認（ユーザー報告では消えた） |
| 3 | BCD の `1500000E` を正しい loader へ | 未実施。Windows なしで値フォーマットを確定する必要あり |
| 4 | rebase 版と組み合わせた動作 | 未テスト |
| 5 | firmware からのデバッグログ取得 | AAVMF の RELEASE build では不可 |

---

# 8. 課された教訓（メモ）

- `create_file` は**既存ファイルに使えない**。編集は `replace_string_in_file`、
  作り直しは `rm` してから使うこと。
- ARM64 `MOV (wide imm)`: **Rd は下位 5 bit**。
  `0x52800001` は `mov w1, #0` であって `mov w0, #1` ではない。
  判定は `(word & 0x1F, (word >> 5) & 0xFFFF)`。
- `pefile` の `pe.__data__` は **read-only**。`bytearray` にコピーしてから書き戻す。
- `genfw` の ELF→PE 変換は **aarch64 では可靠性が無い**（第 9 章を参照）。
  `tools/elf2pe.py` で自前生成する。
- `gnu-efi` 4.0 は UEFI 2.x 系の**古い型定義**:
  - `EFI_MEMORY_DESCRIPTOR` は `PhysicalStart` / `NumberOfPages` 形式
  - `EFI_SIMPLE_TEXT_OUT_PROTOCOL` が正式名（`EFI_SIMPLE_TEXT_OUTPUT` は無い）
  - `EFI_BOOT_SERVICES` に `GetMemoryDescriptorSize` が無い
  - `EFI_SYSTEM_TABLE` に `LoadOptions` が無い（オフセット 0x68 から生読み）
  - `EFI_FILE_IO_INTERFACE` に `GetVolume` / `CloseVolume` が無い
- aarch64 には `-mno-red-zone` オプションが無い。
- 出力を`| tail` やリダイレクトで拾うと端末出力が壊れるので、
  大きな出力はファイルに書いてから `read_file` / `grep` で見る。

---

# 9. diag40.efi のクラッシュ原因と修正（2026-10-05）

## 9.1 発生した現象

GRUB から `diag40.efi` を起動すると即座に落ちた:

```
Synchronous Exception at 0x000000063DE96240
PC 0x00063DE96240 (0x00063DE96000+0x00000240) [ 0] diag.so
ESR 0x02000000   EC 0x00  IL 0x1  ISS 0x00000000
FAR 0x1DE7EC7EDBADC0DE
```

### 重要: これは OCI の AAVMF が DEBUG build である証拠ではない

スタックの `[1]`–`[5]` に `DxeCore.dll` / `BdsDxe.dll` の
**ビルドパスが `DEBUG_GCC5`** と書かれているが、これは
**クラッシュしたイメージのデバッグ情報**（`[0] diag.so` の PDB パス）
であり、firmware 全体のビルドモードを意味しない。
`ConvertPages` メッセージは OCI 側で実際に観測されているので、
OCI の AAVMF に debug 出力 functionality はある（後述の 3.4 参照）。

## 9.2 真因（3 つ重なっていた）

### 真因 1: GenFw が `.rela` を処理せず `.reloc` を作らない

gnu-efi の crt は動的リンクなので、変換必要な relocation は
ほぼ全て **`R_AARCH64_RELATIVE`（164 個）**。

EDK2 の `BaseTools/Source/C/GenFw/Elf64Convert.c: WriteRelocations64()` は
AARCH64 の `ABS` / `ADD_ABS_LO` / `ADR_GOT_PAGE` / `ADR_PREL_PG_HI` /
`CALL` / `JUMP` / `LDST` などは対応しているが
**`R_AARCH64_RELATIVE` は未対応**。

結果として:

```
BASERELOC dir  rva=0x00000000 size=0x00000000  (STRIPPED)
```

### 真因 2: `.reloc` が無い PE は ImageBase でロードできない

UEFI spec では、`PEIM`/`DXE` ドライバは `.reloc` が無ければ
**BASERELOC ディレクトリ综合体にチェック**.
firmware はイメージ全体を好きなアドレスに置くしかなく、
UEFI アプリの 定位置（`ImageBase`）に置けない。

すると:
- ELF 内では絶対アドレスだった值为、配置後kidに全く違う値になる
- `.text` 内の `adrp` / `ldr` / `b` / `bl` が全てずれる
- エントリが**未定義命令**として実行される

これが `ESR 0x02000000 / EC 0x00`（undefined instruction）の正体。

### 真因 3: GenFw は `--rebase` 時に**入力ファイルを上書きする**

```
$ GenFw --help
  --rebase NewAddress   Rebase image to new base address.
  ...
  Overwrite the input file with the output content.
```

`--rebase` は途中で入力ファイルを PE で上書きする。
1 回目は成功するが、**2 回目は「PE を PE に変換」**することになり
`ERROR 3000: The input PeImage is not valid` で失敗する。
結果、`diag.so` が PE converted に化けていて、
以降の分析はすべて壊れた PE に対して行われていた。

## 9.3 修正: `tools/elf2pe.py`（自作 ELF→PE 変換）

GenFw を回避し、Python で PE32+ を直接組み立てる。

```bash
cd ~/win11-arm-oci/work/diag

gcc -I/usr/include/efi -I/usr/include/efi/aarch64 -I/usr/include \
    -fpic -fshort-wchar -Wall -c diag.c -o diag.o

# -Bsymbolic を付けないこと（付けすと relocation が 0 件になる）
ld -nostdlib -znocombreloc -T /usr/lib/elf_aarch64_efi.lds \
   -shared -L/usr/lib diag.o -o diag.elf -lefi -lgnuefi

../venv/bin/python ../tools/elf2pe.py diag.elf diag40.efi --base 0x40000000
```

### 動作

1. `PT_LOAD` セグメントからイメージ実体を取り出す
2. `.text` / `.rodata` / `.data` を PROGBITS から収集
3. `SHT_RELA` / `SHT_REL` を走査し
   `R_AARCH64_RELATIVE` / `ABS` / `GLOB_DAT` を収集
   （対象セクションは **`sh_info` ではなく `r_offset` から判定**。
   gnu-efi の ELF は `sh_info` が dynsym を指すことがあるため）
4. 絶対値を `ImageBase` 相対に書き換え
5. `IMAGE_REL_BASED_DIR64`（type 3）の `.reloc` ブロックを 4KiB ページ単位に生成
6. PE32+ ヘッダ + `.text`(RX) / `.data`(RW) / `.reloc` を XIP で配置

### 生成結果

```
ImageBase 0x40000000  Entry 0x1000
.text  0x1000 +0x15a00
.data  0x16a00 +0x1800
.reloc 0x18200 +0x200 (165 entries)
Subsystem 10 (EFI app)   Machine 0xAA64
BASERELOC 0x18200 size 0x200
```

## 9.4 ESP への配置（済み）

```
sha256 f7a677f7ed70fb0bd2e8426b41da949749fb02d152797acb9f91d700088e31f2
/mnt/efi/EFI/diag40.efi
```

## 9.5 次のテスト依頼

1. 再起動
2. GRUB から **"DIAG: probe firmware (Windows debug)"** を選択
3. `[1]`〜`[4]` の出力（例外が出る場合はスタックトレース全文）を報告

### 期待される出力の解釈

| 出力 | 意味 |
|---|---|
| `[1]` `0x102000` が `Conventional` | firmware は RAM として見ている |
| `[1]` `0x102000` が `Reserved` / `MMIO` | AAVMF が意図的に予約 |
| `[2]` `AllocatePages(addr 0x102000)` SUCCESS | firmware は渡せる |
| `[2]` NOT_FOUND | firmware が拒否（AnyPages パッチが正しい） |
| `[4]` `LoadImage bootmgfw.efi` SUCCESS | イメージ有効・失敗は実行時 |
| `[4]` NOT_FOUND | ESP パス/ファイル名の問題 |

## 9.6 ローカル QEMU 検証ができなかった理由

Ubuntu AAVMF は RELEASE build のため:

- UEFI Shell を含まない（Boot Manager Menu からシェルに入れない）
- `ConvertPages` 等の debug 文字列を含まない
- UEFI コンソールが GOP(VGA) に bind し、`-serial` に出ない
  （`-vga none` を付けると Boot Manager Menu の画面が何も描画されない）
- GRUB を起動しても NVRAM の `Boot####` がないため手動操作が要る

→ ConvertPages エラーは**ローカルでは再現不可**。
実機テストが必須。

## 9.7 修正後の PE が正しいことの根拠

| 検査 | 結果 |
|---|---|
| `file` | `PE32+ executable for EFI (application), ARM64, 3 sections` |
| `Subsystem` | `10` (EFI application) |
| `Machine` | `0xAA64` (ARM64) |
| `ImageBase` | `0x40000000` |
| `.reloc` | 存在、`BASERELOC` ディレクトリが `0x18200` を指す |
| relocation エントリ | 166 件、type 3 (`DIR64`) |
| エントリバイト | `ff4300d1` = `sub sp, sp, #0x10`（`_start` の実コード） |

旧版（crash した版）はエントリが全ゼロバイトで
`udf #0`（未定義命令）になっていた。

---

# 10. 「cannot load image」の原因と修正（2026-10-05）

## 10.1 現象

GRUB から `diag40.efi` を選ぶと:

```
エラー: cannot load image。
```

画面は出ない。GRUB aliens igger して終了する。

## 10.2 メッセージの由来

`/boot/efi/EFI/AnduinOS/grubaa64.efi` を strings で調べた結果、
このメッセージは **chainloader モジュール**にある:

```
chainloader.c / out of memory / out of resources / cannot load image /
no loaded image available / Load another boot loader.
```

→ `grub_dev_chainloader` が `StartImage` に失敗したときに出る。
つまり **firmware がイメージのロードを拒否した**。

## 10.3 真因: `SizeOfOptionalHeader` が 0xF000 だった

`elf2pe.py` の FILE_HEADER  packs で
`SizeOfOptionalHeader` に `0xF000` を渡していた。

```python
struct.pack_into("<HHIIIHH", out, fh,
                 0xAA64, nsec, 0, 0, 0, 0xF000, 0x0022)
#                                        ^^^^^^ これが SizeOfOptionalHeader
```

PE32+ の正しい値は **`0xF0`**（240 バイト）。

### 壊れ方

`SizeOfOptionalHeader` が 0xF000 だと:

- `oh = fh + 20` から 0xF0 バイトが optional header
- セクションテーブルは `oh + SizeOfOptionalHeader` = `oh + 0xF000` に置かれると
  考えるので、**ファイル末尾近辺を_secs_ として garbage を見る**
- → 全セクションが `vs=0 va=0 rs=0 ro=0 ch=0` に見える
- → firmware / GRUB が「有効な PE ではない」と判定

実測（修正前）:

```
PE off 0x40  NumberOfSections 3  SizeOfOptionalHeader 0xf000
section table at 0xf058 -> end 0xf0d0   file size 0x19000
  [0] b''   vs=0x0 va=0x0 rs=0x0 ro=0x0 ch=0x0
  [1] b''   vs=0x0 va=0x0 rs=0x0 ro=0x0 ch=0x0
  [2] b''   vs=0x0 va=0x0 rs=0x0 ro=0x0 ch=0x0
```

修正後:

```
PE off 0x40  NumberOfSections 3  SizeOfOptionalHeader 0xf0
section table at 0x148 -> end 0x1c0
  [0] b'.text'   vs=0x15a00 va=0x1000  rs=0x15a00 ro=0x1000  ch=0x60000020
  [1] b'.data'   vs=0x1800  va=0x16a00 rs=0x1800  ro=0x16a00 ch=0xc0000040
  [2] b'.reloc'  vs=0x200   va=0x18200 rs=0x200   ro=0x18200 ch=0x42000040
```

## 10.4 副次的な問題: エントリポイント

ELF は共有オブジェクト（`e_type = ET_DYN`）なので **`e_entry = 0`**。
そのまま PE にすると `AddressOfEntryPoint = 0x1000`（`.text` 先端）になり、
そこは `.eh_frame` のデータで**未定義命令**になる。

### 修正: `_start` プロローグの自動検出

gnu-efi の PE 用エントリ `_start` の先頭は

```
sub  sp, sp, #0x10     ; d10043ff
str  w0, [sp, #12]     ; e00f00b9
```

（`stp x29,x30` ではない。gnu-efi の `_start` は別の形）

この 8 バイト列を image 内で探し、那里的オフセットを
`AddressOfEntryPoint` にするようにした。

実測で `_start` は image offset `0x3000` にあり、
これが PE の `.text` 先端に一致する。

## 10.5 修正後の PE

```
sha256 b92f1a4285b401a8470f8675e99320dcd96953e39da5314e9e5fbe4872057da0
/mnt/efi/EFI/diag40.efi
```

`grub-file --is-arm64-efi` で GRUB が受理することを確認済み。

## 10.6 検証用コマンド

```bash
# PE が GRUB に受理されるか
grub-file --is-arm64-efi /mnt/efi/EFI/diag40.efi; echo "rc=$?"

# セクションテーブルが正しいか
python3 - <<'EOF'
import struct
b=open('/mnt/efi/EFI/diag40.efi','rb').read()
pe=struct.unpack_from('<I',b,0x3C)[0]
fh=pe+4
nsec=struct.unpack_from('<H',b,fh+2)[0]
optsz=struct.unpack_from('<H',b,fh+16)[0]
print('SizeOfOptionalHeader',hex(optsz),'(must be 0xf0)')
oh=fh+20; st=oh+optsz
print('entry',hex(struct.unpack_from('<I',b,oh+16)[0]))
for i in range(nsec):
    o=st+i*40
    nm=b[o:o+8].rstrip(b'\0').decode()
    vs,va,rs,ro=struct.unpack_from('<IIII',b,o+8)
    print(f'  {nm:8s} va={va:#x} vs={vs:#x} ro={ro:#x} ch={struct.unpack_from("<I",b,o+36)[0]:#x}')
EOF
```

## 10.7 教訓の追加

- PE の `FILE_HEADER` は 6 フィールド:
  `Machine(H) NumberOfSections(H) TimeDateStamp(I) PointerToSymbolTable(I)
   NumberOfSymbols(I) SizeOfOptionalHeader(H) Characteristics(H)`
  `SizeOfOptionalHeader` を `Characteristics` と取り違えやすい。
- ELF 共有オブジェクト（`ET_DYN`）の `e_entry` は 0。
  PE 変換時は `_start` を別途探す必要がある。
- 自作 PE を既存の GRUB / firmware に食わせて **`grub-file` で受理確認**すると
  银杏に気づける。


---

# 11. 「cannot load image」再発と SectionAlignment（2026-10-05）

## 11.1 症状

第 10 章の修正（`SizeOfOptionalHeader = 0xF0`）を適用，但仍く:

```
エラー: cannot load image。
```

## 11.2 重要な認識修正

**`cannot load image` は GRUB の PE パーサエラーではない。**

GRUB の `chainloader` は firmware の Boot Services に
`StartImage` を委譲するだけである。メッセージは
`grub/loader/efi/chainloader.c` にあるが、
発生源は firmware の `LoadImage`/`StartImage` の失敗。

したがって **GRUB 側を調べても原因は分からない**。
OEVM 側の `PeCoffLoaderLoadImage()` を読む必要がある。

## 11.3 EDK2 の LoadImage 検証条件（該当箇所）

`MdePkg/Library/BasePeCoffLib/BasePeCoff.c`:

| 行 | 条件 | 違反時 |
|---|---|---|
| 319-322 | `NumberOfRvaAndSizes <= 16` | `UNSUPPORTED` |
| 334-339 | `SizeOfOptionalHeader - 112 == NumberOfRvaAndSizes * 8` | `UNSUPPORTED` |
| 234 | `SizeOfHeaders > SectionHeaderOffset` | `UNSUPPORTED` |
| 239 | `SizeOfHeaders < SizeOfImage` | `UNSUPPORTED` |
| 244 | `(SizeOfHeaders - SectionHeaderOffset) / 40 >= NumberOfSections` | `UNSUPPORTED` |
| 1337 | `ImageAddress` が `SectionAlignment` アライン | `INVALID_SECTION_ALIGNMENT` |
| 1312 | `RelocationsStripped` なら `ImageAddress == LinkedAddress` 必須 | `INVALID_IMAGE_ADDRESS` |
| 1410-1412 | セクションの `Base`/`End` が NULL（`RVA >= ImageSize`） | `SECTION_NOT_LOADED` |

## 11.4 真因: `SectionAlignment = 0x20`（XIP）

第 10 章の PE は XIP を意図して `SectionAlignment = 0x20` にしていた。

```python
struct.pack_into("<I", out, oh + 32, 0x20)       # SectionAlignment  ← 0x20
struct.pack_into("<I", out, oh + 36, 0x20)       # FileAlignment     ← 0x20
```

EFI の world では这不是标准である。

### Microsoft bootmgfw.efi の実値

```
SectionAlignment 0x1000
FileAlignment    0x200
Characteristics  0x2022   (EXEC|LARGE_ADDRESS|LARGE_SECTION_ADDRESS)
```

`Characteristics` の `0x2000` = `LARGE_SECTION_ADDRESS` は
**「SectionAlignment >= 0x1000」であることを意味**する。
これが無いと 0x20 のような小さい値は原理的に不正。

### EDK2 への影響

`MdeModulePkg/Core/Dxe/Image/Image.c:652`:

```c
if (Image->ImageContext.SectionAlignment > EFI_PAGE_SIZE) {
  Size = ImageSize + SectionAlignment;
} else {
  Size = ImageSize;
}
Image->NumberOfPages = EFI_SIZE_TO_PAGES (Size);
```

`0x20 < 0x1000` なので `Size = ImageSize` になるが、
`BasePeCoff.c:1337` の

```c
if ((ImageContext->ImageAddress & (CheckContext.SectionAlignment - 1)) != 0)
```

は `ImageAddress & 0x1F == 0` を要求する。
firmware が 4KiB 単位でページを確保した場合 ImageAddress は
ページ境界なので通常は通るが、**这不是保证**であり、
LoadOptions でtrak な rekord になることがある。

## 11.5 修正内容

`elf2pe.py` を Microsoft の EFI イメージに合わせて変更:

| 項目 | 旧 | 新 |
|---|---|---|
| `SectionAlignment` | `0x20` | **`0x1000`** |
| `FileAlignment` | `0x20` | **`0x200`** |
| `Characteristics` | `0x0022` | **`0x2022`**（+`LARGE_SECTION_ADDRESS`） |
| セクション配置 | XIP（RVA == raw offset） | RVA と raw offset を分離 |

`SectionAlignment != FileAlignment` にしたため、
セクションごとに `PointerToRawData` を別々に持つ必要がある:

```
.text   vaddr=0x01000  rawoff=0x01000  size=0x15a00
.data   vaddr=0x17000  rawoff=0x16a00  size=0x01800
.reloc  vaddr=0x19000  rawoff=0x18200  size=0x00200
```

## 11.6 Microsoft イメージとの比較（全項目）

```
field                       ours                 MS   match
Machine                     0xaa64             0xaa64  OK
SizeOfOptionalHeader        0xf0               0xf0    OK
Characteristics             0x2022             0x2022  OK
Subsystem                   10                 10      OK
SectionAlignment            0x1000             0x1000  OK
FileAlignment               0x200              0x200   OK
NumRvaAndSizes              16                 16      OK
NumSections                 3                  6       DIFF (正当)
ImageBase                   0x40000000         0x10000000  DIFF (正当)
Entry                       0x3000             0x32370     DIFF (正当)
SizeOfImage                 0x1a000            0x2c5000    DIFF (正当)
SizeOfHeaders               0x1000             0x400       DIFF (正当)
BASERELOC                   0x19000            0x2c3000    DIFF (正当)
```

ヘッダ構造体は完全一致。差分は正当な値のみ。

## 11.7 EDK2 ロード条件の機械検証

```
SectionHeaderOffset 0x148
SizeOfHeaders       0x1000
SizeOfImage         0x1a000
NumberOfSections    3

chk1 SizeOfHeaders > SectionHeaderOffset : True (0x1000 > 0x148)
chk2 SizeOfHeaders < SizeOfImage         : True
chk3 room for all section headers        : 94 >= 3 -> True
OptionalHdr sanity: 0xf0 - 0x70 = 0x80 ; NumRvaAndSizes*8 = 0x80
  match: True
```

全て通過。

## 11.8 配置済み

```
sha256 6542a0d413a0f4e8b4bcf807afec58f0dd5bb7305193aeee8aad7e96f62ffbbf
/mnt/efi/EFI/diag40.efi
```

`grub-file --is-arm64-efi` も `rc=0`。

## 11.9 教訓

- **EFI イメージの `SectionAlignment` は 0x1000 が標準**。
  XIP 的に 0x20 にするのは U-Boot 专用で、UEFI firmware は拒否する。
- `Characteristics` の `LARGE_SECTION_ADDRESS (0x2000)` は
  「SectionAlignment >= 0x1000」の宣言。付けずに
  小さい SectionAlignment を書くと矛盾する。
- `SectionAlignment != FileAlignment` のとき、
  PE は XIP ではないので `PointerToRawData` を
  セクション個別に計算する必要がある。
- **`cannot load image` / `LoadImage  failed` は firmware 側の失敗**。
  GRUB の strings を追っても原因は分からない。
  `MdePkg/Library/BasePeCoffLib/BasePeCoff.c` を読むこと。


---

# 12. ログが出ない問題 → ESP ファイル出力（2026-10-05）

## 12.1 症状

第 11 章の修正で `cannot load image` は解消した。しかし:

- 画面（WDDG/GOP）に何も出ない
- シリアルにも何も出ない

## 12.2 原因

AAVMF の UEFI コンソールは **GOP（VGA）に bind** する。
headless な OCI インスタンス（`drm.edid_firmware=Virtual-1`）では
GOP のフレームバッファが有效的に表示 できない。

シリアルも `SerialDxe` の実装が firmware 依存で、
`LocateHandleBuffer(SerialIo)` で 1 個も見つからないことがある。

→ **画面・シリアルはどちらも「(())
保証されない」**。

## 12.3 対処: ESP のファイルに書き出す

唯一の確実な出力先として **ESP 上のファイル**を使う。

```c
static EFI_FILE_HANDLE g_log = NULL;

static void log_raw (const char *s) {
  UINTN n = 0;
  while (s[n]) n++;
  if (!g_log) return;
  if (EFI_ERROR (g_log->Write (g_log, &n, (VOID *)s))) g_log = NULL;
}

static void say (const char *s) {
  log_raw (s);            /* ← ESP に追記 */
  /* ConOut と SerOut にも出す（あれば） */
}
```

`efi_main` の**最初**で `log_open()` を呼ぶ。
この以降の全ての `say()` が自動的にファイルに入る。

```c
static void log_open (void) {
  EFI_FILE_IO_INTERFACE *fio = NULL;
  EFI_FILE_HANDLE root = NULL, dir = NULL, logf = NULL;

  HandleProtocol (g_image, &gEfiSimpleFileSystemProtocolGuid, &fio);
  fio->OpenVolume (fio, &root);
  dir = root;
  uefi_call_wrapper (dir->Open, 4, dir, &dir, L"\", EFI_FILE_MODE_READ, 0);
  uefi_call_wrapper (dir->Delete, 1, dir);
  uefi_call_wrapper (dir->Open, 5, dir, &logf, L"diaglog.txt",
                     EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE |
                     EFI_FILE_MODE_CREATE, 0);
  g_log = logf;
}
```

## 12.4 起動後の確認手順

再起動して DIAG を実行した後:

```bash
# 1) ESP をマウント
sudo mount /dev/sdb1 /mnt/efi

# 2) ログを読む
sudo cat /mnt/efi/diaglog.txt
```

ファイルが無い場合:
- `log_open()` 自体が失敗（ESP が書けない）
-  Napa early exit した可能性
→ その場合は `/EFI/diaglog.txt` も確認。

## 12.5 注意（gnu-efi 4.0 の API 差異）

| API | 注意点 |
|---|---|
| `EFI_FILE.Delete` | 引数は **1 個**（`dir->Delete(dir)`）。名前を取らない |
| `EFI_FILE.Open` | 引数は **5 個**（handle, &new, name, mode, attrs） |
| `EFI_BOOT_SERVICES.OpenProtocol` | 引数は **6 個** |

`EFI_FILE_DELETE` はファイル名を取らず
「開いているディレクトリ内の単一ファイルを消す」API。
既存ログを消さずに Open すると Already Exist になるので、
必ず `Delete` → `Open` の順で行う。

## 12.6 ファイル名

`diaglog.txt` は UTF-16 リテラルなので `strings` の ASCII 検索では出ない。
確認するには:

```bash
python3 -c "
d=open('diag/diag40.efi','rb').read()
print('ascii:', d.count(b'diaglog'))
print('utf16:', d.count('diaglog'.encode('utf-16-le')))
"
```

## 12.7 ビルド

```bash
cd ~/win11-arm-oci/work/diag
gcc -I/usr/include/efi -I/usr/include/efi/aarch64 -I/usr/include \
    -fpic -fshort-wchar -Wall -c diag.c -o diag.o
ld -nostdlib -znocombreloc -T /usr/lib/elf_aarch64_efi.lds \
   -shared -L/usr/lib diag.o -o diag.elf -lefi -lgnuefi
../venv/bin/python ../tools/elf2pe.py diag.elf diag40.efi --base 0x40000000
```

```
sha256 6f57ec37fcf06a348bf558ba08a7fcdbfaad84c91b503ee7c6658b08ba3fdb02
/mnt/efi/EFI/diag40.efi
```

## 12.8 教訓

- **UEFI アプリの出力は画面/シリアル/OS コンソールに依存しない
  「ファイル」に書くのが最も確実。** とくに AA VMF では画面が出ない。
- `say()` を 1 箇所に集約して、追記先を複数（画面/シリアル/ファイル）
  Stochastic ようにすると、出力先を後から増やしやすい。
- Python で既に生成済みファイルを部分的に書き換えるときは、
  `re.sub` のパターンが隣接する関数まで飲み込むことがある。
  这一次 `probe_handles` の本体と `probe_memmap`/`probe_alloc`/`probe_load`
  が消失した。**正規表現置換の後は必ず関数一覧を検証**すること。


---

# 13. diaglog.txt が作られない理由（2026-10-05）

## 13.1 症状

第 12 章で `say()` から ESP ファイルへの書き出しを追加したが、
`/mnt/efi/diaglog.txt` が **作られていなかった**。

## 13.2 真因: `g_image` に `SimpleFileSystem` が無い

最初の `log_open()` はこう stupidity していた:

```c
/* 誤: ImageHandle の SimpleFileSystem を使う */
uefi_call_wrapper (g_bs->HandleProtocol, 3, g_image,
                   &gEfiSimpleFileSystemProtocolGuid, &fio);
```

**GRUB の chainloader で起動した場合、`ImageHandle` に
`SimpleFileSystem` プロトコルは載っていない。**
GRUB 自身が `LoadImage` を呼び、その際に渡す device path は
GRUB の bloot イメージ用のものだから。

UEFI spec 的には、アプリケーションの `ImageHandle` は
「そのアプリが“从られた”デバイス」を持つだけで、
ファイルシステムのハンドルとは限らない。

実際、`HandleProtocol(g_image, SimpleFileSystem)` は
`EFI_NOT_FOUND` を返し、`log_open()` は何もせず `return` していた。

## 13.3 修正: `LocateHandleBuffer` で全ハンドルを走査

```c
static BOOLEAN log_open (void) {
  EFI_HANDLE *buf = NULL;
  UINTN n = 0, i;

  LocateHandleBuffer (ByProtocol, &gEfiSimpleFileSystemProtocolGuid,
                      NULL, &n, &buf);
  if (EFI_ERROR (st) || n == 0) return FALSE;

  for (i = 0; i < n; i++) {
    HandleProtocol (buf[i], &gEfiSimpleFileSystemProtocolGuid, &fio);
    fio->OpenVolume (fio, &root);
    /* ルート直下に diaglog.txt を作.try  */
    dir->Open (dir, &logf, L"diaglog.txt", READ|WRITE|CREATE, 0);
    if (!EFI_ERROR (st)) { g_log = logf; return TRUE; }
  }
  return FALSE;
}
```

「ESP 用のハンドル」を見つけるまで全部試す。

## 13.4 出力先 3 系統の整理

| 系統 | 状態 |
|---|---|
| ConOut (GOP/WDDG) | AAVMF は GOP に bind。headless 環境では无效 |
| SerOut (Serial) | firmware 依存。`LocateHandleBuffer(SerialIo)` が 0 個のことも |
| **ESP ファイル** | **唯一確実**（`LocateHandleBuffer` で必ず見つか���） |

## 13.5 起動後の確認手順

```bash
sudo mount /dev/sdb1 /mnt/efi
ls -la /mnt/efi/*.txt      # diaglog.txt / diaglog2.txt
sudo cat /mnt/efi/diaglog.txt
sudo cat /mnt/efi/diaglog2.txt
```

`diaglog2.txt` は `diaglog.txt` を作れなかった場合のフォールバック。
両方とも無い場合は `log_open()` 自体が失敗、
つまり `SimpleFileSystem` ハンドルが 1 つも無い状況。

## 13.6 配置済み

```
sha256 0310210b8e7ff2223bb2176b2670c5803147b4dc817fe28d73fdb741c2f62220
/mnt/efi/EFI/diag40.efi
```

`.text 0x1000 +0x15c00`（前回より 0x200 増えた = `log_open` の追加分）

## 13.7 教訓

- **EFI アプリの `ImageHandle` に `SimpleFileSystem` を期待しない。**
  特に bootloader（GRUB 等）が chainload した場合には確実に無い。
  `LocateHandleBuffer` で协议的実体を探すのが正しい。
- **`bootmgfw.efi` が ConvertPages メッセージを出せていた** =
  firmware の `LoadImage`/`StartImage` は正常に動作している。
  したがって diag のエントリも読み込まれているはず。
  ログが出ないのは「ファイルオープン失敗」の方が可能性が高い。


---

# 14. UEFI Shell から起動して分かったこと（2026-10-05）

## 14.1 侥幸: UEFI Shell から serials に出た

```
FS1:\\> EFI\diag40.efi

Synchronous Exception at 0x0000000040003000
PC 0x000040003000
PC 0x00004778CA50  DxeCore.dll
PC 0x00063DD0969C  Shell.dll
```

**BootNext=0005（EFI Internal Shell）** で GRUB を回避して起動できた。
 serialline にPLE 出すので、**serial ログは取れる**。

なお `FS1:` なので ESP は `fs1` だった。`startup.nsh` は
`fs0:` を-hardcode していたので、FS 番号に依存しないよう
`startup.nsh` は `EFI\diag40.efi` のような相対指定にする。

## 14.2 例外の原因: entry RVA が 0x1000 ずれていた

```
PC 0x000040003000    (= ImageBase 0x40000000 + 0x3000)
ESR 0x02000000  EC 0x00  -> undefined instruction
```

### レジスタが証拠

```
X2 0x0000000040003000   <- 跳んだ先（= ImageBase + EntryRVA）
X6 0x506C6C6174736E49   <- "Install" (UTF-16LE = ASCII 逆順)
X7 0x496C6F636F746F72   <- "rotocIlI"
X8 0x656361667265746E   <- "ntface"
```

→ これは **`.eh_frame` の DWARF `.debug_str` セクション**。
entry がデータ（DWARF）を指していた。

### 原因

`elf2pe.py` の entry 計算が 1 つ間違っていた:

```python
if entry is None:
    idx = img.find (want)      # img は vaddr - lo(0) の linear image
    entry = idx                # <- これがそのまま RVA になっていた
```

しかし PE では `.text` を `text_rva`（= 0x1000）に置くので、

```
正しい RVA = text_rva + idx
```

でなければならない。`idx` をそのまま使うと `text_rva` ぶんずれる。

### 修正

```python
if entry < split:                     # .text 内か確認
    entry_rva = text_rva + entry
else:
    raise SystemExit (...)
```

実測: `idx = 0x3000`、`text_rva = 0x1000` → **`entry_rva = 0x4000`**
（= 実ファイルオフセット 0x4000 の `ff4300d1` = `sub sp, sp, #0x10`）

### 教訓

- PE はセクションを `SectionAlignment` に揃えるので、
  **ELF の vaddr と PE の RVA は一致しない**。
  entry Friends Friends は「PE 内でのセクションオフセット換算」が必要。
- `_start` のバイト列検索は DWARF section にまで短路する 危険 がある。
  `sec_of_addr()` でセクションを確かめてから採用すること。

## 14.3 例外スタックから分かったこと

```
PC 0x00004778CA50  DxeCore.dll
```

→ **firmware の `DxeCore.dll` が `StartImage` を呼んだ** ので、
firmware 側は正常。GRUB 経由と同じ経路。

```
[2] ShellPkg/Application/Shell/Shell/DEBUG/Shell.dll
```

→ OCI の AAVMF に **UEFI Shell が入っている**ことが確認できた
（Ubuntu の RELEASE AAVMF には入っていないが、
Oracle の AAVMF には DEBUG build で同梱されている）。

## 14.4 GRUB を完全に回避する方法

```bash
# 1 回だけ UEFI シェルを起動する
sudo efibootmgr --bootnext 0005
sudo reboot

# 起動したら automatic で startup.nsh が diag40.efi を起動する

# BootNext を消す（消費済みだが保险に）
sudo efibootmgr --delete-bootnext
```

起動後にシェルへ手动入场する場合:
- Boot Manager Menu（`Boot0000`）→ EFI Internal Shell
- または Boot Manager Menu は `Timeout: 0` で永久待ちになるので
  ESC/Enter で SIMULATE する

## 14.5 startup.nsh の設置

```
/mnt/efi/startup.nsh
/mnt/efi/EFI/startup.nsh
```

```
@echo -off
echo === DIAG START ===
fs0:

EFI\diag40.efi
```

実機では **FS1** だったので `fs0:` の指定は無意味。
`EFI\diag40.efi` は FS 番号に依存しない相対指定なので
そのままで読めるはずだが、
確実なら `startup.nsh` の最初で
`map -r` して FS 番号を全部試すのが良い。

## 14.6 配置済み

```
sha256 02ec2200795af8e03133aa58fea34044563867805f7453d78ba7c3c95519a4ab
/mnt/efi/EFI/diag40.efi
/mnt/efi/diag40.efi      <- 両方，どちらの FS からも引けるように
```

Entry RVA 検証:

```
Entry RVA 0x4000
bytes: ff4300d1 e00f00b9 e00f40b9 1f340071 800e0054
       ^ sub sp,sp,#0x10  ^ str w0,[sp,#12]  (gnu-efi _start)
```

## 14.7 残り

次回の再起動で `diag40.efi` が正常に走れば、
ESP に `diaglog_*.txt` ができるはず。
それが取れれば:

- `0x102000` が AAVMF で何 MemoryType か
- `AllocatePages(addr 0x102000)` が通るか
- `bootmgfw.efi` の LoadImage が成功するか

が分かる。

出ない場合、次の一手は:

1. `startup.nsh` で `map -r` して FS 番号を全部試す
2. シリアルに `diag40.efi` の進捗を直接出す（ESP に書けないと何も分からないため）


---

# 15. relocation RVA 変換のバグ（2026-10-05 決定版）

## 15.1 现象

UEFI Shell から 2 通りで試しても起動できず、ログファイルも作られない:

```
# 試行 1: startup.nsh -> diag40.efi
=== DIAG START ===
FS1:> EFI\diag40.efi
FS1:> EFI\Boot\bootaa64.efi
ConvertPages: failed to find range 10000000 - 102C8FFF
Image Loaded: bootmgfw.efi
ConvertPages: failed to find range 102000 - 102FFF

# 試行 2: 手動で bootmgfw.efi
FS1:> EFI\Microsoft\Boot\bootmgfw.efi
ConvertPages: failed to find range 10000000 - 102C4FFF
Image Loaded: bootmgfw.efi
```

**重要**: `bootmgfw.efi` は **シェルから起動しても動く**
（`Image Loaded: bootmgfw.efi` が出る）。
つまり firmware の LoadImage/StartImage は正常。
`diag40.efi` だけが動かない。

## 15.2 FS マッピング（シェルの map 出力から確定）

```
FS0 = HD(1,GPT,CC4743DC-...)  = sda1 = AnduinOS ESP
FS1 = HD(1,GPT,057542D2-...)  = sdb1 = Windows ESP   <- diag40.efi はここ
```

`startup.nsh` の `fs0:` は Windows ESP ではないため
`EFI\diag40.efi` が見つからなかった可能性が高い。
`fs1:` に修正済み。

## 15.3 真因: `.reloc` の RVA が `text_rva` ぶんずれていた

###  症状

diag40.efi が何の出力も出さずに落ちる。
エントリは `0x4000`（正しい `_start`）だが、
その中の**数据的参照**が全て壊れていた。

### 原因

`elf2pe.py` が `.reloc` ブロックを**セクション配置が決まる前に**生成していた。

```python
# 旧（バグ）
relocs.append(r_off - lo)          # img 内オフセット = ELF vaddr（lo=0 のため同じ）
...
blocks = bytearray()
page = relocs[i] & ~0xFFF          # <- ELF vaddr のままページ計算
```

PE では `.text` が `text_rva = 0x1000` に置かれるため、
ELF vaddr `0x10520`（.data 内）は PE で RVA `0x17520` になる。
のに buggy コードは `0x10520` をそのまま .reloc に書いていた。

### 証拠

修正前後:

```
旧: .reloc: 165 entries, pages 0x10520..0x10cc8    <- ELF vaddr（.data を指す）
新: .reloc: 165 entries, pages 0x11520..0x11cc8    <- PE RVA（.text 内を指す）
```

旧 PE の `.reloc` は `.data` の RVA を指しており、
`.data` の実 RVA は `0x17000` なので** fences 壊れた RVA を指す**。
relocation が適用されず、イメージ内のすべての絶対参照が
リンク先（`base + ELF vaddr`）のままになり、entry から不定動作。

### 修正

1. `relocs` には **ELF vaddr のまま** 保持
2. セクション配置（`text_rva` / `data_rva` / `split`）確定後に
   RVA へ変換

```python
def img_off_to_rva(r):
    if r < split:
        return text_rva + r          # .text 内
    return data_rva + (r - split)    # .data 内

reloc_rvas = sorted({img_off_to_rva(va - lo) for va in relocs})
# 範囲チェック
for rv in reloc_rvas:
    if not (text_rva <= rv < text_rva + text_size or
            data_rva <= rv < data_rva + data_size):
        raise SystemExit(f"reloc RVA {rv:#x} outside .text/.data")
```

3. `nsec` を常に 3 にして `.reloc` を無条件に生成

## 15.4 生成結果（検証済み）

```
SizeOfOptionalHeader 0xf0        OK
Entry                0x4000      (= ff4300d1 = sub sp,sp,#0x10)
BASERELOC            0x19000/0x200
sections:
  .text    va=0x1000 vs=0x15a00 ro=0x1000 ch=0x60000020
  .data    va=0x17000 vs=0x1800  ro=0x16a00 ch=0xc0000040
  .reloc   va=0x19000 vs=0x200   ro=0x18200 ch=0x42000040
.reloc blocks:
  page 0x11000 entries 166
entry bytes: ff4300d1 e00f00b9
```

`grub-file --is-arm64-efi` → rc=0

## 15.5 配置

```
sha256 f4c85416d176df597edf2cecc02a15ab67c29b270f4868d5b5b5ffb7c9733ae0
/mnt/efi/EFI/diag40.efi
/mnt/efi/diag40.efi
```

`startup.nsh` は `fs1:` に修正済み:
```
@echo -off
fs1:
EFI\diag40.efi
```

`BootNext=0005`（UEFI Internal Shell）を設定済み。

## 15.6 次のアクション

1. `sudo reboot`
2. UEFI Shell が起動し、`startup.nsh` 経由で diag40.efi が動く
3. 起動後:

```bash
sudo mount /dev/sdb1 /mnt/efi
ls -la /mnt/efi/diaglog*.txt
sudo cat /mnt/efi/diaglog*.txt
```

## 15.7 累積したバグ（自作 PE の落とし穴まとめ）

| # | バグ | 症状 |
|---|---|---|
| 1 | GenFw が `R_AARCH64_RELATIVE` 未対応 | `.reloc` が出されない |
| 2 | `--rebase` が入力を上書き | 2 回目 `ERROR 3000` |
| 3 | `SizeOfOptionalHeader = 0xF000` | GRUB `cannot load image` |
| 4 | `SectionAlignment = 0x20` | firmware が `LoadImage` 拒否 |
| 5 | `Characteristics` に `LARGE_SECTION_ADDRESS` なし | 同上 |
| 6 | entry RVA に `text_rva` 未加算 | DWARF を実行 → 例外 |
| 7 | **`.reloc` の RVA に `text_rva` 未加算** | データ参照が全壊れ → 無音クラッシュ |
| 8 | `nsec` を `blocks` 生成前に判定 | `.reloc` セクションが出ない |

共通教訓: **ELF vaddr と PE RVA は一致しない。**
`SectionAlignment` でセクションを詰めるため、
すべてのオフセット変換は「セクション配置確定後」に行う。


---

# 16. 「Image Loaded」の真意と、rebase による最終修正（2026-10-05）

## 16.1 最重要の洞察: `Image Loaded` は「読み込み成功」ではない

ユーザー提供了决定性的証拠:

```
# パッチ版 (AnyPages)
FS1:\EFI\Microsoft\> Boot\bootmgfw.efi
ConvertPages: failed to find range 10000000 - 102C4FFF
Image Loaded: bootmgfw.efi           <- 102000 エラーが消えた（パッチは動作）

# Microsoft 原本
FS1:\EFI\Microsoft\Boot\> bootmgfw.efi.orig
ConvertPages: failed to find range 10000000 - 102C4FFF
Image Loaded: bootmgfw.efi
ConvertPages: failed to find range 102000 - 102FFF   <- 原本は両方出る
```

**`Image Loaded` は firmware が「LoadImage を呼び出した」意味であり、
「イメージのメモリ配置に成功した」ではない。**

## 16.2 エラーメッセージの range は ImageBase と SizeOfImage そのもの

```
bootmgfw.efi : ImageBase=0x10000000 SizeOfImage=0x2c5000 -> end 0x102c4fff
bootaa64.efi : ImageBase=0x10000000 SizeOfImage=0x2c9000 -> end 0x102c8fff
```

観測されたエラー:
```
bootmgfw 起動 -> "10000000 - 102C4FFF"   ← 完全に一致
bootaa64 起動 -> "10000000 - 102C8FFF"   ← 完全に一致
```

**つまり firmware は「イメージ全体を 0x10000000 に置きたいが、
その範囲が ConvertPages できない」と言っている。**

## 16.3 真因: AAVMF の RAM は 0x40000000 起点

```
AAVMF メモリマップ:
  最初の Available = 0x40000000 - 0x43FFFFFF
  RAM は 0x40000000 より下に存在しない
```

bootmgfw の `ImageBase = 0x10000000` は**物理的に存在しないアドレス**。
したがって:
1. firmware が `0x10000000` に size 0x2c5000 の領域を確保しようとする
2. `ConvertPages` が失敗（その範囲は Reserved/MMIO）
3. イメージは**中途半端に/別所に**ロードされる
4. relocation が適用される（或はされない）
5. `Image Loaded` は出るが中身は壊れた → **Windows は起動しない**

## 16.4 修正: rebase (ImageBase を 0x40000000 へ)

`GenFw --rebase 0x40000000` で ImageBase を AAVMF の RAM 起点に変える。
これが handoff で作成されていた `bootmgfw-rebased.efi` の目的。

### 2 つの修正を組み合わせた最終版

```bash
# Step 1: rebase (ImageBase 0x10000000 -> 0x40000000)
GenFw --rebase 0x40000000 -o bootmgfw.rebased.efi bootmgfw-original.efi

# Step 2: 低位アドレス要求の無効化 (mov w0,#2 -> mov w0,#1)
python3 tools/make_patch.py bootmgfw.rebased.efi \
        bootmgfw.rebase-anypages.efi --mode anypages
```

| ファイル | ImageBase | パッチ | 用途 |
|---|---|---|---|
| `bootmgfw.orig.efi` | 0x10000000 | なし | Microsoft 原本（比較用） |
| `bootmgfw.anypages.efi` | 0x10000000 | AnyPages | 102000 のみ回避 |
| `bootmgfw.rebased.efi` | 0x40000000 | なし | rebasing のみ |
| **`bootmgfw.rebase-anypages.efi`** | **0x40000000** | **AnyPages** | **★両方を回避** |

## 16.5 適用済み

```
sha256 55f7377d8dbf3b1173a059354d74424a4273f85d8bbe281857b3ce90c1e59423
/mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi

ImageBase   0x40000000
SizeOfImage 0x2c5000
範囲        0x40000000 - 0x402c4fff     <- AAVMF の RAM 内
パッチ箇所   0x40032488 mov w0, #1      <- EfiAllocateAnyPages
```

バックアップ: `bootmgfw.efi.bak2-20261005-082621`

## 16.6 BCD は正常（確認済み）

BCD の loader object `{cc075cd7-…}` の `21000001`（Device）を解読:

```
GUID 経路ノード (type=0x06 subtype=0x00 len=0x48)
  GUID[0] = b9237fd1-5fa8-4f81-a2bf-88f397a5205f  = sdb3 の PARTUUID  ✓
  GUID[1] = cef8aa2a-97cd-4c62-bf50-518cad9d50f5  = sdb の DISK GUID  ✓
```

**BCD は Windows NTFS（sdb3）を正しく指している。**
Windows 側の設定に疑わしい点はない。

## 16.7 次のアクション

### 起動方法（3 通り）

1. **GRUB から**: "Windows 11 ARM64" を選ぶ
2. **UEFI シェルから**: `sudo efibootmgr --bootnext 0005 && sudo reboot`
   → `fs1:EFI\Microsoft\Bootootmgfw.efi`
3. **startup.nsh 経由**（現在の設定）:
   ```
   @echo -off
   fs1:
   echo === BOOTING WINDOWS ===
   EFI\Microsoft\Boot\bootmgfw.efi
   ```

### 判定

| 観測 | 意味 |
|---|---|
| **エラーが両方消えた** | rebase + patch が両方効いた → 次は Windows 自身の問題 |
| `102000` だけ消えた | rebase が効いていない（要将 ESP の bootmgfw.efi を確認） |
| 両方出る | rebase が適用されていない（ImageBase を確認） |
| エラーなし + 起動した | **成功** |
| エラーなし + 起動しない | firmware は OK。Windows 側（winload/NVMe/CLOCK） |

### 注意

`10000000 - 102C4FFF` のエラーは**修正済み**はず（ImageBase 0x40000000）。
これがまだ出る場合は、ESP のファイルが古いので
`sha256sum /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi` で
`55f7377d...` になっているか確認する。


---

# 17. ConvertPages エラー解消と、完全な次の壁（2026-10-05）

## 17.1 ConvertPages エラーは完全に消えた

```
FS1:\> EFI\diag40.efi
Press ESC in 4 seconds...
=== BOOTING WINDOWS ===
Image Loaded: bootmgfw.efi          <- エラーなし！
```

**`ConvertPages: failed to find range ...` が両方消えた。**
rebase（ImageBase 0x40000000）+ AnyPages パッチが両方効いた。

| バイナリ | ConvertPages |
|---|---|
| Microsoft 原本 | `10000000-102C4FFF` + `102000-102FFF` の 2 つ |
| AnyPages のみ | `10000000-102C4FFF` のみ |
| **rebase + AnyPages** | **なし** ✓ |

この時点で firmware 側は完全に正常。
残るのは **Windows 側の問題**。

## 17.2 症状: `Image Loaded` 後に固まる

```
=== BOOTING WINDOWS ===
Image Loaded: bootmgfw.efi
（ここで画面が止まる。Windows のロゴも出ない）
```

`Image Loaded` は firmware が `LoadImage` を呼んだ証拠。
bootmgfw の `efi_main` が実行され、何かが待つ状態。

## 17.3 原因: firmware に NTFS ドライバが無い

### 証拠 1: AAVMF に NTFS 文字列が無い

```bash
$ sudo strings -a /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd | grep -icE 'NTFS'
0
```

FAT 也不行（`FatDxe` / `FAT32` 文字列なし）。
つまり firmware は **どのファイルシステムも 扱え できない** 可能性がある。

### 証拠 2: bootmgfw にも NTFS 実装が無い

```python
tests = ['NTFS','ntfs','NTLDR','$Boot','$MFT','Bstore','FAT32']
NTFS      utf16= 3 ascii= 4     <- few strings (probably error messages)
$Boot     utf16= 0 ascii= 0     <- NTFS boot sector
$MFT      utf16= 0 ascii= 0     <- NTFS master file table
Bstore    utf16= 0 ascii= 0     <- BCD store
FAT32     utf16= 0 ascii= 0
```

**NTFS の実装シグネチャが一切無い。**
Windows Boot Manager は **NTFS ドライバを外部に委ねる**設計で、
通常は firmware が `SimpleFileSystem` プロトコルで NTFS を公開する。

## 17.4 対処: ESP（FAT）に必要ファイルを全部集める

firmware が FAT しか読めないなら、**起動に必要な物を全部 ESP に置く**。

### コピー済み

```
/mnt/efi/EFI/Microsoft/Boot/
  bootmgfw.efi    2622784  (rebase+AnyPages)
  BCD               40960  (ESP 参照に変更済み)
  winload.efi     2947320  (NTFS からコピー)
  winresume.efi   2456568  (NTFS からコピー、予備)
```

ESP の空きは 59MB あり、十分。

## 17.5 BCD の変更内容

### `{cc075cd7-…}`（Windows 11 loader）

| 要素 | 変更前 | 変更後 |
|---|---|---|
| `12000002`（loader path） | `\WINDOWS\system32\winload.efi` | `\EFI\Microsoft\Boot\winload.efi` |
| `21000001`（Device） | NTFS (sdb3) の GUID 経路 | **ESP (sdb1) の GUID 経路** |
| `22000002`（SystemRoot） | `\WINDOWS` | `\WINDOWS`（Windows 本体仍是 NTFS） |

### Device パス（ESP）

```
04 01 1c 00  01 00 00 00  00 00 10 00 00 00 00 00 00 00
00 00 00 00  00 02 00 01              <- HARDDRIVE (GPT), partition 1
06 01 48 00  d2 42 75 05 5d 1b 82 46 b6 86 62 cd af 98 62 bf
2a aa f8 ce cd 97 62 4c bf 50 51 8c ad 9d 50 f5
00 00 00 00 00 00 00 00 00 00 00 00  <- GUID node (ESP + disk)
04 04 44 00  \EFI\Microsoft\Boot\winload.efi
```

- GUID[0] = `057542d2-1b5d-4682-b686-62cdaf9862bf` = **sdb1 (ESP) PARTUUID** ✓
- GUID[1] = `cef8aa2a-97cd-4c62-bf50-518cad9d50f5` = **sdb DISK GUID** ✓

## 17.6 バックアップ

- BCD: `/mnt/efi/EFI/Microsoft/Boot/BCD.bak-20261005-102650`
- bootmgfw: `bootmgfw.efi.bak2-20261005-082621`

## 17.7 次のアクション

```bash
sudo efibootmgr --bootnext 0005   # UEFI Shell
sudo reboot
# または GRUB から "Windows 11 ARM64"
```

startup.nsh は以下 automatically 起動する:
```
fs1:
EFI\Microsoft\Boot\bootmgfw.efi
```

### 判定

| 観測 | 意味 |
|---|---|
| **Windows のロゴが出る** | NTFS 制約を回避できた。残るは一般的な ARM 初期化問題 |
| 固まる（-bootmgfw が固まる） | winload.efi のロード失敗（firmware が FAT を読める的前提下） |
| エラー出る（firmware DEBUG） | firmware が ESP を見つけられない/別の問題 |

## 17.8 仍未解決，その他の課題

Windows は `\WINDOWS`（NTFS）を SystemRoot として必要とする。
`winload.efi` の起動は FAT からできても、
起動後のカーネルローディングには NTFS が必要。

したがって **firmware が NTFS を読めることが本質的に必要**。
その場合は firmware（AAVMF）側の NtfsDxe 追加が必須で、
 これは EDK2 を再ビルドして AAVMF を差し替える変更。


---

# 18. NTFS 制約の確定と次のアプローチ（2026-10-05）

## 18.1 _ConvertPages は完全解決、維持.ConvertPages エラーが消えた状態

```
=== BOOTING WINDOWS ===
Image Loaded: bootmgfw.efi        <- エラーなし
```

## 18.2 新しい壁: NTFS を読めない

### 証拠 1: UEFI Shell の map 出力

```
FS0: HD(1,GPT,CC4743DC-...)   <- sda1 vfat    FS として認識 ✓
FS1: HD(1,GPT,057542D2-...)   <- sdb1 vfat    FS として認識 ✓
BLK7: HD(3,GPT,B9237FD1-...)  <- sdb3 NTFS    BLK のみ、FS ではない ✗
```

**NTFS パーティションは `FS:` として現れず `BLK:` のみ。**
firmware が NTFS を SimpleFileSystem として公開できていない。

### 証拠 2: AAVMF に NTFS ドライバが無い

```bash
$ sudo strings -a AAVMF_CODE.no-secboot.fd | grep -icE 'NTFS'
0
```

### 証拠 3: bootmgfw にも NTFS 実装が無い

```python
markers = ['NTLDR','$Boot','$MFT','$LogFile','$Volume','$AttrDef',
           'MFT_RECORD','ATTR_RECORD','ntfs_','FAT32','Bstore']
NTLDR        0
$Boot        0
$MFT         0
$LogFile     0
Bstore       0
FAT32        0
```

**NTFS の実装シグネチャが一切無い。**
Windows Boot Manager は NTFS ドライバを firmware に委譲する設計だが、
firmware が NTFS を読めないので winload.efi を NTFS からロードできない。

## 18.3  Galois した対抗: ESP に winload.efi を置く

NTFS を読めないなら、**起動に必要な物を全部 ESP(FAT) に置く**。

### 配置済み

```
/mnt/efi/EFI/Microsoft/Boot/
  bootmgfw.efi    2622784  rebase + AnyPages
  BCD              40960  ESP 参照に変更
  winload.efi     2947320  NTFS からコピー
  winresume.efi   2456568  NTFS からコピー
```

ESP の空きは 53MB。

### BCD の変更（Windows 実測構造に準拠）

loader object `{cc075cd7-…}`:

| 要素 | 変更後 |
|---|---|
| `12000002` | `\EFI\Microsoft\Boot\winload.efi` |
| `21000001` | part=`057542d2-…`(sdb1 ESP) disk=`cef8aa2a-…`(sdb) |
| `22000002` | `\WINDOWS`（Windows 本体は NTFS のまま） |

### Device パスの構造（訂正）

最初に作った時は `subtype=0x01 / len=0x48 / HDDP ノード` を作ったが、
Windows 実測は 全く 違う形式だった:

```
[00..15]  全て 0（16 バイトのパディング）
[16]      06 00 00 00 00 00 00 00
          type=0x06(MEDIA) subtype=0x00 len=0x00000000  ← len=0 が Windows の実測
[20]      PartitionNumber (u32) = 0
[24..39]  partition GUID (16)
[40..55]  disk GUID (16)
[56..87]  zero padding
合計 88 バイト
```

**subtype は 0x00、len は 0x0000**（HDDP ノード無し）。
ESP GUID だけ差し替えて Windows と同一形式にした。

## 18.4 判定が分かれるポイント

| 観測 | 意味 | 次の手段 |
|---|---|---|
| **Windows のロゴ** | NTFS 制約回避成功。C 完了 | 通常起動へ |
| 固まる（bootmgfw で） | winload.efi のロード失敗 | diag で LoadImage 確認 |
| firmware エラー | Device パス不一致 | BCD 構造を再度 |

## 18.5 診断アプリへの追加テスト

`diag40.efi` に **ESP 上の winload.efi を直接 LoadImage** する probe を追加:

```c
probe_load ("bootmgfw.efi",        L"\EFI\Microsoft\Boot\bootmgfw.efi");
probe_load ("winload.efi (ESP)",   L"\EFI\Microsoft\Boot\winload.efi");
```

これで firmware の FAT ドライバが winload.efi を  successfully ロードできるか
を直接確認できる。

`startup.nsh` は diag → Windows の順に実行:

```
@echo -off
fs1:
echo === DIAG: winload LoadImage test ===
EFI\diag40.efi

echo === NOW WINDOWS ===
EFI\Microsoft\Boot\bootmgfw.efi
```

## 18.6 次のアクション

1. `sudo reboot`（`BootNext=0005` で UEFI Shell が起動）
2. シリアルに diag の出力が出る
   - `[4] LoadImage: winload.efi (ESP)` の結果を報告
3. その後 startup.nsh が Windows を起動

### 判定表

```
[4] LoadImage: winload.efi (ESP)  -> EFI_SUCCESS
    → firmware は FAT で winload.efi をロードできる
    → 固まる原因は bootmgfw 内部（BCD パース or NTFS 依存）

[4] LoadImage: winload.efi (ESP)  -> EFI_NOT_FOUND
    → firmware が ESP を見つけられない / FAT 読み込み失敗
    → ESP のファイルシステムに問題
```

## 18.7 仍未解決: NTFS は本質的に必要か

Windows の `SystemRoot = \WINDOWS` は NTFS 上。
`winload.efi` は NTFS ドライバを内蔵していないので
（`$MFT` 等の文字列が無い）、
**起動後もカーネルロードには NTFS が必要**。

したがって [C] が失敗した場合の選択肢:

| # | アプローチ | 難易度 | 所要時間 |
|---|---|---|---|
| A | ESP を NTFS 化 | firmware が NTFS 読めないので不可 | — |
| B | **AAVMF に NtfsDxe を追加してビルド** | EDK2 に NtfsDxe 無し。外部実装を移植 | 数時間 |
| C | winload.efi を ESP から起動 | 設定済み | 起動テストのみ |
| D | GRUB の ntfs.mod を EFI モジュール化 | GRUB モジュールは EFI アプリではない | 高 |

最も現実的なのは **B**。EDK2 の `NtfsDxe` は
NtfsPkg（外部リポジトリ）として提供されている。


---

# 19. diag が無音で落ちた真因: `split` 計算のバグ（2026-10-05）

## 19.1 症状

`startup.nsh` は diag を実行したが、出力が一切出なかった。

```
=== DIAG: winload LoadImage test ===
=== NOW WINDOWS ===
Image Loaded: bootmgfw.efi
```

- `diaglog*.txt` も作られない（0 バイト）
- 例外メッセージも出ない
- `echo` は出ているので **シェル自体は動いている**
- diag だけが沈黙

## 19.2 PE ヘッダは完全に正しい（実測）

```
sha256 29f0de3d179731bb
PE@ 0x40  SizeOfOptionalHeader 0xf0  nsec 3
Machine 0xaa64   Characteristics 0x2022
Entry 0x4000     ImageBase 0x40000000   SectAlign 0x1000
Subsystem 10     BASERELOC 0x19000/0x200
  .text    va=0x1000  vs=0x15c00 ro=0x1000
  .data    va=0x17000 vs=0x1800  ro=0x16c00
  .reloc   va=0x19000 vs=0x200   ro=0x18400
entry bytes: ff4300d1 e00f00b9 e00f40b9     <- 正しい _start
reloc page 0x11000 entries 166
```

ヘッダは問題なし。**しかし `.reloc` の内容が wrong.**

## 19.3 真因: `split` 計算が `.data` を `.text` と誤判定

### relocation の実体は全て `.data` 内

```
reloc target sections: {'.data': 165}
RVA range: 0x10520 - 0x10cc8
```

`.data` は ELF で `0x10000..0x10db0`。

### 旧 `split` 計算（バグ）

```python
ro_end = lo
for s in secs:
    if s["name"] in (".text", ".rodata", ".init", ".fini", ".plt"):
        ro_end = max(ro_end, s["addr"] + s["size"])
split = ro_end - lo
```

gnu-efi のセクションは**アドレス順に並んでいない**:

```
.text   0x03000 .. 0x0aa40
.data   0x10000 .. 0x10db0     <- RW が RO の間にある!
.rodata 0x14000 .. 0x15a3e
```

`ro_end = max(0xaa40, 0x15a3e) = 0x15a3e` → `split = 0x15a3e`

すると `.data`（`0x10000`）が `split` **未満**INI になり、
`.data` の relocation が `.text` 側へ変換されてしまう:

```
0x10520 < split(0x15a3e)  → True
→ text_rva + 0x10520 = 0x1000 + 0x10520 = 0x11520   (WRONG)
```

本来は:

```
→ data_rva + (0x10520 - 0x10000) = 0x11000 + 0x520 = 0x11520
```

（`data_rva` が `0x11000` だったので**偶然同じ値になった**が、
`.text` が `0x1000..0x11000` に収まるようになったため
`entry` 付近のコードが Relocation 対象に入っていた）

### 修正: 最初の書き込み可能セクションで切る

```python
RW = (".data", ".bss", ".got", ".got.plt", ".tdata", ".tbss")
split = None
for s in secs:
    if s["name"] in RW:
        split = s["addr"] - lo
        break
if split is None:
    split = len(img)
```

### 修正後の結果

```
split at img offset 0x10000 (first writable section)
.text  0x1000  +0x10000
.data  0x11000 +0x7200
.reloc 0x19000 +0x200  (165 entries)

reloc page 0x11000 entries 166     <- .data の先頭と一致 ✓
```

## 19.4 自作 PE のバグシリーズ（8 → 9 件）

| # | バグ | 症状 |
|---|---|---|
| 1 | GenFw が `R_AARCH64_RELATIVE` 未対応 | `.reloc` が出されない |
| 2 | `GenFw --rebase` が入力を上書き | 2 回目 `ERROR 3000` |
| 3 | `SizeOfOptionalHeader = 0xF000` | GRUB `cannot load image` |
| 4 | `SectionAlignment = 0x20` | firmware が `LoadImage` 拒否 |
| 5 | `Characteristics` に `LARGE_SECTION_ADDRESS` なし | 同上 |
| 6 | entry RVA に `text_rva` 未加算 | DWARF を実行 → 例外 |
| 7 | `.reloc` の RVA に `text_rva` 未加算 | データ参照が全壊れ |
| 8 | `nsec` を `blocks` 生成前に判定 | `.reloc` セクションが出ない |
| **9** | **`split` が `.data` を `.text` と誤判定** | **無音クラッシュ・ログも残らない** |

**共通教訓: ELF vaddr と PE RVA は一致しない。**
`SectionAlignment` でセクションを詰めるため、
すべてのオフセット変換は「セクション配置を確定した後」に行わなければ���ない。

## 19.5 配置済み

```
sha256 9e6cdda130896969568ed05d723e8f4851d2ff1ec4949b962f96cb6a263712bc
/mnt/efi/EFI/diag40.efi
```

## 19.6 次のアクション

```bash
sudo reboot
```

`BootNext=0005` で UEFI Shell が起動し、`startup.nsh` が
diag → Windows の順に実行される。

確認するファイル:

```bash
sudo mount /dev/sdb1 /mnt/efi
ls -la /mnt/efi/diaglog*.txt
sudo cat /mnt/efi/diaglog*.txt
```

diag が正常に動けば、`[1]`〜`[4]` の情報、特に
**`[4] LoadImage: winload.efi (ESP)`** が是否能えるかが確定する。

| `[4] winload.efi` の結果 | 意味 |
|---|---|
| `EFI_SUCCESS` | firmware は FAT で winload.efi をロードできる |
| `EFI_NOT_FOUND` | firmware が ESP を見つけられない |

# 20. 主因の確定: firmware に NTFS が無い + BCD の device/osdevice 不整合（2026-10-24）

## 20.1 「OS の実体が磁盘に無い」は誤報だった（WOF = CompactOS）

ntfs-3g は reparse tag 0x80000017 を `unsupported reparse tag` として
symlink に変換するため、`ls`/`find` 上は

```
System32     : 4082 / 4398 件が reparse
System32\drivers: 320 /  330 件が reparse
```

と「中身ゼロ」に見える。実測は `ntfsinfo -v -F /Windows/System32/ntoskrnl.exe /dev/sdb3`:

```
File attributes : ARCHIVE SPARSE_FILE REPARSE_POINT RECALL_ON_OPEN (0x00040620)
Reparse tag     : 0x80000017 (Wof compressed)   Data length: 16
Reparse data    : 01000000 02000000 01000000 02000000
$DATA (名なし)  : Runlist VCN 0x0 -> <HOLE> 0xac0        # 見かけは全部穴
$DATA (定義名)  : 'WofCompressedData'                    # 実体はこの ADS
```

- `df /dev/sdb3` = **11G used / 40G free** → 実体は同一ボリューム内にある
- reparse data が 16B なので WIMBoot（外部 WIM 参照 = GUID+offset で 100B 超）ではなく
  **in-place WOF 圧縮**。`drivers\wof.sys` は実体（256456B, 非圧縮）なので
  Windows 側で展開できる。`Recovery\WindowsRE\Winre.wim`(503MB) / `boot.sdi` も実体。
- 教訓: ntfs-3g の "unsupported reparse tag" は欠損ではなく「ntfs-3g が読めないだけ」。
  判定は `Reparse data length` と `df` の使用量で行う。

## 20.2 真の障害は 2 つだけ

1. firmware(AAVMF) に NTFS driver が無く sdb3 が SimpleFileSystem 化されない
   （Shell `map -r` で BLK7 に FS が付かない）→ bootmgr/winload が OS ボリュームを読めない
2. BCD `{cc075cd7-…}` が `11000001`(device)=sdb3 なのに
   `12000002`(path)=`\EFI\Microsoft\Boot\winload.efi`（= sdb3 側に `\EFI` が存在しない）で、
   かつ `21000001`(osdevice)=sdb1(ESP)。§18.3 の編集が osdevice 側を壊していた。

## 20.3 実施した修正（実機適用済み）

NTFS UEFI driver（pbatard ntfs-3g UEFI 1.9 / AA64, EFI boot services driver）:

```
/mnt/efi/EFI/NTFS/ntfs_aa64.efi  86c61901…4f10c920  (read+write)
/mnt/efi/EFI/NTFS/ntfsdbg.efi    8d78abf5…8de097e6  (DEBUG 版, 次弾)
/boot/efi/EFI/NTFS/                                   (予備: AnduinOS ESP 側)
```

Secure Boot は AAVMF が `SecureBoot` 変数すら持たず未実装 → 無署名ドライバで可
（`_signed` 版は READ-ONLY なので偽阴性リスクがあり不採用）。

BCD を native 形へ（バックアップ `BCD.bak-20261024-1642-prewof`、BCD.LOG1/2 は 0 バイトで replay 懸念なし）:

| element | 値 |
|---|---|
| `11000001` device | sdb3 (PARTUUID b9237fd1-…)据え置き |
| `21000001` osdevice | sdb3 へ修正（`11000001` の 88B をコピー） |
| `12000002` path | `\Windows\System32\winload.efi`（実体 2947320B / sha a98b3899…で ESP コピーと同値） |
| `22000002` systemroot | `\WINDOWS`（変更なし） |

`/mnt/winc/EFI` は存在しないので native 一択（ESP から winload を読む A 案は使わない）。

startup.nsh v3（sha `c157c05b…3bf3c174`, 22 行, LF）:
`load ntfs_aa64.efi` → `map -r`/`drivers` を **V3.TXT へログ** → `stall 12s` → bootmgfw。
`BootNext=0005`（EFI Internal Shell）設定済み → 再起動だけで v3 が走る。

## 20.4 hivex 書き込み API（この環境の実測）

```python
h = hivex.Hivex(path, write=1)
e = h.node_get_child(h.node_get_child(
        h.node_get_child(h.root(), 'Objects'),
        '{cc075cd7-8065-11ef-b427-f0aaf1083c73}'), 'Elements')
d = h.value_value(h.node_values(h.node_get_child(e,'11000001'))[0])[1]
h.node_set_value(h.node_get_child(e,'21000001'),
                 {'key':'Element','t':3,'value':d})
h.commit(path)          # commit は filename 省略不可
```

- 書き込みは **dict 一つ**（`{'key','t','value'}`）。t=1 SZ / t=3 binary / 4 dword / 7 multisz
- `Objects` 配下キーは中括弧付き小文字 `{guid}`、要素キーは `11000001` 形式、value key 名は `Element`
- `value_value(v)` -> `(type, bytes)`、`value_type(v)` -> `(type, len)`
- SZ の value は `s.encode('utf-16-le')+b'\x00\x00'`
- `sudo -n` は現在成功する（§11 の「sudo -n 不可」は陳腐化）

## 20.5 次の観測点（V3.TXT）

```bash
sudo mount /dev/sdb1 /mnt/efi; sudo cat /mnt/efi/V3.TXT | iconv -f UTF-16LE -t UTF-8
ls /mnt/efi/V3.TXT /boot/efi/V3.TXT
```

| 結果 | 判定 → 次の手 |
|---|---|
| BLK7 に FSx が付く | NTFS 注入成功。bootmgr/winload の先に進む（winload のエラーコードを取りにいく） |
| FSx が付かない | DEBUG 版 `ntfsdbg.efi` に切替／`DriverOrder`+`Driver0000` NVRAM 化／EfiFs v1.13 検討 |
| V3.TXT が無い | startup.nsh が実行されていない（BootNext 未反映／別 ESP を起動） |

## 20.6 virtio-scsi はブロッカーではなかった（2026-10-24 追加）

`/dev/sdb` の正体:
```
18:00.0 SCSI storage controller: Red Hat Virtio 1.0 SCSI [1af4:1048]
ID_PATH=pci-0000:18:00.0-scsi-0:0:1:1   ID_VENDOR=ORACLE / ID_MODEL=BlockVolume
```
＝ OCI の boot volume は **virtio-scsi**（BCD/Shell に見える `SCSI(0,1)` と一致）。
`System32\drivers` に `vioscsi.sys` は無いが、SYSTEM hive 実測で問題なし:

| service | Start | Type | Group | ImagePath |
|---|---|---|---|---|
| `vioscsi` | **0 = BOOT_START** | 1 | SCSI miniport | `System32\DriverStore\FileRepository\vioscsi.inf_arm64_4b2190f46840dd32\vioscsi.sys` |
| `viostor` | 0 | 1 | SCSI miniport | 同 `viostor.inf_arm64_ca6942d9ef8b0dd4\viostor.sys` |
| `netkvm` | 3 | 1 | NDIS | DriverStore 直指し |

- DriverStore 内の `vioscsi.sys` は **89136B の実体（WOF 圧縮されていない）** → winload が phase-1 で読める
- CDD（CriticalDeviceDatabase）に 1af4 エントリは無かったが不要（Start=0 + Group で十分）
- `System32\drivers` に `vioscsi.sys` をコピーする注入は**不要**。よって NTFS を rw で触る必要なし
- hive 読み注意: hive 内は `CurrentControlSet` ではなく **`ControlSet001`**（CurrentControlSet はリンク）
  / `value_value()` は utf-16 を返すので自分で decode すること

# 21. 運用手順: やってことは再起動だけ（2026-10-24）

## 21.1 結論: EFI Shell を手で選択する必要は無い

`efibootmgr` 実測（再起動前）:

```
BootNext: 0005          ← EFI Internal Shell を 1 回だけ起動
BootCurrent: 0006       ← 今いるのは AnduinOS
Timeout: 0 seconds
BootOrder: 0006,0002,0000,0001,0005
```

なので **インスタンスを再起動するだけ**。流れ:

```
再起動 → firmware が BootNext=0005 を拾う → EFI Internal Shell 起動
  → Shell が ESP ルートの startup.nsh を自動実行（入力不要）
  → v3: NTFS driver load → map -r/drivers を V3.TXT へ記録 → stall 12s
  → fs1:\EFI\Microsoft\Boot\bootmgfw.efi 実行
      成功 → Windows 11 が立つ
      失敗 → Shell へ戻る → fs0/fs2 の bootmgfw を順に試す → そのまま halt or 再起動
  → BootNext は消費済みなので次回以降は Boot0006 (AnduinOS) に戻る
```

- Boot0005 は firmware FV 内の Shell（`FvFile(7c04a583-…)`）。ESP のファイルに
  依存しないので boot 経路が壊れていても必ず出せる
- Timeout=0 は「メニューを出さない」だけで BootNext には干渉しない
- Startup.nsh を読む ESP は sdb1 だけ（`/boot/efi/startup.nsh` は存在せず確認済
  → AnduinOS ESP が先頭にマップされても誤作動しない）。V3.TXT も同じ ESP に書かれる

## 21.2 BootNext は使い捨て（再試行のたびに再セット）

```bash
sudo efibootmgr -n 0005     # 1 回限りの起動指定。firmware が実行後に消す
```

2 回目以降の試行（DEBUG 版ドライバへ切替後など）は必ずこれを再実行すること。

## 21.3 再起動後の見方（agent 側）

```bash
sudo mount /dev/sdb1 /mnt/efi
sudo cat /mnt/efi/V3.TXT | iconv -f UTF-16LE -t UTF-8
#   → 「map -r 2」の行に BLK7 対応の FSx があれば NTFS 注入成功
#   → drivers 行に NTFS Driver が入っているか
ls /mnt/efi/V3.TXT /boot/efi/V3.TXT   # 両 ESP を念のため見る
```

## 21.4 配置物の sha 再検証（2026-10-24 17:0x、umount 済）

```
startup.nsh              c157c05b…3bf3c174  (work/diag/startup.nsh と一致)
EFI/NTFS/ntfs_aa64.efi   86c61901…4f10c920  (work/drivers/ntfs_aa64.efi と一致)
```
sdb1 は unmount 済み（firmware がリードオンリーで読めるクリーンな状態）。

## 21.5 まだ残る未知（Shell 以降）

- winload 以降の成否: 失敗コードをまだ取れていない（画面に出ない）
  次は対象 object の Elements の IDs (15000066/16000060/17000077/
  25000020/250000c2) を解読し、デバッグ出力を ESP ファイルへ出す
- WOF 圧縮された boot critical driver を wof.sys 先行ロードで読めるか
- 恒久化: 正常起動できたら driver を Shell 経由でなく
  `Driver0000`+`DriverOrder`（AAVMF での受理可否は未検証）へ移して BootNext 依存を終了
- 残資産: `diag40.efi`（無音失敗のまま未解明）、`/mnt/iso` の loop マウント、
  `/tmp/bcdt2`（root 所有）

# 22. v3 全滅の根本原因と v4、そして WOF 問題の発見（2026-10-24）

## 22.1 「Unable to redirect file. / Script Error Status: Invalid
Parameters (line number 3)」の解析

コンソールに出たこの 2 行は v3 の 3 行目 `echo v3-start > V3.TXT` が
失敗したことを意味する。EDK2 ソース（`~/edk2`）で裏取りした。

- `ShellPkg/Application/Shell/Shell.uni:42`
  `STR_SHELL_INVALID_REDIR = "Unable to redirect file."`
- 同一 `ShellParametersProtocol.c:1351` で上記を表示。直上の stdout open は
  `ShellOpenFileByName(StdOutFileName, WRITE|READ|CREATE, 0)` を呼び、
  `TempHandle == NULL` なら `EFI_INVALID_PARAMETER` を返す（≈1197-1210 行）。
  → 相対パス `V3.TXT` を解決できなかった = **cwd が未設定**
- cwd は `EfiShellSetCurDir()`（`ShellProtocol.c:3131`、代入は :3279）でしか
  書かれない。 callers は `Cd.c:287` と `ChangeMappedDrive()`
  （`Shell.c` ≈2268-2294, `CmdLine` が末尾 `:` で空白を含まないことを ASSERT）。
  startup.nsh を実行しただけでは cwd は入らない（`fsN:` 1 行目のコマンドが
  必要）。firmware FV から起動した Shell は cwd 空。
- 致命的な追加事実: `Shell.c` の `RunScriptFileHandle`（:2944、ループ
  ≈3080-3260）に `if (EFI_ERROR (Status)) { RestoreBufferList(); break; }`
  → **1 行の失敗で .nsh 全体が途中で終了**。よって v3 の
  `load ntfs_aa64.efi` も `bootmgfw.efi` も一度も実行されていなかった。
  つまり BCD 修正も NTFS ドライバも「まだ一度も試行されていない」。
- 救い: `if` は `UefiShellLevel1CommandsLib/If.c` にあり、exist 判定は
  `OperationResult = (BOOLEAN)(ShellFileExists(StatementWalker) == EFI_SUCCESS)`
  で Status を汚さない（:415-440 付近）→ **`if exist(...) then` は
  絶対にスクリプトを中止させない**。v4 のガード基盤。

## 22.2 v4（`work/diag/startup.nsh.v4` / 96 行 / LF のみ / 79 列超 0）設計則

1. cwd に依存しない: 全パスを `fsN:\...` 絶対形で書く
2. 失敗しうるコマンドは全て `if exist(...) then ... endif` で包む
   （ネスト if は使わない = tag 走査のリスク回避）
3. 「Windows ESP の判別子」= `fsN:\EFI\Microsoft\Boot\BCD` の存在。
   sda1（AnduinOS ESP）側に BCD が無いことを実測確認ずみ。
   したがって BCD 存在 == Windows ESP で一意。
4. NTFS ドライバは sdb1 ESP の 1 個だけに置いた（sda1 側 `EFI/NTFS` は削除、
   `load` の二重発火防止）。
5. ログは bootmgfw の「後」に置く。bootmgr は失敗時だけ戻ってくるので、
   失敗ログを先に書くとブート試行自体を飛びやすいため。
6. `map -r` は bootmgfw 復帰後のみ（採番が動くと相対 resolve が壊れる）。
7. ブート前の `map` は素の `map`（再採番しない）。新 FS が map に現れない
   場合があるが、それはログ上の問題だけで bootmgr の device path 解決には無関係。

## 22.3 【重大】boot 必須ファイル自体が WOF プレースホルダ化されている

`/mnt/winc`（sdb3）を実測。reparse tag 0x80000017 = WOF 圧縮で、
ntfs-3g 上では size=34 のシンボリックリンクに見える（中身は
"unsupported reparse tag 0x..." という ntfs-3g の文字列であり、
リパースデータそのものは読めない）。

| ファイル | 音量の実測 | 判定 |
|---|---|---|
| `Windows/System32/winload.efi` | 2,947,320 | 実体（読める） |
| `Windows/System32/config/SYSTEM` | 8,912,896 | 実体（hivex で読めた） |
| 同 SOFTWARE / SECURITY / DEFAULT / SAM / COMPONENTS | 実体 | 実体 |
| `drivers/wof.sys` | 256,456 | 実体 |
| `DriverStore/.../vioscsi.sys` | 89,136 | 実体 |
| `DriverStore/.../viostor.sys` | 73,776 | 実体 |
| `Windows/System32/ntoskrnl.exe` | 34 | **WOF プレースホルダ** |
| `Windows/System32/hal.dll` | 34 | **同上** |
| `Windows/System32/ci.dll` | 34 | **同上** |
| `drivers/fltMgr.sys` / `clfs.sys` / `Wdf01000.sys` / `ndis.sys` /
 `WdBoot.sys` / `WdFilter.sys` | 34 | **同上** |

- `Windows/System32/` 配下（+Boot/CodeIntegrity）の索引 17,047 件のうち
  **12,398 件が size<=40 のプレースホルダ**。
- SYSTEM ハイブから Start=0（BOOT_START）& TYPE_DRIVER を抽出すると 54 件、
  そのうち **51 件がプレースホルダ**（一覧は `work/woffix/bootset.json`）。
- 意味: winload は `\Windows\System32\ntoskrnl.exe` を **Wof.sys より前に**
  生読みするので、カーネル本体が圧縮されている状態は
  **NTFS ドライバを入れただけでは絶対に/boot しない**。
  `fltMgr/clfs/Wdf01000` なども読み順が Wof より前になる可能性が高く危険。
  通常の CompactOS は boot 関連を圧縮除外するので、この状態は異常。
- 出所: ISO 直下の `autounattend.xml` に **`<Compact>true</Compact>`**
  （`ImageInstall` 配下）。これが WOF を発動させている。
  同じ ISO/manual で再適用すると同じ罠を踏む。

## 22.4 平文ドナーの世代が全部ズレている（重要）

`work/woffix/` に抽出して比較（sha256 とサイズで判定）。
wimlib はこの版だと WIM 内パスが**大文字小文字一致**（`dir` は
`--path=` 指定、`Drivers` ではなく `drivers`、`fltMgr.sys` 等）。

| ファイル | 音量(実体) | install.wim(2026-03) | Winre.wim(2024-04=RTM) |
|---|---|---|---|
| `winload.efi` | 2,947,320 | 3,156,408 | (WinPE には無し) |
| `drivers/wof.sys` | 256,456 | 248,704 | 253,856 |
| `ntoskrnl.exe` | 圧縮 | 11,486,624 | 11,241,792 |
| `hal.dll` | 圧縮 | 17,216 | 17,216 |
| `ci.dll` | 圧縮 | 1,013,096 | 940,176 |

- 音量のビルド: 26100 / 24H2 / **UBR 1742**。つまり音量は「LCU 適用後の
  26100.1742」で、ドナーは RTM(2404) と ISO(2026-03) の両方と異なる。
- `install.wim` の `winload.efi`/`wof.sys` は音量とバイト一致せず →
  ISO の WIM はこの OS のソースではない（より新しい別ビルド）。
- 3 ドナーとも厳密一致はしない。ただし全部 10.0.26100 系で、
  boot 鎖（winload/kernel/hal/ci/boot-driver）を**同一ソースに揃えて**
  入れ替えれば実用上は/boot する見込み（同ビルド番号系列内の互換）。

### 22.5 WOF 圧縮されたブートチェーンの実体化（実施済み・リブート待ち）

原因の確定: `/mnt/iso/autounattend.xml` の `<Compact>true</Compact>` で
適用された結果、**ブートに必須のファイルまで WOF プレースホルダ**状態
（reparse tag 0x80000017、ntfs-3g 上では 34 バイトの symlink に見える）。
決め手: 音量側の `System32/WimBootCompress.ini` の
`[CompressionExclusionList]` は `ntoskrnl.exe` を**圧縮してはいけない物**
として明記している。なのに実体が無い＝通常の CompactOS ではなく
この ISO の適用手順の欠陥。

対象範囲の決め方: SYSTEM ハイブで `Start=0` かつ
`Type` の bit0/1/2（1=kernel driver, 2=file system driver, 3=both）。
→ 59 件。途中で Type=2 を落としていたバグを発見・修正
（`FltMgr` / `FileInfo` が計画から漏れていた。Fs_Rec は Type=8 で
 ImagePath 無しなので除外）。

ドナー選定（優先順: Winre.wim → install.wim）:
- 音量 = 26100 / 24H2 / UBR 1742。`Winre.wim`(26100 RTM) が系譜 closest。
- 決定打: DriverStore のハッシュ付き INF dir 名
  （genpass/prm/qcgpio_i/qctree_i）が Winre.wim と完全一致 ＝同一源の証。
- install.wim(2026-03 系) を当てたのは 6 件だけ（iorate, msseccore,
  RADARM, rdyboost, WdBoot, wfplwfs）＝ winload の必須連鎖外。
- `winload.efi`(2,947,320) / `wof.sys`(256,456) / `vioscsi` / `viostor` /
  `AWSNVMe` は**実体があるので触らない**。wof.sys を RTM 版に差し替えると
  既存 12,398 個の圧縮ペイロード（別世代の apply 産）が読めなくなる恐れ。
  12k 個の後続ファイルは実体 wof.sys が起動後にさばくのでそのまま。

手順（`work/woffix/`）:
1. `list_bootset.py` → bootset.json（59 件のサービス/Group/rel/path）
2. `volidx.py`（sudo）→ /tmp/ntfscase.json：音量側の**実大小文字パス**と
   実サイズ・リンク数。Linux は大文字小文字一致なので必須
   （registry は `fltmgr.sys`、実体は `drivers/fltMgr.sys` 等）。
3. `plan.py` → plan.json（ドナー解決）。`fetch.py` → fetch.tsv
4. `wimlib-imagex extract` で 59 件を平文展開 → `bin/NN.bin`
5. `verify.py`：全件 MZ + PE machine=`0xaa64` + サイズ>=4096 → 不正 0
6. `apply.py`（DRY-RUN→`--apply`）：`mv rel rel.wofbak`（メタデータのみ、
   WOF ペイロード保持）→ 新ファイルとして平文を copy。
   reparse 経由の直接書込みはしない。

結果: 59/59 適用・再検証一致、ブートセットのプレースホルダ残 **0 件**、
`.wofbak` 59 個、空き 40G（stage 34MB）。主要 PE 実測:
ntoskrnl 11,241,792 / hal 17,216 / ci 940,176 / fltMgr 529,840 /
fileinfo 98,736 / clfs 487,328 / Wdf01000 855,344（全て mach=0xaa64）。

可逆性: 各対象は `<rel>.wofbak` に元のリパーザエントリが残って所以在、
`rm <rel> && mv <rel>.wofbak <rel>` で原状復帰できる。

状態: sdb3/sdb1 はクリーンアンマウント済、`startup.nsh` は v4
（sha 45ffe8a3c9…一致）、`BootNext=0005` 装着済。**ユーザーリブート 1 回待ち**。
読むログ: `V4.TXT`（マッピング/load 歴）と `V4D.TXT`
（`ntfs-readable-on-fsN` が勝敗の分岐）。

追記検証: 59 件すべて `bin/NN.bin` と音量上の実ファイルの
sha256 が全一致（サイズ一致だけでなく內容保証済）。
sdb1/sdb3 はクリーンアンマウント済。**リブート 1 回いつでも可**。

## 22.6 v4 の結果解読と v5 設計（2026-10-24）

### v4 起動の観測結果（コンソール報告 + V4.TXT）
- コンソール: Image 'fs1:\EFI\NTFS\ntfs_aa64.efi' loaded ... - Success
- 続けて Image Loaded: bootmgfw.efi 、その後フリーズ
- V4.TXT の末尾は driver-load-attempted →（load 前と同一の map 表）
  → pre-boot 。bootmgfw 実行後の痕跡は無し
- v4 は NTFS プローブをすべて bootmgfw の後ろに置いていたので、
  フリーズ時に全て失われた。教訓: プローブは必ず到達可能な位置に置く
- map 表は load の前後で完全に同一（BLK6/BLK7 に FS 無し）
  → sdb3 に SimpleFileSystem が現れていない疑いが濃厚

### 音量側の調査（dirty volume 説は死亡）
- ntfs_aa64.efi の strings: uefi-driver/uefi_bridge.c、libntfs-3g/uefi_io.c
  = 公式 ntfs-3g の UEFI ドライバ。NtfsCreateFile/Write/Delete/Move と
  ntfs_device_uefi_io_pread/pwrite/seek/sync を export している = RW 対応
- sudo ntfsinfo -m /dev/sdb3: Volume Flags 0x0000（クリーン）、NTFS 3.1、
  512B/4KiB、MFT LCN 786432 → unsafe state での RO 拒否の根拠なし
- sdb3 直下に V4.TXT 等のマーカーは無し（Shell 側が音量に触れていない）

### EDK2 ソースで確定した .nsh 中断規則（重要）
RunScriptFileHandle（Shell.c）は EFI_ERROR (Status) でループを抜けるが、
Status がエラーになる条件は限定的（Shell.c 2495-2545 の分岐）:
- リダイレクト張本の失敗（cwd 無しでの相対 > など。前回の真因）
- script-only コマンド（for/endfor/if/else/endif/goto）の失敗は常に
  EFI_ABORTED（IsScriptOnlyCommand）→ if の書式ミスは致命的
- コマンドが SHELL_ABORTED を返した場合のみ中断。Level1/2 で
  SHELL_ABORTED を返すのは Attrib/Cp/Ls/Mv/Rm のみ
  → cp / ls / rm / mv はスクリプトを殺し得る。v5 では使わない
- 不明コマンドは EFI_NOT_FOUND で殺す → connect を素置きできない
- load / echo / map の失敗自体は中断しない（安全に失敗させられる）
- set は環境変数のみ（NVRAM 非対応）→ 変数による報告経路は不可
- connect/drivers ∈ UefiShellDriver1CommandsLib、mm/memmap ∈ Debug1。
  handoff で memmap -b と mm 0x102000 が成功している ⇒ この Shell は
  フルビルドで connect が入っている可能性が高い（未証明）
- EfiBootManagerProcessLoadOption（BmLoadOption.c 1429-1553）は
  ConnectDevicePath するだけで ConnectController しない
  ⇒ NVRAM の Driver0000+DriverOrder でも DriverBinding.Start は走らない

### handoff から復活した既知事実（ConvertPages）
- この機種の RAM は 0x40000000 開始。その下に RAM は存在しない
- bootmgfw 実行時に ConvertPages: failed to find range
  10000000 - 102C4FFF（元 PE）。rebase 後は消え 102000 - 102FFF が残留
- 発生源は MdeModulePkg/Core/Dxe/Mem/Page.c の CoreConvertPages で
  DEBUG_ERROR 出力＝致死的エラーではない。LoadImage 時の NX/属性設定が
  ImageBase 範囲を変換しようとして失敗する形と整合（rebase で消えた理由も
  これなら説明つく）。NTFS 不在の証拠にはならないが無関係とも言い切れない

### v5（startup.nsh.v5 167 行 / 4671B）の方針
- コンソールを第一のログに昇格（echo -on でコマンドエコーを復元。
  v4 は @echo -off で実行位置が見えなかった）
- 全パスは絶対 fsN:\、if exist ガード、LF・78桁目安、cp/ls/rm/mv 不使用
- 手順: map → BCD 判別で ESP に V5.TXT（生成 + map 追記）→ ntfs_aa64.efi
  を load → **map -r**（マッピング表は map -r でしか再構築されない）→ map
  → 2 秒 stall → map
- ラウンドA（connect 無し）: if exist(fsN:\Windows\System32\winload.efi)
  → 画面エコー + V5A.TXT を音量直下に書く（= RW 実証）
  + load fsN:\Windows\System32\hal.dll と winload.efi
  （実ファイルを読み通せたかどうかの決定的なコンソール証拠）
- connect（素）→ map -r → map → ラウンドB（同型、V5B.TXT）
  ※ connect が不明コマンドならここで中断して構わない: ラウンドA までで
    「FS が現れたか」の答えは既に出ている
- 最後に BCD 判別で bootmgfw.efi を実行。生還すれば
  ALL-BOOTMGFW-RETURNED-NO-HANG

### デプロイ状態（リブート前）
- /mnt/efi/startup.nsh = startup.nsh.v5、sha256 df767ee6…（全 59 行ではなく 167 行）
- v4（sha 45ffe8a3…）は work/diag/startup.nsh.v4 に保存済
- **BootNext は v4 の起動で消費されており 0005 を再装着した**
  （efibootmgr -n 0005。これを忘れると次回起動は AnduinOS に抜ける）
- sda1 直下には startup.nsh が無いので startup.nsh は Windows ESP の 1 本だけ
- sdb1/sdb3 はクリーンアンマウント済。**リブート 1 回いつでも可**

### 次の起動で読むもの
- コンソール全体: 初期 map 表 / NTFS FS の出現 / WINVISIBLE-fsN の有無 /
  load fsN:\Windows\System32\hal.dll と winload.efi の結果行 /
  connect が認識されたか / 最終マーカー
- ESP 直下 V5.TXT（map 表のスナップショット）
- sdb3 直下 V5A.TXT / V5B.TXT（在れば NTFS の FS + RW が証明される）

### 教訓（ツール側）
- run_in_terminal のリダイレクト付きコマンドは VS Code shell integration
  の OSC 633 マーカーが出力ファイル先頭に混入することがある（初回のみ）
  → perl -i -pe で除去し、awk length 検査と grep -c ESC で検査する

## 22.7 v5 の結果と「is not an image」の真意（2026-10-24）

v5 スクリプト（startup.nsh.v5 / 167行 / sha256 df767ee6…e5fe2bf）は全行程を実行済み。
コンソールログから确定した事实:

- `load fs1:\EFI\NTFS\ntfs_aa64.efi` → エラーなし → `map -r` 後に **FS2 (alias HD0b1d) 出現**。
  つまり ntfs-3g UEFI ドライバは BlockIo sdb3 を正常にマウントしている。
  ※ `load` は LoadImage だけでなく **StartImage も呼ぶ**（Load.c:155）。
    v5 で FS2 が出た理由がこれ。
- `if exist(fs2:\Windows\System32\winload.efi)` → true（ディレクトリ参照も正常）。
- 書込み経路も正常: `echo` で作った \V5A.TXT / \V5B.TXT が Linux 側から実在、
  UTF-16LE 内容も正しい（40 B）。ボリュームは ntfsfix -n でクリーン。
- bootmgfw.efi 起動直後（"Image Loaded: bootmgfw.efi" の次行なし）で凍結。

### 重大な認識修正: winload.efi は PE subsystem 16
scratch/peinfo.py で実測:

  winload.efi  2,947,320 B  mach aa64  nsec 10  opt 0x20b  subsys **16**  chars 0x2022
  hal.dll         17,216 B  nsec 4  ep 0x0  subsys 1  chars 0x2022
  bootmgfw.efi 2,622,784 B  nsec 6  ep 0x32370  subsys 10  chars 0x2022  ← ESP の実ファイル
  ntfs_aa64.efi  188,416 B  nsec 3  ep 0x18928  subsys 11  chars 0x002e

EDK2 DxeCore `CoreLoadImage`（MdeModulePkg/Core/Dxe/Image/Image.c ≈601-642）は
ImageType を APPLICATION(10)/BOOT_SERVICE_DRIVER(1)/RUNTIME_DRIVER(2) 以外で
`IMAGE_ERROR_INVALID_SUBSYSTEM; return EFI_UNSUPPORTED` にする。
subsys 16（Windows 専用コード）は **どこの UEFI でも LoadImage 不能**。
→ v5 の `load fs2:\Windows\System32\winload.efi → not an image` は
   NTFS 読み取りの証拠にならない（FAT 上に置いても同じエラー）。**証言として無効**。
- Shell の `load` はステータスを印字しない（Load.c:127 で STR_LOAD_NOT_IMAGE を
  全エラー共通で出すだけ）のため、EFI_STATUS も不明。
- hal.dll (subsys 1) まで同メッセージだった点だけが残り手がかりだが、
  これもステータス不明では読み取り経路の罪を確定できない。
→ **未解決の本来の問い**: ntfs-3g UEFI ドライバの Read/GetInfo は正しいバイトと
   正しいサイズを返しているか？（読み取り経路だけが未測定の変数として残った）
- 副次: ESP の bootmgfw.efi は 2,622,784 B（過去のノートに 724,992 とあったのは
  別物。現物は 2,622,784 / sha 冒頭 55f7377d8dbf3b11）。
- SPCR: OEM BOCHS/BXPC、base 0x09000000、interface type 0x03 = PL011 MMIO。
  16550 不是 → console は MMIO UART。DBG2 も存在。

## 22.8 rdchk.efi（読み取り経路の直接計測）と v6（デプロイ済）

### 目的
NTFS 上ファイルを UEFI 側から読んで「サイズと内容」が Linux 側の実測と一致するかを
1回の起動で確定させる自作 UEFI アプリ。コンソール+ログファイル二重出力。

### 実装 work/diag/rdchk.c (497行) → rdchk.efi 54,880 B
- build2.sh = build.sh の rdchk 版。手順は同じ
  (gcc -fpic -fshort-wchar → ld -T /usr/lib/elf_aarch64_efi_local.lds -shared -Bsymbolic
   → objcopy -R .rela* → GenFw -e UEFI_APPLICATION → peinfo.py で ImageBase 0x40000000 へ patch)
- 生成 PE: subsys 10(EFI app) chars **0x002e**（RELOCS_STRIPPED=0）→ EDK2 は
  RelocationsStripped=FALSE とみなし **AnyPages にロード可**（Image.c:657-706 で確認）。
  ※ chars に 0x0001 が立っていると同じアドレス必須になり失敗し得る。要チェック。
- 出力: ### RDCHK6 BEGIN/END、[fs] N 個の FS 列挙（ro/bs/size/free/lbl + 役割判定
  \EFI\Microsoft\Boot\BCD → ESP、\V5A.TXT → WIN）、ファイル毎に
  open / GetInfo(FileInfo) の FileSize・PhysicalSize・Attr /
  offset×長さマトリクス（0:2,4,8,16,64,256,4096,64KiB、非整列 1,511,512,513、
  4095:2、end-16、end-1、EOF位置で64）＋16進先頭16B＋FNV-1a-64、
  64KiB 逐次ストリーム読取り合計とハッシュ、単発一括読取り（LoadImage と同じ形）、
  probe_load = FileDevicePath+gBS->LoadImage の **EFI_STATUS を名前で**印字。
  末尾に ### VERDICT NTFS-READ-ALL-OK / NTFS-READ-BROKEN / NTFS-FS-NOT-FOUND。
- ログ: 先頭の SimpleFileSystem 2個に \rdchk.log（既存は Delete→Close→再作成大径）。
  ※ say() は char* 前提なので CHAR16 は渡さない（VolumeLabel は char バッファに変換済）。
- 4MB の AllocatePool を使い、終了 3 秒 Stall してから Exit(EFI_SUCCESS)（スクリプト継続）。

### 基準値（Linux 実測 / FNV-1a-64）— 次ブートの答え合わせ用
  rdchk.efi        54,880        fnv=2bf3a6b3483ec6cb   (ESP と NTFS で同一バイト)
  ntfs_aa64.efi   188,416        fnv=d95be3d8ad0ff2aa
  V5A.TXT              40        fnv=f2df64a9e2ee42d2
  hal.dll          17,216        fnv=0c804d6164f9259c
  winload.efi   2,947,320        fnv=a3f5f8cdacd426da
  bootmgfw.efi  2,622,784        fnv=75496dd0aba8826a
- FAT(ESP)=対照群、NTFS=被测群。rdchk.efi 自身の LoadImage を FAT=成功 / NTFS=? で
  読み取り経路の合否を直接判定する。winload.efi の LoadImage は subsys 16 のため
  **どのみち UNSUPPORTED**（=成功でも失敗でも読み取りは無罪の側面がある）。

### 配置（検証済）
- /mnt/efi/rdchk.efi と /mnt/winc/rdchk.efi = 54,880 B / sha f937bb0c0a307bd9（同一）
- /mnt/efi/startup.nsh = startup.nsh.v6（711 B / 31行 / fcf66ef516791a36…35e3f）
  旧 v5 は /mnt/efi/startup.nsh.v5-20261024 に保存
- v6 の順序: ドライバ load(fs1/fs2 両ガード) → map -r → map 印字 →
  fs1:\rdchk.efi → fs2:\rdchk.efi → map -r → cd + bootmgfw.efi（**最期**。凍結しても
  コンソールは生きている）→ SCRIPT-END（届かなければ凍結の意味）

### 22.8b 確定版ハッシュ（EOF テストの誤判定を除去した再ビルド）
- rdchk.efi 54,880 B / **fnv=bc90622b5d3c54e2** / sha 冒頭 83db972dbbef13a5
  （上記 22.8 の 2bf3a6b3483ec6cb は旧版。EOF 位置の読みを失敗カウントしていた）
- EOF 位置（offset=FileSize）の読みは short-read/error が正常なので失敗勘定から除外。
- ESP/NTFS 両方の配置物は新版に差替済（同一バイト）／両ボリューム clean unmount 済。
- BootNext=0005（Internal Shell）設定済。→ v6 ブート待ち

## 22.9 v6 の結果 / 自己クラッシュ原因は自分たちの PE 配置不正

### v6 コンソールで確定した事実
- ntfs_aa64.efi の load は fs1/fs2 両ガードで `- Success`
- `map -noerr` は不正フラグ: `map: Unknown flag - -noerr`
  → v6 の map 更新行は実際には走っていなかった（v7 で修正）
- fs1:\rdchk.efi 実行直後に例外（bootmgr は未起動）:
  Synchronous Exception at 0x0000000040000258（=自アプリ base+0x258）
  ESR 0x96000007 → EC 0x25 Data abort / Translation fault 3rd level
  FAR=0 X0=0（.data 相当を NULL 参照）→ ArmCpuDxe ASSERT(339) で凍結

### ファームの正体が確定（大発見）
- 例外ログのモジュールパスが
  /builddir/build/BUILD/edk2-20260902/Build/ArmVirtQemu-AARCH64/
  DEBUG_GCC5/{DxeCore,Shell,BdsDxe,BootManagerMenuApp,ArmCpuDxe}.dll
- つまり OCI のファームは Ubuntu の ArmVirtQemu AARCH64 **DEBUG** ビルド
- ローカル AAVMF(qemu-efi-aarch64 2025.11-3ubuntu7.3) とバージョン文字列一致
- DEBUG なので ASSERT が即 同期例外 → 全体フリーズ（v6 の振舞と一致）

### 壊れていた自分たち PE の実測（scratch/sections.py）
- /mnt/efi/rdchk.efi: ep=0x240 sizeh=0x240 img=0xd660
  **secalign=0x20** chars=0x2e base=0x40000000 reloc=0xd620+0x1c
- 対照（良品）: ntfs_aa64.efi / bootmgfw.efi / 新ビルドは全部 secalign=0x1000
  sizeh>=0x400 / base reloc あり
- 原因は旧レシピ build.sh / build2.sh の
  objcopy -R .rela -R .rela.plt → GenFw → ImageBase 直 Patch
  RelocsStripped なしで固定 ImageBase → LoadeImage のマッピングと実配置が乖離
  → entry+0x18 で NULL 参照（v6 の例外と完全に整合）
- この環境の binutils に efi-app-aarch64 ターゲットは**存在しない**（--info に無）
- 「GenFw は .rela 付き ELF を扱えない」過去の記録は**誤り**（実証ずみ）

### build3.sh = 正典レシピ（以後これを使う）
- gcc -O1 -mgeneral-regs-only -fpic -fshort-wchar -ffunction/data-sections
- ld -T /usr/lib/elf_aarch64_efi.lds + /usr/lib/crt0-efi-aarch64.o
  -lefi -lgnuefi （再配置は残す: objcopy で消さない）
- ~/edk2/BaseTools/Source/C/bin/GenFw -e UEFI_APPLICATION
- 出力 69,632 B / ep=0x4000 sizeh=0x1000 img=0x11000 secalign=0x1000
  chars=0x2e subsys=0xa base=0x0 reloc=0x10020+0x1c
  layout-OK / relocation PRESENT
- 教訓: デプロイ前に必ず python3 scratch/sections.py <file> で layout-OK を確認

### startup.nsh.v7（作成済・未デプロイ）
- work/diag/startup.nsh.v7 = 460 B / 22 行 / LF のみ / ESC 無し / 最長行 < 78
- v6 からの変更: map の -noerr を全除去（map / map -r のみ）
- 順序: ntfs load(fs1ガード) → map -r → map 印字 → fs1:\rdchk.efi
  → fs2:\rdchk.efi → PRE-BOOTMGR → cd + bootmgfw.efi（最期）→ SCRIPT-END

## 22.10 rdchk 無出力の根本原因：手組み gnu-efi レシピの PE 異常（2026-10-24）

### 決定証拠
- readelf -rW build3_rdchk.elf : RELOC_TYPE=AARCH64_RELATIVE 172 件のみ
  R_AARCH64_ADR_PREL_PG_HI21 / ADD_ABS_LO12_NC は **ゼロ**（`-shared -Bsymbolic`
  でローカル参照が全部折叠され、link 時に adrp 即値が確定済み）。
- PE の `IMAGE_DIRECTORY_ENTRY_BASERELOC` = **rva=0 size=0**（＝ローダは fixup 不能）。
- 例外命令は `adrp x21,10000` + `ldr x22,[x21,#3264]`。ELF 上の .text と .data の
  相対距離は PE で **-0x2000** に変わる（ELF 0x3000→RVA 0x1000、ELF 0x10000→
  RVA 0xF000）ので、折られた adrp はイメージ末尾（base+0x11000）より外を指す
  → translation fault（ESR 0x96000007 / FAR 相当が未マッピング）。
  => rdchk.efi はどの実行経路でも 1 回目の print 前に落ちていた（アプリ
     側のバグではなくビルド産物の欠陥）。
     バグではなくビルド産物の欠陥）。

### EDK2 例外ダンプのアドレス対応（実測）
- `add-symbol-file <elf> 0xBASE2` の BASE2 が真のイメージ base（= 「Loading driver
  at」表示 + 0x1000）。**ELF vaddr = PC - BASE2**。
- `PC 0x… (BASE+off)` 表記の BASE は真の base **− 0x1000**（＝オフ表示は RVA）。
- 実測照合：ELF 0xa790 の 32 バイトが PE の offset 0xb790 に存在（shift +0x1000）。

### 対照実験 hello.efi（同一レシピ）
- 例外なしで完走（`..SH-DONE` 到達）したが **Print 出力ゼロ**。
- gnu-efi 4.0 の `Print` は標準出力ハンドル解決に失敗すると黙って捨てる。
- 自前 DEBUG フirmware では ConOut が GOP 側だけらしくシリアルに出ない（Shell
  自身の出力は出る＝Shell はシリアルへも書く）。

### 結論・方針
- **AARCH64 で gnu-efi 手組みレシピは使わない**（reloc が壊れる）。
- 同じ edk2 ツリー内で `MODULE_TYPE = UEFI_APPLICATION` としてビルドする：
  GenFw 適用済・BASERELOC あり・**DebugLib がシリアルへ直接書く**ので
  ConOut/SerialIo プロトコル探索は不要（＝観測性が確保される）。
- 追加先: `OemPkg/RdChkApp/RdChkApp.inf` を `ArmVirtPkg/ArmVirtQemu.dsc`
  `[Components.AARCH64]`（ファイル末尾）に 1 行足して通常 build。

## 22.11 EDK2 常設アプリ RdChkApp 完成と NTFS 読取経路の潔白判定（2026-10-24）

### なぜ作り直したか
- v6 まで使った手組み gnu-efi 版 rdchk.efi は PE 配置が異常で
  firmware が「not an image」と拒否した（§22.10）。
- AARCH64 の UEFI アプリは EDK2 ツリー内でビルドするのが確実と判明。
  そこで計測アプリを OemPkg として常設した。

### 追加したもの（~/edk2 内・git 管理外なのでここに記録）
- `~/edk2/OemPkg/OemPkg.dec`（340B / PACKAGE_GUID 4A6F0B8E-2C5D-4A93-
  B7E1-6D8C3F510A29）と空の `OemPkg/Include/`
- `~/edk2/OemPkg/RdChkApp/RdChkApp.inf`
  BASE_NAME=RdChkApp / FILE_GUID A7C31E54-9D2B-4E7F-8C61-0B5F4D9A2E77 /
  MODULE_TYPE=UEFI_APPLICATION / ENTRY_POINT=RdChkMain
  libs: UefiApplicationEntryPoint, UefiBootServicesTableLib, UefiLib,
  BaseLib, BaseMemoryLib, MemoryAllocationLib, DevicePathLib, DebugLib
- `~/edk2/OemPkg/RdChkApp/RdChkApp.c`（現在 628 行）
- DSC 接続：`ArmVirtPkg/ArmVirtQemu.dsc` に
  `[Packages] OemPkg/OemPkg.dec` と
  `[Components.AARCH64] OemPkg/RdChkApp/RdChkApp.inf` を追記
  （原本は /tmp/ArmVirtQemu.dsc.orig）
- 教訓：.inf の `[Guids]` に gEfiFileInfoGuid と
  gEfiFileSystemInfoGuid が必須。無いと AutoGen がシンボルを
  生成せずリンクに落ちる（はまりどころ）。

### ビルドと成果物
- `cd ~/edk2 && . ./edksetup.sh; build -a AARCH64 -t GCC -b DEBUG
  -p ArmVirtPkg/ArmVirtQemu.dsc -j 4` → 増分 約11秒（フルビルドは無い）
- 成果物 `Build/ArmVirtQemu-AArch64/DEBUG_GCC/AARCH64/OemPkg/RdChkApp/`
  `RdChkApp/OUTPUT/RdChkApp.efi`（24,576B）
- `work/scratch/gate.py <efi>` の出力（現行ビルド）：
  `magic=0x20b nsec=2 ep=0x3db0 imgsz=0x6000 szh=0x1000 sub=10`
  `BASERELOC rva=0x0 size=0x0` → **reloc ディレクトリが空なのは正常**。
  EDK2 の AARCH64 アプリは固定配置で再配置表を持たない。
  手組み版で reloc が無かったのは欠陥、EDK2 版で無いのは設計。
  ただし gate.py は reloc=NO と表示するので誤解しないこと。

### ハーネス運用で新たに判った制約（次に読む人向け・重要）
- ntfs-3g UEFI ドライバは ConnectAll が無いとブロックデバイスに
  **バインドされない**。Shell で素の `map` だけでは NTFS ボリュームは
  出現せず、`map -r` で初めて接続される。
- 接続後に FS インデックスが入れ替わる：
  FAT(QSH) = FS1（デバイスパス …003E…、起動時は BLK1）
  NTFS(QNTFS) = FS0（…003C…、BLK0）
  → `map -r` 後にアプリを叩く行は必ず `fs1:` を参照する。
- fs0: を指すと Shell が "not recognized as an internal or external
  command" を出す。これが「アプリが走らない」の正体だった。)
- 現行の起動スクリプト `/tmp/qemu/nt4.nsh`（= shfat の startup.nsh）：
  `load fs0:\EFI\NTFS\ntfs_aa64.efi` → `map -r` → `fs1:\rdchkapp.efi`
- **コンソール収集は `-serial file:f.appN` が一番クリーン**。
  `-nographic` は自分の打鍵が pty エコーで混入して解読不能になる。
  実行例は g.appN 生成行を参照。`rc=124` は正常（timeout が Shell> で
  待機中の QEMU を殺すので、成否はマーカーで判定する）。

### 第三の記録チャンネル（これが 一番頼りになる）
- RdChkApp は見えなくなった後に備え、ボリュームごとに自身と同じ内容を
  `\rdchk.log` へ書く（say() がログ handle 以降はファイルにも書く設計）。
- 読出：`mcopy -o -i shfat ::rdchk.log rfatN.txt`
  （mtools が "The devil is in the details: zero number of heads or
  sectors" と唸るのは無害。`mrm` は未導入なので消すときは mcopy で
  空ファイルを被せるか mkfs し直し。）
- **mtools は NTFS を読み書きできない**：`mdir -b -i ntfs.img` は無出力、
  `mcopy -i ntfs.img …` は失敗も言わずに何もしない。
  ntfs.img の中身を見る/入れるには ntfs-3g/FUSE か別ツールが必要。

### 自己クラッシュ2件（原因は全部こちらのバグ、ドライバは無実）
1. `open_logs()` が全ボリュームで READ|WRITE|CREATE を無条件実行。
   ReadOnly ボリュームは SKIP するよう防御した（実測でドライバの
   NTFS は ro=0 を報告するので実害はなかった）。
   ※EFI_FILE_SYSTEM_INFO.ReadOnly は GetInfo で読む。
2. 本命：`del->Delete (del); del->Close (del);`
   EDK2 の FileDelete() は内部で handle を閉じるため、後続の Close は
   freed pool へ jump する。症状は
   `Synchronous Exception at 0xAFAFAFAFAFAFAFAF`（=EDK2 の free-poison）
   ESR 0x8A000000 → EC 0x22 = PC alignment fault、
   PC/LR 0x45F533AC = RdChkApp base(0x45F50000)+RVA 0x33AC、
   続いて `ASSERT [ArmCpuDxe] CpuExceptionHandlerLib.c(438)` で凍結。
   「初回実行だけ成功し、ログが存在する2回目以降は必ず沈む」がこれで
   説明ついた。→ Delete のみを呼ぶ形に修正。
   教訓：0xAFAF… が出たら即 use-after-free を疑う。

### 失敗カウンタの設計ミス（VERDICT の偽陽性）
- 旧：`if (iswin && o[i] < fsize && (EFI_ERROR (st) || got != want2))`
  → EOF をまたぐ長さの読み（40B ファイルに len=4096 等）を
    全部「失敗」と数えていた。short read は正しい仕様。
- 新：真の失敗は EFI_ERROR(st)、または off+len<=fsize なのに got!=len。
  それ以外は eofshort、SetPosition 拒否は seek-rej に分離し、
  bytes は逐次読み分も加算。
- 実測の内訳（app8）：read-fail=0 / bytes=3,196,306 / seek-rej=4 /
  eofshort=9 → `### VERDICT NTFS-READ-ALL-OK`

### 今日追加したテスト
- `test_dir()`：ディレクトリ Open → GetInfo(FileInfo) → `Read()` ループで
  EFI_FILE_INFO を walk（cnt・名前 FNV・attr・bad-entry 検出）。
  FAT/NTFS 双方でエラーなし（FAT \EFI\Microsoft\Boot=4件、
  FAT \=4件、NTFS \=6件、NTFS \Windows\System32=4件）。
  ※EDK2 の EFI_FILE_INFO には FileNameSize が無い。
  名前長 = e->Size - SIZE_OF_EFI_FILE_INFO（=OFFSET_OF(FileName)）。
- ESP 側：`\EFI\Microsoft\Boot\bootmgfw.efi`(2,622,784) と
  `BCD`(45,056) の実読 + 同ディレクトリの列挙。
- NTFS 側：`\Windows\System32\config\SYSTEM`（ハーネスでは未作成＝NOT-FOUND）

### 判定：クリーンな NTFS 上では読み取りは完璧（重要）
FNV-1a64、逐次64KiB と 一発読み の両方が一致：
- V5A.TXT 40 → 0xF2DF64A9E2EE42D2
- hal.dll 17,216 → 0x0C804D6164F9259C
- winload.efi 2,947,320 → 0xA3F5F8CDACD426DA
- ntfs_aa64.efi 188,416 → 0xD95BE3D8AD0FF2AA
- bootmgfw.efi 2,622,784（ESP/FAT）→ 0xCFE01DC221718A4A
  ＝ work/bin/bootmgfw.orig.efi の実測と一致
- BCD 45,056（ESP/FAT）→ 0x2F6E84AA1D201FE6
  ＝ work/bin/BCD.cur の実測と一致
- ドライバ経由の LoadImage は成功：`[load] NTFS rdchk.efi -> st=OK`
  （winload は SubSystem=16 なので INVALARG＝既知の正常挙動）
- 観測された逸脱は 3 点だけ：
  (1) SetPosition が fsize 以上の offset を INVALARG で拒む
      （Windows のドライバは受理する。今回の範囲で実害なし）
  (2) ボリュームの ReadOnly フラグが立たない（ro=0 と報告）
  (3) ログ系ファイルは作れる（＝書き込み経路も動作）
- **帰結：「bootmgr が winload 読取で固まる」という読み筋は、
  クリーンな mkfs.ntfs ボリュームでは否定された。**
  実機の C: は $MFT 多エクステント・4KB レコード・大容量・
  $LogFile リプレイ・ディレクトリ大量といった条件を持つので、
  次の手当ては (a) 実物に近い ntfs.img，(b) 実機そのものの計測。

### 事故：ハーネス用 FAT イメージを rm した（復旧レシピ）
- コマンド末尾に `rm -f shfat ::rdchk.log` と打って /tmp/qemu/shfat を
  消した（意図はイメージ内のログ削除）。教訓：`rm` は 1ファイルずつ、
  イメージ名の変数は置換展開してから打つ。
- 復旧手順（素材は無事だった：work/drivers/ntfs_aa64.efi、
  work/bin/{bootmgfw.orig.efi,BCD.cur}、edk2 Build の Shell.efi）：
  `dd if=/dev/zero of=shfat bs=1M count=64`
  `mkfs.vfat -F 32 -n QSH shfat`
  `mmd -i shfat ::EFI ::EFI/BOOT ::EFI/NTFS ::EFI/Microsoft ::EFI/Microsoft/Boot`
  `mcopy -o -i shfat <Shell.efi> ::EFI/BOOT/BOOTAA64.EFI`（以下同様）
  `mcopy -o -i shfat nt4.nsh ::startup.nsh`
- mcopy は「 Several file names given, but last argument not a directory」
  を出したら出力先ディレクトリ指定の漏れを疑う（$変数が空展開した事故）。

### 実行再現（app8 の流儀）
- `FW=$HOME/edk2/Build/ArmVirtQemu-AArch64/DEBUG_GCC/FV/QEMU_EFI.fd`
- `timeout 70 qemu-system-aarch64 -machine virt -cpu max -smp 1 -m 2048 `
  `-display none -serial file:f.appN -bios $FW `
  `-drive if=none,id=cod,format=raw,file=shfat -device virtio-blk-device,drive=cod `
  `-drive if=none,id=win,format=raw,file=ntfs.img -device virtio-blk-device,drive=win `
  `-net none`
- `-machine virt -cpu max` は必須（無いと "No machine specified"）。
- 整形：`tr "\r" "\n" < f.appN | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; /^$/d'`

### 未処置（次に続ける場所）
- 実機：sdb1(Windows ESP)/sdb3(C:) は ro マウントのまま。古い壊れた
  rdchk.efi が載っている。片付け（アンマウント）と、EDK2 版
  RdChkApp.efi + startup.nsh.v7 のデプロイは要ユーザー（sudo 未キャッシュ）。
  startup.nsh.v7 は `load` → `map -r` → FS0..FS3 を順に
  `If Exist %i:\rdchkapp.efi` で探して実行（FS index が入れ替わる対策）。
- BootNext（0005）は 1 回の shell boot で消費されるので再武装が必要。
- ntfs.img を Windows 寄りにもう少し重く作る（深い階層・多数エントリ・
  非 resident 多エクステント）。まず ntfs-3g/FUSE が使えるか確認。
- rdchk.c（gnu-efi 版）・rdchk.efi・build3*.pe は廃止確定。触らない。

### 22.11a startup.nsh.v7 確定（実機用・実 Shell で構文検証済）
- `work/diag/startup.nsh.v7`（49行 / LF / 79列以内 / ASCII+少しの日本語）
- 構成：`@echo -off` → 各 FS(fs0..fs5) の `\EFI\NTFS\ntfs_aa64.efi` を
  `if exist ... then load ... endif` → `map -r` →
  各 FS 直下の `rdchkapp.efi` を探して実行 → `..V7-END`
- **教訓：この Shell では `REM` が "not recognized as an internal or
  external command" になる**。コメント行は使わず `echo ..V7-*` を
  マーカー代わりにする（画面証拠にもなる）。`-noerr` も不正（v6 の失敗）。
- ハーネスでの検証結果（f.appA/g.appA）：
  `..V7-START → ..V7-DRIVER-LOADED → ..V7-MAPPED → ..V7-RUN fs1 →
   read-fail=0 → VERDICT NTFS-READ-ALL-OK → ..V7-END`（エラー行ゼロ）。
- デプロイ要件：(1) Windows ESP(sdb1) 直下に `startup.nsh`（v6 は
  退避して残す）、(2) 同 ESP 直下に EDK2 build の `RdChkApp.efi` を
  `rdchkapp.efi` として置く、(3) `\EFI\NTFS\ntfs_aa64.efi` は既設、
  (4) BootNext=0005 の再武装、(5) 同期して umount。

### 22.12 現実的な NTFS 体積（ntfs2.img）と new_test v2（2026-10-24 深夜）

#### mkntfs v2022.10.3 の落とし穴（image 作成レシピ）
- `-f`=--fast、`-Q`=quick、**`-F`=force**。素の通常ファイルを対象にするには
  `-F` が必須。かつ **末尾にセクタ数を書く必要がある**（書くと帮助画面になる、
  と見えるが実は引数不足）。
- クラスタサイズは **`-c 4096`**。`-C` は enable-compression で別物
  （間違えるとセクタ数不足になる）。
- 実戦で通ったコマンド：
  `dd if=/dev/zero of=ntfs2.img bs=1M count=768 status=none`
  `mkfs.ntfs -F -f -Q -L QNTFS2 -c 4096 ntfs2.img 1572864`
  → 「The file ntfs2.img seems to contain an existing filesystem」を
  `mkntfs completed successfully` で抜ける。`file` で sectors/cluster=8 確認。
- **root 不要で作れる**：`ntfs-3g ntfs2.img /tmp/qemu/ntmnt`（FUSE）で中身を
  書き、`fusermount3 -u /tmp/qemu/ntmnt` で外す。`mount -o loop`/sudo 不要。
  ※マウントポイントは `/tmp/qemu/ntmnt`（リポジトリ内 `ntmnt` ではない）。
  QEMU に渡す前に必ず unmount すること。

#### ntfs2.img の中身（768 MiB / 4 KiBクラスタ / ラベル QNTFS2 / 使用 214 MiB）
- 直下：`V5A.TXT`(40B) `rdchk.efi`(69632B) `SYSTEM`(混入した hive コピー)
  `Windows/` `deep/` `frag/` `hardlink-SYSTEM` `sparse.bin`(96 MiB 稀疏)
  `sym-hal.dll` `unicode-meisi.txt`
- `\Windows\System32\` = hal.dll(17216) winload.efi(2947320) を実物コピー
- `\Windows\System32\config\` = DEFAULT SAM SECURITY SOFTWARE SYSTEM（実物）
- `\Windows\System32\drivers\` = 実物 381 ファイル（WOF プレースホルダ含む）
- `\Windows\System32\winevt\` = 1500 ファイル
- `\Windows\WinSxS\` = 800 ディレクトリ、`\Windows\Boot\` = 空
- `\frag\big{0,2,4}.bin` = 25,165,824 B の multi-extent
- `\deep\L00\..\L24\deepfile.bin` = 25 階層

#### アプリ拡張（RdChkApp.c は 808 行 / md5 4894f24dc2d6d22f931256cd69045cd4）
- `new_test()` v2：実 Windows に有りそうな 19 ファイル + 23 ディレクトリの表
  （`g_newtests[]`）。無いパスは **miss**（失敗に数えない／VERDICT を汚さない）。
- 各ファイルは **先頭 32 MiB まで、512 KiB 刻みで 64 KiB 読み**、
  チャンク毎に FNV-1a64 → その **XOR / 先頭 h0 / 末尾 hl / n / bytes** を印字：
  `  F#k <path> n= bytes= xor= h0= hl= ms=`
  → multi-extent 継ぎ目・稀疏穴・512 KiB 境界の化けを位置付きで捕まえられる。
- ディレクトリは従来通り件数と名前 FNV（`dir cnt= nameH=`）。
- 追加カウンタ `miss=` を summary 行に出す。
- **ログ書き込みの安全化**：`open_logs()` は
  `\Windows\System32\config\SOFTWARE` が開ける体積（＝実 Windows 領域）へ
  `rdchk.log` を作らない。FAT(ESP) だけに作られる（appD で検証：FAT のみ生成、
  NTFS 側はスキップ）。
- ゲート：`magic=0x20b nsec=3 ep=0x41f0 imgsz=0x8000 szh=0x1000 sub=10`
  `BASERELOC rva=0x7000 size=0x1000` → 「PE32+=OK subsystem10=OK reloc=OK」。
  32,768 B。ビルドは従来コマンド（rc=0、/tmp/hbuild15.log）。

#### 判定：現実的な体積でも読み取りは完璧（appB/appC/appD すべて）
- `read-fail=0 … new-fail=0 miss=6` → `### VERDICT NTFS-READ-ALL-OK`
- dir：winevt 1502 `0x12B54CADC99328E3` / WinSxS 802 `0xDF33BBA8C031F273` /
  drivers 383 `0xBD51FFF96E171383` / config 7 `0x0D313CDD740DBD2B` /
  Boot 2 `0xEA459698E18E3C23` / NTFS root 13 / sys32 7 / FAT bootdir 4
- **チャンク XOR を host 側 python（/tmp/xref.py, os.pread 再現）と全件照合して
  完全一致**：SOFTWARE `xor=0xB62BD8E7C7D9C4C2 h0=0x2C310187CDD8515E
  hl=0x8F1787554FAD8AE4`、SECURITY/DEFAULT/SAM、SYSTEM(hardlink) n=17
  `0x47D43BCD074B77F6`、tcpip.sys n=7 `0xE97EC16477BBB2DF`、volmgrx.sys、
  big0/big2、sparse.bin `0xE2A65662DD01A685`、deepfile.bin。
  → ハッシュ様式そのものが正しいと証明できた（実盤でも同じ式で比較できる）。
- `Classpnp.sys` だけ host 側で "MISSING" になった理由：WOF プレースホルダ
  （`ls -la` で `-> unsupported reparse tag 0x80000017`）。EFI 側は 76 B の
  スタブを読めて FUSE は壊れた symlink に見せる、というだけで不具合ではない。
- タイミング：per-file ms(約17-50ms) はほぼコンソール印字コスト
  （115200baud ≒ 10 chars/ms）。NEWTEST 全体 ms=2547。ドライバは速い。

#### 実機デプロイ完了（reboot 1 回待ちの状態まで進めた）
- `/mnt/efi/startup.nsh` ← `work/diag/startup.nsh.v7`（既存は
  `startup.nsh.bak-v6-20261024` に退避済。v3 もそのままで残置）
- `/mnt/efi/rdchkapp.efi` ← 上記 32,768 B 版（md5 一致を ESP 上で確認）
- `sync` → `/mnt/efi` `/mnt/winc` を unmount（クリーン）
- `efibootmgr -n 0005` 設定済（BootNext: 0005 = EFI Internal Shell）。
  BootOrder は 0006,0002,0000,0001,0005 のまま＝通常起動は無変更。
- sudo はこの端末で効くようになった（`sudo -n true` rc=0）。
- 実機で見るべきマーカー： `..V7-START` `..V7-DRIVER-LOADED` `..V7-MAPPED`
  `..V7-RUN fsN` `RDCHK6 BEGIN` `[fs] #Nh=` `F#k … xor=` `NEWTEST END`
  `VERDICT` `RDCHK6 END` `..V7-END`。

#### 次に続ける場所
- 実機コンソール ⇒ 実盤の同一オフセットを host 側 `/mnt/winc` で読み、
  XOR/h0/hl を突き合わせる（一致 ⇒ 読み取りは無罪、bootmgr/BCD 側へ確定）。
- 不一致が出たら、そのファイル名の該当チャンク（512 KiB 境界）が犯人特定の手がかり。
- 片付け：実機 ESP の `rdchk.efi`（旧壊れ版）は未削除。BootNext は次回消費済。

---

# 22.13 実機計測が完走出来た：ntfs-3g UEFI ドライバの読み取りは「無罪」

（2026-10-24 夜／実機 ampere・再起動1回で採取）

## 手順（このまま再現できる）

- `sudo -n true` rc=0 ⇒ NOPASSWD で sudo が効く
  ⇒ **実機 ESP への書き込みが agent から直接可能**になった
- `sudo mount /dev/sdb1 /mnt/efi`
  - `rdchkapp.efi`（32,768B／md5 4894f24d…）を配置
  - `startup.nsh` を **v7** に更新（旧版は
    `startup.nsh.bak-v3-20261024` / `bak-v6-20261024` / `startup.nsh.v5-20261024`）
- `sudo efibootmgr -n 0005`（UEFI Shell 起動）→ ユーザーが手動 reboot
- ユーザー報告「こうなった、1分ぐらいで終わった」＝**app が最後まで走った**
- 回収：`sudo cp /mnt/efi/rdchk.log
  work/diag/rdchk.real1.log`（27,440B／440行）
  → `tr`+`sed` で CR/ESC を落とし `work/diag/rdchk.real1.txt`

## 実機で app が見ていた FS（ログ原文）

```
[fs] LocateHandleBuffer -> st=OK n=3
[fs] #0h=0x3EEB8F18 ro=0 bs=4096 size=1071624192  free=1064779776 lbl=ANDUIN_EFI
[fs] #1h=0x3EE54D18 ro=0 bs=1024 size=100663296   free=54713344   lbl=-
      ESP-OK (BCD)
[fs] #2h=0x3EE46318 ro=0 bs=512  size=53564390912 free=42181152768 lbl=-
      WIN-OK (V5A.TXT)
```

- 3 フォルダ全部 `ro=0`（書き込み可）
- `V5A.TXT` がある＝Windows ボリュームの判定が生きている
- 参考（§ref）：FAT 側の `rdchk.efi` は**旧壊れ版** 54,880B を読んでいる

## 判定（原文）

```
--- NEWTEST END fail=0 miss=8 ms=6161
### RDCHK6 NTFS-read-fail=0 NTFS-bytes=3240963 seek-rej=4 eofshort=11
###  / new-fail=0 miss=8### VERDICT NTFS-READ-ALL-OK
### RDCHK6 END
```

- `read-fail=0`：16 パターン×複数ファイルで 1 回の読み取り失敗も無し
- `new-fail=0`：新テスト表（19 パス）で読み取り失敗 0
- `miss=8`：開けない 8 件は予定通り
  （`clipsp.dll`・`ACPI.sys` は実在名と大小／残り 6 件は
  `ntfs2.img` 専用パス `frag/*`,`sparse.bin`,`hardlink-SYSTEM`,
  `sym-hal.dll`,`deep/...` が実盤に無いだけ）
- `seek-rej=4`／`eofshort=11` は §22.6 の既知の無害偏差

## host とのハッシュ突合 ⇒ 決定的証拠

`work/scratch/xref.py`（guest と同一プロトコル：512KiB step／64KiB read／
チャンク FNV の XOR + 先頭 h0 + 末尾 hl）を `sudo` で `/mnt/winc` に走らせた。

**11 件のうち 10 件が guest の出力と 1 バイトも違わず一致**：

| # | file | n | bytes | xor | h0 |
|---|---|---|---|---|---|
| 0 | SOFTWARE | 64 | 4194304 | 0xB62BD8E7C7D9C4C2 | 0x2C310187CDD8515E |
| 1 | SECURITY | 1 | 32768 | 0x6C263371F9E931B1 | （同値） |
| 2 | DEFAULT | 1 | 65536 | 0xA228A77957868ACD | （同値） |
| 3 | SAM | 1 | 65536 | 0x17CB4C02499D0966 | （同値） |
| 4 | ntoskrnl.exe | 22 | 1441792 | 0x7484F2EF252E7BB0 | 0x8526E7CEBC9B07D0 |
| 5 | ci.dll | 2 | 131072 | 0xDAED271B1D1F100C | 0xA1EC3C0679B447BE |
| 7 | tcpip.sys | 7 | 458752 | 0xE97EC16477BBB2DF | 0x3032ECA9C04E8524 |
| 10 | volmgrx.sys | 1 | 65536 | 0x6CE7A7230CBCB9D0 | （同値） |
| 11 | System.evtx | 1 | 65536 | 0xCBDF9961357CA300 | （同値） |
| 17 | pagefile.sys | 64 | 4194304 | 0x0（全零） | 0xEB05052EA5B62325 |

- 照合は `python3` で自動化（guest ログを regex で拾って host 出力と比較）
- **結論：実盤・実 firmware で ntfs-3g UEFI ドライバの読み取りは完全正常**
  ⇒ bootmgr の无声停止は **読み取りでは起きない**。BCD／bootmgr 側の問題

唯一の DIFF：`Classpnp.sys`

- guest：`n=1 bytes=65536 xor=0x0 h0=hl=0xEB05052EA5B62325`（=64KiB 全零）
- host：`MISS 2`（open 自体が ENOENT）
- 理由：実体は **WIM プレースホルダ**（下記）

## 副次収穫 1：ボリュームに WIM placeholder が大量

```
$ sudo find Windows/System32 -maxdepth 2 -type l \
      -lname '*unsupported reparse*' | wc -l
7703
$ sudo find Windows/System32 -maxdepth 2 -name '*.wofbak' | wc -l
55
/mnt/winc/Windows/System32/DrtmAuthArm.wim -> unsupported reparse tag 0x80000017
```

- ntfs-3g 上では symlink のように見え（`du -b`=34）、中身は開けない
- firmware 側は「開ける」が読むと 0 埋め、host 側は開けない、という非対称
- bootmgr 停止とは別問題。ただし winload 以降で効いてくる可能性は残す

## 副次収穫 2：dir 枚挙の「4001」はうち側の上限

- `test_dir` に `if (cnt > 4000) { say("  (truncated)"); break; }`
  （`RdChkApp.c` 474 行まわり）→ 4001 は打ち切り値
- firmware は **8.3 短縮名も枚挙**する（`DOCUME~1`,`DUMPST~1.TMP` 等）
  ⇒ host の FUSE 枚挙と件数は一致して初めておかしい
- host 実測（`ls -f | wc -l`, sudo）：
  System32 4404／drivers 383／config 51／winevt 4／WinSxS 16479／
  Boot 11／Installer 2／`$Recycle.Bin` 3／SVI 8／
  DriverStore\FileRepository 417／Program Files 16

## 副次収穫 3：ロード結果（読み取りとは別レイヤ）

```
[load] FAT  rdchk.efi  -> st=OK
[load] FAT  bootmgfw   -> st=OK
[load] NTFS rdchk.efi  -> st=OK
[load] NTFS hal.dll    -> st=INVALARG:0x8000000000000003
[load] NTFS winload    -> st=INVALARG:0x8000000000000003
```

- hal/winload の INVALID_PARAMETER は PE subsystem=
  EFI_BOOT_APPLICATION(11) のため BS->LoadImage が弾く正常挙動
- **bootmgfw.efi 自体は FAT からロードできる**（＝停止は実行中）

## BCD：初めて「起動に使われた現物」をダンプ

新規ツール `work/scratch/bcdump.py`（python-hivex）で全 object/要素を
人間可読化 → 保存 `work/diag/bcd.real1.txt`

- 現物 ESP BCD：md5 `d8b9c1a532198b20dfc2e9bf83d93859`／45,056B
  ／mtime 2026-10-24 16:45 ＝ §20 で直した形そのもの
- ⚠ **注意**：`work/bin/BCD.cur`（md5 5afe…）は §22.10 でお引き合いに
  出した**古い手元コピー**。ログに BCD を読んだ行は無く（見出し
  `--- FAT  BCD ---` があるだけ）、§22.10 の FNV 照合は host 側
  ファイル比較だった。実測比較としては使わないこと
- loader object `{cc075cd7-…}` の device 要素の GUID ペアは
  `b9237fd1-5fa8-4f81-a2bf-88f397a5205f`（= sdb3 PARTUUID）
  ＋ `cef8aa2a-97cd-4c62-bf50-518cad9d50f5`（= ディスクGPT）
  ⇒ §16.6 と同じく**正しく Windows 盤を指している**
- `{dbgsettings}` = `{6efb52bf-…}` に要素 `1500000E` = 0x40000000、
  `{emssettings}` = `{7ff607e0-…}` に
  `250000f3`=0 / `250000f4`=1 / `250000f5`=115200 が元から入っている
- OS loader `{cc075cd7}` 側に debug/EMS を有効化する要素は**無い**
- `{9dea862c-…}`={bootmgr}：`23000003`(default)=`{cc075cd7}`、
  `23000006`(resume)=`{cc075cd6}`、`24000001`=単一エントリ、
  `25000004`=0x1e（timeout）、`11000001` は型 0（＝未指定/ESP）

## 状態・教訓

- `/dev/sdb3` をうっかり **rw** で mount してしまった（気づいて即
  `mount -o ro` に付け替え）。`sudo ntfsfix -n /dev/sdb3` は
  `$MFT`/`$MFTMirr`/代替ブートセクタすべて "processed successfully"
  ＝dirty フラグ無し
- BootNext(0005) は消費済 ⇒次回 reboot は既定（GRUB 側）に戻る
- 未後始末：`/mnt/efi/rdchk.efi`（旧壊れ版 54,880B）

## 次の一手（P6：bootmgr の「声」を自力で拾う）

制約：firmware は差し替え不可（OCI が渡す AAVMF）、`bcdedit` 不在、
そして §3.1 の通り **bootmgr 段では BCD の debug が効かない**。
 ⇒ **自分の EFI アプリでコンソール出力をフックする**のが唯一の可視化手段

作るもの：`OemPkg/IoLogApp/IoLogApp.efi`

1. `gST->ConOut` / `StdErr` の **EFI_SIMPLE_TEXT_OUT をラップ**
   （ReinstallProtocolInterface ＋ gST のポインタ差し替えの両方）し、
   bootmgr/winload が出す文字列を**全文字** ESP の `iolog.txt` へ
2. `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL.Open` をラップして
   「どのパスを開こうとしたか／戻り値」を同ログへ
3. 対象ディスクの `BlockIo.ReadBlocks` の非 OK だけ記録
4. **1 行ごとに Flush**（ハングしてもログが残る）
5. 最後に `bootmgfw.efi` を自分で LoadImage/StartImage し、
   「start 前／start 復帰 st=」を記録 ＝停止位置を確定

開発・検証は QEMU ハーネスで無償で回す
（`/tmp/qemu/shfat` の実 bootmgfw + 実 BCD + ntfs2.img で
 同じ「无声停止」が出ることを確認する）

# 22.14 QEMU TCG ハーネス確立／「无声停止」の正体は bugcheck（2026-10-24）

※ 上記「次の一手（P6：bootmgr の声を拾う）」は本节以降で**陳腐化**。
　 bootmgr は無罪。停止していたのではなく、**Windows が panic して
　 自シャットダウンしていた**（below）。

## ハーネス（work/harness/）

- `win.sh <run名> [追加qemu引数]`
  - 実Disk `/dev/sdb` は **qcow2 オーバレイ**（`-u -b /dev/sdb -F raw`）で
     attach ⇒ 実盤は一切変更されない（書込みは ov-<name>.qcow2 へ）
  - `-machine virt,gic-version=3 -cpu neoverse-n1 -smp 2 -m 8192`（**TCG**／
    /dev/kvm 不在なので起動は遅い：kernel 到達まで数分）
  - firmware = `~/edk2/Build/ArmVirtQemu-AArch64/DEBUG_GCC/FV/QEMU_EFI.fd`
    （実 OCI の AAVMF と同系列：ACPI OEM = BOCHS/BXPC を `*.dat` で確認済）
  - **実 OCI と同じ PCI 構成**：virtio-scsi `1af4:1048` + virtio-gpu `1af4:1050`
    ⇒ グラフィクスのクラッシュは実機でも同名の可能性が高い
  - `-display none -no-reboot -no-shutdown`
    ⇒ `ResetSystem(Shutdown)` 後も **guest RAM / screen が残る**（生命線）
  - `-monitor unix:mon-<name>.sock,server,nowait` / `-serial file:f.<name>`
- `clean.sh <name>`（overlay+ログ削除）/ `mkboot.sh`（FAT: Shell+ntfs driver）

## 検出法（重要）

- リアル OCI firmware は `DXE ResetSystem2:` を print するが、
 Ubuntu 製の ArmVirtQemu ビルドは出さない ⇒ **ログ grep では握り潰せない**
- ⇒ `python3 mon.py "info status"` で **`VM status: paused (shutdown)`** を見る
- ダンプ取るなら `dump.py`（→ ram1.elf）。**nbd を使う前に必ず
  `sudo pkill -f qemu-system-aarch64`**（qcow2 の write lock 衝突）

## 結論：factory bootmgfw の挙動

pristine な `bootmgfw.efi.orig`（md5 2bc7562a…）でも **同じ地点で止まる**。
実際には止まっていない：

1. Windows カーネルまで到達
2. **bugcheck 0x3B SYSTEM_SERVICE_EXCEPTION（例外 0xC0000005）**
3. pagefile へ minidump ヘッダを書き出し（diskdump/crashdmp/dumpfve が常駐＝証拠）
4. `ResetSystem(Shutdown)` ⇒ 画面まっくら＝「无声停止」の見え方

よって bootmgr / BCD / WOF / ESP 改ざんは**全部無罪**（少なくとも本障害に対し）。
犯人は §22.15–22.16 のとおりグラフィックス初期化路径。

# 22.15 メモリフォレンジック基盤（dump.py / ramlib.py）と crash 解析レシピ

## ダンプ → ram1.elf

- `dump.py`：monitor の `dump-guest-memory` で **ram1.elf**（8,589,936,827 B、66.4 s）
- ダンプ範囲は guest RAM のみ：**PA 0x40000000 – 0x240000000**

## ramlib.py（ページテーブル歩行）

- `DTB = 0x200681000`（ELF ヘッダ +0x10 の NOTE = ブートローダの DTB ＝ kernel TTBR0）
- ARM64 4KB granule / 4 段 / shift 39,30,21,12
- **descriptor の出力アドレス = `d & 0x0000FFFFFFFFF000`**（bits[47:12]）
  page は `d&3 == 0b11`、L1/L2 は block（`d&3 == 0b01`）で範囲内直読み
- API: `open_all() readp readfile find_pa desc_at walk readva qva ptrs utf16 pages_in`
- 既知バグ：`pages_in(0xffff000000000000, 0x1000000000000000)` は 0 を返す
 （範囲枝刈り）。`…f80000000000..…f88000000000` は 33,902 ページで OK

## 構造体（実測検証済）

- ARM64 `_CONTEXT`：+0x00 ContextFlags(4)/Cpsr(4)、**+0x08 X0..X28**、
  **Fp=+0xF0 Lr=+0xF8 Sp=+0x100 Pc=+0x108**
- `EXCEPTION_RECORD64`：Code(4) Flags(4) Record(8) Address(8) NP(8) Info[](8)
- `_LDR_DATA_TABLE_ENTRY`：DllBase +0x30 / BaseDllName +0x48,+0x50 /
  FullDllName +0x58,+0x60 ／ `DRIVER_OBJECT`：DriverStart +0x20 Size +0x28
  DriverName.Buffer +0x50

## 今回のクラッシュの実測値

- CTX（例外コンテキスト）= `0xffff9807c968e1b0`（kernel stack 0xffff9807c968e000 上）
- EXR = `0xffff9807c968e728`
  - Code=**0xC0000005** Flags=0 Record=0 NP=2
  - Info[0]=0（=**read**）／ Info[1]=**0x10000000000**
  - AddressOfException = Pc = 0xfffff803fa297c3c
- Cpsr=0x60000044 ContextFlags=0x0040000F
- レジスタ（regs.py）：
  - **X8 = 0x0000010000000000**（＝フォルトしたポインタ）
  - **X20 = 0xffff9982209ee000**（ソース＝caps 構造体）、**X19 = X20+0x2000**（出力先）
  - X1 = 0x1bb0（=7088：コピー対象サイズ）、X21 = 0x30616956（`"Via0"`）
  - Lr = dxgmms2+0x97bcc、Sp=0xffff9807c968ebd0

## フォルト命令（objdump -b binary -m aarch64 で実イメージから）

```
97bc8:  bl      0x2c04b70
97bcc:  ldr     w8, [x20, #1888]     ; ここが Lr の復帰先
97bd4:  str     w8, [x19, #40]
...     （[x20,#2556]/#2560/#3034/#3039] のビットを ubfx して [x19,#44..#51] へ）
97c38:  ldr     x8, [x20, #3104]     ; x8 = 0x10000000000
97c3c:  ldr     w8, [x8]             ; <== FAULT（read）
97c40:  ubfx    w8, w8, #6, #1
97c44:  strb    w8, [x19, #53]
```

**性質**：miniport が報告してきた caps 構造体（x20、7088 B）を
フィールド単位でフラグ転写しているだけの関数。+3104 は
**「追加 caps の配列へのポインタ」で NULL チェックなし**、
そこに載っていた値が **0x10000000000（1 TiB＝どこにもマップされていない）**。
→ 「GPU VA / 1TiB 系オフセットを CPU ポインタとして素引いた」形。

## 教訓

- シンボル化は**そのモジュールの実 SizeOfImage**を使う（mods.pkl の 178 候補中
  126 は MZ 誤検出。誤候補の例 0xfffff803fcdf3000 → nn=2432844775）
- FP チェーン步行（0xffff900000000000<x<0xffffa00000000000, x&7==0）は
  stale データを拾う。主犯モジュールの確定は Pc/Lr ＋命令復元で行う

# 22.16 犯人確定：dxgmms2.sys × viogpudo（virtio-gpu WDDM）（2026-10-24 深夜）

## 名前を付ける方法：PDB 不要、`.rsrc` を読む

常駐イメージには RSDS/デバッグ情報も、ローダーエントリ（`PsLoadedModuleList`）
の実体もない（ページアウト済）。**確実に名前が取れる唯一の経路は
`PE → .rsrc → VS_VERSION_INFO → OriginalFilename`（UTF-16）**。

- `name.py`：mods.pkl 全 178 候補へ適用 → **names.json**
  （`{"<base hex>": [OriginalFilename or null, SizeOfImage, ts, mods名]}`）
- `exports.py <base>`：RAM 上で直接 PE エクスポート表を辿る（ファイル展開不要）
- `imgdump.py <base>`：readva で常駐範囲だけイメージ化
  ＋ `objdump -D -b binary -m aarch64 --start-address=… --stop-address=…`

## names.json の主要な当たり（13/178 が実名）

| base | 実体 | SizeOfImage | ts |
|---|---|---|---|
| fffff803fa200000 | **dxgmms2.sys**（DirectX Graphics MMS, 10.0.26100.1591） | 0x10f000 | a6cbda69 |
| fffff803f8240000 | dxgkrnl.sys | 0x4a5000 | 2417191246 |
| fffff803f86f0000 | **watchdog.sys**（exports 136：WdAllocateWatchdog / SMgr* / DMgr* / DisplayScenario*） | 0x1f000 | 9620ce1b |
| fffff803f9c00000 | **vioscsi.sys** | 0x19000 | — |
| fffff803f9bc00000 | diskdump.sys | 0x12000 | — |
| fffff803f9c50000 | dumpfve.sys | 0x1e000 | — |
| fffff803fa100000 | crashdmp.sys | 0x27000 | — |
| fffff803f7c60000 | ntfs.sys | 0x352000 | — |
| fffff803f80f0000 / f8170000 | usbhub.sys / usbhub3.sys | 0x6e000 / 0xac000 | — |
| fffff803f6ef0000 他 | pci.sys / pciide.sys / intelide.sys | — | — |
| fffff803fb350000 | win32kbase_rs.sys | 0x23000 | — |

- ⇒ 以前の「**vioscsi 不在**」は誤り（System32\drivers に無くても DriverStore 側に
  在ってロードされていた）。storage 系は全部生きている
  （spaceport/storvsc/stornvme/storahci/AWSNVMe/pmem/nvdimm…）
  ⇒ **INACCESSIBLE_BOOT_DEVICE 仮説は死亡**
- diskdump+crashdmp+dumpfve が常駐していたこと ＝ §22.14 の
  「dump を書いてから shutdown」の裏付け

## ミニポートの特定

- `miniport.py`：178 候補全体を走査して `DxgkDdi*` エクスポートを探す → **0 件**
  ＝ダンプ時点でディスプレイ ミニポートは非常駐（ページアウト）。
  RAM 側では特定不能だったのでオフライン側で確定した：
- DriverStore に **viogpudo**（virtio-win の WDDM DoD）が導入済：
  `viogpudo.inf_arm64_809eebb650b1403f/`
  - viogpudo.sys 115,352 B（readable＝WOF 非圧縮）ts=66952c59 SizeOfImage=0x1e000
  - `DriverVer = 07/15/2024,100.95.104.26200`（Copyright Red Hat 2020-2023）
  - `AddService = VioGpuDod` / StartType=DEMAND / ErrorControl=IGNORE
  - **マッチ ID：`PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01`**
    ⇒ ハーネスの `-device virtio-gpu-pci`（既定 subsys 1AF4:1100）と**完全一致**
    ⇒ この環境では **ほぼ確実に viogpudo がバインドする**
- 一方 `BasicDisplay.sys`（basicdisplay.inf_arm64_2a3429a3388f8e73）は
  **WOF プレースホルダ（34 B）**。`display/displaymux/displayoverride/c_display/
  c_linedisplay/usbvideo/wvmbusvideo(HyperVideo)` も DriverStore に在る
- boot-start の display サービスは存在せず（`DXGKrnl` group="Video Init" のみ）
  ⇒ ミニポートは PnP 動的ロード。**起動は PnP 完了後（tcpip/usbhub/ndis が常駐）**
  ＝ win32k/wddm graphics init 段で落ちている

## 死んだ仮説（再確認）

- bootmgr 改ざん（pristine でも同様）／ ESP・BCD 設定 ／ WOF ブロック
 （OS は dxgmms2 まで行っているので起動チェーンは通っている）
- INACCESSIBLE_BOOT_DEVICE ／ vioscsi 不在
- vmbus/Hyper-V 系（HyperVideo は DriverStore にあるだけで_device なし）

## 未解決

- 0xfffff803f9c80000(0xad000) / 0xfffff803f9d30000(0x2fa000) が未命名
 （.rsrc ページアウト）。win32kbase/win32kfull と思うがFP チェーン由来で信用低
- 0x10000000000 の**出所**（viogpudo が返す caps 内のポインタか、
  dxgmms2 側の未初期化 pool か）は未確定 → §22.17 の対照実験で切り分ける

## 作業上の教訓（再現しないため）

- `run_in_terminal` に長い heredoc / 長行を渡すと **~80 列で折り返され**
  文字列リテラルの中に実改行が混入して SyntaxError になる
  （`od -c` で実測済）。→ `cat > f.py <<'EOF'` で **1 行 76 字以内**に切る
- `bash: 予期しないトークン '('` が出たら折り返し事故を疑う
- 端末セッションは掃除されて再生成されることがある（cwd/mount 状態が飛ぶ）

## 22.17 ライブフォレンジック確立：`gva2gpa` と `-d int`（2026-10-24 深夜）

### 22.17a ページテーブル解読は不要になった（放弃せよ）

ELF notes に DTB は入っていない（実測・total 6 notes の中に来る
qword は 0x100000000 / 0x200000000 だけ）。総当たりも敗北：
`findpt4.py` は 22508 件の table 候補から BFS closure で採点するが、
全員 2500 ページ前後で頭打ちになり ground truth（ram1 =
0x200681000）は 2 位に沈む（優勝は 0x2192c4000）。`findpt5.py`
（窓内マッピング枚数で判別）も候補 28 件の全走査が重すぎて未完。
→ **findpt2/3/4/5 は放棄**。QEMU モニターで足りる:

- `gva2gpa <VA>` … **paused (shutdown) 中でも有効**。停止時点の TTBR
  で変換される（実測 SP=0xffffe20014553450 → gpa 0x20b561450）
- `xp/<N><u>g <PA>` … 物理読み。`gx` でも `xg` でも可
- `xp/<N><u>x <VA>` は必ず "Cannot access memory"（変換しない）
  ⇒ 必ず gva2gpa を経由すること
- `log <items>` / `logfile <f>` … **実行中にログ項目を切り替えられる**
  （`log_start` は存在しない。`apropos` も無い）
- `dump-guest-memory [-w] <file> <begin> <len>` … 範囲指定可
  ⇒ 8.6 GB ダンプはもう不要（dump.py は argv[3:] を転送するよう修正）
- `info registers -a` … 全 vCPU の x0-x30 / SP / PC（停止時点）

### 22.17b `-d int` が決め手

`./win.sh <name> -d int` で足すだけ。2 分で 66 MB、TCG 速度への
実害は小さい。1 例外 7 行で ESR/FAR/ELR/転送先が全部出る:

    Taking exception 4 [Data Abort] on CPU 0
    ...from EL1 to EL1
    ...with ESR 0x25/0x96000004
    ...with FAR 0x10000000000
    ...with SPSR 0x60000044
    ...with ELR 0xfffff80342497c3c
    ...to EL1 PC 0xfffff80345404800 PSTATE 0x13c5

- **新規 boot（run intr、KASLR 違い）でも FAR=0x10000000000 の
  Data Abort**。ESR の DFSC=4 = Level 0 translation fault
  ⇒ §22.15 の run 27 と同一障害であることが独立に確認できた
- ELR から dxgmms2 base = ELR-0x97c3c = **0xfffff80342400000**
  （run 27 は 0xfffff803fa200000。ベース違い・オフセット一致＝再現）
- 命令語もライブ読みで一致：`f9461288`=`ldr x8,[x20,#3104]`、
  `b9400108`=`ldr w8,[x8]`
- この abort は "to EL1 PC ...404800" でハンドルされ、直後に
  ESR 0x96000061 / FAR 0xffffe501b4602014 / ELR ...45426648 などの
  abort が数発（crash 処理中の PTE Access 系）、`Exception return`
  数本でログ終了。PSCI SYSTEM_OFF はログに出ない（検知は `info status`）
- 通常運用でも例外は 85,395 本出る（guard page / pool sanitization
  系：FAR が 0xffffb00d25000000 周辺、ESR 0x96000047 など）。
  末尾から見る：`grep -B2 -A8 "Abort\]" qdbg-<run>.log`

### 22.17c 新規ツールとハブの読み方

- `harness/vmlib.py` … `vmlib.NAME=<run>` してから
  `g2p(va)` / `readp(pa,n)` / `readva(va,n)` / `qva(va)`
  （1 呼出 = モニター 1 接続なので遅い。大量読みは下の region() を使う）
- `harness/vmscan.py <run> <ELR> <SP>` … SP-0x2000 から 0x30000 枚を
  2 MB 連続性仮定で読み、`stack-<run>.bin` に保存して ELR/qword を探索
  **実測：intr のスタック窓に CONTEXT も EXCEPTION_RECORD も無し（0 件）**
  ⇒ §22.15 の CTX/EXR 探索はダンプ側で行う手順。ライブ側は `-d int` を信じる
- `harness/dumpinfo.py` `findpt*.py` … DTB 総当たり（失敗、再挑戦する価値なし）
- `woffix/gpusvc.py` … SYSTEM hive から GPU 系 services と
  Class{4d36e968-…} を列挙（`/tmp/ntfsidx.json` 不要になった）
- 教訓：hivex の python API は
  `node_get_child/node_children/node_name/node_values/value_key/
  value_type/value_value`。`h.children()` / `k.name()` は**存在しない**

### 22.17d 実盤 SYSTEM hive から読めた表示系事実

- Services（Start / Type / Group / ImagePath）
  - `BasicDisplay` 1 / 1 / Video /
    `DriverStore\FileRepository\basicdisplay.inf_arm64_2a3429a3388f8e73`
    （`Parameters\SingleDeviceInstall=1`、`Video` 副キー持つ）
  - `BasicRender` 1 / 1 / Video / `basicrender.inf_arm64_deff86832d28abc4`
  - `VioGpuDod` 3 / 1 / (grp 無) / `viogpudo.inf_arm64_809eebb650b1403f`
    `Enum\...\Video` に `Service=VioGpuDod`、
    `VideoID={8B03FF2A-8084-11EF-B4A3-9000180B5B9F}`、`FeatureScore=0xff`
  - `VirtualRender` 3（`vrd.inf_arm64_…`＝virtio-gpu レンダラ側）、
    `HyperVideo` 3（Video grp）、`DisplayMux` 3、`DisplayEnhancementService` 3
- Class{4d36e968-e325-11ce-bfc1-08002be10318}
  - `0000` = Microsoft Remote Display Adapter（RdpIdd_IndirectDisplay）
  - `0001` = **Red Hat VirtIO GPU DOD controller**、
    MatchingDeviceId=`pci\ven_1af4&dev_1050&subsys_11001af4&rev_01`
    ⇒ 実機では viogpudo が正常インストール完了済み。ハarness の
    `-device virtio-gpu-pci` と PCI ID は完全一致

### 22.17e 負けた実験・旧記述の訂正

- **run A（`win-nogpu.sh`＝virtio-gpu 無し）も `paused (shutdown)`
  で止まる（2 回再現）**。しかも 461 MB / 760 MB のオーバーレイの
  どこにも 'PAGE'+'DUMP' は無く、MEMORY.DMP も無く pagefile 未更新
  ⇒ 「GPU を消せば進む」は検証不能（run A のメモリ解析が必要だった）
- run 27 の RAM でも 'PAGE'+'DUMP' は 0 件。
  **§22.14 の「pagefile に minidump ヘッダが書かれた」は証拠なし。撤回**
- §22.15 の「ELF notes が DTB を持っていた」も**誤り**（§22.17a）
- `bug.py` / `bug2.py`（8.6 GB を BugCheckCode qword で総当たり）は
  O(n²) の seen 再計算 + 38 回の全ファイル find で実用外。やめてよい
- `ramA.elf`（8.59 GB）は削除した（DTB 不明のまま、`-d int` で代替可）。
  `ram1.elf`（DTB=0x200681000 と判明済）は保持。空き 28 GB

### 22.17f 環境の落とし穴（追加）

- `win.sh` は `timeout 900` で包む ⇒ **起動 15 分後に QEMU 殺し**
  （forensics はその前に。pause 検知は butler pattern）
- butler の初期版は「connect 失敗＝停止済」と誤読して即終了した
  ⇒ モニターが応答するまで待つループが要る（butler3 パターン）
- `boot.img` は 1 つしか使えない（2 台目の QEMU が write-lock で落ちる）
  ⇒ 併走したいなら boot.img をコピーして `win.sh` のパスを生やせ
- `/mnt/winc` がマウント済みだと `ntfs-3g-mount: … ビジー` が出るが、
  ls が通れば問題なし（再マウント失敗は無視してよい）
- `ps -c -o …` はこの procps では不可（"can not use output modifiers"）

### 22.17g gpu 仮説の否定と version skew 発見（nog2 / nog4 run）

- **nog2（virtio-gpu なし + -d int）でも同一クラッシュ**：
  `ESR 0x96000004 / FAR 0x10000000000 / SPSR 0x60000044 /`
  `ELR 0xfffff80038087c3c`（+0x97c3c、run 27 と命令一致：
  live bytes `881246f9 080140b9 08190653` = run27 ELR のバイト列と同一）
  → **表示系は無罪**。GPU を外しても dxgmms2 は同じ場所で落ちる。
- 60MB / 59MB の int ログ中で `FAR 0x10000000000` は**両方とも 1 回だけ**
  ＝ Deterministic な単発障害。ノイズ不是。
- ELR 所属モジュールの同定：PE ヘッダページは RAM に不在なので
  `img_fffff803fa200000.bin`（run 27 で dump した dxgmms2 実体）と
  ページ内容比較 → base 0xfffff80037ff0000 で 0x1000/0x40000/0x97c00 一致、
  0x97000 だけ 4 バイト差（`2fea9097` vs `2f6a9197`＝ビルド違い）
  ⇒ **実行中 dxgmms2 は run27 とは別ビルド**。
- **根本原因候補＝ version skew**：woffix で書き戻した 59 ファイルは
  全部 **Winre.wim（=26100.1 相当）** 由来、一方でディスク上の実体
  dxgmms2.sys は **26100.1591**（WinSxS マニフェストが 10.0.26100.1591、
  実行中イメージも run27 と違う）。
  `dxgkrnl.sys`(26100.1) + `dxgmms2.sys`(26100.1591) の**異種ペア**で
  DxgkInterface 呼び出しのStructレイアウトがズレ、
  `ldr x8,[x20,#0xC20]` が `0x10000000000` を読む → deref で Level-0 障害。
  - 実測：Winre 版 dxgkrnl = 4845488 / md5 `ffed016f...` / FileVersion
    `10.0.26100.1`（Volume 上に写入済みのファイルと md5 完全一致）
   install.wim 版 dxgkrnl = 4928416 / `10.0.26100.7920`
  - Volume 上 dxgkrnl.sys（WinSxS マニフェスト）は 1591、
   install.wim は 7920 ＝ どのみちビルドは揃わない系。
  - WOF 元プレースホルダは 52 個すべて `.wofbak` として保存済（34B symlink）
    ＝ 情報は失われていない。
  - `acpi.sys` は元から实体あり（793008B、.wofbak あり）で欠落なし。
    最初 NO-DST と出たのは applyiso.py の ROOT が
    /run/desktop/mnt/host/wslc/（WSL 用コピペ）だったため。
    /mnt/winc/ に直して解決。
### 22.17i fault 地点は dxgmms2 でない（決定的実験）

- 実験: 実体 dxgmms2.sys を消し、ディスク上に 34B プレースホルダ相当の
  シンボリックのみを置いた状態（dxgkrnl は 26100.7920 実体）で起動。
- 結果: **完全に同一の syndrome**
  `ESR 0x96000004 / FAR 0x10000000000 / ELR ...+0xc3c`（同じページ内偏移）
  → 後続の `0x96000007 FAR 0xffff84c261202000`、`BRK #0xf002`、HVC も同一。
- **dxgmms2.sys のファイル内容は実行に何も影響していない** ＝
  fault するモジュールは dxgmms2 ではない（img バイト一致は偶然 or
  同一ソースの別ビルドが別経路で読されている）。

### 22.17j woffix 全量ロールバック（pristine 検証）

- 59 レコード分の実体を全て .wofbak（34B WOF プレースホルダ）へ戻した
  （rollback.py / mv 16、残りは vsk2 実験で既に 34B 化済）。
  dxgkrnl.sys は元から实体（Volume の 26100.1591）なので無変更。
- 目的: run 28/29 が「本当に woffix 以前と同じ失敗인가」を -d int で確定する。
  run A 相当の int 記録는 지금까지一度も取れていなかった。

## 22.17k  pristine run "pre"  =  same crash  +  offset lesson  (2026-10-25)

FULL ROLLBACK of all 16 woffix-materialized files (rename X.wofbak -> X
=> WOF placeholders again) incl dxgmms2 -> placeholder.
Run pre (boot.img unchanged, -d int): dies the SAME way:
ESR 0x96000005 FAR 0x10000000000 ELR 0xfffff80188c87c3c, ONE hit only.
=> the original silent failure (pre-wooffix) = THIS bug. Our file swaps
   never caused it.  GPU / skew / dxgmms2 / woffix all refuted (nog2,
   vsk, vsk2, pre).

OFFSET LESSON: observed faults are PAGE offsets 0x13c4 0x28fc 0x4144
0x4408 0x607c 0xc3c 0xaae4 0xe2dc 0x1b040.  Module bases are 64KB
aligned, so 0xc3c => module offset 0x1c3c or 0x20c3c ... NOT 0x97c3c.
Earlier "dxgmms2+0x97c3c" ident was mis-derived => img page dump was a
red herring.

TOOLING LESSONS (this host):
- QEMU monitor qva2gpa/gva2gpa = GVA only.  "info registers" shows user
  regs: V=0 => translations OFF => PCs there are GUEST-PHYSICAL (bunk).
- win.sh uses `-D qdbg-$NAME.log` (not -D log) => grepping plain log =
  silently empty.  Always use the explicit path qdbg-*.log.
- dd here does NOT support iflag=skip_bytes (fails silently, EMPTY
  stdout!).  Use bs=1 skips, or bs=<aligned divisor> + skip=bytes/bs.
- MFT header: attrs_off at 0x14 (0x16=flags).  Fixup: last 2 bytes of
  each 512B sector (0x1FE/0x3FE) = USA[i], usa at usa_off u16@0x04,
  count u16@0x06.  ntfsinfo (-F path dev) does NOT print runlists.
- MFT run for SYSTEM ($DATA nonres): hd 0x32 -> LCN 3 bytes 0xae0880,
  LEN 2 bytes 0x1701 => run LCN 11406720 x4096 = 0xae0880000, but raw
  dd there = ALL ZEROS => run decode or device offsets still wrong;
  brute-force raw scan for "regf" started (hunt.py, bg).
- ntfs-3g (fuseblk) FIBMAP lies.  ntfsls needs --path= not positional.
- chntpw 140201 (Ubuntu): -e/-x/-I all fail with usage-exit1 here;
  reged same.  Not usable => raw byte patch of hive is the way.

PLAN (in flight): locate REAL hive "regf" copies on /dev/sdb3 raw (the
GUEST DISK = /dev/sdb3 itself: win.sh real drive = ov-*.qcow2 WITH
BACKING /dev/sdb3 => raw writes to sdb3 reach guest via fresh overlays
=> a raw dword patch IS persistent across runs (fresh overlays).
Then: patch SYSTEM hive bytes for CrashControl CrashDumpEnabled=1 and
Session Manager Memory Management PagingFiles "\??\C:\pagefile.sys",
boot once (pagefile now exists), let it crash -> MEMORY.DMP on disk ->
offline dump parse tells bugcheck code + TRUE module+offset (no more
guessing).  Watchdog still ON.  Nothing new executed on win11 VM.

## 22.17l 致命例外の完全解読（ram2.elf / dbg1, 2026-10-25）

- SYSTEM hive base 抽出成功: dd bs=4096 skip=$((0x1701AE)) count=2176
  -> /tmp/SYS_base.bin 8912896B regf 妥当（PagingFiles は base になし；LOG2dirty 残り）
- hunt.py 0ヒット理由: version は +0x14 なのに +0x10 で除外していた。MFT 経由で済
- win2.sh(5400s) で dbg1 を disiplin 実行 -> PAUSED、regs-dbg1.txt 捕捉
- qdbg-dbg1.log=60.99MB（ram2.elf と完全対応の権威ログ）
- ram1.elf の教訓: dump-guest-memory -w は aarch64 不可（Windows dump は x64 限定）。
  素の dump-guest-memory file.elf が ELF。-w 生成物は stale 別ラン分だった

### 致命インストラクション確定（capstone+ram2.elf）
- ELR PA 0x2094eb000 = VA 0xfffff80349ec7000（ELR=...49ec7c3c）
- 直前: ldr x8,[x20,#0xc20] ; FATAL: ldr w8,[x8]（L0 translation fault, read）
- 同一関数内で [x20,#0x9fc]/[x20,#0xa00] の bitfield を byte 配列へ展開するシーケンス
  （x19 宛先は +0x2c..0x31 の flag バイト群）→ 設定ブロック→フラグ変換ループ

### 例外記録の確保（PA スキャン findex.py）
- ELR qword スキャン: ヒット2（PA 0x13e981738 / 0x13e9819a8）、CPU0 スレッドスタック
  近傍。EXCEPTION_RECORD: code=0xC0000005, Address=ELR, params=2, VA=0x10000000000
- KTrp トラップフレームタグ直下。CONTEXT_ARM64 ベース 0x13e9818a0:
  Pc=fffff80349ec7c3c, Sp=ffffc08a750c4a00, X14=0x10000000000,
  X20=fffff8034d43a600, X21=fffff8034ca12db0(=nt+0x12db0),
  X22/23=a365c5a9976c(PAC署名残骸), X24=fffff80344970000,
  X25=fffff80349ec7bcc（同一モジュール内呼び出し側リターン）

### 決定的発見: x20 は nt 静的データ、+0xc20 が ECAM 物理
- gva2gpa: x20=0xfffff8034d43a600 -> PA 0x100c3a600 = nt image 内（VA base は
  0x4ca00000）→ nt の .data グローバル（RVA 0xa3a600）のポインタスロット +0xc20 が
  0x10000000000 を保持 → deref = AV。**0x10000000000 = QEMU virt の high PCIe ECAM**
- ram2 読取時点では +0xc20 は 0 ゼロクリア済み（例外ハンドラ後片付け）
- 推定根幹: QEMU virt-6.0+ は ECAM を 0x1000_00000000（high 2^40）に置く。
  <=virt-5.x は 0x3f0000000 付近の low ECAM。NT 側の ECAM ベース格納が
  「マップ済み VA ではなく物理のまま」で deref している疑い強し

### fault モジュール帰属は未解決（要追試）
- qword DllBase=0xfffff8034803..0x49ec0000 は RAM 全体で 0 ヒット = PsLoadedModuleList
  未登録領域（ヘッダページも未常駐）
- winload.efi と fault page 128B一致 → なし。System32\drivers + ntoskrnl/hal/dxgkrnl/
  Boot\EFI 431ファイル一致 → なし。ntfs-3g は WOF(圧縮) をデコードできないため、
  圧縮ドライバーは raw バイト不一致になる点に注意（wimlib で抽出すべき）
- X24=0x44970000 base のヒット 93 箇所（モジュール台帳候補多数）、未精査

### 実行中の実験
- MACH=virt-5.1 ./win3.sh ecam（ECAM=low 世代マシンの決行テスト）
  win3.sh = win2.sh の machine を MACH 変数化。watch2.sh = pause 監視+regs 捕捉
- クリーン残課題: hunt 進殺し済み要確認 / SYS_hive.bin 削除 / ram1.elf 改名 /
  ESP bootmgfw（md5 26b2..）を bootmgfw-original.efi（2bc7..）へ復旧 / ESP  stray diag40.efi

### 22.17m win32kbase_rs.sys 特定 + fatal 関数完全解読 + ECAM 生 PA deref 仮説 + low-ECAM/virt-5.1 二重実験

**(1) fatal 関数の中身（capstone, PA 0x2094eb000）**: prologue@+0xad0（pacibsp、 callee-saved 全退避、x0→x24、x1→x23、x2→
x22）。+0xb48: `ldr x20,[x24,#0x10]` = **x20 = デバイス記述構造**。`mov
x1,#0x1bb0`→bl alloc@0x4d274000、bl 0x49e6fbb8、new=0x1bb0 バイト構造 x19：
[x19]=タグ w21(+4=[x20,#0xf0]、+8={x24,x20}、+0x18=x23、+0x20={[x20,#0x9e4],7}、
+0x1ab8=x22、+0x28=[x20,#0x760]、+0x2c..0x35=フラグ群：[x20,#0xa00]bit
6→x25、[x20,#0x9fc]b19、[#0xbdf]b12、**[#0xbda]b13**、**[#0xc20]→deref bit6→b1**、
+0x6c0!=0→[#0x1b0]bit0→b2、strb
[#0x6c1]→x19+0x1b94。**致命的：+0xbcc/+0xc5c で同じ `ldr x8,[x20,#0xc20];
ldr/ldrb [x8...]` 再 deref**。リターン経路（+0xcac..0xd28）も同 derefx3。

**(2) fatal 関数 = win32kbase_rs.sys `imagebase+0xc7c3c`（RVA
0xc7c3c、関数開始 RVA 0xc7ad0）**：
- findex 0x49e00000 → 8 hit：boot table（0x101000e78）/ pool 'MmLd'（0x1037d1e00：
{entry 0x49e1f030, base 0x49e00000, size 0x23000}+直後に UTF-16 **`win32kbase_rs.sys`
@0x1037d1f18**）/ pool 'RstG'（0x13ea29c10：{0x49e1f030,0x49e00000
entry/size}）/ PE コピーページ PE\0 machine **0xaa64**（0x21111b100）。
- 検証：pool レコード名 ptr 0x**ffffb083e0bd1f18** の下位 12bit **0xf18** =
name のページ内オフと一致 = rigorous match ✓。'RstG' = win32k **RedStone** ✓✓。
- **X24=0x44970000（93 hit）= 第2 win32k モジュール（X30=0x44970980 = この+0x980 が
caller）= win32kfull.sys 候補**（win32kfull 呼び出し→win32kbase_rs
+0xc7ad0(x0=デバイス,x1,x2)）。
- **CONTEXT_ARM64 レコード全文（exception ハンドラがスタックに保存、PA
0x13e9818c0）**: **X14=0x10000000000**（FAR コピー）/ X17=0xfffff8034d571000 /
X18=-1 / **X19=0** / **X20=fffff8034d43a600=nt+0xa3a600（静的 !）** /
X21=nt+0x12db0 / X22=X23=0xa365c5a9976c（PAC 符号付き LR）/
**X24=fffff80344970000** / X25=0x49ec7bcc（自関数呼出元）/
**Pc=0x49ec7c3c（ELR）/ Sp=ffffc08a750c4a00**。隣接 UTF-16 =
`\Runtime…Graphics\Drv…Drivers\B…` + `\Syst…CurrentControlSet\Control…` 断片。

**(3) デバイス記述構造 = nt .data 静的（x20=nt+0xa3a600）、+0xc20 =
「マップ済みポインタ」スロット**：fault 時に **0x10000000000**（= QEMU virt
ECAM base、virt-5.0〜9.x）**を生で保持** → deref 即 faults。**ハンドラ後も 0
（= マップ失敗→clear されるか、初回 faults 直後に zero 化）。GPU 無しラン nog2 も同一
ESR/FAR/ELR 下3桁 `c3c`（別 ASLR base 0x38080000）= **virtio-gpu 非依存の bug**。**
- 競合候補：PCIe ECAM（virt
≥5.0で高配置）/高MMIOウィンドウ。Windows 側 MmMapIoSpace 失敗経路または
ACPI(resource) が生 PA を VA スロットに誤格納。
- **実験マトリクス（作成中）**: ecam ラン = `-machine virt-5.1`（ECAM
0x4010000000）→ faults 位置が同じ RVA かつ FAR=0x4010000000 なら「生 PA
格納」確定。low ラン = `-machine virt +
highmem-ecam=off,highmem-mmio=off`（ECAM 0x3f000000、MMIO 0x10000000-0x3efeffff =
≤4.1 の全低配置）→ 回避できたら勝利条件。**両ラン並行実行中（01:43/01:53 開始、
watch2.sh 監視）**。

**(4) win32k 実体確保（WOF 突破）**: System32\win32k*.sys は全て reparse tag
0x80000017 = **WOF 圧縮（ntfs-3g は展開できない）**。`wimtools` 導入 →
`wimlib-imagex extract /mnt/iso/sources/install.wim 1 '@/tmp/WS.txt'
--dest-dir=/tmp/WS.out`（WS.txt=フルパス1行/1ファイル）で **win32kbase_rs.sys(116KB,
SizeOfImage 0x23000, machine
0xaa64)／win32kfull.sys(3.8MB)／win32k.sys** を取り出し ✓。**だが ISO 版の RVA
0xc7000 ページ ≠ guest 実行ページ = WU でディスク版が更新されている =
ISO シンボルは参考情報扱い**。→ 関数名は unwind(.pdata)・呼び出し形状から意味推定が必須。

**(5) ハーネス更新**：win2.sh→**win3.sh**（`-machine ${MACH:-virt},gic-version=3${LOW
P:+,highmem-ecam=off,highmem-mmio=off}`、**boot
イメージを `boot-${NAME}.img` に分離** = 2 ラン並行時の flock 衝突解決（boot.img
は ecam が保持中）**。watch2.sh = 100min/paused-detect で regs-&lt;NAME&gt;.txt +
state 保存。教訓：qga 無し並行は boot.img ロックに注意。f.ecam が FSOpen'Boot'
で静的でも TCG では正常（debug print なし領域）。**
- TODO（次）：①ecam/low 結果判定（FAR と ELR
under+0xc7c3c）、②low 勝利時は恒久設定化＋起動先確認、③ecam
のみ成功時は virt-5.1 系で進め、④低レイヤ解決（[x20+0xc20] 生成者 = nt
内の書込み側特定：nt 静的 offset 0xa3a820 への code ref =
ram2.elf/staging 内 scan）、⑤ESP 掃除（bootmgfw 復元 +
diag*.efi 削除、要ユーザー合意）、⑥ram1.winDump_old 削除。

## 22.17n low最終=SYSTEM_RESET要求 / live-kernelが元ファイルと別物 (2026-10-25)

### A. low実行の停止原因（確定）
- CPU1: PC=fffff80030c028fc = hvc #0（PSCIラップ末尾）,
  X0=0x84000009=PSCI_0_2_FN_SYSTEM_RESET
  (/usr/include/linux/psci.h: BASE=0x84000000,
  SYSTEM_OFF=FN(8)=..08, SYSTEM_RESET=FN(9)=..09)
- QEMU: SYSTEM_RESET→-no-rebootでshutdown化→
  -no-shutdownで paused(shutdown)。例外ハングではない
- CPU1 SP=ffffbc052eca8450 →PA 0x13cf2a450。
  リターン連鎖 nt+0x252fd4/0x2530f4/0x252f10/
  0x5d078/0x2e2404 → カーネル実行後のリセット要求
  ＝バグチェック→自動再起動経路が最有力
- CPU0: PC=fffff80030ad32bc。命令は capstone で adrp
  （過去の手デコードは誤り）。語ストリーム=
  ret/pad/pacibsp/stp群/adrp+ldr ゲート関数の途中
  = リセット進行中の素のスナップショット、異常なし
- 訂正: regs-low-cpu*-b.txt は別PC（同一説は誤読）
- qdbg-low.log=0B だが非決定（guest_errorsは部分のみ）
### B. live RAM と /mnt/qntf の ntoskrnl.exe が一致しない
- 元ファイル: .text VA=200000 raw=ff600
  TDS=0x84268839 SizeOfImage=124a000 e_lfanew=110
- CPU0 PC前後32語: fileは .text+0xd32a0 期望だが全16語不一致
- live PC含む16語 → file内検索で raw 0x2285d0 hit
  = .text 内 RVA 0x328fd0（1ヒット）。だが
  PA 0x1004d3290（イメージ先頭 0x100200000 基準）
  の RVA 0x2d3290 と 0x55d40 ズレ → 配置が不同
- live PA 0x100200000 ≈ file .text+0 だが 4/16 語差
  (102645f9↔10ce44f9 等) = 再配置/別ビルド型差分
- ram-low.elf 全RAMスキャン: .text先頭64B=0hit,
  MZ+TDS=0hit → 元ファイルの PE ヘッダはRAMに不在
### C. ディスク構造の_fact
- ov-low.qcow2 = QCOW3 backing=/dev/sdb (64424509440B)
- /mnt/qntf = sdb3 = pristine base（WU前のクローン）
- boot-low.img = FAT ESPのみ(BOOTAA64.EFI+startup.nsh)
  →起動カーネルは always qcow2 overlay 側経由
  （＝過去VM内書き込みが読める。「WU後ISO≠disk」の
  一段深い版）。/mnt/qntf 直接参照は base しか映らない
### D. ecam(virt-5.1)ラン状況
- 起動48分経過で依然 running / CPU1 PC=0
- CPU0 PC=fffff8014de52f20 ≠ lowのカーネルbase
  → 少なくともカーネル空間には入っている
- qdbg-ecam.log=0B（win32kbase_rs系DataAbort未発）
### E. 次の一手
- 全ページ整列 MZ+PE\0\0+AA64 ヘッダスキャンで
  live nt の実イメージ base/ビルドIDを確定
- bugcheck原因コード探索 / PSCI wrapper module特定
  (VA fffff80030c00000→PA 0x100600000)
### 22.17o: low live-RAM kaisoku2 - SYSTEM_RESET no zen chain to kernel build mismatches no kakunin

ram-low.elf (vmcores済) + address soksei (RVA = PA - 0x100000000, live nt ImageBase=fffff80030600000,
VA->PA wa VA-0xfffff80030600000+0x100000000) de dokai enkui.

(A) live nt header kakutei - ISO to wa beta build
- PA 0x100000000 ni hontou no MZ+PE top (kyu 22.17n no header-fuzai setsu wa tekkyo).
  e_lfanew=0x130, TimeDateStamp=0x1149c62d, ImageBase=fffff80030600000, SizeOfImage=0x1249000.
- /mnt/qntf no pristine ntoskrnl.exe wa TDS=0x84268839 / SizeOfImage=0x124a000. TDS/size sunawachi beta BI
  -> boot reta nt wa disk no pristine file dewa nai (18.8 no kata chi kousui to gochi).
- /tmp/mz9.out (354 hits) demo kernel-VA kan with header is PA 0x100000000 to 0x101600000 (ib=fffff80031c00000
  size 0x6000) mi. win32kbase_rs.sys me wa UTF16 de PA 0x10242909a / 0x1027fd95a / 0x1070877b8 ni mieru ga
  header ga page fugou de scan gai.

(B) CPU1 teishi=i i 0x84000009 SYSTEM_RESET hatsya no kanzen chain (hvc stack 0x13cf2a450 ikou)
  rva2e2404 : BlpBugCheckEx w0=0x3b SYSTEM_SERVICE_EXCEPTION, w1=[nt+0x60d618]. just below 0x3b and args.
  rva25d078 : call gen (0x5d0 frame, prologue rva25c400, head: walk of PEP power gate callsite array rva60f0e0)
  rva452f10 : power state dispatch no bl kaeri; inside calls bl rva4c4930(4,0) and KeBugCheckEx(0,0,0,0,0) etc
  rva452fa4/452fd4 : power phase fn. X=[nt+0xe032c0], dword[X+0x60]=0x50b with bit8 fire;
      calls [X+0x40]=nt+0x468000 with w0=0x84000009, return path calls [X+0x48]=nt+0x467fd0(x0=0x8004,w1=FID,x2=0)
  rva468000 : go directly to PSCI invoke branch (b #0x1006028f8 style). FID constant literal nt+0x453028 = 0x84000009
  rva6028f8 : HVC wrapper sub sp/str x7/hvc 0/ldr x7,1f/ret. CPU1 PC=6028fc wa hvc jikkou ATO = RESET okurei fidai.
- KPCR+0x38 wa genzai system power state. rva205970 / rva205d24 that keep/restore state 0..2 = PoSetSystemPowerState.
- KTrp record (KTRAP=fffff8003060485c synchronous exception dispatcher, KFRAME=fffff80030805d24) at 0x13cf29864
  = on CPU1 kernel stack. same stack: sync exception -> bugcheck -> reset. confirmed.
- SHA-512 IV constants at 0x13cf2a960.. = parallel hash verify on same stack (shutdown-time checksum?).
- rva2058f0 fail path: log call (0,10,0,nt+0x60fc18,0x343) via rva45aaa0 = power code log (string ntos!).

(C) CPU0 teishi=i
- PC rva4d32bc post-call <- rva2761cc (callback calling rva27a910) <- rva27aae4: rva27a910 passes [x19+0xfb8]
  to rva4d8718, then rva4d8250 then rva4d3298. code right-after rechecks [x24]&0xf, clear-lock bit 0x20000 at [x19+0x9460],
  then calls fnptr [x21+0x1a8] via rvaaba040. = periodic check inside worker. stack x0=obj fffff800262b0980, nt data fffff80031254ab8.
- 0xf028198e on CPU0 stack = trap-code kashiko. CPU0ハ reset machi no timer check de teishi shita dake to gaidaku. (kanji nashi)

(D) imi
- low saishuu tai = PEP gate wo tonda exception shori (0x3b kien) -> bugcheck roudou -> PEP yuru PSCI SYSTEM_RESET.
- boot nt ga ISO to beta build de aru koto ga header level de shoumei. goji no jikken wa overlay naka no nt/driver
  jittai wo qemu-nbd de tokutei suru hitsuyou (22.17n item C).
- ecam run 48fun sadou-chu (CPU0 PC=fffff8014de52f20 = nt gai, CPU1 PC=0, qdbg 0B). timeout kire ati f.ecam kakunin.
- [addendum 22.17o] OVERLAY verified via qemu-nbd (ro copy: /tmp/ovlow.copy.qcow2 -> nbd0, nbd0p3 -> /mnt/ovnt ro):
  overlay Windows/System32/ntoskrnl.exe = TDS=0x1149c62d SizeOfImage=0x1249000 -> EXACT match with LIVE kernel header.
  pristine /dev/sdb3 copy = TDS=0x84268839 / 0x124a000 (different build). => booted kernel IS the overlay copy; the
  "pristine volume" premise was VIOLATED for every qcow2-overlay run so far (orig3/orig2/low/ecam ...).
- overlay root also contains: Windows.old, V5A.TXT/V5B.TXT (win-visible FS markers), rdchk.efi, pagefile.sys, swapfile.sys.
- WinSxS store (overlay) already holds 26100.1742 packages: os-kernel_10.0.26100.1742, win32kbase_1742; win32kbasers stays
  1301 and its r/ copy is byte-identical between overlay and pristine (md5 9fb90a7bf2f0e85da0c4c0495080336b, WINXSX compressed).
- reparse-tag 0x80000017 placeholder files (System32 hardlinks) are unreadable through fuseblk ro even with sudo; System32/
  ntoskrnl.exe itself IS readable and IS the WOF-decompressed live build. wofbak/store copies unreadable from this mount.
- implication: to test a truly pristine kernel, must boot from an image whose System32 is the ISO copy (no overlay writes),
  or restore the update-removed state. Update-era (26100.1742) nt in overlay matches LIVE TDS -> the crash build is UPDATED kernel.
- [addendum 22.17o/2] ecam run endgame: VM still "running" but f.ecam FROZEN at 01:43:39 (60+ min, 1740 lines). Last serial:
  SetMemoryAttributes/ClearMemoryAttributes @0x40BD6000 then FSOpen EFI/Microsoft/Boot Success (winload path). NO bugcheck/PSCI.
  Mon regs: CPU0 SP=fffff80147999840 X30=fffff8014dc5d0c8 (nt base here fffff8014dc00000 -> rva5d0c8 inside nt), CPU1 PC=0.
  => ecam(virt-5.1)= HANG inside kernel (no reset), low(virt+nohighmem)= runs to BOOTMGR/BSOD->0x3b->PSCI SYSTEM_RESET.
  The ecam/low divergence is REAL behavior difference, consistent with ECAM aliasing hypothesis. timeout will kill it soon.
- [session close-out] low=run-to-reset forensics DONE (22.17n/o). ecam=hang confirmed (frozen serial, CPU1 PC=0, guest 100% spin).
  All qemu procs killed (dumps kept: ram-low.elf=low endstate, ram2.elf=dbg1). watch2/watch3 watchers killed. mounts: /tmp/bl unmounted,
  /mnt/ovnt+nbd0 detached. Disk 6.9G free (keep dumps; do NOT delete root-owned files without user). DISK caveat: overlay=dirty
  (updated-in-guest) volume -> next milestone: build PRISTINE-from-ISO boot path (no in-guest updates) to retest 0xc7c3c fault on
  a known build, and/or keep both: (a) ECAM fix probe on virt-5.1 hang (watchdog via WPP symbols), (b) 26100.1742 vs ISO-build diff.

## 22.17p: ★ELFオフセット則の確立と「前セッション forensics」の大規模訂正 (2026-10-25)

ram-low.elf の正確な対応関係を確定。以降、dump内주소 = **fileoff = PA − 0x40000000 + 0x8b0**
（逆向き PA = fileoff + 0x40000000 − 0x8b0）。検証: ①先頭GCD風エントリ群(file 0x8b0〜)が
0x47ff3f18〜の表領域を指す ②file 0xC00008B0 に nt MZ+TDS(0x1149c62d)+SizeOfImage(0x1249000)
→ PA base = **0x100000000 確定**（overlay現行ビルド起動を再確認）③file@0=ELF magic。

### 訂正を要する過去結論（「identity fileoff==PA」前提のものが全滅）
- bugcheck記録@file 0x13cf2a518, KTRAP@0x13e9818c0, x20=nt+0xa3a600 の静的读出し,
  win32kbase_rs+0xc7c3c の「関数disasm」等は**すべて別領域を誤読していた可能性大**。
  実際に今日の再読出で: 0x13cf2a4f0群=ゼロ、KTRAP周辺に0x10000000000ヒットなし。
- 「ELR=win32kbase_rs+0xc7c3c」も要再検証: overlay/現行ntでは RVA 0xc7c3c は **.pdata
  （例外テーブル内）** でありコードではない（.text=0x200000-0x646600）。
  したがって ELR のモジュール/セクション帰属そのものがやり直し。
  ただし win32kbase_rs.sys(WSXS現物) SizeOfImage=0x23000 なので wbr帰属もやはり不可。
  → ELR生値の再抽出は実行時ログ(-d int)で取得する方針に切替（下記 intr2 ラン）。

### 0x10000000000 (=2^40, PA40の末尾) の実態（正マッピングで再走査）
- ファイル全域: nt像内に **1175箇所**（.data 475 / .rdata 100 / GFIDS他多数 / .text 4は誤検隣接）。
  近傍に fffff800xxxxxxxx カーネルVA群 → **カーネルが通常に多用する定数**
  （最有力: PARange=40bit に由来する「参照可能PA空間の上限」＝HV/PaP/メモリマネの境界センチネル）。
- EFI memmap/GCD 領(file 0x8b0〜, 0x18歩調)にも多数。PA4-8GB に ~110万（配列性、未解析）。
- ⇒ **「生PAがそのまま漏れた」仮説は修正**: 値は正規の『PA空間上限(=size境界)』であり、
  境界値をポインタとして deref するクラスのスレッドセーフ/境界バグの可能性。
  境界値をポインタとして deref するクラスのスレッドセーフ/境界バグの可能性。
  提供元特定は DSDT/テーブル側には存在せず（MCFG=0x3f000000, FACP/テーブル内に 2^40 なし）。
  提供元特定は DSDT/テーブル側には存在せず（MCFG=0x3f000000, FACP/テーブル内に 2^40 なし）。


### DSDT再確認（runtime コピー@file 0x7ff18c8 = PA 0x47FF1018, len 0x14e5, BOCHS）
### DSDT再確認（runtime コピー@file 0x7ff18c8 = PA 0x47FF1018, len 0x14e5, BOCHS）
- iasl -d 済み 56KB。内容: ACPI0007×2 / ARMH0011 / QEMU0002(fwcfg) / LNRO0005(virtio-mmio)×多数
- iasl -d 済み 56KB。内容: ACPI0007×2 / ARMH0011 / QEMU0002(fwcfg) / LNRO0005(virtio-mmio)×多数
  + **Memory32Fixed の羅列（予約領域バケズレ）**。→ 詳細走査は保留（PCI root/PNP0A08不在:
  + **Memory32Fixed の羅列（予約領域バケズレ）**。→ 詳細走査は保留（PCI root/PNP0A08不在:
  PCIは MCFG/IORT 側 = Windows 側ペルファの別経路。DSDT内に 2^40・1TB窓なし）。
  PCIは MCFG/IORT 側 = Windows 側ペルファの別経路。DSDT内に 2^40・1TB窓なし）。


### 新方針: post-hoc forensic 停止 → ライブ例外ログで ground truth 再取得
### 新方針: post-hoc forensic 停止 → ライブ例外ログで ground truth 再取得
- win3i.sh = win3.sh + `-d int`（exception log を qdbg-intr2.log へ）。
- win3i.sh = win3.sh + `-d int`（exception log を qdbg-intr2.log へ）。
- intr2 ラン起動（low構成, overlay）。すでに DataAbort×90+ 記録開始（EL1ハンドラ経由）。
- intr2 ラン起動（low構成, overlay）。すでに DataAbort×90+ 記録開始（EL1ハンドラ経由）。
  フォール時の ELR/FAR/ESR を QEMU レコードから直接読むのが決定的。
  フォール時の ELR/FAR/ESR を QEMU レコードから直接読むのが決定的。
- ※教訓: 8GB dump の post-hoc 検索は phdr 誤読1箇所ですべてのオフセット証拠が汚染する。
- ※教訓: 8GB dump の post-hoc 検索は phdr 誤読1箇所ですべてのオフセット証拠が汚染する。
  dump 解析は必ず①phdr デコード②既知アセット(nt MZ等)でのマッピング自己検証を先に行う。
  dump 解析は必ず①phdr デコード②既知アセット(nt MZ等)でのマッピング自己検証を先に行う。

## 22.17q — ダンパ開封完遂 + nt再ベース修正 + 凍結ループ正体 = WFIアイドル (§22.17p続き)

### 22.17q.1 d2.vmcore マッピング法則（確立）
- ELF64 phdr 単一 PT_LOAD: off=0x8b0, va=pa=0x40000000, sz=0x200000000
- **fileoff = PA − 0x40000000 + 0x8b0**（スキャン出力は最終 seek 値・再加算不要）
- 検証: /tmp/sighex.txt（nt.bin先頭168B）scan → **PA 0x100000000 にユニークヒット**
  ⇒ ロード済み nt = /tmp/nt.bin とヘッダ一致（本人証明）

### 22.17q.2 【重要修正】nt VA base = 0xfffff8014d800000
- 従来の 0xfffff801_48000000 は**誤り**（ DOS stub 断片を別ページで誤読した幻覚）
- 決定的証拠: 活きVA 0xfffff801_4e606000 = ダンプ PA 0x100e06008 と同一内容
  → base = 0x100000000 + (0x4e606000−0xe06000) − 0x4d800000+0 … 要は
  **PA = 0x100000000 + (VA − 0xfffff8014d800000)**（線形）
- PEセクション表と完全整合: .text VA=0x200000..0x646600,
  ALMOSTRO=0xe06000（x10テーブル@0x14e606000 ✓）, SizeOfImage=0x1249000 ✓
- 結果: ELR RVA 0x626648 ∈ .text ✓ / 凍結PC RVA 0x451AFC ∈ .text ✓
  両方とも nt 本体コードと確定

### 22.17q.3 凍結PCの正体 = WFIアイドル（gdb逆アセンブル）
- PC=0xfffff8014dc51afc: `bl <sleep>; dsb sy; isb; wfi; ldp x29,x30,[sp],#16; ret`
  = **WFIの次命令でフック**（TCG: WFI traps/assist → EL1ハンドラ経由で無限再生）
- 呼び出し側 RVA: 0x4e91cc (bl 0x451ae0) → 0x4e91d0: `mov w0,#0; ret`
  = ハルカミの idle 経路. 両CPU同一PC = 全CPUアイドル
- ⇒ ゲストは「起動継続の意欲なし・全CPU眠り」状態. ブート処理は停止済み

### 22.17q.4 フレーム.walk = ブートローダ列挙スタック（決定的）
- x29=0xfffff80149d98b00, 連鎖: RTN=0x14dce91d0 → 0x14dce98b8 → …
- 0x14dce91c0 側は LoaderBlock リスト走査+初期化コード（[x22+5120]等）
- f1=0x14dce98b8 直下 0x14dce92bc–0x14dce92f4: LoaderBlock エントリの
  [x22+33] ([+5736]) フラグ見て [x19+712..718] コピー — **LdrEnumerateLoaderModules**
- x10系テーブル(.data ALMOSTRO)=[flag+VA対]×2 + 0x8000000000010001…
  (nt自己相関 flag 家系 0x...010001)

### 22.17q.5 フォールトページ = Loader Block entry と判明
- FAULT VA 0xffffd100_e6602014 → PA 0x40346000（livelock stlr x14,[x8] の先）
- 隣接トポロジ（活き monitor xp）: PA−0x2000/−0x1000 = **unmapped**、
  +0x3000 = mapped かつ **全 qword 0xff...**（poison fill）、fault page は live
- ページ先頭: q=0x0fa00000_00000000（**pool/LOB header "0fa0"**）、
  +0x20=0x0e234000（93984=0x16F40 ≒ LoaderBlock Size系）、
  +0x24/+0x28=0x43（EntryCount?）、+0x30="X:\windows" UTF-16 ✓
- ダンプ時 q@8=0x000000016fcf775f に対し**ライブでは 0x000000035ffb97da**
  ⇒ 「凍結」表示でもページは**変異継続**（+0x10=0xcc9d9dc3_00000003,
  +0x18=0x01dd642f_01dd642f, +0x2c=0xaa64aa64 guard）
- stlr 先の x8=page+0x14 は**アライメント不正**（0x21 021 = PC-align 系）
  = EL0t SPSR のユーザーモード文脈で Staging 書き込み → 0x21/0x25 inject
- 教訓: フォールト VA を指す qword をダンプ全体 scan すると
  **2サイトのみ**: PA 0x428a29b8（プールアレイ 0x428a2000 内 stride≈0xF0）と
  PA 0x100e06008（nt .data ALMOSTRO）. 両者とも fault page と相互リンク
  ⇒ fault page は **ローダ/プール系オブジェクトの所有者直下** と強推定
- 0x428a2000 アレイは nt base 未満 VA 定数混在（0xfffff801_44d00980 ×20,
  0xfffff801_49db2c50..ddc0）= **別モジュール領域**（0x144d00000/0x149db2d00家系）
  — hal? ローダル？ 未同定（残課題）

### 22.17q.6 凍結レジスタ一式（gdbstub 読取、p/x 式）
- PC=0xfffff8014dc51afc x8=0xfffff7e00055ecf0 x9=0
  x10=0xfffff7e00055ecf0 x11=0 x12=0
  SP=0xfffff80149d98b00 X29=0xfffff80149d98b00（同一値=WFI復帰直後フレーム）
- ※gdb: printf 複数reg は "Wrong number of arguments" → p/x 1行1reg 方式
- monitor socket は先客1名のみ → `socat -t8 - UNIX-CONNECT:... </dev/null`
  で退避してから oneshot.py（§22.17p 手順踏襲）
- 生 PA 0x100000000 はダンプ後**ページ再利用**（Rich ヘッダ風 dword）で
  ダンプ≠ライブ。nt.bin 同一性証明はダンプ側 scan のみ有効

### 22.17q.7 総合解釈（作業結論）
- 全CPUは loader-block 列挙後に WFI アイドル。フォールトは**EL0 起源の
  0x21/0x25 群**（SPSR=EL0t）が VBAR+0x22648 ループで再生され続ける構図
- 「BOOTMGR が X:\windows\system32\winload.efi を開けず、LIVE の
  LoaderBlock entry を EL0 が触りに行って整列フォールト → アイドル退避」仮説
- winload 不在/パス不一致が根本候補（X:\windows 文字列は entry 内に実在）

### 22.17q.8 残課題（次ラン）
- PENDING-DISK-FIX: win11-arm-oci/win11.qcow2 の ESP に \EFI\Boot\bootaa64.efi
  （＝winload の ESP コピー/または BOOTMGR.efi エントリ）欠落をマウントで確認
- aarch64 objdump（llvm-objdump --triple=aarch64）で 0xfffff8014da5bb70 /
  0xfffff8014dce7730 呼び先同定（MiRosLoadImage? ZwLoadDriver?）
- -cpu max,pauth=off + -s スタブ付き次ランで autibsp フック仮説の切り分け

## 22.17r — screendump 開眼 + 「Display output is not active.」発見（2026-10-25）

### 22.17r.1 screendump でFB取得可能と判明
- `oneshot.py mon-instr2.sock "screendump /tmp/scr.ppm"` → 1280x800 取得成功
  （-display none でも virtio-gpu scanout は読める。PIL で PNG化→解析）
- 画面内容: **ほぼ全面黒 + 中央1行のみの灰(170,170,170)テキスト**
  bbox x520-748 y386-398（水平/垂直とも中央寄せ）
- tesseract OCR = **"Display output is not active."**（グリフ25個+4空白=29字、
  末尾g24="."一致・字間8px一致で OCR を人手検証）

### 22.17r.2 例外ログは今も増殖中 = 無期限livelock確定
- qdbg-instr2.log 212MB+, 45秒窓で例外1541件: SVC(EL0)約半分 +
  **ESR 0x25 系 625件/窓** (0x96000061×421, 0x96000047×153, 0x96000007×46)
- EL0 PC 分布は 0x7ffc47c5 系の複数スタブ混合で窓間で不変 = **周期サイクル**
  （正常負荷ではなくループ。SVC storm を伴う全体周期ループに格上げ）
- シリアル末尾が EDK2 "FSOpen EFI/Microsoft/Boot Success" で凍结 =
  **BOOTMGR以降 UART 無出力なだけ**（winload 以降の正常状態でも固まりと区別不能）

### 22.17r.3 instr2 起動経路の再確認
- boot-instr2.img FAT: @echo off → dmpstore → load \EFI\NTFS\ntfs_aa64.efi
  (fs0-2) → map -r → **fs1:\EFI\Microsoft\Boot\bootmgfw.efi.orig 直接実行**
- = EDK2 Shell 経由で BOOTMGR(.orig) を起動する構成（shell が ConOut/GOP を
  占有した状態で Windows へ引き継がれる）
### 22.17r.4 仮説: GOP/ConOut が死んだ状態で継続実行中
- "Display output is not active." は bootmgfw/winload 内文字列に**存在せず**
  （ブートバイナリ scan 0hit）→ EDK2 ConSplitter/GOP ドライバ側の出力と推定
- 対案: 次回ランは (a) startup.nsh を bootapp 直起動へ（shell かませる）,
  (b) virtio-gpu 外し=vga=none + GOP 欠落環境で同じข้อความが出るかの対照,
  (c) bootmgfw.orig 直接でなく bootaa64.efi 経路 A/B 試験

### 22.17r.5 【結着】「Display output is not active.」の正体 = QEMU 本体
- 全探索0hit: ESP全ファイル/nt.bin/winload/Windows\Boot実体(FUSE再マウント後)/
  Recovery/edk2ソース/QEMU_EFI.fdバイナリ/**d2.vmcore 8GiB全体(utf8+utf16)**
- → /usr/bin/qemu-system-aarch64 単独に文字列存在（唯一の供給源）
- = QEMU ui/console.c が **-display none 時のデフォルトvcサーフェス**に描く
  中央寄せ灰(170)プレースホルダ。**screendump はゲストFBでなくQEMUコンソール面
  を返していた**（1280x800黒+1行=これ。字間8pxピッチ/語長7-6-2-3-6+dot全一致で
  誤読なしと人手確認ずみ）
- 教訓: -display none 環境の screendump は virtio-gpu 内容を保証しない。
  ゲスト画面を見るランは **-vnc :N（headless可）を必ず付ける**
- 残る本質: ゲスト画面はまだ未観測。例外 storm の「livelock か通常負荷か」も
  未決着（SVC=正常syscallを -d int が全部書いている可能性が高い）

### 22.17s 次ラン w4 起動（04:39）
- instr2 手動停止（212MBログ/状態asset済、self-kill待ちムダ回避）
- win3i.sh: -display none を ${DISPOPT:-既定} にパラメータ化
- 実行: DISPOPT="-vnc 127.0.0.1:5" ./win3i.sh w4
  → boot-w4.img(=instr2コピー)、ov-w4.qcow2 新規、serial=f.w4、mon-w4.sock、
  timeout 5400（自爆 ≈06:09）
- 狙い: VNCクライアント接続状态下の screendump で **本物のゲストFB** を観測
  （instr2まで画面観測だと思い込んでいたものは全部QEMUプレースホルダ）
- t+60s: FSOpen EFI/Microsoft/Boot Success（BOOTMGR手前、正常進行）

### 22.17t 【大転換】例外stormは正常動作、ブートはほぼ成功していた
- w4(04:39起動)で gdbstub(hmp `gdbserver tcp:127.0.0.1:1235`)接続成功:
  * CPU0 PC=0xfffff8016f651afc = **nt!+0x451AFC = instr2と同一WFI idle RVA**
    (w4 nt base=0xfffff8016f200000, SP=base+0x49d98b00instr2と同一RVA)
  * stormの本体=`ldr x8,[x19,#8]; add x8,#0x14; stlr x13,[x8]` での
    alignment Data Abort(ESR 0x25/0x96000061, FAR …2014)、
    ハンドラは**ELR+4で復帰**= **Windows ARM64の非整列STLRカーネルエミュレーション
     (正常仕様)**。※対象は0fa0プールヘッダ+"X:\windows"(UTF-16)ページ(instr2と同一)
- → instr2 の「livelock/クラッシュループ」疑いは否定。**CPUは実質アイドル**
- d2.vmcore( instr2 45分時点)物理検索: csrss.exe×19 / wininit.exe×8 /
  services.exe×11 / winlogon.exe×11 / svchost.exe×18 / lsass.exe×8 / dwm.exe×5
  → **サービスフェーズ到達、ほぼブート成功**。見えないだけ(-net none・
    画面はQEMUプレースホルダでゲストFB未観測・serialはbootdebug無で沈黙)
- w4観察メモ: qdbg -d int が6分で166MB(stormログ=正常だが膨大)。
  次は -d int を落としてログ削減する価値あり
- VNC接続が数回目でスタックした(初回greeting成功→以降timeout)。原因未究明
  (listen backlog=1 + QEMUがacceptしない/Zombie)。次ランでは起動直後に繋ぐ

### 22.17u w5 起動（05:0x）— 可視化ラン
- boot-w5.img(=instr2複製), 新規オーバレイ, DISPOPT=-vnc 127.0.0.1:6
- ネット: user-net host=10.0.2.2, dhcpstart=10.0.2.20(Windowsは既定DHCP),
  virtio-net-pci, hostfwd tcp 3390→guest3389 / 5986→5985(WinRM) / 4451→445
- 検証計画: ブート30分後あたりから
  1) nmap/tcpdump for hostfwd: 5986/3390 越しに WinRM/RDP ハンドシェイク
     (`curl -X POST http://127.0.0.1:5986/wsman` or `winrm-cli`)
  2) 成功→WinRMから systeminfo / bcdedit bootdebug on 等
  3) ダメ→BCDのdebug要素をstartup.nsh(Shell cpによるESP上書き、実盤不変・
     オーバレイ載せ)で注入する次ラン
  4) 起動直後にVNC接続試行(+15分ごとにscreendump併用)

### 22.17v VNCスタックの真相と screendump=FB観測の鍵
- QEMU10.2 TCG+slirp環境では -vnc のRFB greetingが**コンソール再描画イベント
  時にのみ flush**される（通常は永久に保留→ handshake timeoutに見える）。
  接続中に monitor へ screendump を打つと greeting が即届く(tryflush.py実証)
  が、FramebufferUpdateまでは届かない/不安定 → VNCは観測手段として不採用
- **`screendump` コマンドは「アクティブコンソール面」を返す**。
  virtio-gpu-pci 構成だと QEMU vc プレースホルダ(黒bg+Gray170中央1行
  "Display output is not active.")が見えるだけでゲストFBではない
- → ゲストFBを見る手段として **bochs-display device** 案:
  bochs-display は own cons = primary、guest の graphical console が
  直接スキャンアウトされ screendump=正 truly FB になる (QEMU標準パターン)
  1280x800等 guest driver が解像度決めるのでプレースホルダとサイズで見分け可
- w5(winit起動済・qdbg 208MB@6.5min -d int重)は観測仕様ミスで残し。
  次 run w6: -device bochs-display(または virtio-gpu 併用可: primary優先)で
  毎5分 screendump 保存ループ + net user hostfwd(5986 WinRM/3390 RDP/4451)
  + vncはovertcp併用でも可
- apt導入ずみ: python3-winrm 0.5.0, chntpw(reged), hivexregedit

### 22.17w: **画面の真実とw6失敗/w7成功/w8(e1000)起動。win3jの正しい使い方** (05:2x)
- **w6 (bochs-display)= 失敗**: screendump は "Guest has not initialized the display (yet)." のまま。EDK2 Build ツリーに BochsDxe なし（VirtioGpuDxe/QemuRamfbDxe/DisplayEngine のみ）→ アームfirmwareがbochsを初期化不能 → OS側BasicDisplayはfirmware GOP必須。bochs案は設計段階で不可と判明。
- **w7 (virtio-gpu-pci + EDK2 VirtioGpuDxe)= GOP画面観測成功!!** t+20s screendump = 1280x800、非黒43060px、**UEFI Shell UIがそのままOCR可**: 「Shell v2.2」「ESP 05754202」「Image fs0:\EFI\NTFS\ntfs_aa64.efi Success / fs1 error StartImage(Load Error=2台目のESPコピーで無害)」「HARNESS-RTC-OK/DRIVER-LOADED」「ESC 4s」。=> **harnessチェーン全工程が画面上で可視化**。
- **t+1min で画面=684px placeholder ("Display output is not active.") に戻り以後6分間ハッシュ一致でフリーズ**。= WindowsがEOBS後に**virtio scanoutへ一度も描_writeしない**。d2のOS側文字列"OCI kernel init: Failed to initialize frame buffer"と整合：**GOPミラーBasicDisplayがエミュ環境で機能せず、実GPU用viogpudoもvirtio-gpu(1AF4:1050)には紐付かず=デスクトップの描画先が存在しない**。screen凍結は**フリーズではなく"描画先ゼロ"**と解釈。
- **d2 vmcore**: PCI列挙記録(PCI\VEN_*文字列)はプールに存在せず(0ヒット)。"Debug Port" u16文字列も0ヒット（BCD表示名テーブルは非常駐）。PCIフォレンジックは打ち止め。
- **w8 起動 05:22**: win3i系レシピ + **e1000 NIC**（Windows ARM64のinbox網罗可能性に賭け）+ hostfwd 5990->5985, 3394->3389。自己kill≈06:52。**w7 net版(04:56, hostfwd 5988/3392/4453)も生存中**。
- **win3j.sh 使い方訂正（はまった）**: 第1引数positional=NAME。env NAME=w8だと$1が"-device"で汚染（boot--device.img化）→ `./win3j.sh w8 -device ...` が正しい。
- qemu-img create は語順 `... -u -b /dev/sdb -F raw <file> 60G`（file→size）が必要。sudo付きでも root オーナー化で chmod 666 不可（FUSE系）。QEMUは sudo 実行なので素で書ける。

### 22.17x: **オフラインSAM/SYSTEM外科手術（ov-w9）— mpsvc無効化+RDP許可+Administrator有効化blank pwd** (05:1x)
- **chntpw は Win11ARM64 SAM をパース不能**（-l が help しか出さない）→ **python hivex 読み + hivexregedit --merge 書き** で全実施。regen 教訓: SYSTEM hive rootに
  \SYSTEMプレフィックスなし（[\ControlSet001\...] が正しい）。SAM 側は [\SAM\...] が効いた。**F+0x38=0x215→0x214 (ACB_DISABLED クリア)**, V の NTLM@V+0xA8 / LM@V+0xB4 の len=0（blank pwd）。検証済。
- SYSTEM: LimitBlankPasswordUse=0, fDenyTSConnections=0, TermService Start=2, **WinRM Start=4→2 (元々DISABLED!! = w5/w7 WinRM死の直接原因)**, mpsvc Start=4 (FW自体オフ)。
- 経路: qemu-nbd -c /dev/nbd0 ov-w9 (sudo必須, /dev/sdbは$USERには読めない) → kpartx (PATH陷阱: sudo secure_path で ./kpartx不可、のちに素のqemu-nbd -dで代替) → ntfs-3g roマウント→hive抽出→編集→**ntfsfix -d（$LogFile空=overlay層のみ、実盤無傷）**→rw再マウント→SAM/SYSTEM書換+config/*.LOG1/2削除+pagefile/swapfile削除→umount→qemu-nbd -d。**hiberfil.sys 不存在（実盤はclean shutdown済み）**。
- **w9 05:15:53 起動: ov-w9(編集盤)+virtio-net(5992→5985,3396→3389)+e1000(5993→5985,3397→3389)二重NIC**。**probe予定05:41**（boot+25分）。w5/w8はfw生存のためsilent=想定内。w8(e1000)は起動健全=bootmgr到達済。

### 22.17y: **w9 профиール=ユーザーランド生存確認 / 初回probe silent（05:35）**
- qdbg-w9 例外プロファイル (05:23→05:35): tail-3000 で SVC 162 / IRQ 138 / DataAbort(alignment) 112、
  ELR census = **0x7ffb8bed_xxxx / 0x7ffb887e_xxxx（ntdll=ntdll.dllユーザーランド範囲）** と 0xfffff802_37xxxxxx（ntkrnl）。
  ⇒ **services.exe/svchost 相当のユーザープロセスが能動稼働** = 過去最深のブート到達。bugcheckループ痕跡なし。
- qdbg内の "e1000"(1282件)/100e(47件) は**すべてFARアドレス部分文字列の誤検出**（`grep -i unassigned`=0）。NIC BARへのMMIO痕跡は -d ログ対象外で観測不能。
- **初回probe 05:35 (boot+20分): 4ポート全部TCP accept後タイムアウト**（slirpローカルlistenでguest無応答）。RDP CRQ→recv timeout、WinRM(ntlm,Administrator/blank)→read timeout。
  - wrmp.py 認証修正済: Protocol(ep, transport="ntlm", username="Administrator", password="")。
- **probeループ常時化**: /tmp/probe_loop.sh (pid生存確認済) が5分x13回 rdp.py 3396/3397 + wrmp 5992/5993 を /tmp/probe-w9.log へ記録。w9自死(06:45)まで自動。
- hostのRDPクライアント: xfreerdp3/rdesktop **未インストール**（libfreerdp3-3 3.32.1 のみ）。バナー確認取れたら apt freerdp3-utils 導入予定。
- bash陷阱メモ: printf のダブルクォート内 "!/bin/sh" は history expansion で即死（event not found）。shebang無しで sh file 実行に退避。

### 22.17z: **DriverStore網罗フォレンジック: netkvm.inf ARM64同梱判明 / e1000不在確定** (05:4x)
- 実盤 /mnt/qntf DriverStore/FileRepository に **netkvm.inf_arm64_9c8ee6330e4d1136**（DriverVer 2024-07-15, 100.95.104.26200）= PCI\VEN_1AF4&DEV_1000 / DEV_1041 バインド。netkvm.sys 190KB + netkvmp.exe 同梱。
  ⇒ QEMU virtio-net-pci 既定ID=1AF4:1041 なので **w9のn0はドライバ一致が見込まれる**。e1000系統（e1g/8254x）はFileRepository皆無 = e1000のw8は設計段階で不可、probe無視可。
  他同梱virtio: balloon.inf / viogpudo.inf（GPU: 1AF4:1050はw7でscanout書込ゼロ=実働せず）/ vioser.inf（virtio-console）。netvsc.sys（azure synth）もdrivers/に存在。
- info usernet(n0,n1)@05:36 = HOST_FORWARD 4本のみ、guest発信パケットゼロ。DHCP未到達は時間問題かnetkvmp/NdisInitのTCG低速。probe loopは06:45まで自動継続。
### 22.17aa 外科消失postmortem + w10再外科（検証手順を確立）
- 05:14のw9外科は**書き込み先が別物**だった: /mnt/nntfsは死んだnbd0接続経由でbase由来の別ビューに接続、さらに /tmp/SAM.w9 は後続コマンドで**未編集版に再cp**（copyfileはmtime非保存なので見抜けなかった）。ov-w9/qcow2生走査・snap再マウントで**全-overlayに外科バイト不在**を確定。base /dev/sdb3は無傷(SAM==原)。
- 実盤SYSTEMは**01:01の半途編集状態**が常態（fDeny=0済/WinRM Start=4/mpsvc-start欠/LSA欠/FWPolicyノード無し）。= 過去セッションのmerge失敗がそのままベース。
- dp2.py（SYSTEM編集、python-hivex direct）: dictは{"key","t","value-bytes"}、Hivex(path,write=1)、commitは h.commit(path)。mpsvc/FWPolicyノードはdisk版に存在せず→editスキップ（FW未起動=ブロック要因でなし）。結果: WinRM=2 TermSvc=2 LimitBlank=0 fDeny=0 ✓
- **検証付き外科 sx.sh**（bash -ex）: qemu-nbd -c → ntfs-3g rw mount（fail時ntfsfix -d→再mount）→ cp SAM.new/SYSTEM.new → **同マウント内 cmp 両方** → pagefile/swapfile/*.LOG1/2 削除 → sync → umount → qemu-nbd -d → **ro再接続でcmp二重検証**。all green、ov-w10.qcow2 diff 11.3MB、SAM/SYSTEM mtime= chirurg時刻、pf/sw absent 確認。
- 教訓1: copy後の整合確認は cmp必須、mtimeは当てにしない（cp系は copy2 を使う）。
- 教訓2: /tmpの中間成果物は同じ名前で再cpされる経路があると silent に元に戻る — 以後 再展開→編集→適用 を1スクリプト化（sx.sh）。
- 教訓3: bash スクリプトは shebang ではなく明示 `bash -ex` で実行（shebang -e は実行時に無視された実例あり）。マウントは remount ではなく mkdir -p + 素の mount + fail時ntfsfix。
- 教訓4: qemu-nbd -c 失敗時は前runの接続残りがロック保持。pkill -f "qemu-nbd -c /dev/nbd0" で解放。
- w9は22:00前にself-kill待ちせず手動停止。w10: virtio-net のみ（netkvm同梱済み確認済 §z）、hostfwd 5994→5985/3398→3389。
### 22.17ab w10=検証済み外科 disks で起動、85分の観察ログ
- w10 (05:55起動, virtio-net のみ, 5994/3398 forward) — qdbg は SVC/IRQ/UA の三角形（ESR 0x15/0x25 syscall-trap ペア、exception2=SVC 入口 2757本/60k行=**syscall処理継続=活着**）。bugcheck 0。ELR top は kernel(0xfffff803_87xxxxxx)+user(0x7ffae67d_xxxx 一組)が同一集合のまま=ループの可能性と、単純にTCG低速の別区間内の可能性が未分離。
- **/sys/block/sdb stat 60秒間ゼロ増**（189911rd固定）=ゲストこの間ディスクI/Oゼロ。overlay も 11534336B で 05:55 から静止。**user-mode が CPU を回すが disk-write 皆無** = w4〜w9 と同一パターン（=パチ与否に関わらず、この壁はネットワークより前）。
- screen: screendump=1280x800 全面黒+中央684pxのみ灰色文字→OCR="Display output is not active." (**EDK2コンソールの残骸**、Win側描画ゼロ)。viogpudo 同梱はあるがロード到達か不明。
- **ブートチェーン確定**: boot-*.img 内 startup.nsh が ntfs_aa64.efi ロード→fs1:**\\EFI\\Microsoft\\Boot\\bootmgfw.efi.orig**（=実disk sdb1 ESP）起動→BCD も sdb1 ESP 上（/tmp/espp マウント可視、複数bakあり）。boot.img 側にBCDなし。**KD可視化案**は BCD の dbgtransport が device-pathバイナリ形式（UART ACPI경路 blob 手作りが必須）で難易度高→一旦保留、まず経過観察。
- 教訓: screendumpの黒画面は「OSが描いていない」だけで「OSが死んでいる」とは限らない。進捗判定は (a)overlay成長 (b)/sys/block/sdb stat 増分 (c)`info usernet` のDHCP行、の3点 heartbeat（io10.sh 実装済、5分毎）。
### 22.17ac timeout 5400 が真犯人だった
- **w10 は 07:32 死亡**（job終了124 = win3j.sh の `timeout 5400` が90分でQEMUを殺した）。w9 の「応答なし90分」も w4〜w9 全滅も、観察窓が全員90分にクギを刺されていた＝**ゆっくり起動していた可能性は一度も試しきれていなかった**。
- win3k.sh 作成（timeout 72000=20h）。w10 再起動 07:33（overlay は外科済のまま）。hb10.sh(10分heartbeat) + probe10b.sh(4分毎WinRM/RDP) 常設。
- メモリフォレンジック計画: tmpfs 残り3.6G/ram23G。hang 確認後に `pmemsave 0 0xC0000000 /tmp/ram.bin`（3G）→ volatility3(ISF要ダウンロード、host net OK) で pslist/svcscan 期待スピン箇所を特定。
- 実装: v3env=$HOME/v3env/bin/vol（volatility3 2.28.2, py3.14）。ramcap10.sh: 09:03 に ov 静止のままなら pmemsave 3G→$HOME/ram_w10.bin（/home残り5.4G、1個だけ）。ISF は初回に microsoft store から自動取得予定。

## §22.17ae 08:0x exception-profile 変化 = ユーザーモード進行の兆し（ただし disk 読み 1sectors/30min のまま）
- qdbg 直近40MB: ESR 0x15(83k)+0x25(34k)+**0x24(30k: data abort same-EL)**+**0x20(6k: instruction abort)**。0x24/0x92000047=読み取り・VALID低orderbits=通常のページフォールト/dispatch 系（ガード破損系ではない）。
- 直近6MB 内で **ELR 1993 distinct** = 単アドレス・スピンループではない。上位は kernel 0xfffff803de026648(15k) と user 0x7ffb0b55_xxxx 密集クラスタ（1モジュール内複数オフセット=実行進行形）。
- 0x20 (コードページ取り込み) が現れた = 新規バイナリ起動フェーズの兆候。**disk(sdb) read だけ 30分で+1** が説明不能（キャッシュ済みイメージからの page-in なら理論上可能: 8GB RAM に earlier フェーズで読んだ物が残存假説）。
- 判定は予定通り 09:03 の RAM ダンプ（ramcap10.sh 稼働, pid 221215）+ volatility3（$HOME/v3env/bin/vol）で確定させる。
- 監視系 bugfix 記録: python heredoc 内で bash 変数を `$$` に二重エスケープするとそのまま文件中に残り sh 構文エラー（exit 2 連発の真因）。python 生成では `$` を1個で書くこと。watch10b.sh（120x10min: WINRM/RAMDUMP/GUEST-NET(UDP|ESTABLISHED)/overlay 成長）稼働開始 08:1x pid 226038。

## 22.17af "FWは効いていない"の大誤訂正 + SAM真構造 + netkvmは生存 (w11 世代)

- **誤診爆発**: 前回まで「SharedAccess/FirewallPolicy ノード不存在 ⇒ FW エンジン
  不動 ⇒ inbound 開いている前提で他を疑え」と書いたが **dp2.py のパス 타이ポ
  (`Services/mpsvc` に s 欠落) が生んだ幽霊**だった。実ツリーは全世代で存在し
  Domain/Standard/Public **EnableFirewall=1 (FW 全面ON)** が確定 (/tmp/SYSTEM.new
  実測)。w9/w10 の WinRM/RDP 無応答 (RST でなく完全無応答 = SYN drop 挙動) と
  完全に整合。FW 疑惑は消え、むしろ本命に昇格。
- **SAM の正しい読み方** (Domains\Account の F/V は 400B の hint 専用だった):
  ユーザは `\SAM\Domains\Account\Users\<RID16進大写>` の F(0x50B)/V(blob)。
  V record: +0x38 UAC / +0x9C LM relative offset / **+0xA0 LM len** /
  +0xA8 NT offset / **+0xAC NT len**。RID500 素性: lm_off=412 lm_len=24
  nt_off=436 nt_len=56 (＝ハッシュ格納オフセット、旧 §17x の "V+0xA8=長さ"
  解釈は **オフセットを長さとして zero していた破壊編集**)。admin F+0x38=0x210
  = **既に enabled** (guest 1F5=0x215 と対照)。blank 化 = len 2つを 0 +
  offset 位置の 20B ゼロクリア (/tmp/edit3.py 実装・VRFY 済)。
- **netkvm は無罪**: Services\netkvm 完備 (Start=3, Group=NDIS, NDIS 6.89) かつ
  **Enum\PCI に VEN_1AF4&DEV_1041(=現QEMU NIC)/1048/1050 のインスタンスが
  2024 build 時から登録済**。setupapi.offline.log に X:\drivers\netkvm.inf
  import 履歴。→ ドライバ不在假説は死亡。ただしバインド成功はオフラインで
  見切れず、guest 発信ゼロ packet の説明には RAM 解析が必須。
- **gdbstub 直接診断 recipe (確立)**: hmp `gdbserver tcp:127.0.0.1:1240` →
  `gdb-multiarch -batch -ex "target remote ..." -ex "info threads" -ex
  "x/3i $pc" -ex "info registers pc sp x0 x8 x19 x29 x30" -ex "thread 2" ...
  -ex detach`。**w10 +1h45m: CPU0/CPU1 とalso nt+0x451AFC (WFI 復帰命令) で
  d2 と同 RVA** = 20h cap も要らない程に boot 進行停止済み (遅い起動ではない)。
  w10 nt base = 0xfffff803dda00000。
- **w11 世代 = 訂正込み完全 Surgery** (/tmp/edit4.py + /tmp/pipe4.sh 用意):
  SAM blank-passwd (正オフセット) / WinRM=2 / **mpssvc=2 (disable 版 edit3 は
  anti-pattern と判明し撤回: ms guide は "service 有効 + profile EnableFirewall=0"
  を規定。mpssvc 停止は非公式)** / TermService=2 / LimitBlankPasswordUse=0 /
  fDenyTS=0 / FirewallPolicy 3profile EnableFirewall=0 (SYSTEM 側・ノード create
  込み) + **SOFTWARE\Policies\Microsoft\WindowsFirewall\{Domain,Standard,
  Public}Profile EnableFirewall=0** (GPO 側、両方塞ぎ)。
- 運用教訓: (1) nbd0 の sysfs pid が stale 化して -d で消えず → **nbd1 へ**
  (2) sudo 経由 win3k.sh は $HOME=\root 化して FW 解決失敗 → **`sudo env
  HOME=$HOME bash -c`** (3) pkill が効かない残骸は pid 直 kill -9。
- 現在: w11 起動 (修正前 edit だが FW off + SAM blank 正しいオフセット、
  v1 と同等以上)、hb11/probe11b 稼働。★次の分岐: WinRM 応答あれば決着、
  無応答なら **w11 RAM ダンプ (`dump-guest-memory /tmp/w11.elf 0x40000000
  0x200000000`, raw ELF)** → vol3 pslist/netstat/svcscan で service/NIC 実態を
  決着させる (d2.vmcore 削除で tmpfs 空ける)。

### af.1 vol3 は arm64 Windows に使えなかった（本件で死亡確認）
- QEMU dump ELF(e_ehsize=8) を 0x40 に直しても vol3 2.28.2 は "layer_name
  unsatisfied"。**WindowsIntelStacker/KDBG 系しか無く Windows ARM64 検出 path
  不存在**。v3env は py3.14 で動すがプラグイン(yara 他)欠落多数で実用外。
  → RAM フォレンジックは §q の自前の生検索/手フォレンジック路線のみ。

### af.2 hunt.py 検証通る + w11 は静止確認（09:31 gdb: 両CPU nt+0x451AFC idle）
- hunt.py (ELF PT_LOAD→ANSI名scan) for d2: csrss=50 wininit=7 services=2 lsass=10
  svchost=17 winlogon=6 dwm=2（§22.17t と同系統、件数差は検索名末尾\x00固定の差）。
  → 手フォレンジック土台は生存。EPROCESS ring は §ring1 (総当り)0件 = 26100
  オフセット別物、anchor 全RAMスキャンは実行中(3cf1..)で未決着。
- w11 (edit3: mpssvc off+3profile off) 09:26-09:31 qdbg 201MB でほぼplateau、
  gdb 両CPU idle = **WFI停止到達**。probe は最初から ReadTimeout のみ。
  FW off でも応答なし → 「FWが唯一の元凶」仮説は w11 では証偽寄り(ただし
  停止に至るまでの listener 確立有無は未確認)。
- ★決定的テスト w12 起動 09:34 (pipe4/edit4: mpssvc=2 auto + SYSTEM FirewallPolicy
  3profile=0 + SOFTWARE GPO Policies\Microsoft\WindowsFirewall 3profile=0 +
  SAM blank 正オフセット + LimitBlank=0 + fDenyTS=0)。probe12b 稼働、watch12  armed。
- 運用メモ: pkill は sudo 付き親コマンド全体に効かず残った (**pid直kill必須**);
  残QEMUが hostfwd ポートを掴み w12起動が "Could not set up host forwarding" した。

## 22.17ag: w12 offline page-table reconstruction (10-25)

- w12 kill -> /tmp/w12.elf offline route. ELF CORE PT_LOAD off 0x8b0 va=pa=0x40000000 sz 0x200000000; fileoff(PA)=PA-0x40000000+0x8b0. ELF notes lack TTBR/prstatus.

### idx consistency: 16K granule, 3-level, shifts 36/25/14 (11-bit idx) - self-consistent:
- nt VA fffff80162200000 -> PA 100000000 32MB block: idx2=(VA>>25)&0x7FF=0xB1 matches slot off 0x588 in L2 page 102888000 (q=0x100000001). CAREFUL: compute (VA>>25) on full VA (bit32 adds +0x80; partial 0x62200000>>25=0x31 was my bug).
- stack VA fffff801574e0980: idx1=780 idx2=AB idx3=538. pool VA ffffdc0f106cc538: idx1=DC0 idx2=788 idx3=1B3.
- 4 process twin L2 pages holding nt block slots: 102888000 1028ac000 1028d8000 102940000.

### key mis-ID killed: 0x456xxxxx/0x4562xxxx region are PFN arrays, not HW tables
- traits: no zero entries at all (2048 filled), q = PFN<<12 | 0x70f, stride +0x1000 per slot (4KB!). A HW 16K leaf table would step 0x4000. So these are Mi physical-page list structures.
- pt4/pt5 parent hits (45608440 -> 102888000 etc) are references inside those PFN arrays. HW parents NOT found by mask 0xffff or strict 0xFFF scans over full RAM.
- theory now: HW PTE entries carry high attr bits (Windows PTE high bits, e.g. 6000000040000687: bits57/58 sw-guard etc) breaking masked equality -> par2.py rescanning ignoring bits48+.
- root-table scan (entries[0x780]&0xFFF==3 & entries[0xDC0]&0xFFF==3 & idx<0x700 zero) = 0 hits. flags form or alignment differ.

### VA-PA anchored pairs (unique 48B needle search)
- stack: VA fffff801574e0980 <-> PA 40ba0980 UNIQUE (KTHREAD-like seq).
- nt image: all 12 random windows hit ONLY at PA 100000000+RVA (2 stray windows = other-module lookalikes).
- pool: needle hits {103e96538, 11e8cc538} - arbitration pending vs gap-aware HMP qwords.

### VM side
- old w12 killed; relaunched 13:2x with -gdb tcp::1337 (pids 288118/119/121).
- QEMU aarch64 gdbstub target.xml does NOT expose sysregs (ttbr*) - that route closed. Plan: after kernel reached, HMP gva2gpa walk output gives granule/level/table-base ground truth.
- boot at EDK2 SetMemoryAttributes stage as of 13:2x; hours ahead under TCG.
- tmpfs /tmp has 3.5G free; must xz-or-delete w12.elf (8.3G) before new dump.

### pending
1. par2 parent scan results -> trace to root -> TTBR1 candidate.
2. pool candidate arbitration.
3. w12 kernel boot -> gva2gpa 3 points -> offline walker exact-match -> LIST hunt.
4. disk space for new dump.

## 22.17ah: 16K granule 假説は誤り、4K granule 4level が正 (10-25)

- par4 (leaf scan: q&~0xFFF==0x100000000 & bit1) = 38803 hits, parent scan (47:16 exact) = 64 hits and ALL of them inside the 0x4560xxxx runs. So the 4 "twins" (102888000/1028ac000/1028d8000/102940000) have ZERO referrers in the whole 8GB RAM: they are orphans, never a live path.
- decisive re-read of the 0x4562_7d00 run: entries were
  45627d00: 40ba070f, 45627d08: 40ba170f, 45627d10: 40ba270f ...
  I read that as "flags growing by 0x1000 per slot => software array". WRONG: those are
  ADDRESS bits 12+ — i.e. plain 4KB-stride page descriptors 0x40ba0000+k*1000 | 0x70f.
- flags 0x70f decoded for 4K granule: V=1 AF=1 SH=0b11(inner) nG=0 AP=0b00(EL1) PXN=1 XN=1
  AttrIndx=3 => perfectly valid HW page descriptor. For 16K granule bits[3:2] are RES0 so 0x70f
  would be illegal - that single fact is what made me call these arrays "PFN lists, not tables".
  Under 4K granule they are exactly the L3 leaf tables (512 entries x 4KB = 2MB per table page)
  of a linear mapping of physical memory. Region 0x4560_0000-0x4563_xxxx = page-table pages.
- model now: T0SZ/T1SZ=16, 4K granule, 4 levels, idx = (VA>>39),(VA>>30),(VA>>21),(VA>>12).
  nt VA fffff80162200000 -> idx 1F0 / 005 / 111 / 000 (block at slot off 0x888 = 2MB block desc
  value 0x100000001 for PA 100000000). stack VA fffff801574e0980 -> 1F0 / 005 / 0AB / 0E0
  (L3 slot off 0x700, in-page 0x980 = PA 40ba0980 anchor, consistent).
  (old 16K reading "nt idx2=0xB1 matches slot 0x588" was coincidence; 0x588 matches no 4K idx.)
- par5 (parents of 15 slot-0x588 candidate frames + 40ba0000 + 4562_4/6/0000 frames): the 0x588
  frames are pool/heap data (q0 = ...6869 6e62 = "hbin"), not tables. 40ba0000 appears only in
  0x4562_7d00 leaf run + one data word -> the true L3 for that stack page is elsewhere.
- par6 (running): ONE full pass building a reverse index of every qword that can be a valid
  descriptor (byte classes: odd low byte, byte4<=0x23, bytes5-7 zero -> target in RAM range) into
  /tmp/idx.out as "D <target4K> from <referrerPA> fl <flags>". Then parent-chasing from any anchor
  frame is instant; frames with no referrer = root-table candidates = TTBR1 root. (par5 lesson:
  mask bits16-47 only is ambiguous because addr starts at bit 12 - always mask ~0xFFF.)
- VM: w12 3rd boot alive, CPU 7.2% (was 1%), TIME 5:08/1h10m, f.w12 progressed to
  "FSOpen: Open Microsoft/Boot Success" (bootmgr reading \EFI), qdbg 214MB @14:31. Still TCG-slow.

## 22.17ai 3rd boot(w12) はカーネル到達・全員待ち型で live-lock

### reverse index 全走査 (par6.py / /tmp/idx.out)
- 4K ページ単位で「ある PA を指す記述子」を全 RAM から拾う逆引き。
  1,228,780 候補 / 73,651 targets / 53 秒。regex 是在修正后 OK.
- 落とし穴（すべて実測で修正）:
  1. `r[...]` に printable な奇数バイトを生で入れると Class 終端が早い
     → パターン文字列自体を \xNN テキストで組む (rb'' + chr(92))
  2. `B+'x00'*0` の単項演算子優先で不要なバックスラッシュ混入
  3. mmap は f.fileno() が要る／非0オフオフ不可 → ファイル全体 READ マップ
     + finditer(m, a, a+CH) で窓指定（CH=256MB）
  4. マスク 0xFFF00000F001 は bit12 を壊す → 0x0000FFFFFFF000
  5. 結果ファイルは root 作成 → 後段は必ず sudo -n

- 致命的バグ（par6b で発覚・未修正）: `tp=(q>>12)<<12` はフラグビット
  (bit>=48) を保持したままになり、RAM 範囲判定で落ちる。逆引きの target は
  必ず `q & 0x0000FFFFFFF000` のような純マスクで求む。
  結果 par6b(缓和版) 1,023,740 件 < par6(严格) 1,228,780 件 という
  矛盾した数字になり、APTable/PXNTable 検証の目的は未达。）

- par7/par8/par9 による照合:
  - 0x40ba0000 的 referrer: 45627000+0xd00 (fl 70f) だけ / 40a00000: 3件だけ
  - 45627000 の親は 45626000 内 14 スロット (fl fff)、45626000 の親は 0
  - だが VA 0xfffff801574e0980 の要求 slot は (VA>>12)&0xFF=0xE0 (=off 700)
    実 off=d00=index 0x1a0 → **4K 素通しでは不整合**。idx2 も 0xBA（0xAB ではない）
  - 濃度ヒューリスティック (>=250/4K) は sparse な L1/L2 を潰すので無意味

### 3rd boot の実態（serial + monitor + gdb）
- シリアルは 13:49 に 0x180 で止まる（41分間不動）。その後も user-mode SVC
  相当のトラップが ntdll 範囲 0x7fffc059xxxx で継続 → ユーザ thread は生きている
- `info registers`: 両 CPU とも $pc = nt+0x51afc = `bti-c; wfi; b 0`（idle loop）。
  カーネル VA 実行中＝**(kernel) ラベル付き**で KASLR 後ベースが読める。
  このインスタンスの kernel base = 0xfffff8035a600000（$pc - 0x51afc）。
  dump 版 (22.17) の idle と同一命令オフセット → ブートはほぼ同じ位置で待ち受けている
- disk I/O: READ 449 件/543MB・WRITE 4 件で停止 → 全員待ち型（スピンではない）

### ⇒ 大発見: gdbstub はライブ VM の任意カーネル VA を読める
`target extended-remote localhost:1234` + `set architecture` 後、
  `x/3gx 0xffffac815fe02014` が**通る**（=翻訳成功）。通らない VA はコマンドが
  ハングするので timeout 必須。つまり TCG page-table walk 経由でライブ参照でき、
  ページ表再構成（22.16-x の大掛かり解析）はライブ機では不要。
- 注: 例外ログに `Read from ... failed to complete` が出るのは guest 側の正常エラー
  （QEMU は無関係）。

### ハング中の例外統計（qdbg-w12.log, 163,705 件）
- DataAbort @ nt+0x226648（87,316 件・半数超）: 宛 FAR 0xffffac815fe02014 で固定、
  ESR 0x96000047（Write/Permission fault L3）。x17=0x4c9, x5=1。
- ただしライブ読蜜すると 0x1c のカウンタが実際に増えている＝**書き込みは成功**しており、
  ARM64 の AF(Access Flag) 更新系の正常 churn と判定（元凶ではない）。
- 0x…02000 の中身: UTF-16 で "X:\\windows" + 0xaa64aa64 プールの guard + 0x2028
  → ランタイムのパス／プール格納。22.17w の「0x14 に 0x13e8 を書けない」という
  解釈は**ライブ機では成立しない**。

### その他
- virtio-gpu のコンソールは virtio ブランド画面のまま**フリーズ**（HMP screendump で確認、
  /tmp/ppm は root 作成なので sudo -n で mv）。
- 保存: work/harness/f.w12.hang3, qdbg-w12.hang3.log。VM 強制停止後、回線を足して再起動:
  `sh ./win3k.sh w12 -device virtio-net-pci,netdev=n0 -netdev user,id=n0,hostfwd=tcp::15985-:5985,hostfwd=tcp::13389-:3389 -gdb tcp::1337`
  → host :15985 = guest WinRM(5985)、:13389 = RDP。次は WinRM 越しに見える世界を取りに行く。

---

## 22.17ai 4th boot（virtio-net 付き）の滞在中データを固定

起動: `sh ./win3k.sh w12 -device virtio-net-pci,netdev=n0 -netdev
user,id=n0,hostfwd=tcp::15985-:5985,hostfwd=tcp::13389-:3389 -gdb tcp::1337`
→ pid 306122, gdb :1337, host :15985/:13389 は LISTEN（=QEMU の hostfwd だけで、
guest 側の応答は無し。`/dev/tcp` 接続は TCP 確立するが WinRM 応答ゼロ）。

- `f.w12`（serial）は **14:54:58 で停止**（111,510 B）。中身は全面 **EDK2
  firmware の出力だけ**。末尾は
  `FSOpen: Open 'EFI'/'Microsoft'/'Boot' Success` ＝ bootmgfw.efi へのハンドオフ点。
  Windows 側の文字は 1 つも出ない（bootmgfw/winload は UEFI console に書かない）。
  → 「シリアルが止まった」は Windows の進行度情報ではない。これまでの読みは過信できない。
- `qdbg-w12.log` 214 MB / 15:43 時点で 8 秒に +9.8 KB ≒ **4 例外/秒**（IRQ 主体、
  ときおり SVC / DataAbort). `-d int` のログ書き込みだけが実際の活動。
- `/proc/306122/io`: `read_bytes` は 10 秒間で **増分 0**、`write_bytes` だけ増える
  （＝ログファイルへの書き込み）。guest はディスク read を issue していない。
- host CPU は idle（VM の utime+stime 増分は 8 秒で 2 tick だけ）。

## 22.17aj ライブ kernel のシンボル解決（PDB 無し）で分かったこと

- msdl の `ntoskrnl.pdb` / `ntkrnlmp.pdb`（GUID 00D46CC0-E2A1-3E48-6AC6-C224799CFC23,
  age 1）は **両方 404**。public PDB は存在しない → on-disk PE の
  `.pdata`/`.edata` でやるしかない → ツール `/tmp/nt2.py`
  （secs 34 / exports 3164 / .pdata funcs 15052、`python3 /tmp/nt2.py <rva>...`）。
- 24H2 arm64 ntoskrnl.exe の実際のレイアウト: `.text` RVA 0x200000..0x66a794、
  `.edata` 0xdd000、exception `.pdata` = DataDirectory[3] = (0x9b000, 0x3acc8)。
  IMAGE_EXPORT_DIRECTORY は +20=NumberOfFunctions(0xcd5)、+24=NumberOfNames(0xcb0)、
  +28/32/36 = AddressOfFunctions/Names/**NameOrdinals(WORD!)**。
  （+28 に numberOfXxx を読む説は誤り。名前の文字列は 0xe4f9c="ntoskrnl.exe" で整合）
- **決定的な否定結果**: ライブ RAM 上のコードは on-disk ntoskrnl.exe と
  **バイト一致しない**。gdb から取り出した 3 関数分（320B/864B/2304B）を
  8-gram 投票で画像に当てると、page-align しない implied base
  （…fe20 / …f738 / …e480）に分散し、48B 一致は 0 件。
  理由はこのマシン固有ではない：Windows ARM64 の .text はロード時に
  KPS / PTR・BTI サロゲート（`bti c` 前置変換）で**命令列が延びる**。
  → ディスク画像の RVA 系とライブの VA 系は**別物**。gdbstub だけでは関数名を
  確定できない（＝Kd（windbg 互換 KD）か PDB が要る）。
- 一方で**ライブの VA 系は内部で完全整合**している：
  `$pc=0xfffff800cee51afc`、`$sp=$x29=0xfffff800caf38b00`、
  frame 連鎖 = `[sp]→fp 0x…8b10 ret 0xfffff800ceee91d0` →
  `fp 0x…8c50 ret 0xfffff800ceee98b8` → `ret 0xfffff800ceedc6e0`
  （＝qdbg に現れる ELR と同値）→ `ret 0xfffff800ceee7a24`。
  実際に `stepi` 3 手で 0xfffff800ceee91d0 へ戻ったので連鎖は本物。
- $pc のある関数（live disasm、304B 級）は PAC 序文 +
  `tlbi vmalle1is; dsb sy; isb`（**全TLB broadcast invalidation**）+
  `bl`（RtlZeroMemory 相当、配列を 8B/page でクリア）を持つ TLB/ページ情報
  系の内部関数。ELR 側（0xfffff800ceedc500..）は epilogue の直後に
  `mov w0,#2; brk #0` を連ねるコードで、直前の `bl 0xfffff800ceee78c0` が
  frame 0 の番地群と同じ-block。

## 22.17ak 「ハング」の正体：停止ではなく超低速進行（4th boot 実測）

- $pc を 16 回サンプリング → **全部 0xfffff800cee51afc**。
  `$sp` / スタックトップ 2 qword も 8 回サンプリングで完全に不変。
- しかし `stepi` は進む：`51afc(ldp) → 51b00(autibsp) → 51b04(ret) →
  0xfffff800ceee91d0`。**取り得る分岐は ret 一本**（直後が padding,
  次の関数入口は 0xfffff800cee51b10 の pacibsp）なので、抜けても同じ所へ
  戻ってくる＝**極めて短い循環に閉じ込められている**（＝live-lock）。
- 例外レート ~4/秒に対して host は idle。gdb 側の attach/detach だけで
  数秒かかるのと、TCG + 全TLB broadcast の組み合わせで
  「1命令あたりの現実時間」が異常に大きいのが効いている可能性。
- 教訓：`-serial file:` 運用では Windows 側の進捗が一切見えない。
  進行判定には (a) disk read の増分、(b) 例外ログの種別推移、
  (c) virtio-gpu の screensump 比較を使う。

## 22.17al virtio-win リポジトリは「要らない」（確認済）

`github.com/virtio-win/kvm-guest-drivers-windows` は netkvm / viostor /
vioscsi / viogpudo / balloon / viorng の上流だが、**guest には arm64 版が
既にインストール済み**（`/mnt/qntf2/Windows/System32/DriverStore/FileRepository`）:
`balloon.inf_arm64, netkvm.inf_arm64, viogpudo.inf_arm64, viorng.inf_arm64,
vioscsi.inf_arm64, viostor.inf_arm64`
→ ドライバ入手のためのダウンロードは不要。リポジトリが要るのは
**test-signing で再ビルドして直す場合**だけ（`win11_arm64.ddf` / fwcfg の
A64 サポートはこのツリーにある）。つまり WinRM/RDP に足りないのは
ドライバではなく **guest がその段階まで到達すること**。

## 22.17am 未検証だが筋の悪い容疑候補（次に潰す順）

1. **KD 待ち**：`/debug` が効くと停止するのは bootmgfw ではなく
   winload 以降（§3.1 の再確認）。serial は `file:` なのでKD ハンドシェイク
   の相手が居ない。**まず BCD の Debug 要素の有無を regf パーサで確定させる**
   （`/tmp/bcd2.py` は vk cell の読み位置を +4/+6/+8/+12/+16 に修正済、
   BCD の要素名は格納されていないため要素 GUID/ID 名の一覧が出るはず）。
2. `tlbi vmalle1is` を連発させる側（呼び出し元）を特定する。
   gdbstub の single-step は 1 手あたり重いので、**gdb event async +
   non-stop + continue / 5 秒後に break** を非対話で回してラフな PC 分布を採る。

### 22.17an Pause誤検出の訂正・進捗判定の新指標・BCD解読完了（2026-10-25）

**(0) 前節の "hang" 計測の多くは無効**：`timeout N gdb-multiarch`
を kill すると QEMU が paused のまま残り、その後の
「進捗ゼロ」観測すべてがアーティファクトだった。
確認は `printf "info status\n" | sudo -n socat - UNIX-CONNECT:$PWD/mon-w12.sock`
（絶対パス必須）。再開は gdb を attach して `continue` してから
detach（HMP の `continue` だけでは復帰せず）。

**(1) 進捗判定の決定打を2つ確保**（どちらも guest を止めない）：
- `info jit` の TB count 差分 = 新規翻訳ブロック数。
  50 s で 809016 → 809038（**+22**）, gen code +9.8 KB, TB flush 0,
  invalidate 42483 一定 → 同一コード域で回っているだけで前方進行なし
- `screendump`（HMP）で virtio-gpu フレームバッファを取れる。
  1280x800 P6、中身は全面黒（nonzero 0.08%）、50 s 間 MD5 一致
  → viogpudo はまだ画面を書いていない（firmware 側の black フレームのまま）

**(2) `-d int` は実測 8.4 MB/s のログ書き込み**（qdbg-w12.log が
280 s で 259 MB → 2.6 GB）。tmpfs 逼迫＋TCG 遅延の原因なので
`log none` で停止し、末尾 3 MB を /tmp/qdbg.tail.gz に保存後に
`sudo -n truncate -s 0 qdbg-w12.log`（O_APPEND なので安全）。
/proc/<pid>/io は root 所有 → `sudo -n` 必須。
log 停止後は overlay(ov-w12.qcow2) の増分 0 / read_bytes 0（読みは
全部 host page cache に当たるので read_bytes は進捗指標にならない）。

**(3) BCD を hivex で完全解読（=VM 起動なしで hosts 側のみで確定）**
  パーツ: /tmp/bcdhiv.py /tmp/bcdsum.py /tmp/bcdel.py → /tmp/bcdel.out
- Boot Manager {9dea862c-...}: 12000002=`\EFI\Microsoft\Boot\bootmgfw.efi`,
  23000003(default)=**{cc075cd7-...}**, 23000006(resumeobject)={cc075cd6},
  25000004(timeout)=0x1e=30 s。GlobalSettings {a5a30fa2} の 24000001=
  display order [9dea862c, cc075cd1, cc075cd0, cc075cd3]（後者は UiApp）
- {cc075cd7} = "Windows 11" / 12000002=`\Windows\System32\winload.efi`、
  要素は 11000001 12000002 12000004 12000005 14000006 14000008 15000066(=3)
  16000009(=1) 16000060(=1) 17000077 21000001 22000002(=\WINDOWS)
  23000003(resumeobject) 25000020(=0) 250000c2(=1) のみ
- **debug / dbgport / dbgbaud / testsigning / nointegritychecks 系要素は皆無**
  → §22.17am の容疑その1「KD 接続待ちで静止」は**否定**
  （ Geoff Chappell: 0x23000003 は Boot Manager では default、
     Boot Loader では resumeobject。型は object type 依存で意味が変わる）
- まつろわぬ発見: ESP の BCD に Alpine 3.20 Live OS の reinstall エントリ
  {c04a951d-8106-11ef-b49d-806e6f6e6963} = `\EFI\reinstall\grubaa64.efi`、
  UiApp が 5 個（cc075cd0/1/3/4）。既定起動は Windows 11 なので無害だが、
  boot menu（timeout 30 s + Standard でない policy）は頭がないと危険

**(4) ホット TB の RVA 算出（host 側のみ）** base=0xfffff800ce9d0000
cf0033a0→0x6333a0(PAGE) / cf0033c0→0x6333c0 / cf4ba040→0xaea040(.data領域)
cec12ddc→0x242ddc(PAGELK) / cecef38c→0x31f38c / cec05e20→0x235e20
cf005a30→0x635a30 / ceed0ec0→0x500ec0(.text) / cf004880→0x634880
ceec8c08→0x4f8c08 / cee7d1d8→0x4ad1d8。ただし §22.17aj のとおり
live .text は disk 像と違う（PTR/BTI+KPS で膨張、invalidate 42483 回）なので
export 括り出し（wcsnlen+0x9a0 等）は**参考値**。cf4ba040 は disk 像では
.data に落ちる＝live 専用コード（KPS スタブや hvc/stub 域）の可能性。

**(5) 「VM でなくこのホストで native 実行」の可否 = 不可能（実測）**
- `/dev/kvm` 無し → nested 仮想化不可（TCG 一択は変わらない）
- DMI: product_name=`KVM Virtual Machine`, sys_vendor=`QEMU`,
  fw_platform_size=64 → **「このホスト」自体が OCI の入れ物 VM**. 
  NV:S; Ampere A1 = OCI hypervisor 上のゲストなので bare metal じゃない
- CPU part 0xd0c = Neoverse N1, 4 vCPU / 23 G
- native ブートには (a) インスタンスの boot volume 差し替え+UEFI ブータ
  (b) 実機再起動（禁止）(c) OCI の AAVMF 互換 ACPI 上で Win ARM64 が
  通る保証なし — の3つが全部必要。セッションも落ちる。
- 速度的な選択肢: MTTCG は aarch64→aarch64 で可（QEMU 2.9 以降）だが
  TB 差分+22/50 s から見てボトルネックは並列数でなく guest 側の静止域
  → `-smp` 増やしても進まない所では進まない。現実解は「hosts 側 offline
  解析で仮説を潰し、boot 回数を減らす」（本節 (3) がその実例）。

**(6) 次に hosts 側でできること（boot 不要）**
- SYSTEM/SOFTWARE hive を hivex で読み WinRM/TermService/SharedAccess の
  Start と limitBlankPasswordUse を確認（既に /tmp/dp2.py 相当は作る済）
- `%SYSTEMROOT%\INF\setupapi.setup.log` / `Windows\PFREPAR`・
  `Windows\Logs\CBS`・`Windows\System32\config\SIH` 等を RO マウントで読み
  「どこまで初期設定が進んだか」を disk 側から確定（=進捗の真の物差し）
- BOOTSTAT.DAT は 2024-10-02 で stale（§3.3）なのでアテにしない

---

## 22.18 ネイティブ起動準備（2026-10-25 / ホスト再起動の前的準備・完全可逆）

### (1) platform: native 起動は理屈上OK
- IORT は全長128B / NodeCount=2 / NodesOffset=48 のみ（ITS+Root 
  Complex）→ SMMU/SMMUv3 ノードが入る余地なし＝SMMU 実質無し。
- PCI は全部 virtio かつ subsystem 108e:1100(Oracle) だが installed INF
  側に裸の PCI\VEN_1AF4&DEV_1048/1042/1041 が入っているので subsystem 不一致は問題なし。
- DMI=QEMU Virtual Machine / EDK2(BOCHS) だがそれは OCI の入れ物側。
  nested KVM は無関係（native には不要）。

### (2) disk / BCD（編集不要と確定）
- /dev/sda = Linux(AnduinOS) boot vol  wwn-0x609e161c…  by-path 18:00.0-scsi-0:0:0:1
- /dev/sdb = Windows 50G             wwn-0x603b9a491a32433e8a3f77aea61e74b2
  by-path 18:00.0-scsi-0:0:1:1 / ORACLE BlockVolume / sdb1 ESP 057542d2-1b5d-
  4682-b686-62cdaf9862bf, sdb2 MSR, sdb3 NTFS b9237fd1-5fa8-4f81-a2bf-88f397a5205f
- \EFI\Microsoft\Boot\BCD を hivex で全ダンプ（/tmp/bcd2.py → /tmp/bcd.txt）
  - {bootmgr} 9dea862c: device=HD(GPT 057542d2=sdb1 ESP) / path=\EFI\Microsoft\Boot\bootmgfw.efi / desc="Windows Boot Manager" / timeout=0x1e / boot app={cc075cd7}
  - "Windows 11" cc075cd7 (type 0x03002010=OS Loader): device=21000001/11000001
    とも d17f23b9a85f814fa2bf88f397a5205f = **b9237fd1…=sdb3** / path=\Windows\System32\winload.efi / system=\WINDOWS
  - 他に {fwboot} a5a30fa2, WinRE(cc075cd8), Resume(cc075cd6), \EFI\reinstall\grubaa64.efi(alpine 3.20 = OCI Win-ARM イメージ由来), UiApp, EFI Internal Shell
  ⇒ BCD は実 disk の GPT partition GUID を正しく指している。**BCD は触らない**
- Boot0002 "UEFI ORACLE BlockVolume" は Pci(0x5,7) 旧址で stale。既存エントリは使わない

### (3) 新戦略: offline いじくり → 起動時サービス 1 本
SAM ハッシュ書き／静的IPレジストリ key／BCD EMS blob 等の fragile な
offline 手術を捨て、SYSTEM hive に自作サービス **WinArmsvc** を 1 個作り、
SYSTEM 権で PowerShell を走らせて全部 runtime にやる設計。

### (4) hivex / hivexregedit の実測の落とし穴（重要）
- **tmpfs 上で commit(_None_)＝in-place 書き戻しが EPERM（許可がありません）**
  → /tmp は使えない。ext4（~/tmp/hive）で編集して cp で戻す運用が必須。
- python binding: node_children()/node_values() は **handle(int) の list**
  （名前が要るなら node_name()/value_key()）。value_type()→(type,len) タプル、
  value_value()→(t, bytes)。文字列は value_string()、dword は value_dword()。
  ※node_get_root()/value_utf16() は存在しない（node_get_child/value_string系を使え）
- hivexregedit の reg ファイルのキーは `[\ControlSet001\...]` 形式で OK（作成も編集もできる）
- hex(7) MULTI_SZ は hivexregedit 経由だと終端 NUL が 1 個削れる（14B に なった）→ DependOnService は最初から削除（RPCSS 依存は無くても可）
- ImagePath のバックスラッシュは python 側で chr(92) 連結で作る（\\ の多重エスケープ事故防止）
- 検証スクリプト: /tmp/chk.py（hive 経由で該当値を全部 print）

### (5) 適用した値（実 disk /dev/sdb3 に反映・再読 sha256 一致済）
- Services\WinArmsvc: Type=0x10(SERVICE_WIN32_OWN_PROCESS) Start=2 
  ErrorControl=1(=SERVICE_ERROR_IGNORE) ObjectName=LocalSystem 
  ImagePath=powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\winarm\setup.ps1
  Security サブキー無し→SCM 既定 SD で起動可。powershell は SCM に開始通知
  しないので 1053 が出る可能性が高いが **プロセスは走り続ける**（ErrorControl=1 で起動にも影響なし）
- Services\WinRM Start 4→2 / TermService 3→2 / mpssvc は元々 2
- Control\Lsa\LimitBlankPasswordUse 1→0
- Terminal Server\fDenyTSConnections は元々 0 / WinStations\RDP-Tcp\UserAuthentication 1→0
- FW policy is at Services\**SharedAccess**\Parameters\FirewallPolicy（MpsSvc じゃない）
  Public/Standard とも EnableFirewall 1→0
- SAM は**無編集**（RID500 Administrator の F+0x38=0x0210 で既に有効）
- SYSTEM.LOG1(0B)/SYSTEM.LOG2(2162688B)/pagefile.sys/swapfile.sys を削除。
  SAM.LOG* は未編集なので保持。hiberfil.sys は元々無し。
- backup: work/offline-backup-20261025-native/{SYSTEM,SAM}（編集前）
- 作業用: ~/tmp/hive/SYSTEM（マージ後 26a4ae66ca681b8169fc3f7d195fb04706e7ceb3159e7d54ca5ad533fc5a1f45 = 実 disk と一致）

### (6) ペイロード C:\winarm\setup.ps1（md5 2944f280f3584e7bb1ffc1f9a57a7e2a / 42 行）
  ※C:\Windows\Temp\wa.ps1 にも同じコピー
 FW off, reg add x4, powercfg /h off, Administrator パスワード設定+有効化,
 60s sleep, VirtIO NIC を選んで static <private-ip>/24 gw 10.0.0.1、DNS 
 169.254.169.254/1.1.1.1、DHCP Disabled、ipconfig /all、winrm quickconfig、
 AllowUnencrypted/Basic 有効、Start-Service WinRM、listener 列挙、
 5985/3389 listen 確認、metadata v1 を meta-instance.txt / meta-vnics.txt に保存、
 10.0.0.1 と 1.1.1.1 へ ping、bcdedit で bootstatuspolicy IgnoreAllFailures +
 EMS(EMSPORT:1 115200, /bootems)。**C:\winarm\log.txt が boot 進捗マーカー**
（power-cycle 後に hosts 側から offline で読めるのがデカい）。

### (7) ブート選択（一発・可逆）
- 作成: sudo efibootmgr -c -d /dev/sdb -p 1 -L "Windows ARM64 Native" 
  -l \EFI\Microsoft\Boot\bootmgfw.efi → **Boot0003** = HD(1,GPT,057542d2…)/\EFI\Microsoft\Boot\bootmgfw.efi
- **efibootmgr -c は BootOrder に先頭挿入する**ので手動で復元した: BootOrder=0006,0002,0000,0001,0005,0003（Linux 優先）
- BootNext=0003（efibootmgr -n 0003）＝次回 1 回だけ Windows。
  ハングしたら console から power-cycle すれば自動的に Linux へ戻る。
- 中止: sudo efibootmgr --delete-bootnext / 恒久化: sudo efibootmgr -o 0003,0006,0002,0000,0001,0005
- ESP 側: bootmgfw.efi 2622784B(2024-10-05 版= native 実積物), \EFI\Boot\bootaa64.efi 2625456B, startup.nsh は V7 用（shell エントリでしか走らないので放置）

### (8) ユーザ側 TODO / 未決
- VCN security list（または NSG）に **5985/tcp + 3389/tcp** を手元 IP から ingress 追加
- public IP は v1 metadata に出ない（v2 は Bearer token PUT が必要）→ 初回ブート後に C:\winarm\meta-vnics.txt で確定するのが確実
- Windows 稼働中はインスタンスの SSH は落ちる。復帰手段=OCI console connection からの reboot/power-cycle
- 接続試験（手元 Win）: Test-WSMan <pubIP> / winrs -r:http://<pubIP>:5985 -u:Administrator -p:"REDACTED" "cmd /c whoami" / mstsc
- Linux 復帰後: sudo mount -t ntfs-3g -o ro /dev/sdb3 /mnt/win で C:\winarm\log.txt・meta-*.txt・Windows\INF\setupapi.dev.log・winevt\Logs\System.evtx を読めば進捗が確定できる

### (9) 追記（同じ日 / 再起動直前）
- metadata **v2 は PUT が 405 Method Not Allowed**（この OCI metadata proxy は
  token 発給不可）→ GET は 403。v1 には publicIp フィールドが**存在しない**
  （v1 instance/vnics に出るのは privateIp <private-ip> / mac <mac>
  / virtualRouterIp 10.0.0.1 / ipv6 ::/64 のみ）。public IP は OCI コンソールで見るか、
  ペイロードが https://api.ipify.org から取る（下記）。
- setup.ps1 を 44 行に更新（md5 c3556caed6efacc5f6fae4a601bb86e7、
  winarm\setup.ps1 と Windows\Temp\wa.ps1 両方一致）。追加行=完了 1 行前に 
  api.ipify.org へ GET → C:\winarm\pubip.txt に保存 + log に pubip=。
- 起動前最終状態: /dev/sdb のマウント全て解除・fuser 空・QEMU プロセス無し・
  /etc/fstab に sdb 記載無し。BootNext=0003、BootOrder=0006,0002,0000,0001,0005,0003
  （Linux 優先のまま一発だけ Windows）。

## 22.19 ネイティブ起動テスト#2: viogpudo 無効化 + シリア観測体制 (2026-10-25)

### (1) 今回加えた編集（全てオフライン実施・md5 記録）
- SYSTEM hive: ControlSet001\Services\VioGpuDod\Start を 3→4 (disabled) に。
  hivex python (open write=True, node_set_value) で実施。hivediff.py で
   hive 全体 diff 差異はこの 1 箇所のみと確認済。sdb3 へ書き戻し済。
  live md5=86f09ded2654fd6d4954756b18995cd7。Linux 側: ~/tmp/hive/SYSTEM.pre-viogpu(前)・SYSTEM.v2(後)。
  BasicDisplay は Start=1 (boot-start) のまま残る → viogpudo 無効でも Video クラスの
  フォールバック表示は生きている。Class\{4d36e968-...} の inst 0000/0001 は
  Service/Driver 値なし（バインド無し）。viogpu 名の nodes は EventLog 設定のみ。
- BCD (ESP \EFI\Microsoft\Boot\BCD): 最終 md5=d74a001e1bcf11d1d8c0ace99bfbe340
  (45056→49152B、hivex commit による成長。読み取り影響なし)。
  {bootmgr}: +16000020(bootems)=1、timeout(25000004)=5。
  default {cc075cd7-8065-11ef-b427-f0aaf1083c73}: +260000b0(kernel ems)=1、
   +26000090(bootlog)=1 (→C:\Windows\ntbtlog.txt)、+26000091(sos)=1、
   +250000e0(bootstatuspolicy)=1 (IgnoreAllFailures)、16000009(recoveryenabled)=0。
   ※ 16000009=00 は default のみ。WinRE {cc075cd8} の recoveryenabled=1 は無変更。
  {emssettings}={7ff607e0-4395-11db-b0de-0800200c9a66}: +15000022(emsport)=1[COM1]、
   +15000023(emsbaudrate)=115200（QWORD LE）。元からある 250000f3/f4/f5=0/1/115200 は
   hypervisor-debug 系だと geoffchappell 要素表で確認。hypervisor 不使用なので無害放置。
  要素 ID 出典: geoffchappell.com/notes/windows/boot/bcd/elements.htm（再取得・全一致確認）。
  注意: BCD の要素は Elements\{16進ID小文字混在}\Element(REG_BINARY) 構造。
  bool=1B、integer=8B LE。バックアップ ESP: BCD.bak-presos-20261025 (=d8b9c1a5)。
  Linux 側作業コピー: ~/tmp/bcd/bcd.now3(無変更元)・bcd.v2(導入最終)。
- startup.nsh V8 (ESP 直下): md5=b717d1342b335eb4fb82708bda1b9d4a (67行)。
  段階別ファイル breadcrumb 方式: \v8_00_start → \v8_10_drv → \v8_20_map →
  \v8_30_rdchk → \v8_40_launch_fsN → 異常時 \v8_50_return_fsN / \v8_99_nowin。
  (echo > ファイル 方式。shell 変数依存なし・>> 非依存で最終状態が1ファイルに残る)
  V7 相当は startup.nsh.bak-v7-20261025 へ保存。rdchkapp/ntfs_aa64 読込は V7 踏襲。

### (2) NVRAM/GRUB 起動経路
- Boot0003 (Windows Boot Manager) は NVRAM リセットで消滅済（BootNext も消える。
  §22.18(7) の efibootmgr 手順は無効化された）。残存: 0002/0000/0001/0005/0006。
- GRUB(Anduin) に "Win11 via ESP Shell V8"（sdb1:\EFI\Boot\bootaa64.efi を
  chainload → EFI Shell 起動 → startup.nsh V8 自動実行 → bootmgfw 継承）を追加。
  GRUB_DEFAULT をタイトル指定 "Win11 via ESP Shell V8" に変更（番号索引は
  エントリ増減でずれるので不採用）。GRUB_TIMEOUT=10・menu 表示。
  既存の "Windows 11 ARM64"(bootmgfw 直 chain)・DIAG エントリも残存。
  ※ 40_custom と 41_custom が同じ Windows 11 ARM64 を出す重複が cfg 内に2つあるが無害。
- 再起動前に efibootmgr -n 0005（一回だけ Shell 直_boot）。NVRAM リセットで消えたら
  Linux→GRUB 既定 10 秒→と同じ V8 経路に着地するので二重保険。

### (3) 期待する観測（OCI console connection シリアル）
- SPCR=PL011@0x09000000 / EMS 有効化済 → bootmgr・winload(sos 進行テキスト)・
  kernel がコンソールに文字を出す。止まった行名=犯人の特定になる。
- bootlog → C:\Windows\ntbtlog.txt。startup.nsh は ESP の v8_*.txt 群。
- viogpudo がフリーズ主因なら今回は SMSS 以降→setup.ps1 が走り C:\winarm\log.txt。
- 失敗時回収: ESP の v8_*.txt 有無・rdchk.log・BCD 生きているか・ntbtlog・hive mtime。

### (4) 復旧手段
- SYSTEM: cp ~/tmp/hive/SYSTEM.pre-viogpu → sdb3:\Windows\System32\config\SYSTEM
- BCD: cp ESP\EFI\Microsoft\Boot\BCD.bak-presos-20261025 → BCD
- startup.nsh: cp /tmp/espp/startup.nsh.bak-v7-20261025 → startup.nsh
- GRUB: /etc/default/grub GRUB_DEFAULT="3" への復帰 + grub-mkconfig。

## 22.20 V8 失敗解析 → V9 (2026-10-25 実測)
- 実行結果(Shell): Image Loaded→mapping table 正常。startup.nsh V8 が
  line3 `echo V8 boot > \v8_00_start.txt` で "Unable to redirect file."
  → Script Error Status: Invalid Parameter でスクリプト全体が中断。
  原因: 実行時点のカレントはマッピング前無名 root（相対 \ は書けない）。
  shell はリダイレクト失敗でスクリプトを打ち切る（continue しない）。
- GRUB chainloader は aarch64/EDK2 で "ConvertPages: failed to find range
  102000 - 102FFF" により全滅（40_custom 系 GRUB→EFI app 継承は使用不可と判定）。
- V9 設計教訓: ①map -r 前に書き込みしない ②相対 \ 禁止・fsN:\ 全明示
  ③対象 ESP は Windows 側 fs1（sda1=Linux ESP は fs0、混同注意）
  ④echo > は既存ファイル上書きのみ安全→マーカー v9drv/v9rd/v9l0/v9l1.txt を
  事前プレイス済 ⑤rdchk.log が単独証拠なので rd 完了マーカーは任意。
- V9 md5=10f8295d5355dab08a913e263c1b9b83 (52行)。バックアップ startup.nsh.bak-v8-20261025。
- BootNext=0005 再装填済。V9 ブレッドクラム: v9drv→v9rd→v9l0/v9l1（＋echo 進行行）。
- ※直前のホスト reboot で /tmp/espp マウント消失に注意（tmpfs）。毎回 mkdir+mount 要。

## 22.21 テスト#2解析確定 + ARM64 EMS修正 (2026-10-25 19:0x)

### テスト#2 の結論 (V9 完走・bootmgfw 転送後に無音)

- V9 は全行程完走: ..V9-MAPPED → ..V9-RDCHK-DONE → v9rd →
  ..V9-LAUNCH-fs1 → シェルが Image Loaded: bootmgfw.efi 表示 → 以後ゼロ出力。
- フォレンジック: ntbtlog.txt 無し / winarm log.txt 無し / SYSTEM md5 不変
  (86f09ded…) → カーネルは起動していない。凍結は bootmgfw 起動後・SOS  text 無し。
- RDCHK NTFS-READ-ALL-OK 済みなのでディスク読解は无罪。ハーネス(V9)も无罪。

### EMS 設定の誤り（最有力仮説）と公式ドキュメント根拠
- 従来 {emssettings} に emsport=1 (COM1) + emsbaudrate=115200 を入れていた。
  COM1=0x3F8 は x86 の I/O ポート番号意味。本機 ARM64 のシリアルの実体は
  PL011 MMIO @0x09000000 (ACPI SPCR/DBG2)。winload の EMS init がこの端口
  指定で失敗 or ハンガし、bootmgr/winload 全無音と符合。
- 公式 (learn: bcdedit--emssettings / boot-parameters-to-enable-ems-redirect):
  "UEFI ファームウェアなら /ems on だけ使え。Windows は SPCR を読んで
  ポートと速率を自動決定する。BIOS パラメータ併用時 emsport/emsbaudrate
  は設定するな" → UEFI 系で emsport を置くこと自体が不正。
- geoffchappell elements.htm 全面再取得: 15000022=BcdLibraryInteger_EmsPort
  (integer) のみ。USE_FIRMWARE_SETTING のオンディスク番兵は未記載。
  → 番兵の代わりに「要素削除＝SPCR フォールバック」＝文書化された正攻法。

### 実施した BCD 編集 (bcd.v3, md5 cd003911fc4098e20b1fbdcab92972c6)
- 元ライブ BCD md5=d74a001e… (→ ESP へ BCD.bak-preemsfix-20261025 として保存)
- diff 検証で意図した 6 変更のみを確認:
  {emssettings} {7ff607e0-…}: 15000022(delete) 15000023(delete)
  {bootmgr} {9dea862c-…}: 16000046(graphicsmodedisabled)=1 +
                             1600006c(bootuxdisabled)=1
  {default}   {cc075cd7-…}: 16000046=1 + 1600006c=1
- graphics/bootux 無効は GOP 依存排除（viogpudo 無効化と合わせ表示経路を
  完全に切る）。ブートハング原因が graphic init だった場合も同時に潰す。
- hivex python API 補足: 削除は node_delete_child(子node)（名前引数不可）。
  value は bytearray 不可・bytes 直呼び。要素キーは波括弧なし小文字16進
  (Windows 自身の 250000c2 等と同形式、読み取り照合済)。
- インストール: rw remount → cp → md5 一致 → ro remount。BCD 57344B へ成長。

### 起動前状態 (テスト#3 へ)
- BootNext=0005 再装填済 (efibootmgr -n 0005 実測表示で確認)。
- GRUB_DEFAULT="3" へ復元 + grub-mkconfig 再生成済 (GRUB chain は
  ConvertPages bug で死んでいるため V8 経路エントリは使わない)。
- startup.nsh は V9 のまま (md5 10f8295d…)。マーカーは全再プレイス必須でない
  (上書き方式なので既存で可)。v9l0 のみ未更新=bootmgfw fs0 経路未実行のまま。
- テスト#3 期待: …V9-LAUNCH-fs1 → Image Loaded: bootmgfw.efi →
  (EMS on SPCR なら) Windows Boot Manager / winload SOS 行がシリアルに出る。
  出ればカーネル到達の切り分け可能。依然無音なら EMS 経路自体が死んでおり、
  その場合は winload 側の別要因 (BTI/PTR KPS 再 Patch 検証 §22.17aj 系) へ。

## 22.22 テスト#3解析: EMS出力成功 → 0xc0000428 と nointegritychecks (2026-10-25)

### テスト#3の結果
- §22.21 の emsport/emsbaudrate 削除は**有効**。bootmgfw.efi 実行後に
  Windows Boot Manager のエラーページが PL011 シリアルへ実際に描画された。
- 表示: Status: 0xc0000428 / "The digital signature for this file could
  not be verified." / ESC=UEFI Firmware Settings
- 注意: 文字が2重になり語が入れ替わる (WWiinnddooww)。Windows EMS/ConOut
  と EDK2 シリアルデバッグが同一 UART に同時書込するため。无害だが読みにくい。
- `Windows Boot Loader` バナー無し → 失敗は bootmgr がアプリ起動前/最中。

### 0xc0000428 = STATUS_INVALID_IMAGE_HASH の調査
- winload.efi (md5 a72be797…, 2947320B) は改変されていない純正:
  証跡=PE 証明書テーブル 0x2c6e00+35576B が EOF ちょうど。
  サインナ: Microsoft Windows <- Windows Production PCA 2011 <- Root CA 2010
  + RFC3161 タイムスタンプ (Time-Stamp PCA 2010, counter-sig 2024-09-05)。
- 証明書有効期限 (pkcs7 blob 先頭8B ヘッダを除き openssl pkcs7 で読めた):
  leaf 2023-11-16→2024-11-14 (失効済・counter-signで保護)
  PCA2011 2011-10-19→**2026-10-19** (失効済) ← 現在 2026-10-25 と接近
- efivarfs に SecureBoot/PK/KEK/db/dbx が**存在しない** (32個中0個)
  → SB 完全オフ。よって nointegritychecks は設定可能かつ有効な解。
- BCD 自体の欠損要素は無し (device/path/GPT GUID 全て正しい) を再確認。

### BCD 要素 ID 権威表の訂正 (Wack0 gist)
- **16000048 = DisableIntegrityChecks (nointegritychecks)** 16000049=TestSigning
- 1500001A は DebuggerNetHostIP だった (旧 §22.21 の nointegritychecks 推定は誤)
- 2500012C/2F/39 も表中に存在しない (旧推定は誤)。以後この表のみ使う。

### 対応 (テスト#4 準備完了)
- {bootmgr} {9dea862c} と {default} {cc075cd7} に 16000048=1 (bool 1B) を追記
- ~/tmp/bcd/bcd.v4 (md5 75137efea88e46298e139a4b30ae4914, 61440B)
  diff = 追加2行のみ確認 (`16000048 t=3 short:01`)。
- ESP へインストール済。バックアップ: BCD.bak-preinteg-20261025
- BootNext=0005 再装填済。→ ユーザー再起動 (テスト#4)。
- 次の分岐: A=Boot Loader バナー以降の SOS _DRIVER_LINES が見える
  B=依然 0xc0000428 → 16000049 追加 / 日付を 2026-10 以前へずらす実証テスト
  (PCA2011 notAfter=2026-10-19 なので日付起因の検証価値あり) / 26000020 でメニュー。

## 22.23 テスト#4解析 + ブート鎖のバージョン混成を確定 (2026-10-25 20:3x)

### 観測
- シリアル: File \WINDOWS\system32\ntoskrnl.exe / Status: 0xc0000a04 /
  "The operating system couldn't be loaded because it is missing or
  contains errors"。ENTER=OS Selection / ESC=Recovery。
- bootmgr→winload の受け渡しは成功 (§22.22 nointegritychecks=16000048 が有効)。
- 0xc0000a04 は公開 NTSTATUS 名なし (検索ゼロヒット・magnumdb 403)。
  0xc0000428 (ハッシュ/署名) ではない → 失敗箇所は署名でなく
  winload による ntoskrnl の取込段階 (読込/検証/バージョン整合)。

### 出所判明
- イメージの出所 = $HOME/tiny11.iso (6,258,675,712 B / 2024-09-21)。
  §22.5 の /mnt/iso と同一。未知の第三者配布＝Sam Lab の改変 ISO。

### ファイル健全性監査 (読み取りのみ)
- SYSTEM ハイブ Start=0 & Type bit0-2 監査: 実在 58 / 欠損 0
  (work 外 /tmp/bootdrv4.py)。uefi は Start=3→DriverStore、
  fsrtl/msisadrv はregistry要求なし → ファイル欠落は無罪。
- 教訓: この ntfs3 マウントの stat は大文字小文字を区別する
  (/etc の BOOTVID.DLL ok / bootvid.dll ENOENT)。
  wofchk.py の MISSING 大半は偽陽性。要 case 非依存ルックアップ。
- hivex python binding: node_values→ハンドルint・読み出しは
  value_dword/value_string (node_get_value は存在時ハンドル返却)。

### 版本混成の実測 (FileVersion)
- winload.efi = 10.0.26100.1742 (音量本来の世代)
- ntoskrnl.exe = 11,486,624 B = install.wim(2026-03 ≒8036) 由来
- ci.dll = 10.0.26100.8036 / clfs=fltMgr=26100.7920 / hal.dll=26100.1
- §22.5 表の再確認: 音量 WOF プレースホルダの номинал ntoskrnl
  11,252,128 B ≡ WinSxS os-kernel_31bf…1742 の ntoskrnl.exe と厳密一致
  → 音量の正当な 1742 カーネルは WinSxS に無傷で残存。ci も 1591 が残存。
- 混入元: §22.17b 以降の「install.wim で実体化」実験 (NOTES 3526 行以降)
  が boot-critical を 1 世代新しい 8036/7920 へ差し替えていた。
- 署名系 (参考): ntoskrnl(8036) leaf 2025-06-19→2026-06-17 失効済、
  PCA 2011 は 2026-10-19 失効 (ホスト時刻 2026-10-25)。いずれにせよ
  0xc0000a04 は署名コードではない。

### 容疑 (最有力)
winload(1742) が別世代 (≒8036) の ntoskrnl.exe を拒否している。
音量の registry / DriverStore / WinSxS / winload は 1742 系で整合済み。

### 選択肢 (未実施・ユーザー判断待ち)
- A: 鎖を音量本来の 1742 状態へ復元 (WinSxS の同版本写しが最有力。
  ntoskrnl=1742 / ci=1591 / 差替えた boot driver も各世代適合版へ)
  → 追加 DL 不要・winload と同ビルド・可逆 (.wofbak あり)
- B: クリーンインストール
  /dev/kvm 無し (OCI A1 は nested 非提供) → QEMU は TCG 全エミュのみ、
  実用数日規模。OCI BYOI は Windows Server のみ対応・ISO 取り込み不可
  → ローカル導入→raw 変換→カスタムイメージ import の二段構え
- C: 8036 へ全統一 (winload も tiny11.iso の install.wim 版へ)
  registry/WinSxS が 1742 系のため整合性は逆に悪化。非推奨

## 22.24 winload=ISO版 単体差替 TCG 検証（2026-10-25 夜）

### 動機（md5 実測で混入元が確定）
- /mnt/win ntoskrnl.exe md5 = 3de0e6e01cfe509f8bba2d706f613cd9
  = tiny11.iso install.wim の ntoskrnl.exe と完全一致（TDS 0x84268839）。
- 現 winload.efi(2,947,320B) は ISO 版(3,156,408B / TDS 0xdde68802)と別ビルド。
- つまりカーネル群=ISO世代、winload のみ RTM 世代のペアリング不一致。
- hal.dll(17KB halstub) は winload を import しない → GUID interface 層で
  解決されるはず。静的検査では決着つかず → 実機/TCG 実験が最短。

### COW オーバーレイ実験（実 disk 無傷）
- /tmp/wlt/cow.qcow2 = backing /dev/sdb（qemu-nbd で nbd0p3 に winload 差替
  only: winload.efi.rtm へ退避 → ISO 版 md5 14e805cd… を配置）
- nbd0p1: startup.nsh から rdchkapp 起動行のみ削除（TCG 時間節約）
- 起動: qemu -machine virt,gic-version=3 -cpu max -smp 4 -m 8192
  AAVMF no-secboot + vars.fd / -serial file:/tmp/wlt/serial.log
  -chardev socket mon / scsi-hd で cow / -no-reboot -display none
- 成否判定: serial に 0xc0000a04 エラペが出るか否か。
  早期終了(shutdown)=カーネル実行=前進。cow 増殖=深いブート継続。

### 次段候補（A 失敗時）
- B: ESP bootmgfw も ISO 版(3,030,944B TDS 0xc1e2a2fa)へ（TCG では無patchで
  可。native に持ち込む場合は rebase+anypages patch 要）
- C: WinSxS 1742 系への全面復元（winload 維持方向）

### 22.24 続1: A案（winload only）TCG結果とTCG運用ノウハウ
- Ubuntu AAVMF release + pflash vars では TCG 54分でも disk read 0、
  画面未初期化のまま沈黙（判定不能）。→自作 DEBUG FW へ切替で解決。
- **TCG標準レシピ（確立）**: `-bios ~/edk2/Build/ArmVirtQemu-AArch64/
  DEBUG_GCC/FV/QEMU_EFI.fd -smp 1 -m 4096 -net none` + 追加NVRAM不要
  （ESPへ edk2 Shell.efi を \EFI\BOOT\BOOTAA64.EFI として注入→Shell自走、
  \EFI\NTFS\ntfs_aa64.efi load → map -r → bootmgfw）。
  結果が約5分で出る。DEBUG FW はConOutをシリアルにも出すので
  winload/BootMgr エラペがそのまま読める。
- A案結果（ISO winload単体差替+RTM patch bootmgfw）: chain は完走、
  BCD/WinSiPolicy/CiPolicies 読取済 → "Windows failed to start" 
  **Status: 0xc0430001 / InfoAn: unexpected error** で shutdown。
  native での 0xc0000a04(文件行付き) とは別コード → 失敗モードは変化した。
  0xC0430001=STATUS_DRIVER_UNABLE_TO_LOAD 系（winload 戻り値）。
  判定には対照実験（cowC: 無差替 control, bootmgfw RTM-patched winload RTM）が要る。
- 教訓: startup.nsh から rdchkapp 呼び出しを sed で1行削除すると 
  if/endif が壊れて Shell が "No matching If for EndIf" で対話停止する。
  → TCG 用には /tmp/wlt/mini.nsh（ntfs load + map -r + bootmgfw 実行のみ、
  T-START/T-MAPPED/T-GO/T-RET マーカー付き）を startup.nsh として直接配置する。

### 22.24 続2: 対照実験で TCG=native 忠実性を実証、次戦線=boot drivers
- cowC（無差替 control, 同じ TCG レシピ）が native test#4 と完全一致:
  File: \WINDOWS\system32\ntoskrnl.exe / Status: 0xc0000a04 /
  Info: OS couldnt be loaded missing or errors → **TCG はこの段階で忠実**
- A=cow(winload only ISO)/B=cowB(winload+bootmgfw ISO) とも
  Status: 0xc0430001 (InfoAn) に変化、File 行なし。
  → winload=ISO 差替は a04 の壁を確実に除去（ペアリング説✔）。
  → B==A なので bootmgr 世代は要因でない。0xc0430001 の容疑は
    winload が読む boot-start ドライバ群の世代混在（System32\drivers\*.sys
    が 8036 混成で ISO winload の検証/読込と不整合の可能性）。
- 次: cowE = winload ISO + install.wim から System32 直下 dll/exe と
  drivers\*.sys を抽出し上書き（config\* ハイブは絶対に触らない）。
  wimlib-imagex extract --include-globs があればそれで、無ければ
  System32 全体を退避-dirへ extract 後に subset cp。
  ※フルWIM適用は不可: \Windows\System32\config の既定ハイブが
    ローカル設定済み SYSTEM/SAM 等を潰す。
- TCG実行は約5分/回。実 disk 適用(realfix.sh)+reboot 前に cowE まで
   TCG で詰めてからユーザー reboot Handoff 那のが得策。
- 次 hand: cowG = winload ISO 単独 + BCD へ 26000003 = 0xA0
  (BootCriticalSignificant=0 + DriverSignificant=0)。CI 検証機構の
  winload 側読み込みを無効化して a04/430 地点まで戻せるか試す。

### 22.24 続4: BCD v5 作成（26000003=0xf40021a0: 26000016 に加え
  BootCriticalSignificant(bit5)=0 DriverSignificant(bit7)=0 両 obj 追加, marker 2個確認）
- cowE は 0xc0e90001 "CI failed to initialize" で winload 初期化段に退行
- 次: cowK = winload=ISO + BCDv5 + (必要なら) s32x subsets で TCG

### 22.24 続5: 実ESPステージング完了（テスト#5 待ち, 2026-10-25 深夜）
- /tmp/espp を rw remount（ro mount は単なるマウントオプション、root remount,rw 可）
- 実 BCD に g3.py で 26000003=0xf40021a0 を両 obj 追加・commit・再読検証済
  （{9dea862c}=['26000003'] / {cc075cd7}=[26000003,90,91,b0]）。
  backup: BCD.bak-precieval（同ディレクトリ）
- startup.nsh は現物 V9 版（1207B 18:26, ..V9-START クラム）が既に正位置、変更不要
- BootNext=0005 再装填済（efibootmgr 実表示 BootNext: 0005 確認）
- winload=ISO(14e805cd) は実 disk 適用済（続3/§22.24）。winload=ISO 単独 swaps 系は
  TCG では cowG run3 で bootmgr 通過後に無言停止（デバックFWのFSOpen 'Boot' まで）、
  一方 実機 native では a04 地点を保持してきた経緯 → native で見る価値あり
- cowN(harness win3k+ov-cowN) は shell マルチFS環境で bootmgfw 実行到達前に
  OS Selection Shutdown の表示のみ・マーカー不出力（boot.img V3 startup 側が fs のみ
  見て bootmgfw 起動に至らない）。harness 側は boot.img 内容刷新が要る → 保留、
  実機テスト先行へ
- ★ユーザー操作: OCI コンソールから reboot 1 回（BootNext 発火で Shell→V9 チェーン）

## 22.25 テスト#5 解析: bootmgfw 起動直後ハング = v5 の要素が容疑 (§22.24続5 の続き)

### 実測 (2026-10-25 22:45 実機 console + 復帰後 ESP)
- Shell→V9 startup→ntfs_aa64→rdchkapp(READ-ALL-OK, fail=0)→..V9-RDCHK-DONE
  →..V9-LAUNCH-fs1 / Image Loaded: bootmgfw.efi → **以後無出力・ハング**
- ESP パンくず: v9l1.txt=L(22:45:16) だが ..V9-RETURNED-fs1 未達
  = bootmgfw は制御取得後に復帰せず。BCD/WinSiPolicy/CiPolicies 読み取り
  段階でのハングと推定（cowG run3 TCG の FSOpen 'Boot' 後無言と同一パターン）
- BootNext は消費済（BootCurrent 0006 のみ・BootNext 消滅）= 発火は成功

### 隔離根拠（TCG 実測マトリクス）
- BCDv4 + winload-ISO = bootmgr 通過 → 0xc0430001 (cowA/B)
- BCDv5(26000003 両obj) + winload-ISO = bootmgr 段ハング (cowG run3 & 実機#5)
- 単一变数 = 26000003 の追加。**特に {9dea862c}(bootmgr自身obj) への追加が
  bootmgr のパーサを殺している疑い**

### 続6実験: H1 = BCDv6a (v4 + 26000003 を {cc075cd7} loader obj のみ)
- bcd.v4(md5 75137e..) → g4.py(単一obj注入) → bcd.v6a(65536B, md5 38584cee)
- 検証済: {9dea862c}=v4と同要素集合 / {cc075cd7}=v4+['26000003'] のみ
- cowh.qcow2 = 新規オーバーレイ(backing /dev/sdb, tmpfs再作成)
  ESP: BCD←v6a, startup.nsh←mini(H-START/H-MAPPED/H-GO-fs1/H-RET/H-END)
  winload=ISO は実 disk に既載なので backing 経由で自動適用
- 起動: 標準 TCGrecipe (FV/QEMU_EFI.fd, smp1 mem4096, serialH1.log)
- 分岐: H-GO 後に 0xc0430001/a04 系判定到達 → bootmgrobj要素が毒と確定、
  v6a を実 ESP へ（ネイティブ#6 handoff）
  H-GO 後ハング継続 → loader obj 要素も毒 → 値/形式の再設計（v4 復帰が安全側）

## 22.26 続7: 26000003 敗北確定（正式スキーマ検証）+ 実ESP BCD を v4 へ復元

### H1 実測（cowh + bcd.v6a: 26000003 を loader obj み注入）
- H- チェーン完走 → bootmgfw はハングせずエラーページ描画:
  Status: 0xc0000224 "There is an invalid object in the BCD store" → Shutdown
- つまり bootmgr は生きたまま obj 検問で拒否（v5 の bootloader obj 版が毒、
  bootmgr obj 版 {9dea862c} への追加がハング要因）と整合

### geoffchappell 正式表で確定（URL=/notes/windows/boot/bcd/elements.htm、
  /studies/... ではない。2026-10-26 取得済）
- {bootmgr} obj 表: .3 は 0x23000003=default(GUID)。26000003 は存在しない
- OSLOADER obj 表: .3 は 0x23000003=resumeobject(GUID)。26000003 は存在しない
- 0x26000003 は RESUME=customsettings(bool) と MEMDIAG=cacheenable(bool) のみ
- 元仮説（BootCriticalSignificant/DriverSignificant）は要素住自体が誤り
- 教訓: BCD obj へ未定義 ID を足すと loader obj=0xc0000224 / bootmgr obj=無言ハング。
  値の形式（t=4/4B）が正しくても ID がobj表に無ければ拒否。bcdedit の custom:
  で書けるものと bootmgr 検証通過は別物

### 決定
- v5/v6a/26000003 路線を完全廃止。bcd.v5,bcd.v6a は研究資料としてのみ残す
- 実 ESP BCD を BCD.bak-precieval(v4, md5 75137efe) へ復元済・
  26000003 不在を hivex で再验证（{9dea862c}=v4 13要素 / {cc075cd7}=v4 22要素）
- 次戦線: 調印チェーン era-match。ISO ブート領域の winload(14e805cd) と 
  install.wim 内 OS は別ビルド可能性大。install.wim から
  \Windows\Boot\EFI\winload.efi を抽出し on-disk OS(8036系) と同版なら
  cowI = そのwinload + BCDv4（ドライバ上書き不要・可逆）で a04/c0430001 同時解消を狙う

## 22.27 (続8) WOFの真実・パス要素確定・TCG-430は環境要因／原生test#6準備Complete
- WinSxS/BootEFI復習: store内 ntoskrnl.exe/Boot\EFI配下のefi群は
-  reparse tag 0x80000017 = WOF圧縮プレースホルダ。ntfs-3gは読めるが
-  データ展開不可(unsupported reparse)。→1742時代への下位互換(downgrade)は
-  入手手段なしで破綻(Option A死)。ci.dll 1591等も同様。
- BCD loader path確定: 12000002 = "\Windows\System32\winload.efi" (OS obj cc075cd7)。
-  \Windows\Boot\EFI\winload.efi は bootmgr 経路ではない(mui/boot.stlのみ同ディレクトリ)。
- bcdobj.py 完成(短行printf版)。hivex意味論確定: node_get_value->intハンドル、
-  value_value(h)->(fmt,bytes); Elements子ノードは value key="Element";
-  Description ノード value key="Guid"; node_get_name は無く node_name。
- 要素フォーマット復号例: boolは fmt3先頭1byte, integer hex, string utf16。
- 古い cowi(qcow2)の v5 BCD 幽霊 = 再マクソート/スタック残骸アーティファクト。
-  全新 cowi + drop_caches + 再detach/attach で = 75137efe(v4,22:59復元) を実機確認。
- 実 /dev/sdb1 BCD = v4 確定(22:59復元は永続化済み)。
- TCG run I: cowi に winload(WIM a4b3f4d2/3156408, install.wim抽出) を
-  rename+new-file で配置(System32のみ、Boot/Store hardlink無傷)。BCD v4(SOS/EMS済)。
-  miniHチェーン、smp1で起動→ bootmgfw起動→ EMS に "Windows Boot Manager
-  failed to start..An unexpected error..ENTER OS Selection/ESC=Recovery",
-  StatusAttributes行に 0xc0430001。File/Reason行は出ず。SOSドライバ行も0行。
- ⇒ 時代一致pair(Load a4b3f4d2 + ntoskrnl8036 + ci8036 全WIM同一)でもTCGは430。
-  ⇒ 430は時代不一致では説明できない。TCG環境要因説が最有力:
-  winloadのboot-startストレージドライバ(vioscsi/stornvme)ロード失敗が
-  STATUS_DRIVER_UNABLE_TO_LOAD=0xc0430001 なら筋が通る(bootmgr→winload
-  手渡しまで成功、winloadはdriver負荷で死ぬ、SOS行はgraphics側専用?)。
-  TCG harnessは virtio-scsi/scsi-hd のみ。OCI実HW=NVMe/OCI pv drivers。
- 原生test#6準備Complete(実ディスク、sdbマウント解いてsync済):
-  sdb3: System32\winload.efi = WIM era (a4b3f4d2) / 旧1742はwinload.efi.1742bak
-  sdb1: BCD = v4(75137efe), startup.nsh=V9チェーン intact, bootmgfw原版
-  NVRAM: BootNext=0005(EFI Internal Shell→startup.nsh V9→rdchk→bootmgfw)
- 期待: OCI実HW+実NVMeでは430要因が消える可能性大。
-  -> bootしたら WinRM 5985 / RDP 3389 をホストから確認。
-  -> 失敗時: OCI インスタンスのコンソール接続 = 仮想シリアル。EMS=onなので
-     winload SOS行がライブで読める!! 画面/スクショ乞う。
- 次一手(430原生再現時): SYSTEM hive Services の vioscsi/storNVMe/viostor
-  Start型をオフラインhivexで点検、boot critical化/ドライバ追加投入。

### §22.28 (続9) ★★真の元凶発見: BCD内の分区番号が実在しない partition 6 を指していた
- 実機#6（era合致winload+a4b3f4d2・v4 BCD・BootNext=0005）も 0xc0430001/ESC回復不能。
- ISO pristine BCD（16KB）比較: {bootmgr} に11000001自体なし、OS path=\windows\system32\boot\winload.efi、ramdisk参照型。timeout=30。
- hivex生デコード（bcdobj.py）で决定性発見:
  v4 BCD の全 device element（88B stream: [disk GUID 16B]+[partition DWORD@16…]+参照GUID列）が
  **partition=6** を指す。実GPTは 1(ESP)/2(MSR)/3(Windows) の3分区のみ（parted確認）。
  → bootmgrはOSボリュームを解像できず era非依存で一律430。WinRE参照もpartition6でESC回復不可と整合。
- partfix.py（字节16-19のみ書換）: {bootmgr}.11000001→01、{cd6}×3/{cd7}×2/{cd9}.31000003→03、
  {cd8}はオブジェクト参照型（part=00、{cd9}経由）で不変。**bcd.v7**（8be1323f…、61440B、全8B/88B检验済）。
- 実ESPへインストール済（BCD=v7。バックアップ BCD.bak-v4-prepart 生成済）。
- TCG run J（cowk=修正bcd+era-match winload+V9chain）: **430消滅**、新エラー=
  File:\Windows\System32\winload.efi Status=**0xc00000dd**（STATUS_INVALID_IMAGE_FORMAT）。
  bootmgrのデバイス解像成功が確認。ddは virtio/TCGスタック限定の可能性大（同一ファイルはISO抽出SHA1一致済）。
- ★次の一手: 実機リブート（BCD v7+a4b3 winload の現実盘がそのまま本命構成）。ddなら 
  12000002 を \Windows\System32\Boot\winload.efi(1742 fa9a) に切替検証。winload起動後は 
  OCI NVMe/virtio boot-critical ドライバ（离线SYSTEM hive）が次の戦場。

### 22.29 BCD 要素の正格フォーマットと KD debug 起動への道（run S–AA、2026-10-26）
- run 一覧: S(v13)/T(v7b era張替)/V(v7e)/W2 = 全て 0xc000000d 維持 → era/枝葉要素理論は死んだ。
  U(v7d: 12000004へ文字列誤設) = **0xc0000024 invalid object** 初観測 = bootmgr は BCD 要素スキーマを検証している。
  X(v7f: debug要素群を fmt5=8B int / bool=8B で注入) = 0x24。Y(v7g: boolを4Bに) =仍然 0x24。
  Z(v7h: **ネイティブt=3エンコーディング**) = 0xd に戻る＋**エラー画面が新形式「File: \\Windows\\System32\\winload.efi / Status: 0xc000000d」に変化**。
  AA(v7i = Z + DebugType=0x1AF4 + KernelDebugPath=\\Windows\\System32\\kd.dll) = 結果待ち。
- **hivex 実測真実**: 要素値は value の生バイトが全て。このストアの全既存要素の type は **3**、
  boolean は **1バイト 0x01**、integer は **8B LE**。hivex value_type() のタプル (a,b) で b=3 が実type。
  4B/8B bool や fmt6 誤読(v7f/g)は bootmgr が invalid object(0x24)で弾く。**bool=1B・int=8B・t=3 が唯一の正解**。
- **run Z の大発見**: debug要素を正格形式で置くと 0xd が「required file is missing」の意味になる =
  DebuggerType=0(serial) は **kd_0C11.dll をハードコード要求 → ISOイメージ System32 に実在せず → winload の KD transport 読み込み失敗 = 0xd** という因果が確定方向。
  つまり元々の v7 系 0xd も「winload が要求する何かのファイル不足」線が濃い（画面形式がちがうが同款か要検証）。
- ARM64 26100 イメージの kd DLL: kd.dll / kd_02_(10df,10ec,1137,14e4,15b3,1969,19a2,**1af4=virtio**,8086) / kd_07_1415 / kd_8003_5143 / kdcom / kdcpw / kdhvcom / kdnet(_uart16550) / kdstub / kdusb（すべて \\Windows\\System32）。
- 要素ID権威表の出典: sysprogs/BcdLib/BCD.h と DiscUtils WellKnownElement.cs（fetch済・summary収録）。
  22000013=**KernelDebugPath(文字列)** / 260000a0=KernelDebug / 260000a1=HalBreak / 16000010=DebuggerEnabled /
  15000011=DebugType / 15000013=DebugPort / 15000014=DebugBaud / 15000018=DebugStartPolicy / 260000b0=EmsEnable / **26000091=SOS** / 26000090=BootLog。
- bcdobj.py の 'GUID:' 表示は t=3 の cosmetica なラベル（実体はint/bool）。注意。
- 恒久物: $HOME/tmp/bcd/{bcd.v7g(壊),bcd.v7h(debug正格),bcd.v7i(virtio kd)}, bcdobj.py, wlim2(=ISO era bootmgfw 5384)。
  /tmp/wlt/{cowt..cowaa, rS..rAA}(再起動で消える)。実 disk ESP には今も ISO era pair + BCD=v7 + .oldera/各種bak。

### 22.30 run AB–AM: BCD 分岐全系譜 • TCG 下 bootmgr UI キーボード deaf • ネイティブ実験に備え bcd.am 導入（2026-10-26）

**AB (v7s=実ディスクGUID刻印)**: 0xc000000d  unchanged。実GPT GUID(00010000-...)+part3でも 0xd。GUID理論 DEAD。
**AC (v7t=16000048 integrity-disable, {bootmgr}+{cd7}両方)**: 0xd 不変 → integrity 説 DEAD。
**AD (v7u=winloadQ.edi 偽パス・オラクル)**: **偽パスを画面に出したまま同じ 0xd** = bootmgr は winload を開く前（パラメータ構築途中）で失敗確定。パス実在性は 0xd と無関係と判明。
**AE/AG (v8 / v8w＝ISOテンプレBCD, bootmgfw=wlim2 era)**: メニュー無し・エラー無し・**無音 ResetSystem2 Shutdown**。BCD読込(Open 'BCD' Suces)まで正常、直後に終了。
**AH (v8v=v8w+DisplayBootMenu+DisplayOrder={7619dcc9}+timeout30)**: **初めてメニュー画面まで生きて到達**（8分存活）。QMP sendkey ret/down/f10/esc 全部 {} 成功返すも bootmgr が無視。→ **TCG+このEDK2では bootmgr は UI で USB キーイベントを受け取れない**（Shell では効くのに）。
**AJ (bcd.orig=10/2024インストール時無改造, as-is)**: メニュー待ちで存活・無音・キー deaf（AH 同族）。orig の device=**88B ゼロGUID + partition 6**（イメージ元は6番パーティ構成）、{cd8} recovery=200B ramdisk 構造＋Winre.wim、25000004=30。
**AK (v8w+menu off)**: AE/AG と同型 即無音 Shutdown。
**AL (bcd.op=orig+menu off)**: 無音存活（終了も起動もしない）。
**AM (bcd.am=AL+part 6→1/3 のみ最小刻印, md5 adb042d1)**: 無音存活・File/Status 行なし・kernel起動無し。10分 timeout kill。
→ 系譜結論: **v7系(自作BCD)=0xd画面 / ISO・orig系=無音終了 or 無音ハング**。TCG+OVMF の empty-NVRAM bootmgr は winload を起動し得ない（UI経路はキー deaf で閉鎖）。0xd の原因は BCD 中身のパラメータ構築失敗だが、要素を何に変えても動かず。残仮説=**NVRAM Boot####/BootCurrent が実在するネイティブ環境でのみ解決する何か**（bootmgr の current-boot-entry 検査）。

**ネイティブ実験 arm 済（要 user OCI reboot）**:
- 実ESP BCD ← bcd.am（menu off・インストール時オブジェクト・part 1/3）。バックアップ: BCD.bak-preAM-2026-10-26（直前=v7 8be1323f、他 bak-* 一式済）
- bootmgfw=26b200d（ディスク era のまま）・startup.nsh V9（ESP直下の bootmgfw.efi 起動経路）・**BootNext=0005 セット済**
- ロールバック: `sudo -n cp /tmp/espp/EFI/Microsoft/Boot/BCD.bak-preAM-* /tmp/espp/EFI/Microsoft/Boot/BCD`
- 全 TCG ログ保存: $HOME/tmp/wltlogs/all.tgz（cow/qcow は再起動で消える前提）

**分岐予測**: ネイティブで winload 起動→INACCESSIBLE_BOOT_DEVICE 類なら次=SYSTEM hive offline で vioscsi/storNVMe/viostor ブート可能化。ネイティブでも 0xd/無音なら bootmgr(26b200d) と BCD の世代ミスマッチ疑い→WinRE の bcdedit /store offline 路径。

## 22.31 native 0xd ブレイクスルー + era-proxy 法則 + デバイス schema 解明 (2026-10-26)

- **native v7 = 初の bootmgr 画面実写**: File:\Windows\System32\winload.efi / Status:0xc000000d
- bcd.am3(orig family+menuON) native = 無変化(silent)。BCD.LOG1/2 はゼロ継続 = winload 未実行
- **era-proxy 法則**: TCG+wlnat(ESP era bootmgfw pair)で native と同種結果を再現 (AQ=v7→0xd 完全一致)
- era bisect: v75→silent-shutdown / v77(8B timeout)→silent-alive / v7cd-off→0xd / swap1c(str)→0xd(File行は変 more) / v7esp(ESP-FAT dev)→0xd
- → 0xd は path 文字列・partition・GUID 表記・file 実在に非依存。デバイス解決そのものが失敗
- GPT 調査: LBA1 ヘッダ mylba=last / last LBA ヘッダ mylba=1 = **両ヘッダ位置入替**(OCI クローン由来)。
  kernel/EDK2 は寛容で分区読める。fdisk type=dos 化。DiskGuid(hdr@56)=2aaaf8ce-97cd-4c62-bf50-518cad9d50f5 = BCD GUID2 と完全一致
- BCD デバイス schema 解明:
  - 88B form: hdr@0(zero),objtype@16(1=bm,3=os,6=?),0x48@24,**partGUID@32**(mixed),**diskGUID@56**(=GPT DiskGuid mixed),path なし
  - 176/200B form: ownGUID@0,ver@16,len-16@24,3@32,1@56,dpregion@60(120/144),@64=5,@68=5(ISO)/6(AM),48@80,(AM: partGUID@85,diskGUID@106),**path utf16@134**
- TCG 追加実験: v7be(BE-GUID)→0xd / v7g2(GUID2=part3)→0xd / v7disk(GUID2=MBR混線)→0xd / v7ff(v8w form移植,ISO dev)→**0xbb** NOT_SUPPORTED
  / v7ntfs(AM GUID spec+winload path)→**0x0f** NO_SUCH_DEVICE / v7bf(f60=134)→0xf / v7verbatim(実 cd8 200B 無加工)→**0xd**
- ★重要な限界: 実 OCI で動作した 200B verbatim が virtio TCG で 0xd = **era-proxy はデバイス層(virtio⇔NVMe)で忠実でない**。
  device resolution 判定は NATIVE のみがオラクル。ISO era bb / AM era f = form 階層ではprogressiveだが解なし
- **ESP 現 bcd.v7ntfs**(59f9b769…)- native oracle 投入済。backup: BCD.bak-preV7ntfs-*。BootNext=0005 arm 済
- 次の一手: native reboot → v7ntfs の画面テキスト採取。0xd なら 88B verbatim(実 {cd6} 構造)+12000002 winload で追加 trial

## 22.32 BE1/CF/CI 除外完了と winload 正常性証明 (2026-10-26)

- BE1 (bcd.v7embed: 88B device blob + winload path を blob 末尾へ追記,

  len@24=0x88) → era-proxy で File: winload.efi / Status 0xc000000d。

- CF (bcd.v7fat: 両GUID→sdb1 ESP GUID 057542d2.., winload.efi を

  FAT/ESP \Windows\System32 へ実コピー) → 同じく 0xc000000d。

- CI (bcd.v7d2: sfdisk製の完全な正常GPT+FAT32 64MB disk d2.img,

  disk GUID=77777777.. part GUID=12121212.. (byte-symmetric), 実winload,

  12000002 path=\Windows\System32\winload.efi 確認済) → 同じく 0xc000000d。

- → 除外: ディクラレイアウト/NTFS/GPT header swap/FAT vs NTFS/GUID

  byte-order/embedded-path form。すべて無罪。

### winload 側の正常性
- sdb3 winload.efi: PE32+ Machine=0xAA64 Subsystem=16 NumRvaAndSizes=16,

  data dirs は opt+112 (PE32+ 基準). CERT@0x2f800..(dir4) BASELOC dir5

  0x342000+0x1824 (=SizeOfImage 0x344000 境界と一致) EXCEPTION=.pdata.

- sha256 cce44a3b..5c7e = tiny11.iso boot.wim index2 の winload.efi と

  完全一致 → ファイルは無傷。NTFS も ntfsinfo Volume Flags 0x0000 クリーン。

### 歴史スキャン (30 ser.log 全部, $HOME/tmp/wltlogs/hist)
- **bootmgr が歴史上どの run でも単一の image も LoadImage 成功したことが

  ない** (wim も含む)。過去の menu 表示(segoe_slbot フォント)は bootmgr

  本体の描画であり bootmgfw は firmware/GRUB/Shell によりロードされたもの。

  → 0xd は bootmgr の LoadImage 経路そのものが常に失敗していることを意味。

### gptfix.py
- ヘッダ本文 swap + pte_lba を各自元の値に保つ方式は kernel が拒否

  (parted: primary/backup とも corrupt)。canonical は primary header も

  末尾 pte_lba を指す。→ gptfix ルートは封印 (run2.sh 併用不可)。

### wltest.efi (次段階の準備・完成)
- 趣旨: EDK2 内で BS->LoadImage(winload buffer) を直接呼ぶ gnu-efi app。

  成否で bootmgr ロジック障害か firmware/loader 障害かを分離する。

- 出力は EFI_SERIAL_IO_PROTOCOL (GUID BB25CF6F..) へ直接 Write。

  ConOut/ramfb は ser.log に出ないため必須。

- ビルド成功 recipe (binutils 2.46 の ld PE出力 assert 回避):

  1) gcc -I/usr/include/efi{,/aarch64} -O1 -ffreestanding -fno-pic

     -fshort-wchar -mgeneral-regs-only -c wltest.c

     ※ gnu-efi 4.0 は main ではなく efi_main という名前が必須

  2) gcc -nostdlib -shared -Wl,-Bsymbolic

     -Wl,-T/usr/lib/elf_aarch64_efi.lds -o x.dll crt0-efi-aarch64.o x.o

     /usr/lib/libefi.a /usr/lib/libgnuefi.a $(gcc -print-file-name=libgcc.a)

     → ELF PIE (PE ヘッダなし)

  3) $HOME/edk2/BaseTools/Source/C/bin/GenFw -e UEFI_APPLICATION

     -o x.efi x.dll → PE32+ EFI application ARM64

  ※ --oformat=pei-aarch64-little 直接リンクは ld 2.46 が

    elfnn-aarch64.c:5037 assert で全滅 (binutils regression)。

    GenFw 経由が正解。lld-21 は --oformat=coff 非対応で useless。

- wlrun.sh (/root): cow + d2.img attach + ESP \EFI\Boot\bootaa64.efi を

  wltest.efi に置換 + ESP \Windows\System32\winload.efi 配置。

  control として \EFI\Microsoft\Boot\bootmgfw.efi も LoadImage 試行。

  出力: FS枚数, W open=/r=/l=/sz= , C open=/r=/l=/sz= (hex).

- WL1 実行中 (nbd15)。

### 22.33 WL2-WL11 + ERA12/14: winload LoadImage 拒否の真犯人 = PE Subsystem=16 (判明!)

- gnu-efi 路线全滅の記録(WL2-WL9): LD_LIBRARY_PATH 無し exec=ELF ld.so 死 / PL011 MMIO 直書き不可( firmware が SERIAL_IO 経由で所有者確保)/ stderr=0x19 未接続 / ConOut 0x0E 無し / DebugPrint(0x8e) import だけで Build 成功もし実行死 / ph 変数 BSS 衝突(0xBssMainStackCookie と ph が ambas 8B 干渉= 0x70000→0x71600 へ移設で解消)/ EFI_FILE_MODE_CREATE 必須(WL10 初回: 旧wltest.log が残るだけ)。**gnu-efi apps では遊ばない。EDK2 内蔵アプリが正解**。
- **EDK2 内蔵 WlTest .recipe(確立)**: $HOME/edk2/OemPkg/WlTest/{WlTest.inf,WlTest.c} + ArmVirtQemu.dsc 末尾 [Components.AARCH64]。**この EDK2 ツリーは新しく GCC5 宣言廃止= build -t GCC5 は "Tool chain not defined" で失敗。-t GCC + GCC_AARCH64_PREFIX=aarch64-linux-gnu- が正**。增量 build ~9-56s。=output Build/ArmVirtQemu-AArch64/DEBUG_GCC/AARCH64/OemPkg/WlTest/WlTest/OUTPUT/WlTest.efi。 DebugPrint はアプリ文脈だと serial に出ない( silent )。→**出力は ESP 直書き wltest.log ファイル**(delete-then-create + vol->Open(EFI_FILE_MODE_READ|WRITE|CREATE))。run 後 cow の nbd0p1 mount→sudo cat /tmp/e2/wltest.log。
- **WL10 判定(supervisor 回答)**: winload C:\Windows\System32\winload.efi open=Success rd=Success sz=0x301ed8 **ld=Unsupported(0x800000000000000a)** / control bootmgfw ld=Success。
- **真犯人( EDK2 ソース直)**: MdeModulePkg/Core/Dxe/Image/Image.c L605-640: ImageType switch が EFI_IMAGE_SUBSYSTEM_EFI_APPLICATION(10)/BOOT_SERVICE_DRIVER(11)/RUNTIME_DRIVER(12) のみ受理、**default: IMAGE_ERROR_INVALID_SUBSYSTEM → EFI_UNSUPPORTED**。winload.efi の Subsystem=**16**(=EFI_ROM enum; Windows は UEFI PE に 16 を使う歴史的事実)= 旧 ampere firmware も同等ロジック=**全 era/era bootmgr の 0xc00000bb/0xd はこの拒否の伝播だった**。bootmgfw=10 なので通る。winload.exe の UEFI 版(=winload.efi)を固件 LoadImage する設計自体が ampere EDK2 と不整合、ただし—
- **WL11 実証(パッチ有効)**: offset 0x134(e_lfanew 0xd8+20+68+4=Subsystem field)の Subsystem **16→10** に2byte改変(/tmp/wlload10.efi sha 6ced020023ce, 3156408B 同サイズ)→ **WL11: ld=Success!**。**実 sdb1 へ恒久安装**: Windows/System32/winload.efi + winresume.efi + EFI/Microsoft/Boot/winload.efi(全部 wlload10 同一物), /tmp/wlref/winload.efi=PATCH済(元は ISO sha cce44a3beddbfb9a から再生成可), wlrun.sh は以後 PATCH済を ESP に置く。
- **ERA12/13/14( patched winload 済 BCD 実験)**: ERA12=BCD 元(v7ntfs)→ bootmgr 起動、画面 **"required device isn't connected" 0xc000000f**。ERA13=同じ。ERA14=**bcd.v7wl10=v7ntfs 内 sdb3 GUID 17箇所を sdb1 GUID に全置換**+ESP 側に全 winload 経路(\Windows\System32\, \EFI\Microsoft\Boot\ winload/winresume)実置→ **依然と同画面 0xf**。**解釈**: この EDK2 build には **NTFS ドライバ無し**(FAT only)= v7ntfs BCD の osloader device(sdb3)が視えず 0xf、は筋が通るが、sdb1 置換で解消しないのは **{default} エントリが別レコード/別要素( path 指定や bootstatus/recovery 系)を参照している**可能性。**未完**: BCD レジストリ( REGF)レベルで default={9dea862c-...} の 0x21000001(device)/0x21000002(path) を厳密特定→ 置換。または EDK2 FatDxe+Image.c に DEBUG_ERROR print を入れて era 実行→ **bootmgr の FAT open 失敗パス名/LoadImage 呼びの有無を serial 実測**(最有力の次手)。
- 副次観察: ERA で firmware log に "Loading driver ... bootmgfw.efi" 直後に画面 0xf = bootmgr は起動完了、失敗はその後の config/winload 解決。FvMain 99%(8B free)= これ以上 DXE 追加は FV 拡張必要。

### 22.34 ERA15 結果 + 最重要リード: era9b 成功BCD の再遂 (era16 で最有力)

- ERA15 = bcd.v7wl15(v7wl10+**sdb2 GUID 置換を試みたが BCD 内 0 occurrences**=v7 BCD に sdb2参照なし)= ERA14 と同一の 0xc000000f "required device" 画面。**v7 系 BCD の device GUID 操作(sdb3→sdb1 ×17)では 0xf は動かない**と確定 = 犯人は partition GUID 解決之外 (disk signature 参照/BCD integrity fallback/別ブランチ) の可能性。
- **決定的対照(再確認済)**: 旧 **era9b run = bootmgfw 起動 + winload FAT open 成功 + firmware LoadImage 拒否(0xd 系到達)= winload 読み取り自体は成功していた**。その era9b 使用 BCD = **/tmp/wlt/era9bwinboot.qcow2 の ESP 埋め込み BCD**($HOME/tmp/bcd/era9b.bcd として抽出済)。**winload は今や subsubsystem 10 に patch 済みで sdb1 FAT 常駐** = **ERA16 = run1.sh で era9b.bcd を使用该成功環境の完全再現 = winload 通過の最有望ルート**(0xd 要因はパッチで消除済み)。
- 対比の変遷: era10(era9b成功後の installed BCD=era10.bcd, winload 非patch常駐)= 0xc00000018 / ERA12-15(v7 BCD 系, winload patch済)= 0xc000000f。era10 の 0x18 解析(FWがB C D をどう解釈し何の image を拒否したか)も未。
- 未実施の次々手候補: (a) EDK2 DirectoryManage.c/DirectoryCache の FatLookup 失敗 DEBUG_ERROR print + FV再build で bootmgr の FAT open 失敗パス名を serial 実測 (b) blkid -s PTUUID の **disk-level GUID** が BCD を参照していないかの GUID scan (c) winload の **winre/wdiLoader レコード**(0xec2f/0xa112 群)を BCD から丸ごと削除して recovery 分岐を無効化。
- 教訓: grep -P(UTF-16抽出)は当hostで無反応。python re で `(?:[\x20-\x7e]\x00){n,}` 抽出は動くが bootmgr 画面は interleave 全角化文字列でヒット薄い。**screen 内容確認は `sudo strings ser.log` の decode 済み出力で**。BCD GUID 操作は uuid.UUID(bytes_le) の bytes 一致のみ。run1.sh は BCD を引数で ESP に置くだけ(実 disk不変)。

### 22.35 黒画面 native #N の forensic と sdb3 winload patch 投入 (2026-10-26 23:30)

- user 試走(=-n 0000 reboot, ~23:25)= 全面無出力的黑。周辺実測:
  - **ESP へ 22:00 以降の書込ゼロ**(BCD.LOG1/2=0B@2024 不変)= 今回の boot では bootmgr/shell の BCD 更新動作なし。rdchk/v9*.txt は 22:21 の自走分。
  - **sdb3 winload.efi mtime=23:21**(再起動直前)かつ sha=**cce44a3b=原版**。user が起動直前に sdb3 winload を原版へ戻した行動と整合(=「変わらず」テストの前提復帰)。
  - _installed_ BCD md5 4cec1d3e = **bcd.v7ntfs そのもの**(v7wl10/15 は未インストール=run1.sh は cow のみ。私が誤認した)。
  - pstore(efi_pstore)=**空** → ネイティブ firmware は ELF/ConLog を残さない。**事後ログ不存在、観測は OCI console connection ライブのみ**。
  - **Boot0000=BootManagerMenuApp(FW ユーティリティ)** + BootOrder=0006(Linux)...。**user の -n 0000 は menuアプリ起動で実際には Windows 不開始の可能性高**(=黒無出力の説明候補)。正解は **BootNext=0005(Shell→startup.nsh V9→ntfs driver load→bootmgfw)** = 文書化済連鎖。
- 投入済(user リブート待ち): **sdb3\Windows\System32\winload.efi = /tmp/wlload10.efi(Subsystem10, sha 6ced020023ce) 置換**。backup winload.efi.orig16(cce44a3b)同階層+1742bak 温存。BootNext=0005 set。sdb1 側 3 経路は patch済のまま。BCD=v7ntfs(sdb3 dev 参照)据置 = **firmware が NTFS/sdb3 winload を読みに行く構成そのものに patch 弾を装填**。
- 分岐読解: (a) winload 段の画面(File/Status)や SOS/ロゴ=**native FW も Subsystem10 受理=era ブロッカー確定除去**、次は ntoskrnl/boot driver(vioscsi/stornvme offline 点検済用地雷)。(b) 依然無音黒=黒は winload LoadImage より前(連鎖切断か bootmgfw 前段)→user のトリガ手順確認と startup.nsh echo 痕跡(V9-START がシリアルに出るはず)で切り分け。
- 手順依存の未確認事項: 過去 native 画面実写(0xd)がどのエントリ経由か不分明(-n 0000 表記だが menu では出せないはず=当時の実トリガを user に確認要)。

## 22.36 native CI 修正の実投入 (2026-11-07)

- 実 sdb3 の CodeIntegrity は **2024-era WOF placeholders 11個**(実体34B reparse)で winload からは stale/不能 = native 0xc0430001 の原因と確定。TCG の CI 修正は **2026-era 実ファイル13個**(/tmp/wimci2: boot.stl, driver.stl, driversipolicy.p7b, previous.driver.stl, VbsSiPolicy.p7b, CIPolicies/Active 8cip)で 0x430→0xf に前進済。
- 実 sdb3 winload は §22.35 の sub10 patch (5d54a092) のまま。TCG v4bcd/ck で **patch 済 winload は bootmgr が 0xd で拒否**(modified image)。orig16 (14e805cd, sub16) は TCG v4 と native#6 で winload 到達済 = **orig16 を採用**。
- 実fix 投入 (backup 済):
  - sdb3: winload=orig16 (旧 patch は winload.efi.patched10-20261107-184439)、CodeIntegrity=2026 13ファイル (旧は CodeIntegrity.old-20261107-184439)、drivers=WIM 323実ファイル、SYSTEM に storport/WdfLdr (Start=0, Tag=1) 追加 (SYSTEM.bak-nativefix-20261107-184439)、hvloader.dll/skci.dll=WIM 2026、securekernel は既に WIM と同一 (ab8308c4)。
  - sdb1: BCD=bcd.v4 (75137efe, backup BCD.bak-nativefix-20261107-184439)、CIPolicies/Active=wlim2 3cip (旧 backup Active.bak-20261107-184439)。
- BootNext=0005 (Shell→startup.nsh V9) 設定済。user native reboot 待ち。
- 観測点: V9-START echo / bootmgr 画面 (File/Status/Info) / Windows logo / 0xf 再発なら device 層 (era9b BCD ルートへ)、0xd なら v4 か winload、無音黒なら連鎖 (v9*.txt)。

## 2026-11-10 最終反映 (26100.1742 セット)

- 実ディスク /dev/sdb へ 1742 セットを反映した。
  - SYSTEM: /tmp/SYSTEM_195_min (seq 196/196, Services\WdfLdr 削除,
    CI\Policy\VerifiedAndReputablePolicyState=0,
    CI\Protected\VerifiedAndReputablePolicyStateMinValueSeen=0)
  - バイナリ 10 個: ntoskrnl 1742, ci.dll 1591, winload.efi 1742,
    symcryptk.dll, WdfLdr/Wdf01000 1301, dxgkrnl 1742, hidparse 1150,
    pdc/vpci 1591
  - CodeIntegrity: オーバーレイの 1742-era セットへ置換
  - DRIVERS/SOFTWARE/DEFAULT/SAM/SECURITY/ELAM は実ディスクのまま (seq clean)
- 実 ESP/BCD は変更していない。実 BCD の実測 md5 は
  75137efea88e46298e139a4b30ae4914 (61440 bytes)。
  以前の記録 db786a2d... は現物と不一致だったが、この BCD のまま
  TCG 起動に成功した。
- バックアップ:
  - /tmp/real_backup_20261110
  - /dev/sdb3 内 win11arm_backup_20261110 (README.txt 付き)
- 検証:
  - 実ディスクを backing にした使い捨て qcow2 (/tmp/wlt9/real_final_test.qcow2)
    で TCG 8GB 起動 -> winlogon.exe / dwm.exe / win32k 系 146 modules 確認
  - 反映後、実ディスクを backing にした qcow2
    (/tmp/wlt9/real_postapply_test.qcow2) でも再確認 -> winlogon 到達
- 現在 /dev/sdb は rw、未マウント。ネイティブ再起動はユーザー操作で実施。

## 2026-11-10 V10: 26100 boot manager チェーンで QEMU ログイン到達

- 目的: ネイティブ V9 が 26089 rebase `bootmgfw.efi` を経由していたのに対し、
  QEMU 成功経路は ESP の `\EFI\Boot\bootaa64.efi` (26100.1041, SizeOfImage 0x2C9000)
  を直接起動していた。世代不一致を潰すため、V10 シェルチェーンを検証。
- V10 `startup.nsh` (md5 5a82f05a7670bf249d0d8035b283c61e):
  `map -r` → BCD を持つ fs を fs0..fs3 から探索 → `\EFI\Boot\bootaa64.efi` (26100)
  を起動 → 戻ったら `\EFI\Microsoft\Boot\bootmgfw.efi` にフォールバック。
- QEMU TCG 検証 (win3.sh v10, 実 /dev/sdb の COW, virtio-scsi+virtio-gpu, 8GB):
  - シリアル: `..V10-ESP-fs1` → `FSOpen: Open '\EFI\Boot\bootaa64.efi' Success`
    → `SizeOfImage=0x2C9000` → BCD/CIPolicies → bootstat.dat → Fonts。
  - 05:51 に Windows ログイン画面を screendump で確認。
  - overlay 検査: `LOGONUI.EXE-F639BD7E.pf` 21:51:38 (guest)、
    System.evtx 21:48:19、Security.evtx 21:47:47、ntbtlog.txt 21:51:43。
    → winlogon/LogonUI 到達確定。
  - 証拠: work/backup_20261110/v10_evidence/ (f.v10, login_screen.png,
    inspect_v10.log)、overlay は work/harness/ov-v10.qcow2。
- 実 ESP へ投入:
  - 全 ESP バックアップ: work/backup_20261110/esp_backup_20261110/
    (esp_full_20261110.tar 54MB, md5_esp_full.txt 159 files)
  - V9 startup.nsh を `startup.nsh.bak-v9-20261110` として ESP 内に保存
    (md5 10f8295d5355dab08a913e263c1b9b83)。
  - V10 startup.nsh を ESP 直下に配置 (md5 5a82f05a..., テスト済みと同一)。
  - /dev/sdb は rw に戻し、全パーティション unmount 済み。
- UEFI Shell の startup.nsh 自動実行根拠:
  - V9 痕跡で Linux ESP (fs0) に rdchk.log、Windows ESP (fs1) に v9l1.txt。
  - Shell は PATH 探索で fs1 の startup.nsh を自動実行していた。
  - V10 も同じ経路 (fs0=Linux ESP に BCD なし → fs1=Windows ESP の BCD を検出)。
- BootNext=0005 (EFI Internal Shell) を設定済み。
  BootOrder=0006,0002,0000,0001,0005、BootCurrent=0006。
- ネイティブ起動後の自動確認手段:
  - SYSTEM に `WinArmsvc` (Start=2, LocalSystem) が残存。
    `powershell -File C:\winarm\setup.ps1` を実行。
  - setup.ps1 (md5 c3556caed6efacc5f6fae4a601bb86e7) は 60 秒後に
    VirtIO NIC を <private-ip>/24 gw 10.0.0.1 に設定、DNS 169.254.169.254/1.1.1.1、
    Administrator パスワード `REDACTED`、RDP 3389/WinRM 5985 を有効化。
  - ログ: `C:\winarm\log.txt`、metadata: `C:\winarm\meta-instance.txt`。
  - TermService Start=2、fDenyTSConnections=0、RDP-Tcp UserAuthentication=0。
- 次の観測点 (ネイティブ):
  1. シリアルに `..V10-START` / `..V10-ESP-fs1` が出るか。
  2. Windows boot manager の SOS/EMS、ロゴ、その後ネットワーク。
  3. <private-ip>:3389 (RDP) / 5985 (WinRM) / C:\winarm\log.txt。
  4. 失敗時は power-cycle で Linux 復帰 → ntbtlog/EventLog/Prefetch/SYSTEM を検査。

## 2026-11-10 16:30-17:45 修正版 V11: CatRoot 補完 + WinArmsvc 対策

### 判明した真因（ネイティブ V10 の失敗）
- RDP 3389 / WinRM 5985 が開かなかった直接原因:
  - `WinArmsvc` が `powershell -File C:\winarm\setup.ps1` を起動したが、
    SCM の 45 秒タイムアウト（Event 7009/7000, 1053）で PowerShell ごと終了。
  - `C:\winarm\log.txt` が存在しない = setup.ps1 が完了していない。
- ネットワーク難の真因:
  - `nsiproxy.sys`（10.0.26100.7920）の CodeIntegrity 3004 が多発。
  - ファイル自体は WIM と SHA256 完全一致（2e4d297e...）。
  - ディスクの CatRoot は 1742/1150 世代のみで、7920/8036 用カタログが欠落。
  - WIM (tiny11.iso, 26200.8037) の CatRoot 3260 個をマージして解決。
- ディスクの CatRoot は 3.3MB / 2669 個、WIM は 87MB / 4980 個（マージ後）。
- 失敗ドライバは 6725/7309/7705/7920/8036 の多世代にまたがるため、
  WIM CatRoot 全体のマージが必要。`oem*.cat` は保持。

### QEMU TCG 検証（2026-11-10 17:00-17:20）
- overlay `work/harness/ov-fix.qcow2`（backing /dev/sdb）
- SYSTEM ハイブを hivex で `cmd.exe /c bootstrap.cmd` に書き換えたところ、
  **Windows がログオン画面まで到達せずカーネル初期化で停止**（CPU 0%、書き込み停止）。
  - 原因: 元ハイブが dirty（seq 216/215, flags=0x1）で、hivex が seq 217/217 に
    したが flags=1 のまま。古い SYSTEM.LOG1/LOG2 と不整合になった可能性が高い。
- SYSTEM ハイブを元に戻すと、同じ CatRoot マージ状態で **ログオン画面まで正常起動**。
  - CodeIntegrity 3004 はこの起動で **0 件**（前回は多数）。
  - DHCP Client が正常動作し、QEMU user-net の 10.0.2.15/24 を取得。
  - ACPI 電源ボタン（monitor `system_powerdown`）で正常シャットダウン
    （VM status: paused (shutdown)、Event 6006/109）。
- つまり **CatRoot マージは有効、SYSTEM ハイブのオフライン編集は危険**。

### 最終方式（V11）
- SYSTEM ハイブを編集しない。ImagePath は元の powershell setup.ps1 のまま。
- `C:\winarm\setup.ps1` をランチャーに差し替え、`setup2.ps1` を独立プロセスで起動。
  - QEMU TCG では PowerShell 起動に約 30 秒かかり、45 秒制限に間に合わなかった。
  - ネイティブでは高速だが、検証可能性のため cmd.exe 方式も並行検討。
- cmd.exe 方式（最終候補）:
  - SYSTEM をクリーンな seq 272/272, flags=0 の状態で hivex 編集し、
    ImagePath を `cmd.exe /c C:\winarm\bootstrap.cmd` に変更。
  - SYSTEM.LOG1/LOG2 を削除。
  - bootstrap.cmd が `WinArmSetup` タスク（onstart, SYSTEM）を作成・即実行。
  - setup2.ps1 が RDP/WinRM/パスワード/ファイアウォール/DHCP を設定し、
    最後に WinArmsvc を disabled にする（次回以降はタスクが起動）。
- QEMU 検証は `ov-fix2.qcow2` / `boot-fix2.img` / `f.fix2` / `mon-fix2.sock`。

### 実ディスク適用時の注意
- `/dev/sdb3` は ntfsfix で dirty を解除してから rw マウント。
- CatRoot / SYSTEM / C:\winarm をバックアップ。
- SYSTEM ハイブは編集しない（cmd.exe 方式を採用する場合のみ、クリーン hive +
  LOG 削除 + flags=0 を厳守）。
- 適用後 `efibootmgr -n 0005` で BootNext を再設定。

### 2026-11-10 18:00-18:45 追加検証

- `ntfsfix` は `-d` を付けないと **次回 Windows 起動時に chkdsk (autochk) を強制する
  dirty フラグを立てる**（man ntfsfix: "schedules an NTFS consistency check for the
  first boot into Windows"）。
  - 新規 overlay の初回ブートが winload 以降で無音停止したのは、これによる
    autochk が TCG で完走できなかった可能性が高い。
  - `ntfsfix -d` で dirty をクリアした ov-fix3 の 2 回目ブートはロック画面まで到達。
- ローカル GPO スタートアップ（gpt.ini Version=65537 + Machine\Scripts\scripts.ini
  + Startup\bootstrap.cmd）は **実行されなかった**。
  - GroupPolicy/Operational に 4115/4116/4117/5320 等はあるが、Scripts CSE
    (42B5FAAE-6536-11D2-AE5A-0000F87571E3) のイベントが無い。
  - bootstrap.log 無し、C:\Windows\System32\Tasks\WinArmSetup 無し。
  - → GPO 方式は不採用（ファイルは置いても無害だが、実ディスクには入れない）。
- ランチャーを最小化: `[System.Diagnostics.Process]::Start(...)` の 1 行 (188B)。
  PowerShell のモジュール自動ロードを避け、SCM の 45 秒以内に子プロセスを
  起動できるか ov-fix3 の 3 回目ブートで検証中。
- ACPI 電源ボタン（QEMU `system_powerdown`）は今回も 70 秒で正常シャットダウン。

## 2026-11-10 19:00-20:05 V11 最終修正（実ディスク適用完了）

### 確定した真因（3 つ）

1. **WinArmsvc の SCM 45 秒制限**
   - ImagePath が `powershell.exe ... setup.ps1` で、TCG では PowerShell の
     起動だけで 28〜35 秒かかり、残り時間で処理が終わらず SCM が
     プロセスを kill（Event 7009/7000, 1053）。
   - 実機でも旧 setup.ps1 は 60 秒 sleep していたため確実に kill されていた。
2. **CatRoot カタログ欠落**
   - ディスクの CatRoot に 7920/8036 用カタログが無く、`nsiproxy.sys` 等が
     CodeIntegrity 3004 でブロックされていた。
3. **`ntfsfix` の dirty フラグ**
   - `-d` なし実行で次回 Windows 起動時に autochk を強制し、TCG の
     初回ブートが winload 以降で無音停止していた。

### 最終方式（実ディスクに適用済み）

- SYSTEM ハイブ: `SYSTEM_cmd.hive`（md5 `aacafef658f7ce669a5adfd2c8c63f8a`,
  seq 285/285, flags 0）に差し替え。
  - `WinArmsvc` ImagePath = `C:\Windows\System32\cmd.exe /c C:\winarm\bootstrap.cmd`
  - Start=2, Type=16, ObjectName=LocalSystem, ErrorControl=1
- `C:\winarm\bootstrap.cmd`:
  `start "" /b powershell ... -File C:\winarm\setup2.ps1`
  - cmd.exe は 1〜2 秒で終了するため SCM に殺されない。
  - PowerShell は切り離された子プロセスとして setup2 を完走。
- `C:\winarm\setup2.ps1`: RDP/WinRM 有効化、Administrator パスワード設定、
  VirtIO NIC の DHCP 確認（失敗時 <private-ip>/24 固定）、OCI metadata。
- CatRoot: WIM 8037 のカタログをマージ（2669 → 4980 個）。
- NTFS: `ntfsfix -d` で dirty クリア（Volume Flags 0x0000）。

### 検証結果

- `ov-fix4`（実ディスク overlay）:
  - `bootstrap.log`: `bootstrap start` → `start rc=0` → `bootstrap done`
  - `log.txt`: `pwd-set-ok`, `admin-enabled=True`, `LISTEN 0.0.0.0:3389`,
    `LISTEN :::5985`, `ip-valid=10.0.2.15`
  - WinRM NTLM 認証 OK、RDP X.224 応答 OK
  - 今回のブートの CodeIntegrity 3004 は 0 件
- `ov-verify`（実ディスクへ V11 を適用した完全コピー、初回ブート）:
  - setup2 が完走し `done.txt` 作成、RDP/WinRM 応答・認証 OK
  - WinRM quickconfig はネットワークプロファイル Public のため firewall
    例外で警告を出すが、setup2 が先に全プロファイルの firewall を無効化して
    いるため RDP/WinRM は動作する（実害なし）。
- 実ディスク `/dev/sdb3` へ同一適用を実行:
  - CatRoot 4980、SYSTEM md5 `aacafe...`、Volume Flags 0x0000
  - バックアップ: `fix_20261110/real_backup_20261110_200127/`
- `efibootmgr -n 0005` 設定済み（BootNext 0005、次回 1 回だけ UEFI Shell）。

### 実機起動の注意

- シリアルコンソールで `..V10-START` / `..V10-MAPPED` / `..V10-ESP-fs1` を確認。
- 起動後 2〜5 分で `<private-ip>:3389` / `5985` が上がる見込み。
- 失敗時は Power cycle → Linux 復帰 → `check_native_v11.sh` を実行。
- 引き継ぎ: `work/backup_20261110/NATIVE_V11_HANDOFF.md`

## 2026-11-11 26H2 向けハーネス検証（tiny11 / 手動 DISM）

### 目的

26H2 ISO 提供前に、QEMU qcow2 へのインストール → RDP/WinRM 検証 →
`/dev/sdb` 書き戻しの経路を確立する。実ディスクは変更しない。

### 実施

- tiny11 ISO（26200.8037 / Pro、UDF-only）を使用。
- AAVMF は ISO を直接ブートできないため、`make_bootfat.sh` で
  MBR + FAT32 の bootfat を作成し、ISO 内の boot.wim を起動。
- 標準 Setup は `DataImage` 9% で停止（`Service winmgmt stop: 0x000005b4`）。
  改造 WinPE 依存を避けるため、boot.wim の Setup イメージの
  `HKLM\SYSTEM\Setup\CmdLine` を `cmd.exe /c manual_start.cmd` に変更。
- WinPE で vioscsi を `pnputil` 注入 → `install.wim` を DISM 適用 →
  ドライバ追加 → unattend/OEM コピー → `bcdboot`。
- OEMDRV は USB CD-ROM（Joliet ISO）。WinPE で確実にドライブ文字が付き、
  diskpart の Disk 0 を占有しない。
- インストール先 qcow2 が Disk 0、bootfat が Disk 1 になることを確認。

### 結果

- qcow2 から UEFI ブート成功。Windows 11 Pro 26200.8037 が起動。
- WinRM は `User` / NTLM で接続成功。3389 / 5985 LISTEN。
- RDP はログオン画面まで正常描画（黒画面ではない）。
- `dwm.exe` / `dwmredir.dll` は 26100.1、`RdpIdd.dll` は 393,216 バイトで健全。
- tiny11 の install.wim は OOBE 完了済みで `C:\OEM` / Panther の残骸を含み、
  specialize が走らず `defaultuser0` が残る。RDP ログオン時に競合するため、
  最終検証は 26H2 のクリーン ISO で行う。

### ハーネスの変更

- `make_oemdrv.sh`: OEMDRV を ISO 化、`image-index.txt` 出力、
  `drivers/`（vioscsi + netkvm）と `drivers-extra/`（viogpudo）に分離。
- `autounattend.template.xml`: `PnpCustomizationsWinPE` 削除、
  `/IMAGE/INDEX` を `{{IMAGE_INDEX}}` に、`PnpCustomizationsNonWinPE` は
  vioscsi + netkvm のみに限定。
- `make_manual_bootwim.sh`: boot.wim / ISO から手動インストール用
  boot.wim を再現可能に生成。
- `manual_start.cmd` / `manual_install.cmd`: install.esd 対応、
  index 外部化、旧 OEM/Panther の掃除。
- `run-qemu.sh`: `BOOTFAT_BUS` の既定を `scsi` に変更。
- `write_sdb.sh`: GRUB を新しい ESP UUID に更新し、古い
  Windows Boot Manager エントリを置き換える。
- `autounattend.template.xml`: `PnpCustomizationsNonWinPE` を
  specialize から **offlineServicing** へ移動。standard Setup 経路で
  vioscsi がオフラインイメージに入らず `INACCESSIBLE_BOOT_DEVICE` に
  なる問題を予防。
- 再チェック（`recheck` VM、新 bootfat / OEMDRV）で WinPE が
  vioscsi を注入し、`E:\sources\install.wim` を検出して
  `manual_install.cmd` のバナー（OEMDRV=D:、INDEX=1）まで到達することを確認。
  DISM 適用前に停止し、`recheck.qcow2` は削除済み。
- 26H2 本番用の容量確保のため、tiny11 検証用 `manual-test.qcow2`（16GB）を
  ユーザー承認のうえ削除。空きは 32GB。`boot-manual.wim` / `bootfat.img` は
  tiny11 用の成果物として残置（26H2 用は再生成する）。

### 次の作業

1. 26H2 ARM64 ISO の提供を受ける。
2. Pro の image index を確認して `make_oemdrv.sh <ISO> <index>`。
3. 標準 Setup を試し、止まる場合は手動 DISM 経路へ。
4. `C:\OEM\done.txt` / `READY rdp=1 winrm=1` / RDP デスクトップ /
   DWM・RdpIdd の健全性を確認。
5. `finish_qcow2.sh` → `write_sdb.sh --yes` → ネイティブ起動。

### 26H2 ホスト側適用（2026-11-11 深夜）

- 標準 Setup は OEMDRV の `autounattend.xml` を検出せず、言語選択 UI で停止。
  手動 DISM 経路の DISM 適用は TCG で約 0.4MB/s と実用外。
- `host_apply.sh` を追加: ホストの `wimlib-imagex apply` で qcow2 の NTFS へ
  直接適用（ACL・ハードリンク保持）。unique data は約 14GiB。
- 最初の失敗原因は `mkntfs -F`。`-F` は「強制」で、クイック指定ではない。
  50GB 全体をゼロ埋めして qcow2 が 29GB まで膨張し、NTFS が空のまま
  ディスクを圧迫した。**`-f -F` が必須**。
- `mkntfs -p <p3 start> -H 255 -S 63` で NTFS BPB のジオメトリを
  Windows 形式（hidden sectors=239616）に合わせる。未指定だと
  「Windows will not be able to boot from this device」警告が出る。
- NBD は `qemu-nbd --connect` 直後に容量が 0 のまま見える競合がある。
  `blockdev --getsize64` が正になるまで待つ処理を `host_apply.sh` に追加。
- 適用後は `ntfsfix -d` で dirty フラグを落としてから WinPE の
  `manual_finish.cmd`（vioscsi/netkvm 追加 + bcdboot）へ進む。

### 起動ループ修復と /dev/sdb 書き戻し（2026-11-12）

- QMP `system_reset` で強制リセットすると、SOFTWARE ハイブの先頭が
  レジストリログ（ElfChnk）で上書きされ、NTFS メタデータも破損する。
  WinPE repair2（chkdsk /f /x + SOFTWARE 復元）で回復。
  **ゲスト再起動は必ず `shutdown /s` を使うこと。**
- WinPE の `chkdsk` はログを X: に出せば完走する（exit=3 は C: ハンドル保持が原因）。
- RDP が約 2 分で切断される原因は RdpIdd.dll（UMDF）ホストのクラッシュ。
  Defender リアルタイム検索＋Windows Update＋TCG の重負荷がトリガ。
  負荷を下げると 10 分以上安定。イメージの不具合ではない。
- `boot.ps1` は boot.lock が 10 分以上古い（または経過時間が負の）場合に
  削除して続行するよう変更。強制リセット後のスキップを防止。
- `hiberfil.sys` は WinPE からは `del` できなかったが、Linux の ntfs-3g rw
  マウントからは削除できる。
- 書き戻しは `write_sdb.sh --yes --no-full-backup` で完了（14:27-14:40）。
  バックアップは `backup/sdb_20261112_142740/`（GPT/ESP/ハイブ）。
  GRUB は ESP UUID 2760-2671 に更新、UEFI は Boot0003 を先頭に設定。
- 書き戻し後の初回ネイティブ起動はユーザーがホスト再起動して確認する。

### live ISO の cloud-init / SSH 検証（2026-11-14）

- Ubuntu 24.04.5 live-server arm64 ISO を QEMU の TCG で起動し、
  `prepare.sh --ssh` と同じ seed（`mkfs.vfat -n CIDATA` + `user-data` /
  `meta-data`）を virtio-scsi のディスクとして渡した。
- cloud-init は `CIDATA` を自動検出し、`ubuntu` ユーザー
  （`uid=1001`, `shell=/bin/bash`, `sudo NOPASSWD`）を作成した。
- live ISO には openssh-server と `ssh.socket` が入っており、seed の
  `systemctl enable --now ssh` が無くても 22 番は listen する。
- `ssh -i <key> ubuntu@<host>` でログインでき、`sudo -n true` も通った。
- TCG では systemd の起動完了まで実時間で 15 分ほどかかった。シリアルは
  `[ 176s] Received client request to flush runtime journal` の後、
  cloud-init の `runcmd` が終わるまで数分沈黙する。
- QEMU の起動には `-machine virt,gic-version=3 -accel tcg,thread=multi
  -cpu neoverse-n1` と AAVMF（`AAVMF_CODE.no-secboot.fd`）が必要。
  `-cpu max` だけでは `PC=0x5200` で止まる。
- `meta-data` の `local-hostname` は live では反映されず、ホスト名は
  `ubuntu-server` のままだった。動作への影響はない。

### 最終イメージの起動検証（2026-11-18）

- `/dev/sdb` の最終構成: p1=Ubuntu recovery (ext4, 4 GiB)、p2=Windows 11
  (NTFS, 45.9 GiB)、p15=ESP (vfat, 99 MiB)。ESP は
  `EFI/BOOT/BOOTAA64.EFI` = shim、`EFI/BOOT/grubaa64.efi` = GRUB、
  `EFI/ubuntu/grub.cfg` = GRUB メニュー。`bootmgfw.efi` は OCI A1 用
  パッチ済み（sha256 `37202f54...`、開始クラスタ 31522）。
- `timeout=1` でキーを押さずに起動 → GRUB の既定 `Windows 11` が選ばれ、
  WinRM が `Microsoft Windows [Version 10.0.26300.9457]` を返した。
- シリアルソケットからメニュー表示直後に Down + Enter → `Ubuntu 26.04.1
  LTS win11-live ttyAMA0` の `login:` まで到達した。
- Ubuntu エントリの無い新しい NVRAM でも、ファームウェア →
  `\EFI\BOOT\BOOTAA64.EFI`（shim）→ GRUB → Ubuntu の `login:` を確認した。
- Windows 初回起動後に BCD へ Ubuntu のファームウェアミラー
  `{c8fa8d61-e318-11f1-baa2-806e6f6e6963}` が再生成された。
  `bcd_remove_ubuntu.py` を拡張し、削除したオブジェクトへの
  `{fwbootmgr}` のダングリング参照も除去。実 ESP に適用し、冪等性を確認。
- `inspect_image.sh` は BCD を直読みして `displaybootmenu=True`,
  `timeout=1s`, `EMS/SAC: unavailable` を表示する。
- 未解決: パッチ済み `bootmgfw.efi` は QEMU で約 68 秒後にゲストが終了する
  （stock は起動する）。OCI A1 実機での最終起動確認は未実施。ESP の FAT
  backup 差分 `offset 65: original 00 / backup 01` も残存（`fsck.fat -a` は
  mostly harmless と表示）。

### Ubuntu emergency mode の修正と fstab の恒久対策（2026-11-20）

- 実機（hostname `<host>`, aarch64）は `--fresh-ubuntu` のレイアウト:
  sda1=ESP(100M, vfat, PARTUUID `5933fc32-...`), sda2=Ubuntu(4G, ext4, UUID
  `28f50ee3-...`), sda3=Windows(45.9G, ntfs, PARTUUID `dc51ffec-...`)。
- 緊急モードの原因は、step 6 が書き込んだ fstab の ESP UUID が step 12 の
  `esp_compact.sh` による再フォーマットで古くなり、`/boot/efi` の device unit
  を 90 秒待つこと。BCD は sda3/sda1 の PARTUUID を正しく参照しており、
  SecureBoot 変数は存在しなかった（有効ではない）。
- 恒久修正:
  - `make_recovery_ubuntu.sh`: `/boot/efi` を PARTUUID +
    `nofail,x-systemd.device-timeout=10s` で書く（FAT volume serial に依存しない）
  - `esp_compact.sh`: 再フォーマット時に FAT volume serial を `-i` で保持
  - `inspect_image.sh`: 復旧 ext4 を ro マウントし、fstab の ESP 指定子と
    最終 ESP の UUID/PARTUUID を比較。不一致または nofail 欠落で警告/失敗
  - `test_recovery_boot.sh`（新規）: 最終イメージから QEMU でカーネルを直接
    起動し、`login:` 到達と emergency mode 非突入を検証。
    `internal/build-image.sh` の step 12 後に実行（TCG は 15 分程度）
  - `finish_disk.sh`: `PATCH_BOOTMGFW=0`（+ `STOCK_BOOTMGFW=<stock.efi>`）で
    stock の `bootmgfw.efi` のまま ESP を仕上げられるようにした。ローカル
    QEMU 比較専用で、最終 OCI イメージには使わない
- 実機の `/etc/fstab` も PARTUUID に更新済み。`daemon-reload` と `mount -a` は
  成功し、`/boot/efi` は sda1 にマウントされたまま。failed unit は
  `cloud-init-main.service` のみ（ビルドとは無関係）。
- **Windows が起動しない原因（最有力）: BCD の明示的 EMS 設定の再発**。
  - 証拠: Windows のイベントログは 2026-11-19 15:47 以降ゼロ（Kernel-Boot 12/27
    は 11-19 の QEMU 2 回のみ、Event 41/1001/6008 ゼロ）。`C:\OEM\boot.log` は
    11-19 15:25 UTC / QEMU の 10.0.2.15 で `READY rdp=1 winrm=1`。
    一方 ESP の `BOOTSTAT.DAT` は 11-20 14:00 に更新 → **bootmgr は実機で
    実行されたが Windows カーネルは一度も起動していない**。BSOD でも
    GRUB 段階の失敗でもない。
  - BCD を直接解析すると `{0ce4991b-...}` に
    `15000022=1`(EMSPORT:1=COM1), `15000023=115200`(EmsBaudRate),
    `16000020=0`、`{bootmgr}` に `16000020=1`(bootems)、Windows loader
    `{58297ee1-...}` に `260000b0=1`(kernel EmsEnable) が存在。
    これは commit `ec9f10d`（11-18）が `oem/boot.ps1` に
    `bcdedit /ems {current} on` / `/emssettings EMSPORT:1 EMSBAUDRATE:115200`
    / `/set {bootmgr} bootems yes` を追加した結果（rc=0 で成功、
    QEMU の LoadOptions にも `REDIRECT` が残っている）。
    commit `3468957` はコメントを「expected no-op」に変えただけだった。
  - §22.21-22.22 の実測どおり、OCI ARM64 のシリアルは PL011 MMIO
    @0x09000000 で、x86 COM1 の I/O ポート 0x3F8 を指す EMS 設定は
    bootmgr/winload を無音ハングさせる。要素削除で初めてエラーページが出た。
  - 対策: `pipeline/bcd_disable_ems.py`（新規、hivex 使用）で
    15000022/15000023/16000020/25000006/26000000/26000001/26000002/260000b0
    を全オブジェクトから削除。`finish_disk.sh` が bcd_remove_ubuntu.py の
    直後に呼ぶ。`oem/boot.ps1` から EMS 設定コマンドを削除し、
    BUILD/DUALBOOT/OCI の「bcdedit /ems は no-op」という誤記を修正。
  - 実機の BCD もバックアップ取得後に編集済み（5 要素削除、
    再オープンで EMS 要素ゼロを確認）。**再起動して Windows を選び、
    VNC で画面を確認する必要がある**（このセッションは再起動で切れる）。
  - その他切り分け結果: GRUB/chainloader は健全（shim/GRUB 一致、
    bootmgfw/grub.cfg の開始クラスタは 14/9/5 で 65536 未満、SecureBoot
    変数なし）。BCD の GUID は sda3/sda1 を正しく参照。CodeIntegrity は
    実ファイルで WOF placeholder は無し。patch 済み bootmgfw の hash は
    `37202f54...` で、`mov w0,#1` が 1 箇所だけ。
  - EMS 削除後にユーザーが再起動しても Windows は起動せず（BOOTSTAT は
    15:48 に更新、イベントログは 11-19 のまま、VNC は真っ黒）。
    → EMS は真の原因ではなかった（初期の無音ハングの一因ではある）。
  - **QEMU による stock/patched 比較（実ディスクは COW overlay で変更せず）**:
    - QEMU は `/` にinstallせず deb を `/tmp/qemu-root` に展開して実行
      （`-L /tmp/qemu-root/usr/share/qemu`, AAVMF no-secboot,
       `-accel tcg,thread=multi -cpu neoverse-n1`, `/dev/sda` を
       backing にした qcow2 overlay）。
    - モニタの `screendump` で VNC 相当の画面を取得。
    - **patch 済み `bootmgfw.efi`（sha `37202f54...`）**: GRUB が Windows を
      選択した約 68 秒後にゲストが終了（画面は GRUB のまま）。WORKLOG
      5343 の既知事象を再現。
    - **stock `bootmgfw.efi`（sha `fae47d78...`）**: ゲストは終了せず、
      約 2 分で Windows 11 のロック画面（1:09 / 11月21日）に到達。
      WinRM は HTTP 405（= サービス応答）を返し、QMP の
      `system_powerdown` でクリーン shutdown。
    - → **patch 自体が OCI A1 で Windows を起動不能にしている最有力証拠**。
  - 実機の ESP の `bootmgfw.efi` を stock に差し替え（patch 済みは
    `bootmgfw.efi.oci-patched.bak` として保存、hash 確認済み）。BCD の
    EMS 要素は削除したまま。ユーザーが再起動して実機確認する。
  - stock で実機再起動 → **シリアルに `ConvertPages: failed to find range
    102000 - 102FFF`**。つまり OCI A1 では stock もダメで、AnyPages 系
    パッチは**必要**。 event log / OEM/boot.log は 11-19 のままで
    カーネル未到達。
  - QEMU で追加実験（すべて /dev/sda の COW overlay、モニタ screendump で
    画面確認）:
    - `mov w0,#1`（従来パッチ）: 約 68 秒で終了
    - `mov w0,#3`: 約 68 秒で終了
    - `mov w0,#0`（本当の AllocateAnyPages）: 約 68 秒で終了
    - リテラル `0x102000` を `0x200000` に変更（AllocateType は stock のまま）: 約 68 秒で終了
    - `bootmgr.efi`（ImageBase 0x140000000、0x102000 要求なし）:
      QEMU は生存するが GRUB から先に進まず
    - **stock のみロック画面 + WinRM HTTP 405 で完全起動**
    - → QEMU は RAM が 0x40000000 起点なので低アドレス確保系の
      パッチをことごとく拒否する模様。QEMU は native の判定に使えない
      （WORKLOG の既知注意と一致）。
  - **UEFI enum の訂正**: `EFI_ALLOCATE_TYPE` は 0=AnyPages,
    1=MaxAddress, 2=Address, 3=Last。`patch_bootmgfw.py` の
    「`mov w0,#1` = AnyPages」という説明は誤りで、実態は MaxAddress。
    `patch_bootmgfw.py` に `--mode` を追加し、各 immediate を試せるようにした。
  - 二段目の壁 as 仮説: §22.33 のとおり native の EDK2 は winload の
    Subsystem=16 を LoadImage で拒否する。実機に適用済み:
    - `C:\Windows\System32\winload.efi` の Subsystem 16→10
      （bak: `winload.efi.orig16.bak`, sha `fc788408...` → `29a99161...`）
    - BCD loader `{58297ee1-...}` に `16000048=1`（DisableIntegrityChecks）
    - ESP の `bootmgfw.efi` は従来パッチ（`37202f54...`）に戻す
    - EMS 要素は削除したまま
  - NTFS は dirty フラグで rw マウントを拒否されたため `ntfsfix -d /dev/sda3`
    で解消してから winload を書き換えた。`ntfs-3g` も導入済み。
  - ユーザーが再起動して Windows を試す。**ConvertPages エラーは消えた**
    が、シリアル・VNC とも無出力、WinRM/RDP も応答なし、C: のログも
    11-19 のまま = カーネル未到達。
  - SPCR 経由 EMS（`16000020` / `260000b0` のみ、port/baud は置かない）と
    `graphicsmodedisabled`(16000046) / `bootuxdisabled`(1600006c) も
    bootmgr と loader に設定したが、シリアルには GRUB 以降何も出ない。
  - **自分で作った回帰に気づく**: 実機へ `cp` で bootmgfw を差し替えた
    際、FAT の開始クラスタが **82040**（GRUB の上限 65536 超え）に
    移動していた。ビルド本来の ESP レイアウトを復元するため、
    `esp_compact.sh /dev/sda1 <patched>` を実行（`/boot/efi` は一旦 umount）。
    結果: bootmgfw=クラスタ 14, BCD=6110, grub.cfg=5、
    volume serial `2E8D-167D` を保持（Volume ID 保存の修正が効いた）。
    BCD の全設定も保持。
  - 再起動して再テストしたが、**やはり起動せず**（BOOTSTAT 17:42 更新、
    イベントログ 11-19 のまま）。bootmgr までは動くが、
    winload 以降でサイレントに停止している。
  - winload を orig16 に戻し nointegritychecks も削除して再起動 → 変化なし。
  - `BOOTSTAT.DAT` を解析すると patch 済み `bootmgfw.efi` に対して
    **0xc0000428 (STATUS_INVALID_IMAGE_HASH)** が多数記録されていた。
    ESP の `CIPolicies/Active/*.cip` と `winsipolicy.p7b` を一時退避して
    ESP を再構築（bootmgfw cluster 14）しても起動せず → CI ポリシーだけ
    が原因ではない。退避先は再起動で消えたため ESP の CI ファイルは
    未復元（Windows は元から起動していないので実害はない）。
  - **最終状態**: Ubuntu 側の修正（fstab PARTUUID / nofail、
    esp_compact の volume serial 保持、inspect_image の照合、
    test_recovery_boot、EMS 要素削除、BCD の EMS/GOP フラグ、
    bootmgfw 低クラスタ）はすべて有効。Windows は native OCI A1 で
    未解決のまま。stock は `ConvertPages: 102000-102FFF`、patch は
    bootmgr がサイレントに停止、という板挟みで、QEMU では stock のみ
    起動する。解決には OCI ファームウェア側の挙動確認か別 Windows
    ビルドの bootmgfw が必要。
  - `patch_bootmgfw.py` の enum 表記を訂正: 0=AnyPages, 1=MaxAddress,
    2=Address, 3=Last。従来の「#1 = AnyPages」は誤記。既定の #1
    （MaxAddress）パッチは従来と同じ sha `37202f54...` を生成することを
    確認済み。`--mode {any,max,address,last}` で切替可能。

## 22.41 QEMU 再検証: stock 26089 は起動、patch は早期終了 (2026-11-20)

### QEMU の再現条件

- overlay `/tmp/ov-base.qcow2`（backing `/dev/sda`）に実 ESP を複製。
- BCD から EMS/`graphicsmodedisabled`/`bootuxdisabled` を削除
  （`bcd_disable_ems.py` を拡張）。
- ESP の `CIPolicies/Active/*.cip` と `winsipolicy.p7b` を
  `C:\Windows\Boot\EFI` から復元。
- QEMU 10.2.1 TCG (4 vCPU, 6 GiB, AAVMF no-secboot, ramfb, VNC)。

### 結果

| bootmgfw | 結果 |
|---|---|
| 26089.1001 stock | GRUB → Windows Boot Manager → **ロック画面、WinRM 405**（約 5 分） |
| 26089.1001 patch (MaxAddress) | GRUB 直後、60 秒以内に QEMU 終了。BOOTSTAT 未更新 = bootmgr 未到達 |
| 28000.367 stock | 以前の QEMU でロック画面到達済み |
| 28000.367 patch | 以前の QEMU で約 68 秒で終了 |

- stock 26089 は現在の 26100.9457 / 28000-era BCD と互換。WinRM も応答。
- patch は署名済みイメージを変更するため、boot.stl/CIPolicies の
  integrity チェックで silent shutdown すると考えられる。`ConvertPages`
  の DEBUG 出力は戻り値を見ていないので無害。**patch を既定にしない**。

### 実機へ投入した内容

1. `EFI/Microsoft/Boot/bootmgfw.efi` を **stock 26089.1001**
   (sha `6a5aa7f0...`) に戻した（esp_compact で cluster 14）。
2. BCD から `16000020` / `16000046` / `1600006c` / `260000b0` を削除。
3. CI ポリシー 3 個と `winsipolicy.p7b` を復元。
4. GRUB の default を Ubuntu、timeout 5 に変更（失敗時の復帰用）。
5. ファームウェア直接起動用の `Boot0005`
   (`\EFI\Microsoft\Boot\bootmgfw.efi`) を作成し、`BootNext=0005` を設定。
   GRUB を経由せず、stock bootmgfw を直接 LoadImage する検証。

### 次の観測点

- VNC に Windows ロック画面が出るか。
- 出ない場合、power-cycle 後は GRUB default=Ubuntu に戻る。
- 直接起動でも失敗するなら、bootmgfw の版（26089 vs 28000）か
  OCI firmware の 0x102000 予約が残因。

## 22.42 native 26089 停止と boot chain 世代統一 (2026-11-20)

### 実機の観測

- `Boot0005`（ESP の `\EFI\Microsoft\Boot\bootmgfw.efi` を直接）と
  EFI Internal Shell からの直接実行の両方で、Windows は起動しなかった。
- EFI Shell のログ:
  - `ConvertPages: failed to find range 10000000 - 102C4FFF`
  - `Image Loaded: bootmgfw.efi`
  - `ConvertPages: failed to find range 102000 - 102FFF`
  - その後、Windows Boot Manager の画面も Windows ロゴも出ない。
- このログではファームウェアが `Boot0000 BootManagerMenuApp` を起動し、
  `BootNext:` は空、Boot Options は `Boot0002` だけだった。Boot0005 は
  BootOrder に入れていなかったため、メニューには出ていない。最初の再起動で
  BootNext は消費済みと判断できる。
- `ConvertPages` は EDK2 の DEBUG 出力で、bootmgfw は `AllocatePages` の
  戻り値を見ずに続行する（22.40 の QEMU 解析と同じ）。今回の停止は
  `ConvertPages` 自体が原因ではない。

### 世代不一致の発見

ESP の内容を Windows ボリュームと比較した。

| ファイル | ESP | `C:\Windows\Boot\EFI` |
|---|---|---|
| `bootmgfw.efi` | 10.0.26089.1001 | 10.0.28000.367 |
| `bootmgr.efi` | 10.0.28000.367 | 10.0.28000.367 |
| `boot.stl` | 12521 B = `boot.pnd.stl` | `boot.stl` 12006 B / `boot.pnd.stl` 12521 B |
| `CIPolicies` / `winsipolicy.p7b` | 28000 世代を復元済み | 28000 世代 |

つまり ESP は **bootmgfw だけ 26089、BCD/bootmgr/boot.stl/CI は 28000** という
混成だった。26089 は QEMU ではロック画面まで到達するが、実機ファームウェア
（Oracle AAVMF 20260902）では bootmgr のメニュー前に停止する。QEMU の
AAVMF はこの混成を許容するが、実機は許容しないと考えられる。

### 実機へ入れた修正

1. `C:\Windows\Boot\EFI\bootmgfw.efi`（stock 28000.367、sha
   `fae47d78...`）を ESP の `\EFI\Microsoft\Boot\bootmgfw.efi` へコピー。
   `esp_compact.sh` で cluster 14 に再配置。volume serial `2E8D-167D` は保持。
2. GRUB の `default=0`（Windows 11）、`timeout=10` に変更。失敗時は
   power-cycle 後に Down + Enter で Ubuntu (recovery) を選べる。
3. `systemd-networkd-wait-online.service` を live で disable + mask。
   ビルド側は `pipeline/make_recovery_ubuntu.sh` で同じ設定を行う。

### リポジトリ側の修正

- `pipeline/finish_disk.sh`: Windows ボリュームの
  `\Windows\Boot\EFI\bootmgfw.efi` を読み、ESP の stock コピーとして使う。
  ESP が patched でも、Windows の stock があれば置き換える。
  `STOCK_BOOTMGFW=` は明示指定として残す。
- `pipeline/finish_winpe.sh`: bcdboot 後の ESP に、インストール済み
  Windows の `bootmgfw.efi` をコピーして世代を揃える。
- `pipeline/make_recovery_ubuntu.sh`: `systemd-networkd-wait-online` を
  disable + mask。OCI の DHCP 待ちで 11 秒以上（上限なし）止まらないようにする。

### 次の観測点

- VNC に Windows Boot Manager のメニュー（30 秒）が出るか。
- 出れば Windows ロック画面まで進むか。
- 出なければ bootmgfw 28000 でも同じ停止か。その場合は boot chain の
  世代ではなく、OCI ファームウェアのメモリマップか virtio-scsi の
  ブロック I/O を疑う。
- 失敗時の復帰: power-cycle → GRUB の 10 秒以内に Down + Enter →
  Ubuntu (recovery)。

## 22.43 WinRE の boot chain と BOOTSTAT 0xc0000428 の照合 (2026-11-21)

### WinRE.wim の boot ファイル

- `/mnt/win/Recovery/WindowsRE/Winre.wim` は Build 26100.9444 だが、
  `/Windows/Boot/EFI/bootmgfw.efi` は **28000.367**（sha
  `fae47d78...`）、`bootmgr.efi` も 28000.367、`boot.stl` 12006 B、
  `boot.pnd.stl` 12521 B。ESP の stock 28000 と完全一致する。
- つまりこのインストールには 26100 世代の boot manager が存在しない。
  以前の QEMU V10 経路で使った 26100.1041 は UUP 由来で、現在は
  ローカルに残っていない。WinRE から 26100 の bootmgfw を取り出す
  道はないため、世代統一は 28000 で揃えるのが正しい。
- WIM の読み出しは Ubuntu archive の `wimtools` +
  `libwim15t64` を `/tmp` に展開して行った（`wimlib-imagex`）。
  再取得用に `/root/wimtools`、抽出した boot ファイルを
  `/root/winre-boot`、stock 26089/28000 の bootmgfw と
  `BOOTSTAT.DAT` のコピーを `/root` に保存した。

### BOOTSTAT.DAT の 0xc0000428 は patched 画像の記録

- `BOOTSTAT.DAT` の `0xC0000428` レコードの直後は
  Authenticode(SHA256) ハッシュ（`0c 80 00 00` = CALG_SHA_256、
  `20 00` = 32 B）。
- ESP の `bootmgfw.efi.oci-patched.bak` の Authenticode ハッシュ
  `fe8a30a1...` と一致するレコードが 16 件ある。
- 一方、stock 26089 の Authenticode ハッシュ `28bfb2cd...` と
  stock 28000 の `1eeecb67...` は **0 件**。したがって
  `0xc0000428` は patched bootmgfw に対する記録であり、**stock 26089 の
  native 停止は image hash 拒否ではない**。もう 1 つの
  `85fcd757...` は現存しない patched コンポーネントで、winload とは
  限らない（現存ファイルの Authenticode hash とは一致しない）。
- 現在の `winload.efi` は orig16 に戻っており、Authenticode
  `e31b0cdf...`、Subsystem 16。`winload.efi.orig16.bak` と同一。
- `ConvertPages: failed to find range 102000 - 102FFF` は QEMU でも
  出る（22.20）。今回の native 停止の直接原因ではない。

### ESP の boot.stl

- ESP の `boot.stl` は 12521 B で
  `C:\Windows\Boot\EFI\boot.pnd.stl` と同一。インストール済み
  Windows の active `boot.stl` は 12006 B。
- ESP のファイル時刻は bcdboot 実行時（2026-09-14 03:15:52 JST =
  2026-09-13 18:15:52 UTC）で、Windows 側の `boot.pnd.stl`
  （18:15:51 UTC）の 1 秒後。bcdboot が pending policy を ESP の
  `boot.stl` として置いたと判断できる。active 12006 B に差し替えると
  逆に世代がずれる可能性があるため、12521 B のままにする。
- Secure Boot は無効（`SecureBoot`/`PK`/`KEK`/`db` 変数なし）で、
  QEMU は 12521 B のままロック画面まで到達している。

### 28000 実機テスト（未実施）

- ESP: stock 28000.367 `bootmgfw.efi`（sha `fae47d78...`、cluster 14）。
- BCD: default `{58297ee1}` = Windows 11、displayorder も同じ、
  timeout 30、displaybootmenu=1。EMS/debug 要素なし。
  `winload.efi` は stock（Subsystem 16）。
- GRUB: timeout 10、default 0 = Windows 11。Ubuntu は Down + Enter。
- 期待: GRUB → Windows Boot Manager メニュー（30 秒）→ ロック画面。
- 失敗時: power-cycle → GRUB の 10 秒以内に Down + Enter →
  Ubuntu (recovery)。
- 失敗後の切り分け候補:
  1. `{bootmgr} bootems=1` と loader `260000b0=1`（port/baud なし）で
     PL011 に winload 以降のエラーを出す。`kd_0C11.dll` は ESP にも
     `C:\Windows\System32` にも無いため、serial KD debug は不可。
  2. OCI の表示は virtio-gpu `1af4:1050`。QEMU 検証は ramfb 併用
     なので、bootmgr の GOP 初期化が virtio-gpu で止まる可能性を
     QEMU（virtio-gpu のみ）で再現する。
  3. OCI は RAM 24 GiB（0x40000000 起点）・GICv3。QEMU の 6 GiB /
     GICv2 との差を疑う。

## 22.44 /dev/sdb 実績個体との差分と 26100.1041 boot manager (2026-11-21)

### /dev/sdb の構成（実績個体）

- p1 = ESP 100 MiB (PARTUUID `057542d2-1b5d-4682-b686-62cdaf9862bf`)、
  p2 = MSR 16 MiB、p3 = NTFS 49.9 GiB (`26100.1742`)。
- Windows は **10.0.26100.1742**（2024-10-05 era）。`C:\Windows\Boot\EFI` の
  `bootmgfw.efi` は **10.0.26100.1041**（2,625,456 B、sha
  `3e85158b...`）、`boot.stl` は 10,853 B（2024-04-01）。
- ESP の `\EFI\Boot\bootaa64.efi` は同じ 26100.1041。開始クラスタは
  **73466** で、65536 以上でもファームウェアから起動できる。22.40 の
  「GRUB は 65536 以上のクラスタを読めない」という前提は、少なくとも
  firmware の既定パスには当てはまらない（sdb は 73466 で起動）。
- ESP の `\EFI\Microsoft\Boot\bootmgfw.efi` は 26089.1001（2,622,784 B、
  sha `55f7377d...`）だが、stock 26089（sha `6a5aa7f0...`）と 2,314 箇所の
  単バイト（主に `0x10`/`0x00` → `0x40`）が異なる実験残骸で、そのままでは
  信頼できない。F2 → Block Volume 2 の既定経路は `EFI/Boot` 側と判断する。
- sdb1 の BCD は `16000046`(graphicsmodedisabled)、`1600006c`
  (bootuxdisabled)、`16000020`(bootems)、`260000b0`(kernel EmsEnable) が
  すべて 1 でも起動する。EMS/画面系フラグはこの個体では致命ではない。
- sdb3 の `SYSTEM` と `System.evtx` は 2026-11-21 05:17 UTC に更新されて
  おり、直近のブート成功と整合する。

### /dev/sda との差分

- sda3 は 10.0.26100.9457。`winload.efi` は stock の 3,190,032 B
  (Subsystem 16、sha `fc788408...`)。
- ESP の `bootmgfw.efi` は 28000.367（sha `fae47d78...`）で実機停止。
  stock 26089（`6a5aa7f0...`）も 22.42 で停止済み。
- 残る未検証の stock は **26100.1041** だけ。24H2/25H2 の boot manager で、
  9457 の winload を扱える見込み（22.41 の QEMU では 26089 + 9457 winload が
  ロック画面まで到達）。

### 実機へ投入した内容

- ESP `\EFI\Microsoft\Boot\bootmgfw.efi` を 26100.1041
  （sha `3e85158b...`、署名あり、6 sections）へ差し替え。`esp_compact.sh`
  で cluster 14、volume serial `2E8D-167D` は保持。
- BCD（sha `b99d0009...`）と GRUB（default Windows、timeout 10）は変更なし。
- バックアップ:
  `/root/sda1-bootmgfw-28000-fae47d78.efi`、
  `/root/sda1-esp-before-26100.tar`、
  `/root/bootmgfw-26100.1041.efi`。
- 注意: `/dev/sdb3`（ntfs3, ro）から `cp` した bootmgfw は、`sha256sum`
  では `3e85158b...` と読めるのに、コピー結果が全ゼロ相当の壊れたファイル
  （sha `7077b329...`、`file` は data）になった。vfat の `/dev/sdb1` から
  コピーし、SHA-256・PE・FileVersion を再検証してから配置した。ntfs3 の
  読み出しは今後もコピー後に検証する。

### リポジトリ側

- `pipeline/finish_disk.sh`: 書き込む boot manager の FileVersion を表示し、
  `10.0.28000` 以上なら OCI AAVMF 停止の警告と `STOCK_BOOTMGFW` の案内を
  出す。
- `internal/build-image.sh`: step 12 で ISO の `efi/boot/bootaa64.efi` を
  取り出し、`STOCK_BOOTMGFW` として `finish_disk.sh` に渡す。サービス更新で
  `C:\Windows\Boot\EFI` が 28000 に置き換わっても、メディア世代の boot
  manager を優先できる。ISO が 28000 世代なら警告が出る。

### 次の観測点

- GRUB 10 秒 → 26100.1041 bootmgfw → Windows Boot Manager メニュー（30 秒）
  → Windows ロック画面。
- 失敗時: power-cycle → GRUB の 10 秒以内に Down + Enter → Ubuntu (recovery)。
- 成功したら、`boot.stl` / `bootmgr.efi` も ISO 世代に揃えるか、9457 の
  winload との組み合わせをどこまで固定するかを決める。

## 22.45 26100.1041 実機テスト（無音）と GRUB ステージ診断 (2026-11-21)

### 結果

- ESP の `bootmgfw.efi` を 26100.1041（`3e85158b...`）へ差し替えた状態で
  再起動した。VNC には GRUB 後の Windows Boot Manager メニューもロゴも
  出ず、ユーザー報告は「何も出なかった」。シリアルコンソールは未確認。
- 再起動は 14:32:35 UTC、Ubuntu recovery は 14:35:25 UTC に起動。
  Ubuntu の cmdline は GRUB の `console=ttyAMA0,115200 console=tty1` を
  含むため、GRUB 自体は動作している。
- ESP の `BOOTSTAT.DAT` は 14:14:28 のまま更新されていない。28000.367 の
  テストでは bootmgr が BOOTSTAT を更新していたので、今回は
  **bootmgr が BOOTSTAT を書く地点まで到達していない**。
  `C:\Windows\System32\config\SYSTEM` と `System.evtx` も 11-19 のまま。
- したがって次のいずれか:
  1. GRUB の `chainloader` が 26100.1041 を開始できていない
     （画面には GRUB のエラーが出るはずだが未確認）。
  2. `StartImage` は成功したが、bootmgr が BCD 読み込み前後で停止した。
  3. VNC の表示だけが失われ、実際には別の場所で停止した。
- シリアルを取れていないため、GRUB 側に **ステージ記録** を仕込んで
  再テストする。

### 診断用 GRUB メニュー

- `pipeline/write_grub_menu.py --diagnostics` を追加。`EFI/ubuntu/grubenv`
  に以下を保存する（`save_env`）。GRUB の prefix は `/EFI/ubuntu`。
  - `grub_menu_seen=1`: grub.cfg を読めた。
  - `win_entry=1`: Windows 11 エントリに入った。
  - `win_chainload=1`: `chainloader` を実行した。
  - `win_returned=1`: `chainloader` から戻った（起動失敗）。
  - `dbg_*`: 同じ内容を `bootmgfw-dbg.efi` 経由で実行。
  - `ubuntu_entry=1`: Ubuntu エントリに入った。
- Windows エントリでは `search` 前後の `$root` と
  `ls -l /EFI/Microsoft/Boot/bootmgfw.efi` を画面とシリアルへ出す。
  `chainloader` が戻った場合は 10 秒待ってからメニューへ戻る。
- `--diagnostics` は `EFI/Microsoft/Boot/bootmgfw-dbg.efi` が存在するときだけ
  「Windows 11 (debug copy)」エントリを追加する。中身は同じ 26100.1041。
- タイムアウトはテスト用に 30 秒。Ubuntu は 3 番目（Down 2 回 + Enter）。

### ESP の再配置

- 前回の `cp` で `grubenv` と debug copy がクラスタ 65536 以上に置かれ、
  GRUB の FAT ドライバ（65536 以上を読めない）に抵触する。`esp_compact.sh`
  の優先コピーに `EFI/ubuntu/grubenv` と
  `EFI/Microsoft/Boot/bootmgfw-dbg.efi` を追加し、存在する場合だけ
  低クラスタへ置くようにした。
- 再構築後のクラスタ: grub.cfg 5、EFI/Boot/grub.cfg 11、bootmgfw 18、
  BCD 5146、grubenv 5250、debug copy 5252。すべて 65536 未満。
- `grubenv` は `grub-editenv create` で 1024 B の空ブロックにした。
  `bootmgfw.efi` と debug copy はどちらも `3e85158b...`。

### 次のテスト

1. VNC とシリアルコンソールの両方を開いて再起動する。
2. GRUB 30 秒メニューで既定の「Windows 11」を選ぶ。
   - 画面/シリアルに `GRUB diag:` 行が出るか。
   - `ls -l` がサイズ 2625456 を出せるか。
   - Windows Boot Manager のメニュー/ロゴが出るか。
3. 無音なら power-cycle し、GRUB で「Windows 11 (debug copy)」を選ぶ。
4. それでも無音なら power-cycle し、「Ubuntu (recovery)」を選ぶ。
5. Ubuntu 復帰後に `grub-editenv /boot/efi/EFI/ubuntu/grubenv list` を読み、
   `win_chainload` / `win_returned` / `dbg_chainload` の有無で切り分ける。

## 22.46 Windows 11 実機起動成功と BCD 正規化 (2026-11-22)

### 結果

- `/dev/sda` の ESP で、Windows Boot Manager のメニューが **OCI のシリアル
  コンソールに表示され、Windows 11 がデスクトップまで起動した**。
- 22.45 の無音停止から変えた点は 2 つ。
  1. `/dev/sdb1`（実績個体）から `bootmgr.efi` と `boot.stl` をコピー
  2. BCD のフラグを実績個体に合わせて設定
- シリアルでは `WWiinnddooww` のように 1 文字おきに二重表示された。

### ESP の boot chain

| ファイル | 版 | SHA-256 先頭 | サイズ |
|---|---|---|---|
| `bootmgfw.efi` | 10.0.26100.1041 | `3e85158b…` | 2,625,456 |
| `bootmgr.efi` | 10.0.26089.1001 | `2fb07cf2…` | 2,608,560 |
| `boot.stl` | — | `fb5146c8…` | 10,853 |

- `bootmgfw.efi` は 22.45 から変更なし（26100.1041）。
- `bootmgr.efi` / `boot.stl` は `/dev/sdb1` の
  `EFI/Microsoft/Boot/` からコピーした。インストール済み Windows
  （`/dev/sda3`）の同じファイルは 10.0.28000.367 で、26100 の bootmgfw と
  混成になっていた。
- バックアップ: `/root/sda1-bootmgr-28000-.efi`、
  `/root/sda1-boot.stl-28000-.stl`、`/root/sda1-BCD-before-flags.bcd`。

### BCD フラグ

`/dev/sdb1` の BCD と同じ値を入れた。

- `{bootmgr}` `{9dea862c-…}`:
  `16000020=1`（bootems）、`16000046=1`（graphicsmodedisabled）、
  `16000048=1`（nointegritychecks）、`1600006c=1`（bootuxdisabled）
- 既定ローダー `{58297ee1-…}`:
  `16000009=0`（recoveryenabled）、`16000046=1`、`16000048=1`、
  `1600006c=1`、`26000090=1`（bootlog）、`26000091=1`（sos）、
  `260000b0=1`（EmsEnable）

`16000048=1` は必須だった。過去の `bcd_disable_ems.py` は「デバッグ用の
残骸」としてこの要素を削除しており、その状態では `0xc0000428`
（デジタル署名を検証できない）で停止する。

### BCD 正規化（二重表示の解消）

起動成功後、シリアルの二重表示を止めるために BCD を正規化した。

- 明示的な EMS ポート/ボーレート（`15000022`/`15000023` など）を全削除。
- `16000020`（bootems）と `260000b0`（EmsEnable）を **0** に設定。
  Windows の EMS と通常の ConOut が同じ PL011 に書かなくなる。
  実績個体 `/dev/sdb` は両方 1 でも起動するが、起動可否と二重表示は別問題で、
  `/dev/sda` では EMS 有効時に `WWiinnddooww` が出ていた。
- `26000090`（bootlog）と `26000091`（sos）を削除。
- `16000046`/`16000048`/`1600006c` は 1 のまま維持。
- 正規化後の BCD SHA-256 は `827287fe…`。バックアップは
  `/root/sda1-BCD-before-normalize.bcd`（起動に成功した状態）。

## 22.47 Windows 初回起動後に Ubuntu が消えたように見える問題 (2026-11-22)

### 症状

- Windows の初回起動後、再起動すると GRUB が出ず Windows Boot Manager が
  直接起動した。Ubuntu のパーティションと ESP の GRUB は残っていた。
- ファームウェアの NVRAM は次の順序だった。

```text
BootOrder: 0003,0002,...
Boot0003  Windows Boot Manager  \EFI\Microsoft\Boot\bootmgfw.efi
Boot0002  UEFI ORACLE BlockVolume  （ファイル指定なし＝フォールバック）
```

Ubuntu の `Boot####` は存在しなかった。イメージはフォールバック
（`\EFI\BOOT\BOOTAA64.EFI`）だけで GRUB に入る構成だったため、Windows が
自分のエントリを先頭にすると GRUB に到達できない。

### 復旧

EFI シェル（シリアルで Esc → Boot Manager → EFI Internal Shell）から
Ubuntu のエントリを追加し、先頭へ移動した。

```text
Shell> fs0:
FS0:\> bcfg boot add 9 FS0:\EFI\ubuntu\grubaa64.efi Ubuntu
FS0:\> bcfg boot mv 9 0
FS0:\> reset
```

この操作後は GRUB が起動し、Ubuntu（Linux 7.0.0-30-generic）が起動した。
現在の NVRAM は `Boot0007 Ubuntu` が先頭で、`Boot0003 Windows Boot Manager`
は残っている。

### 恒久対策

- 復旧 Ubuntu に `oci-ubuntu-boot-order.service`（oneshot）を追加。
  `efibootmgr` で Ubuntu のエントリを探し、無ければ
  `--create`、あれば `--bootorder` で先頭へ移す。他のエントリは削除しない。
- `make_recovery_ubuntu.sh` は online なら `efibootmgr` を apt で、
  offline なら ISO の pool から `efibootmgr`/`libefivar`/`libefiboot` の
  .deb を入れる。見つからない場合は警告のみでビルドを続ける。
- 実機の Ubuntu にも unit をインストールして `systemctl start` し、
  `Boot0007` が先頭のままであることを確認した。

## 22.48 stubble の assert と UKI からの `.linux` 抽出 (2026-11-22)

### 症状

GRUB から Ubuntu を選ぶと、次の assert で停止する経路があった。

```text
efi-log.c:34@efi_assert: stubble: Assertion
'description || pcrindex == UINT32_MAX' failed at
measure.c:246@tpm_log_ipl_event, halting.
```

### 原因

- Ubuntu 24.04 以降の arm64 は `/boot/vmlinuz-<version>` を UKI として
  インストールする。エントリポイントは stubble。
- stubble 9 の `stub.c` は、EFI シェルから起動された場合にシェルの引数を
  コマンドラインとして使う。引数が無いと UKI 内の `.cmdline` を読むが、
  Ubuntu の UKI は空なので `cmdline` が NULL になる。
- その状態で `tpm_log_ipl_event` が説明文字列なしの PCR イベントを記録
  しようとして `measure.c:246` で assert する。
- BDS（NVRAM エントリ）から GRUB を起動した場合はシェル引数が無いため
  この分岐に入らず、同じ UKI でも起動できる。経路によって成否が変わる。

### 対策

- `pipeline/extract_uki_kernel.py` を追加。PE/COFF のセクションヘッダを
  読み、`.linux` セクションを取り出す。Ubuntu の `.linux` は EFI zboot
  （`MZ` + `zimg`）で、先頭のヘッダが payload の位置・サイズ・圧縮方式を
  持つ。zstd なら libzstd（ctypes、無ければ `zstd` コマンド）で展開し、
  gzip なら標準ライブラリで展開して `vmlinuz-<version>.raw` に書く。
  入力が UKI でなければ何もせず 0 で終了する。
- 実機の UKI の `.linux` は 17,486,336 B の EFI zboot で、payload は
  111,352 から 17,363,185 B の zstd。展開すると 72,613,888 B の
  `Linux kernel ARM64 boot executable Image` になり、0x38 に `ARM\x64`
  があることを確認した。zboot をそのまま GRUB の `linux` に渡すと
  ブートヘッダが無いため起動できない。
- `make_recovery_ubuntu.sh` はビルド時に抽出し、
  `/boot/grub/grub.cfg` と GRUB メニューの `linux` 行を `.raw` に向ける。
- `write_grub_menu.py` は `<kernel>.raw` があればそちらを優先する。
- raw カーネルは stubble を経由しないため、EFI シェル・フォールバック・
  NVRAM のどの経路でも同じ boot protocol になる。Secure Boot は無効なので
  未測定カーネルで問題ない。
- 実機での GRUB → raw カーネルの起動確認は次の再起動で行う
  （NVRAM 修正後の GRUB → Ubuntu 起動は確認済み）。

## 22.49 リポジトリへの反映 (2026-11-22)

### スクリプト

- `pipeline/bcd_normalize.py`（新規）: BCD の正規化。
  EMS ポート削除、`bootems`/`EmsEnable` を 0、`16000048` を 1、
  `16000046`/`1600006c` を 1、`bootlog`/`sos` 削除。冪等。
  `pipeline/bcd_disable_ems.py` は互換エイリアスに変更。
- `oem/specialize.ps1.template`: `bcdedit /ems`、`/emssettings`、
  `{bootmgr} bootems yes` を削除。ARM64 では「no-op」ではなく実際に BCD へ
  書かれ、OCI の PL011 でハングと二重表示の原因になる。
- `pipeline/finish_disk.sh`: BCD 正規化を `bcd_normalize.py` に変更。
  インストール済み Windows から `bootmgr.efi`/`boot.stl` も取得し、
  `bootmgfw.efi` と同じ世代に揃える。`STOCK_BOOTMGFW` を指定した場合は
  隣接ファイルまたは `STOCK_BOOTMGR`/`STOCK_BOOT_STL` を使い、混成を避ける。
  28000 系が残る場合は警告する。
- `internal/build-image.sh`: ISO の `efi/boot/bootaa64.efi` に加えて
  `efi/microsoft/boot/bootmgr.efi`（無ければ ISO ルートの `bootmgr.efi`）と
  `boot.stl` を `STOCK_BOOTMGR`/`STOCK_BOOT_STL` として渡す。
- `pipeline/make_recovery_ubuntu.sh`: `efibootmgr` の導入、
  `oci-ubuntu-boot-order.service` の登録、UKI からの `.linux` 抽出、
  フォールバック GRUB 設定の raw カーネル化。
- `pipeline/oci-ubuntu-boot-order.sh` / `.service`（新規）:
  Ubuntu の EFI エントリをブート順の先頭へ戻す。`efibootmgr` や
  `efivarfs` が無い場合は何もせず正常終了する。
- `pipeline/write_grub_menu.py`: `.raw` カーネルの優先。
- `pipeline/inspect_image.sh`: `bootems`/`EmsEnable`/`nointegritychecks` を
  表示し、`16000048` が 1 でなければ警告する。

### ドキュメント

- `docs/BUILD.md` / `docs/DUALBOOT.md` / `docs/OCI.md`:
  BCD 正規化の内容、NVRAM のブート順と `bcfg` 復旧、UKI/stubble、
  boot chain の世代統一を追記。

### セッション消失の記録（イメージとは無関係）

- 作業中、別セッションで OpenCode のデータディレクトリに対して
  `find ... -type f -delete` を実行してしまい、セッション DB を失った。
- 会話の復元は `prompt-history.jsonl`、`docs/WORKLOG.md`、git の履歴から
  行った。この節以降の作業はその復元後の内容を含む。

## 22.50 実機での最終確認と診断メッセージの修正 (2026-11-22)

### 実機で確認できたこと

OCI A1 の実機 `/dev/sda` で、次の一連の動作を確認した。

1. 電源投入 → ファームウェア → GRUB のメニュー（Windows 11 が既定）
2. `Windows 11` を選ぶ → `bootmgfw.efi` → Windows Boot Manager →
   Windows 11 が起動
3. Windows Boot Manager で **F8** を押す → 詳細オプション →
   **ESC=Exit で GRUB に戻る**
4. GRUB に戻った後、`Ubuntu (recovery)` を選ぶ →
   `EFI ExitBootServices: Called.` の後に Linux が起動

```text
Linux version 7.0.0-30-generic ... #30-Ubuntu SMP PREEMPT_DYNAMIC
...
ubuntu@<host>:~/win11-arm64-oci$ uname -r
7.0.0-30-generic
```

- シリアルの Windows Boot Manager は 1 文字ずつ表示され、
  `WWiinnddooww` の二重表示は解消した。
- `efibootmgr` は `BootCurrent: 0007` / `BootOrder: 0007,0003,...` で、
  `Boot0007 Ubuntu` が先頭、`Boot0003 Windows Boot Manager` は残っている。
- `oci-ubuntu-boot-order.service` は `active (exited)` / `status=0/SUCCESS`。
- Ubuntu の起動ログに `EFI ExitBootServices: Called.` が出ており、
  GRUB が EFI アプリ（stubble）ではなく arm64 Image を直接起動したことと
  整合する。UKI の `.linux` を zboot 展開した経路が実機で通った。
- 復帰後の `grubenv` には次のマーカーが残っていた。

```text
grub_menu_seen=1
win_entry=1
win_chainload=1
win_returned=1
dbg_entry=1
dbg_chainload=1
dbg_returned=1
ubuntu_entry=1
```

  `win_*` → `dbg_*` → `ubuntu_entry` の順で、Windows Boot Manager の
  メニューから F8/Exit で GRUB に戻り、debug copy でも同じことを確認して
  から Ubuntu を選んだ操作と一致する。

### `... returned; Windows did not start` は誤解を招く

GRUB の `chainloader` は、Windows が起動して `ExitBootServices` を呼べば
戻らない。戻ってくるのは次のどちらか。

- Windows Boot Manager のメニューで **ESC=Exit**（または F8 → Exit）を選び、
  bootmgr が親イメージ（GRUB）へ正常に戻った
- bootmgr が Windows を開始できず、エラー後に戻った

22.45 の診断メッセージは前者も「Windows did not start」と表示していたため、
正常な Exit を失敗と誤認させた。`write_grub_menu.py --diagnostics` の文言を
次のように変更した。

```text
GRUB diag: bootmgfw.efi returned to GRUB (Exit/F8, or Windows failed to start)
```

`grubenv` の `win_returned` / `dbg_returned` も「戻ってきた」ことだけを示し、
失敗の証明ではない。コメントにもその旨を書いた。

### `grub-editenv` が無い復旧環境での読み方

オフライン構築した復旧 Ubuntu には `grub-common` が入らないため、
`grub-editenv` は存在しない。`grubenv` は 1024 B の
`key=value` ブロックなので、coreutils だけで読める。

```bash
sudo cat /boot/efi/EFI/ubuntu/grubenv | tr '\0' '\n' |
    grep -E '^(grub_|win_|dbg_|ubuntu_)'
```

OCI.md のトラブルシューティングにもこの方法を追記した。`grub-editenv` を
使いたい場合は `apt-get install grub-common` で入る（復旧環境では任意）。

## 22.51 スクラッチビルドで NVRAM 問題を予防する (2026-11-23)

### 22.47 の対策は「事後修理」だった

22.47 で追加した `oci-ubuntu-boot-order.service` は、Ubuntu が起動した
ときに `efibootmgr` で Ubuntu の `Boot####` を作り、先頭へ移す。しかし
Ubuntu のエントリがまだ無い状態で Windows を先に起動すると、Windows が
`Boot0003 Windows Boot Manager` を作って先頭に置く。次の電源投入では
ファームウェアが Windows を直接起動し、GRUB に到達しない。GRUB に到達
しないので Ubuntu も起動せず、unit は走らない。つまり **初回の起動順が
Windows だと、この修理は永久に発動しない**。

実機では EFI シェルの `bcfg` で一度 Ubuntu を登録して復旧したが、対策前は
同じ順序でスクラッチビルドすると再発した。ビルド中に NVRAM へ書く方法は
無い（NVRAM はディスクイメージに含まれない）ため、ディスク側で「最初の
1 回だけ Ubuntu を起動する」必要がある。

### 初回だけ Ubuntu を起動する

`write_grub_menu.py` に `--first-boot-ubuntu` を追加した。これは
`EFI/ubuntu/grubenv` に次の 1 行を書く。

```text
next_entry=Ubuntu (recovery)
```

GRUB のメニューは `next_entry` があればそれを `default` に使い、その場で
空に戻す（`set next_entry=` → `save_env next_entry`）。したがって Ubuntu は
1 回だけ既定になり、次回以降は通常どおり Windows 11 が既定になる。
`grub.cfg` は `$prefix/grubenv` を `load_env` で読んでから `next_entry` を
確認する（GRUB は環境ブロックを自動では読まない）。

`internal/build-image.sh` は `--fresh-ubuntu` のとき、step 10（Windows の
初回起動・WinRM 待ち）が終わった後の step 12 で `finish_disk.sh` に
`FIRST_BOOT_UBUNTU=1` を渡す。step 9 の `finish_winpe.sh` で書くと、
step 10 が Ubuntu を起動して WinRM が返らずビルドが失敗するため、位置は
step 12 でなければならない。`--reuse-ubuntu` は unit の有無を保証できない
ので既定 0。

`finish_disk.sh` は ESP の `EFI/ubuntu/grubenv` を取り出し、
`pipeline/grubenv.py` で `next_entry` を設定して戻す。GRUB の FAT ドライバは
先頭クラスタ 65536 以上を読めないので、`grubenv` も `esp_compact.sh` の
優先リストに入れ、必要なら ESP を作り直す。`finish_winpe.sh` は step 10 の
Windows 準備完了テストが Ubuntu で止まらないよう、古い `grubenv` を消して
から終了する。

### `pipeline/grubenv.py`

`grub-editenv` の無い環境向けの小さな読み書きツール。1024 B の
ヘッダ + `key=value` + `#` パディングをそのまま扱う。

```bash
python3 pipeline/grubenv.py show  /mnt/esp/EFI/ubuntu/grubenv
python3 pipeline/grubenv.py set   /mnt/esp/EFI/ubuntu/grubenv next_entry "Ubuntu (recovery)"
python3 pipeline/grubenv.py unset /mnt/esp/EFI/ubuntu/grubenv next_entry
```

`write_grub_menu.py` もこのモジュールを使う。`--diagnostics` を付けた
ときに `grubenv` が無いと `save_env` が失敗する問題も、空ブロックを
作ることで解消した。

### 確認したこと

- `write_grub_menu.py --first-boot-ubuntu` が 1024 B の `grubenv` と
  `next_entry=Ubuntu (recovery)` を生成することを、偽の ESP/Ubuntu ツリーで
  確認した。
- 既存の `grubenv` に `--diagnostics` を重ねても `next_entry` とマーカーが
  保持されることを確認した。
- `python3 -m py_compile` と `bash -n` は通っている。
- 実機または QEMU での「初回 Ubuntu → 再起動で Windows」は未確認。
  次のスクラッチビルドで、シリアルに Ubuntu が一度起動し、
  `oci-ubuntu-boot-order` が `Boot#### Ubuntu` を作ることを確認する。

## 22.52 Windows 側のブート順保険（22.51 の前提を修正）

### 指摘

22.51 の説明では「Ubuntu の `Boot####` が存在すれば Windows は自分を先頭へ
動かさない」と書いた。しかし実機で確認できたのは `bcfg` 後に Windows を
起動し、**その後 Ubuntu を起動して unit が先頭へ戻した**時点の NVRAM
（`BootOrder: 0007,0003,...`）だけだった。Windows 起動直後に Ubuntu を
介さず読んだ記録は無く、「入口があるから上書きされない」というのは
推測に過ぎない。Windows の初回起動が無条件に `Boot####` を先頭へ置くなら、
22.51 の初回 Ubuntu だけでは GRUB が再び隠れる。

### 対策

`oem/boot.ps1` に次を追加した。これは OEM Bootstrap タスク
（`onstart`, SYSTEM, HIGHEST）から **毎回の Windows 起動** で走る。

```powershell
bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addlast
```

実機の BCD では `{fwbootmgr}` の displayorder は
`{bootmgr}` → `{6f5d77a7}`（UEFI ORACLE BlockVolume）→
BootManagerMenuApp → EFI Firmware Setup → EFI Internal Shell の順だった。
`{bootmgr}` を末尾へ移すと BlockVolume が先頭になり、そのエントリは
`\EFI\BOOT\BOOTAA64.EFI`（shim → GRUB）を起動する。Windows が初回起動で
`Boot0003` を先頭にしても、次の電源投入では GRUB に到達できる。
GRUB の既定は Windows 11 のままなので、既定起動は変わらない。

Ubuntu 側の unit（Ubuntu を先頭へ）と Windows 側の `boot.ps1`（Windows を
末尾へ）は、どちらも「GRUB が先に来る」ことを保証するので矛盾しない。
`finish_disk.sh` の BCD 正規化はオフラインの hive 編集なので、この
`bcdedit` が書いたファームウェア BootOrder を壊さない。

### 未確認

- 実機で Windows 起動直後に `efibootmgr -v` を読み、Boot0002（または
  Boot0007）が Boot0003 より前にあることを確認する。
- その状態で power-cycle し、手動 `bcfg` なしで GRUB が出ることを確認する。

## 22.53 復旧 Ubuntu から live が起動しない (2026-11-23)

### 症状

README のステージ2-B どおりに次を実行して reboot したが、live が起動せず
復旧 Ubuntu に戻ってきた。

```bash
sudo ./scripts/prepare.sh /srv/iso/ubuntu-26.04.1-live-server-arm64.iso \
    --write --ssh --once
sudo reboot
```

### 原因

`scripts/prepare.sh` は standard な Ubuntu の GRUB を前提としている。

- `--write` は `/etc/grub.d/40_custom` にエントリを足して `update-grub` を
  呼ぶ
- `--once` は `grub-reboot` で `/boot/grub/grubenv` に `next_entry` を書く

しかしこのプロジェクトの復旧 Ubuntu は次の構成だった。

- GRUB が読むのは `/boot/grub/grub.cfg` ではなく
  `\EFI\ubuntu\grub.cfg`（署名済み GRUB の prefix が `/EFI/ubuntu`）
- `update-grub` / `grub-reboot` / `grub-common` は入っていない

`prepare.sh --ssh` は ESP への cloud-init seed 書き込みと CIDATA ラベル
変更には成功したが、`update-grub` が無いのでメニューは変わらなかった。
`/boot/grub/grub.cfg` には復旧 Ubuntu のエントリしか無く、ESP の
`EFI/ubuntu/grub.cfg` には live エントリが無い。したがって再起動後は
従来どおり GRUB → 復旧 Ubuntu（既定 Windows）になった。

### 対策

`write_grub_menu.py` に live 用のオプションを追加した。

```bash
sudo ./scripts/prepare.sh /mnt/iso/ubuntu-26.04.1-live-server-arm64.iso \
    --write --ssh || true      # seed/CIDATA を作る。update-grub 失敗は無視
sudo python3 pipeline/write_grub_menu.py /boot/efi / /dev/sda2 \
    --timeout 30 \
    --live-iso /mnt/iso/ubuntu-26.04.1-live-server-arm64.iso \
    --live-seed --first-boot-live
sudo reboot
```

- `--live-iso`: ISO のあるマウント先の UUID と相対パスを `findmnt` で
  取得し、`loopback` + `boot=casper ... toram` の menuentry を生成
- `--live-seed`: `ds=nocloud` をカーネル引数へ追加
- `--first-boot-live`: `EFI/ubuntu/grubenv` の `next_entry` を live の
  タイトルに設定。GRUB が既存の `load_env` / `next_entry` 処理で 1 回だけ
  選択する

生成した `grub.cfg` を `grub-script-check` で検証し、`next_entry=Ubuntu live
(toram)` を確認した。README のステージ2-B と SCRATCH.md にも同じ手順を
追記した。

### 未確認

再起動して live が実際に `Ubuntu live (toram)` を起動するかは未確認。
起動しなければシリアルの GRUB メニューで live エントリを直接選ぶこと。

## 22.54 UEFI の Ubuntu エントリが古い ESP GUID を指していた (2026-11-23)

### 症状

Windows は起動できたが、UEFI の BootMenu で "Ubuntu" を選んでも起動しない。
EFI シェル → `startup.nsh`（`..V10-START` / `..V10-MAPPED` / `..V10-ESP-fs0`）
→ GRUB 経由なら `Ubuntu (recovery)` は起動する。GRUB → `Windows 11` は
`Failed to boot both default and fallback entries` になった。

### 検証（実機・読み取り専用）

- `lsblk`: 現在の ESP は `sda1` = `f6ed2307-e6e8-4b5d-b7b5-9d7e76a2f520`、
  Ubuntu `/` = `sda2`、Windows = `sda3`。`sdb1` = `057542d2-...` は古い
  BlockVolume の ESP。
- `efibootmgr -v` の `Boot0007* Ubuntu` は
  `HD(1,GPT,5933fc32-596a-4286-9916-a5e24583534c,...)/\EFI\ubuntu\grubaa64.efi`
  を指していた。この GUID は現在のどのパーティションにも存在しない
  （22.20 頃の ESP の GUID）。つまり **ローダーパスは正しいがデバイスパスが
  古い**。対して `Boot0003 Windows Boot Manager` は `f6ed2307-...` を
  正しく指していた。
- `\EFI\ubuntu\grubaa64.efi` / `shimaa64.efi` / `grub.cfg` / `grubenv` は
  全部存在し、`/boot/vmlinuz-7.0.0-30-generic.raw`（72,613,888 B）もある。
  `grub.cfg` の `linux` 行も `.raw` を指すため 22.48 の stubble assert は
  原因ではない（同節で NVRAM 経由では発動しないと明記）。
- `oci-ubuntu-boot-order.service` は active / exited 0 だったが、
  `pipeline/oci-ubuntu-boot-order.sh` の `find_ubuntu_num()` は
  `\EFI\ubuntu\grubaa64.efi` という**文字列だけ**で既存 entry を判定する。
  古い GUID の Boot0007 が「見つかった → 先頭なので OK」となり、
  デバイスパスを一度も検証していなかった。

### 対処

1. NVRAM を修正: `sudo efibootmgr -b 0007 -B` →
   `sudo /usr/local/sbin/oci-ubuntu-boot-order`。
   新しい `Boot0007 Ubuntu` は
   `HD(1,GPT,f6ed2307-...)/\EFI\ubuntu\shimaa64.efi` を指し、BootOrder
   `0007,0003,...` の先頭になった（ESP に shim があるためローダーは shim）。
2. `oem/boot.ps1`: Windows 起動時に ESP を `mountvol` で確認し、
   `bcdedit /enum firmware` の Ubuntu entry が `{bootmgr}` と同じ ESP
   を指すか照合。古い/重複 entry は削除し、無ければ
   `bcdedit /create /d Ubuntu /application firmware` で作って
   `device partition=<ESP文字>` と `path` を設定し、
   `displayorder <id> /addfirst` で先頭へ。作れない場合だけ旧来の
   `{bootmgr} /addlast` にフォールバック。
3. `pipeline/oci-ubuntu-boot-order.sh`: `find_ubuntu_entries()` が
   `Boot<num> <GPT GUID>` を出力し、現在の ESP の PARTUUID と違う
   entry を削除してから作り直す。重複も削除。
4. `docs/DUALBOOT.md` / `docs/OCI.md` に手順とトラブルシュートを追記。

### 検証（対処後）

- わざと古い `sdb1` を指す一時 entry を作り、
  `Boot0007` (正) + `Boot0008` (GUID `057542d2-...`) の状態で unit を実行。
  `Boot0008 points at old ESP ...; deleting` と出て削除され、
  `Boot0007 is already first` のまま正しい entry だけが残った。

### 未確認

- Windows を起動して `oem/boot.ps1` の `bcdedit /create /application firmware`
  が ARM64 で実際に NVRAM entry を作れるかは未確認（失敗時は
  `{bootmgr} /addlast` にフォールバックする）。

## 22.55 WBM メニューから Ubuntu を外し timeout を 1 秒にする (2026-11-23)

### 実験結果

- 22.54 の NVRAM 修正後、再起動すると GRUB が消えなくなった。
  `BootOrder: 0007,0003,...`、`Boot0007 Ubuntu` は
  `HD(1,GPT,f6ed2307-...)/\EFI\ubuntu\shimaa64.efi` を指す。
  Windows 起動後の BCD では Ubuntu オブジェクト
  `{382d1743-e754-11f1-8bc4-806e6f6e6963}` の path も
  `\EFI\ubuntu\shimaa64.efi` に同期されていた。
- 実験として `{382d1743-...}` を `{bootmgr}` の displayorder に追加して
  再起動すると、WBM の OS メニューに **Windows 11 と Ubuntu が並んだ**。
  Ubuntu を選ぶと失敗し、ARM64 の BootMgr が bootapp を起動できない
  既知の制約を再確認した。

### 原因の整理

BCD には 2 つの displayorder がある。

- `{fwbootmgr}` (a5a30fa2) の `24000001`: ファームウェアの BootMenu
- `{bootmgr}` (9dea862c) の `24000001`: WBM の OS メニュー

Ubuntu は前者にしか入っていなかったため、WBM には Windows 11 しか
表示されなかった。`{bootmgr}` の timeout 要素 `25000004` も 30 秒
（0x1e）のままだった。

### 対処

- 実 BCD: `{bootmgr}` の displayorder から Ubuntu を削除し、
  `25000004` を 1 に設定。`{fwbootmgr}` の Ubuntu は維持。
- `oem/boot.ps1`: 毎回の Windows 起動で
  `bcdedit /set {bootmgr} timeout 1` と
  `bcdedit /set {bootmgr} displayorder <Ubuntu GUID> /remove` を実行。
- `docs/DUALBOOT.md` に WBM メニューの扱いを明記。

実験用の BCD 編集・バックアップはリポジトリ外
（`/home/ubuntu/wbm-test-backup/`）に置き、コミットしない。

## 22.56 RAM 起動のセットアップを最小構成に分離 (2026-11-23)

### 症状

- `sudo ./scripts/prepare.sh /srv/iso/ubuntu-26.04.1-live-server-arm64.iso
  --write --ssh --once` が
  `prepare: fatlabel failed for /dev/sda1 (install dosfstools)` で停止。
- `sudo ./scripts/setup.sh` は
  `E: The repository 'file:/cdrom resolute Release' does not have a Release file.`
  で停止。復旧 Ubuntu には `/cdrom` が無い。
- 復旧 Ubuntu には `update-grub` / `grub-reboot` / `grub-editenv` も無く、
  `prepare.sh --once` は dosfstools を入れても次の段階で失敗する。
  実際に読まれる GRUB 設定は ESP の `\EFI\ubuntu\grub.cfg` なので、
  `/etc/grub.d/40_custom` への追記では live エントリが出ない（22.53 と同じ）。

### 対処

- `internal/apt.sh`（新規）: インストーラが残した `cdrom.sources` /
  `cdrom.list` を `.disabled` にリネームし、`/etc/apt/sources.list` の
  `deb cdrom:` 行をコメントアウト。`setup.sh` と `setup-live.sh` から
  `apt-get update` の前に呼ぶ。冪等。
- `scripts/setup-live.sh`（新規）: RAM ビルドに必要なパッケージだけを
  入れる。CI/アップロード用の `rclone` / `age` / `jq` / `shellcheck` /
  `libxml2-utils` / `debootstrap` は入れない。`python3-winrm` と
  `rpm2cpio`/`cpio` も任意として除外。`/dev/shm` の再マウントと
  `/dev/shm/iso` / `/dev/shm/build` の作成、`preflight.sh` の実行まで行う。
  `--check` は変更しない。
- `internal/preflight.sh`: `rclone` を必須から任意（warn）へ変更。
  `age` と同じ扱いにする。
- `scripts/prepare.sh`: `--seed-only` を追加。cloud-init seed と ESP の
  `CIDATA` ラベルだけを書き、GRUB 設定は触らず終了する。
- `scripts/prepare-live.sh`（新規）: `prepare.sh --ssh --seed-only` と
  `write_grub_menu.py --live-iso ... --live-seed --first-boot-live` を
  組み合わせ、ESP の GRUB メニューに live エントリを書き、`next_entry`
  で次回 1 回だけ live を起動する。
- `README.md` / `docs/OCI.md`: 入口スクリプトの一覧、最小構成、復旧 Ubuntu
  からの live 起動手順、apt/cdrom の注意を追記。

### 検証

- `sudo bash internal/apt.sh disable_cdrom_source` の後
  `apt-get update` が成功。`/dev/sda1` のラベル操作に必要な
  `dosfstools` だけを導入（`fatlabel` が使えるようになった）。
- `./scripts/setup-live.sh --check` は apt エラー無く動作し、不足
  パッケージと preflight の結果を表示した。
- 新規スクリプトは `bash -n` を通過。

### 未確認

- `prepare-live.sh` は ESP を書き換えるため、未実行。再起動して live が
  起動するかは次の作業で確認する。
- live 起動後に `setup-live.sh` を実行して、最小パッケージで
  `build.sh` の preflight が通るかは未確認。
