# Sandy public macOS runner template

このディレクトリを、非公開の Sandy リポジトリを検証する専用 public repository にコピーします。公開リポジトリ側の入口は `repository_dispatch` だけです。`push`、`pull_request`、`issue_comment`、`workflow_dispatch` は追加しません。

private coordinator は、ランダムな UUID の `request_id` と private request Workflow の `request_run_id` だけを `client_payload` に入れて dispatch します。リポジトリ、ref、manifest、コマンド、URL を payload で渡してはいけません。public runner は `SANDY_SOURCE_TOKEN` で private run の `sandy-private-request-$request_id` artifact を取得し、repository ID、head/base SHA、期待job集合を検証します。

public repository には次の専用 secret と変数を設定します。

- `SANDY_SOURCE_TOKEN`: private repository の read-only Contents と Actions 権限。private request artifact を取得するため Actions read が必要です。wrapper は固定 repository ID から一時的に repository 名を解決し、公開コードへ private repository 名を埋め込みません。
- `SANDY_CI_RECIPIENT_CERT`（変数）: 非公開側だけが持つ秘密鍵に対応する公開証明書。テスト結果を暗号化するために使います。
- `SANDY_CALLBACK_TOKEN`: private Sandy repository だけに限定した fine-grained PAT。権限は Issues: write のみとし、短い有効期限（推奨7日）を設定します。公開 runner の完了通知にだけ使用します。
- `SANDY_CALLBACK_REPOSITORY_ID`（変数）: private Sandy repository の数値 repository ID（`1217636338`）。
- `SANDY_CALLBACK_ISSUE_NUMBER`（変数）: public runner 完了通知専用の private relay issue 番号（`81`）。

`sandy-public-callback.yml` は既存の `private macOS validation` workflow が完了したときにのみ実行されます。通知前に workflow path/name、`repository_dispatch` event、初回 attempt、workflow SHA が現在の `main` の履歴に含まれること、run title 内の UUIDv4 と request run ID を検証します。run title は `sandy-public-ci-<request UUID>-<request run ID>` 形式です。通知本文は `request_id`、`request_run_id`、`public_run_id` だけを持つ固定 JSON object です。workflow source の checkout、artifact download、候補コード実行は行いません。

`SANDY_SOURCE_TOKEN` を使う fetch は候補コード実行前に終了し、Git remote に残った認証情報を除去します。候補コード実行後の暗号化には公開証明書だけを使い、長期秘密鍵を public runner に渡しません。ログは runner の一時領域に捕捉し、public artifact には暗号化した結果だけを置きます。

ラッパーは `GITHUB_RUN_ATTEMPT=1` を要求するため、public UI からの直接 re-run は拒否します。private coordinator が新しい request UUID で全件を再実行してください。prepare job と opaque な6レーンを実行し、製品を使うレーンは各 runner 内でビルドします。実際のテスト種別、manifest、scheme、コマンドは private source 内の entrypoint で解決します。最終集約は非公開側で行います。

公開側の artifact は AES-256-GCM の CMS 暗号文だけで、保存期間は2日です。非公開 coordinator が全7件を秘密鍵で復号し、認証タグ・候補 SHA・期待 job 集合・証拠ファイルを検証してから private check を発行します。最終 evidence には products 本体を含めず、build log と products のファイル数・ハッシュだけを残します。

公開リポジトリは、ここにある `.github/workflows/` と `runner/` をリポジトリ root にコピーして作成します。公開リポジトリ側には private source や request の内容を commit しません。このテンプレートは public repository の作成と Secrets の登録自体は行いません。GitHub App、R2、control bucket、カスタム controller は使用しません。
