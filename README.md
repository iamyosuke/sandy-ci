# Sandy public macOS runner template

このディレクトリを、非公開の Sandy リポジトリを検証する専用 public repository にコピーします。公開リポジトリ側の入口は `repository_dispatch` だけです。`push`、`pull_request`、`issue_comment`、`workflow_dispatch` は追加しません。

private coordinator は、ランダムな UUID の `request_id` と private request Workflow の `request_run_id` だけを `client_payload` に入れて dispatch します。リポジトリ、ref、manifest、コマンド、URL を payload で渡してはいけません。public runner は `SANDY_SOURCE_TOKEN` で private run の `sandy-private-request-$request_id` artifact を取得し、repository ID、head/base SHA、期待job集合を検証します。

public repository には次の専用 secrets だけを設定します。

- `SANDY_SOURCE_TOKEN`: private repository の read-only Contents と Actions 権限。private request artifact を取得するため Actions read が必要です。wrapper は固定 repository ID から一時的に repository 名を解決し、公開コードへ private repository 名を埋め込みません。
- `SANDY_PAYLOAD_KEY`: products と test results の暗号化・復号だけに使う専用鍵。

secretを持つfetch/decrypt/encrypt stepと、PRコードを実行するbuild/test stepを分離します。公開 workflow は build/test step に token/key を渡さず、ログは runner の一時領域に捕捉します。public artifactにはproducts・結果の暗号文だけを置きます。

ラッパーは `GITHUB_RUN_ATTEMPT=1` を要求するため、public UI からの直接 re-run は拒否します。private coordinator が新しい request UUID で全件を再実行してください。prepare jobが共有成果物を一度だけ作成し、opaqueな6レーンを実行します。実際のテスト種別、manifest、scheme、コマンドはprivate source内のentrypointで解決します。finalize jobはrequestの期待job集合と全レーン結果を照合し、`result.json`を`result.bundle.enc`として保存します。

公開側の artifact は暗号文と HMAC だけで、保存期間は2日です。復号前に HMAC を検証するため、壊れた・差し替えられた artifact を受け入れません。products と各6結果は固有のファイル名で保存し、finalize が全件を検証して private evidence を復号・集約した後、最終 bundle を HMAC 付きで再暗号化します。最終 evidence には products 本体を含めず、build log と products のファイル数・ハッシュだけを残します。

公開リポジトリは、ここにある `.github/workflows/` と `runner/` をリポジトリ root にコピーして作成します。公開リポジトリ側には private source や request の内容を commit しません。このテンプレートは public repository の作成と Secrets の登録自体は行いません。GitHub App、R2、control bucket、カスタム controller は使用しません。
