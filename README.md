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
  snapshots/<YYYYmmdd-HHMMSS>/   # 毎回新規。LaunchAgent は既存 inode を更新できない
    .complete
    brew/Brewfile
    ...
    encrypted/secrets-latest.tar.gpg
    tool/                    # 復元用キット（その回の実効設定）
      backup.conf.local
      gpg-pass               # mode 600。フォルダ取得者は復号可能
      scripts/
  logs/
  changes/
```

差分の実体は `~/Library/Application Support/pc-backup/mirror`（ローカル）。
OneDrive へはスナップショットを新規ディレクトリとしてコピーする。14日より古いものは削除する。
`snapshots/` が無いときは復元は従来の `mirror/` を見る。

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

LaunchAgent から OneDrive 上の既存ファイルを開くと `Operation not permitted` になる。
バックアップは既存ツリーを上書きせず、`snapshots/<timestamp>/` を新規作成する。

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
<PC_BACKUP_ROOT>/snapshots/<latest>/tool/scripts/restore.sh --yes --brew
```

再認証（gh / SSO / MCP 等）と Cursor User Rules（Settings）はファイルでは復元できない。
