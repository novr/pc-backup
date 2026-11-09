# pc-backup

任意の同期先ディレクトリへ、設定・AI資産を rsync ミラーするツール。

## 構成

```
pc-backup/
  backup.conf.example      # デフォルト（パス一覧含む）→ 先に source
  backup.conf.local        # 必須・gitignore（ROOT / GPG / 上書き）
  scripts/
    backup.sh
    restore.sh
    brewfile-update.sh
    install-launch-agent.sh
```

## バックアップ先

`PC_BACKUP_ROOT` 直下:

```
<PC_BACKUP_ROOT>/
  mirror/
    brew/Brewfile
    ...
    encrypted/secrets-latest.tar.gpg
  logs/
  changes/
  tool/                    # 復元用キット（毎回・実効設定を生成）
    backup.conf.local      # バックアップ時点の実効値（example 不要）
    gpg-pass               # mode 600。フォルダ取得者は復号可能
    scripts/
```

対象パスは `backup.conf.local` の `PC_BACKUP_DIRS` / `FILES` / `SECRETS` / `DIR_EXCLUDES`。
`backup.conf.example` の配列は空。`.local` で定義する。

## セットアップ

```bash
cd ~/Developer/my/pc-backup
cp backup.conf.example backup.conf.local
# PC_BACKUP_ROOT、パス配列、PC_BACKUP_GPG_PASS を設定
security add-generic-password -a pc-backup -s pc-backup-gpg -w 'your-passphrase' -U

chmod +x scripts/*.sh
./scripts/backup.sh
./scripts/install-launch-agent.sh
```

OneDrive / iCloud 等の Files On-Demand 先では、`mirror/`（少なくともその親）を
「このデバイスに常に保持」にする。dataless のままだと rsync / secrets 更新が
`Operation not permitted` で失敗する。LaunchAgent 実行時は `/bin/bash` に
フルディスクアクセスが必要な場合もある。

## 手動実行

```bash
PC_BACKUP_DRY_RUN=1 ./scripts/backup.sh
./scripts/backup.sh
./scripts/brewfile-update.sh
```

## 復元

conf のパス一覧に従い、ミラーから `$HOME` へ戻す。
リポジトリが無いマシンでは `tool/` から実行する。

```bash
# リポジトリから
./scripts/restore.sh --dry-run          # 確認のみ
./scripts/restore.sh                    # 対話確認あり
./scripts/restore.sh --yes              # 確認スキップ
./scripts/restore.sh --yes --brew       # Homebrew も bundle
./scripts/restore.sh --yes --no-secrets # 平文ミラーのみ

# バックアップ先のキットから（新マシンなど）
<PC_BACKUP_ROOT>/tool/scripts/restore.sh --yes --brew
```

再認証（gh / SSO / MCP 等）と Cursor User Rules（Settings）はファイルでは復元できない。
