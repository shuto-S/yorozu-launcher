# Yorozu 実装計画

最終更新: 2026-07-30

## 1. 目的

Yorozu は、macOS 上で日常的に使う操作を一つのコマンドパレットから素早く呼び出す、軽量なネイティブアプリである。

初期リリースでは、次の四つを同じ検索・操作モデルで提供する。

1. アプリランチャー
2. クリップボード履歴
3. スニペット
4. OpenAI 連携 AI チャット

この計画は、参照会話の本文にある「Raycast の代替となる macOS アプリ」と、そこで決定したプロダクト名 `Yorozu` を前提にする。

## 2. 成功条件

### 2.1 プロダクト要件

- 設定可能なグローバルショートカットから Yorozu を開ける。
- 表示直後からキーボードだけで検索、選択、実行、キャンセルできる。
- アプリ、クリップボード、スニペットをローカルで横断検索できる。
- AI チャットを明示的に開いた場合だけネットワーク通信する。
- クリップボードや選択テキストを、ユーザー操作なしで AI へ送信しない。
- Accessibility / Input Monitoring 権限がなくても、アプリ起動、履歴閲覧、AI チャットなど利用可能な機能は動作する。

### 2.2 性能目標

以下は v0.1 の計測目標であり、実装後に Instruments と `os_signpost` で確認する。

| 指標 | 目標 |
|---|---:|
| 常駐後のホットキーからパレット表示 | p95 80 ms 以下 |
| キー入力から検索結果更新 | p95 30 ms 以下 |
| アイドル時 CPU 使用率 | 平均 0.5% 未満 |
| 常駐メモリ | 100 MB 未満 |
| 通常検索時のネットワーク通信 | なし |

### 2.3 品質条件

- 主要なランキング、重複排除、保存期間、貼り付け競合を自動テストで保護する。
- API キー、クリップボード本文、AI 会話本文をログへ出力しない。
- 権限拒否、API エラー、DB エラーが起きても、パレット全体を利用不能にしない。
- サポート対象アプリで日本語 IME 使用中の入力を壊さない。

## 3. スコープ

### 3.1 自分で使える MVP

- AppKit の `NSPanel` を使った常駐コマンドパレット
- グローバルショートカット
- `/Applications` などを対象としたアプリ索引と起動
- テキスト、URL、ファイルパスのクリップボード履歴
- クリップボード履歴の検索、再コピー、貼り付け
- スニペットの作成、編集、検索、挿入
- OpenAI Responses API を使ったストリーミングチャット
- ローカル会話履歴
- 設定画面
- API キーの Keychain 保存
- 最低限の権限オンボーディング

### 3.2 配布可能なベータ

- ASCII キーワードによるスニペット自動展開
- アプリ別のクリップボード記録・自動展開除外
- 保存期間、最大件数、全件削除
- ログイン時起動
- 性能計測と回帰基準
- Developer ID 署名、Hardened Runtime、Notarization
- クラッシュ診断とプライバシー説明
- 自動更新

### 3.3 初期スコープ外

- ChatGPT 本体の会話履歴との同期
- Windows、Linux、iOS 対応
- 拡張機能ストアや第三者コードのアプリ内実行
- チーム共有、クラウド同期
- 画像 OCR
- すべてのクリップボード表現の完全保存・復元
- AI による自律的な Mac 操作
- 開発者共通の OpenAI API キーをクライアントへ同梱する方式
- Mac App Store 配布

## 4. 技術方針

### 4.1 基本構成

| 領域 | 採用方針 |
|---|---|
| 言語 | Swift |
| UI | AppKit と SwiftUI のハイブリッド |
| パレット | `NSPanel` + `NSHostingView` |
| 非同期処理 | Swift Concurrency (`async/await`, `actor`) |
| 永続化 | SQLite + GRDB |
| 全文検索 | SQLite FTS5 trigram tokenizer |
| API キー | macOS Keychain |
| AI | OpenAI Responses API |
| 配布 | Developer ID 直接配布 |
| 依存管理 | Swift Package Manager |

SwiftUI は検索結果、設定、チャットなどの画面構築に使い、ウィンドウ、フォーカス、アクティブアプリ復帰、クリップボード、Accessibility など macOS 固有の制御は AppKit 側へ置く。

### 4.2 最低対応 OS

v0.1 は **macOS 14 Sonoma 以降**を暫定対象とする。実装開始時に、利用予定 API、想定ユーザー、検証可能な Mac を確認して最終決定する。

### 4.3 外部依存候補

| パッケージ | 用途 | 導入タイミング |
|---|---|---|
| KeyboardShortcuts | ユーザー設定可能なグローバルショートカット | Phase 0 |
| GRDB.swift | SQLite、migration、型付き DB アクセス | Phase 0 |
| Sparkle 2 | 直接配布版の自動更新 | Phase 6 |

依存追加時には、最新リリース、macOS 対応範囲、ライセンス、メンテナンス状況を確認し、バージョンを固定する。Sparkle は MVP には入れない。

## 5. アーキテクチャ

```text
Global Hotkey
    │
    ▼
PaletteWindowController (AppKit / NSPanel)
    │
    ▼
PaletteViewModel (MainActor)
    │
    ▼
SearchCoordinator
    ├── ApplicationProvider
    ├── ClipboardProvider
    ├── SnippetProvider
    └── AIProvider
            │
            ▼
Repositories / Platform Services
    ├── DatabaseWriter actor
    ├── ClipboardMonitor actor
    ├── ApplicationIndex actor
    ├── PasteCoordinator actor
    ├── SnippetExpansionService
    ├── OpenAIResponsesClient actor
    └── KeychainStore
```

### 5.1 モジュール境界

- `App`: 起動、依存解決、メニューバー、アプリ全体の状態。
- `Core`: 検索結果、アクション、ランキングなど機能横断の型とロジック。
- `Features`: Applications、Clipboard、Snippets、AI の各ユースケースと画面。
- `Platform`: AppKit、Pasteboard、Accessibility、Keychain、FSEvents、OpenAI HTTP 通信。
- `Data`: DB migration、record、repository。
- `Services`: 権限、ログイン項目、更新、診断。

### 5.2 Provider インターフェース

各機能は共通の検索結果とアクションへ変換する。初期版では同一プロセス内で動作させる。

```swift
protocol CommandProvider: Sendable {
    var id: CommandProviderID { get }

    func search(
        query: SearchQuery,
        context: SearchContext
    ) async -> [CommandResult]

    func actions(
        for result: CommandResult,
        context: SearchContext
    ) -> [CommandAction]

    func perform(
        action: CommandAction,
        result: CommandResult,
        context: SearchContext
    ) async throws
}
```

`CommandResult` は表示に必要な値だけを保持し、AppKit や DB record を直接公開しない。検索リクエストには世代番号を付け、古い非同期検索結果で新しい画面を上書きしない。

### 5.3 想定ディレクトリ

```text
Yorozu/
├── App/
├── Core/
│   ├── CommandKit/
│   ├── Search/
│   ├── Ranking/
│   └── Actions/
├── Features/
│   ├── Applications/
│   ├── Clipboard/
│   ├── Snippets/
│   └── AI/
├── Platform/
│   ├── PaletteWindow/
│   ├── Hotkeys/
│   ├── Pasteboard/
│   ├── Accessibility/
│   ├── EventTap/
│   ├── Workspace/
│   ├── Keychain/
│   └── OpenAI/
├── Data/
│   ├── Database/
│   ├── Migrations/
│   └── Repositories/
└── Services/
    ├── Permissions/
    ├── LoginItem/
    ├── Update/
    └── Diagnostics/

YorozuTests/
YorozuUITests/
```

## 6. 共通 UX

### 6.1 基本操作

- グローバルショートカット: パレットを開閉する。
- `↑` / `↓`: 選択を移動する。
- `Return`: 主アクションを実行する。
- `⌘ K`: 選択項目の Action Panel を開く。
- `Esc`: 一段戻る。ルートなら閉じる。
- `⌘ ,`: 設定を開く。
- `?` プレフィックス: Quick AI を開く。

空クエリでは、Pin、最近の利用、利用頻度を合成して候補を表示する。

### 6.2 パレット表示フロー

1. 表示前のフロントアプリとウィンドウ文脈を記録する。
2. 既存の `NSPanel` を再利用して表示する。
3. 検索フィールドを first responder にする。
4. 実行時は必要に応じてパレットを閉じる。
5. テキスト挿入が必要なら元アプリを再アクティブ化する。
6. 挿入完了または失敗を、秘密情報を含まない形で記録する。

## 7. 機能別実装

### 7.1 アプリランチャー

#### 索引対象

- `/Applications`
- `/System/Applications`
- `/System/Applications/Utilities`
- `~/Applications`
- ユーザーが追加した任意ディレクトリ

#### 保存・索引項目

- 表示名、正規化名、ローカライズ名
- Bundle ID
- app bundle URL
- アイコン参照
- Alias
- Pin
- 最終利用日時、利用回数

起動時にバックグラウンドで走査し、Bundle ID と標準化 URL で重複排除する。初回索引が終わる前も、得られた候補から段階的に検索できるようにする。アイコンは表示対象だけ遅延ロードし、サイズ別の `NSCache` を使う。

MVP では起動時と手動操作で再索引する。FSEvents による差分更新は、計測上必要になった時点またはベータ前に追加する。

#### ランキング

```text
score =
  fuzzy match
  + prefix bonus
  + acronym bonus
  + alias bonus
  + pin bonus
  + frequency score
  + recency score
```

履歴によるスコアは上限を設け、過去に頻繁に使ったアプリが永久に上位を占有しないよう時間減衰させる。文字列一致の妥当性を利用履歴より優先する。

#### 完了条件

- 代表的な system app、通常 app、ユーザー app を検索・起動できる。
- `vsc` のような頭文字検索、Alias、日本語表示名をテストできる。
- app の削除や移動後に、壊れた候補を安全に除外できる。

### 7.2 クリップボード履歴

#### 監視

`NSPasteboard.general.changeCount` を 350 ms 間隔の低優先度タスクで確認する。変化があった場合だけ内容を読む。

MVP の対象は次のとおり。

- プレーンテキスト
- URL
- ファイル URL
- コピー時刻
- コピー元アプリの Bundle ID
- Pin

保存前に内容種別ごとの正規化ハッシュを計算し、直前項目との重複を抑制する。書き込みは `DatabaseWriter` actor へ集約する。

#### プライバシー

- パスワード管理アプリと Keychain Access を初期除外候補にする。
- ユーザーが除外アプリを追加・削除できるようにする。
- 監視の一時停止、保存期間、最大件数、全件削除を用意する。
- 履歴本文をログ、クラッシュ属性、Telemetry に含めない。
- AI への添付は毎回ユーザーの明示操作を必要とする。

コピー元アプリの判定は変化検知時のフロントアプリに基づくため、完全ではない。この制約は設定画面またはプライバシー説明に明記する。

#### 再コピー・貼り付け

自分自身による Pasteboard 更新の再記録を防ぐため、次を管理する。

- `expectedChangeCount`
- `injectedContentHash`
- `suppressionDeadline`

貼り付け後に元の Pasteboard を復元する場合、復元直前の `changeCount` が想定値と一致した場合だけ戻す。途中でユーザーが新しくコピーした内容は上書きしない。

#### 完了条件

- テキスト、URL、ファイル URL を保存・検索・再利用できる。
- 除外アプリ、一時停止、期限切れ削除が機能する。
- 自己貼り付けで履歴が増殖しない。
- 競合する新規コピーを復元処理が上書きしない。

### 7.3 スニペット

#### Phase A: 検索して挿入

- 名前、キーワード、本文、タグ、利用回数を保存する。
- 一覧、作成、編集、削除、検索を提供する。
- `{clipboard}`、`{date}`、`{date:format}`、`{time}`、`{uuid}`、`{cursor}` を展開する。
- 元アプリへの挿入は `PasteCoordinator` をクリップボード機能と共有する。

プレースホルダは保存時に構文検証し、不正な記法を実行時まで持ち越さない。クリップボード参照は明示的な実行時だけ評価する。

#### Phase B: 自動展開

`CGEventTap` でキー入力を監視し、小さなリングバッファ上で ASCII キーワードを照合する。

安全側の初期仕様は次のとおり。

- `;` または `::` プレフィックスを必須にする。
- Space、Tab、Return などの delimiter 後にだけ展開する。
- 日本語 IME の変換中は展開しない。
- Secure Input 中、権限なし、非対応アプリでは何もしない。
- アプリ単位で無効化できる。
- event callback 内で DB 読み書きや文字列展開をしない。

イベントコールバックでは一致候補をキューへ渡すだけにし、Backspace と貼り付けは別タスクで実行する。event tap がタイムアウトで無効化された場合は再有効化し、連続失敗時は自動展開を停止してユーザーへ知らせる。

#### 完了条件

- 検索挿入は Accessibility 権限あり・なしの状態を明確に扱える。
- ASCII 入力中だけ自動展開し、日本語変換中の入力を破壊しない。
- Safari、Chrome、Slack、VS Code、Terminal、Office 系アプリで手動検証する。
- パスワード入力、Secure Input、除外アプリでは展開しない。

### 7.4 AI チャット

#### 方針

- 新規実装には OpenAI Responses API を使う。
- HTTP の Server-Sent Events を `URLSession` で受信する。
- `response.created`、`response.output_text.delta`、`response.completed`、`error` を最低限扱う。
- 会話履歴はローカル SQLite を正とし、初期版では `store: false` を明示する。
- 必要な過去メッセージだけをトークン予算内で毎回送る。
- ChatGPT 本体の履歴とは同期しない。

モデル ID はコード各所へ直書きせず設定へ集約する。初期既定値は実装時点の利用可能モデル、応答速度、費用を確認して決める。

#### API キー

個人利用 MVP は BYOK とする。

1. ユーザーが OpenAI API キーを入力する。
2. Keychain へ保存する。
3. ログ、DB、UserDefaults、クラッシュ情報には保存しない。
4. 設定画面では値を再表示せず、登録済み状態と削除操作だけを提供する。

一般配布で開発者側が利用料を負担する場合は、Mac アプリへ共有キーを含めず、認証、レート制限、利用量管理を備えたバックエンド経由へ切り替える。

#### MVP 機能

- 新規チャット、会話一覧、会話削除
- ストリーミング表示、生成停止、再生成
- Markdown とコードブロック表示
- 回答コピー
- モデルと system/developer instruction の設定
- 選択テキスト、現在のクリップボードを明示的に添付
- Quick AI と通常チャットの分離
- オフライン、認証失敗、rate limit、server error の区別

#### 完了条件

- SSE の分割位置に依存せず JSON event を復元できる。
- キャンセル後に遅れて届いた delta が画面や DB を更新しない。
- 部分応答と失敗状態を区別して保存・再試行できる。
- API キーと会話本文がログへ出ない。

## 8. データ設計

最初の migration では、少なくとも次のテーブルを用意する。

```text
applications
application_aliases
usage_events

clipboard_items
clipboard_search (FTS5)

snippets
snippet_tags
snippet_search (FTS5)

ai_threads
ai_messages

settings
```

### 8.1 共通ルール

- ID はローカル生成し、将来の同期追加でも衝突しにくい形式にする。
- 日時は UTC で保存し、表示時にローカル時刻へ変換する。
- 本文のない metadata と検索対象本文を分離できる設計にする。
- migration は forward-only とし、既存 DB を使った migration test を用意する。
- AI メッセージとクリップボード本文は削除要求時に関連検索索引からも削除する。

### 8.2 日本語検索

- 入力と索引値を Unicode NFKC、英字小文字、空白正規化する。
- アプリと頻用スニペットはメモリ内検索する。
- 長いクリップボード本文と AI 会話は FTS5 trigram を使う。
- 3 文字未満のクエリは、直近の件数を制限したメモリ検索または `LIKE` へフォールバックする。

## 9. エラー処理と権限

### 9.1 権限要求

初回起動で全権限を一括要求しない。

| タイミング | 説明・要求 |
|---|---|
| 初回起動 | グローバルショートカット設定 |
| クリップボード有効化 | 保存対象、期間、除外アプリの説明 |
| 初回の直接貼り付け | Accessibility の目的と設定導線 |
| 自動展開有効化 | Accessibility / Input Monitoring、入力監視範囲、除外、停止方法の説明 |

権限を拒否された場合は、設定への導線を示し、検索結果のコピーなど権限不要の代替操作を残す。

### 9.2 エラー分類

- `UserActionError`: 入力不足、対象削除済み、権限不足。
- `RecoverableError`: 一時的 API 障害、DB busy、event tap 無効化。
- `ConfigurationError`: API キー未設定、保存先初期化失敗。
- `InvariantViolation`: 開発時に検出すべき状態不整合。

ユーザー向け文言と診断ログを分離し、ログには本文や認証情報を入れない。

## 10. セキュリティとプライバシー

- API キーは Keychain のみに保存する。
- クリップボードと AI 本文を `UserDefaults` に保存しない。
- OSLog の privacy 指定だけに依存せず、秘密値そのものをログ引数へ渡さない。
- DB ファイル、診断 export、クラッシュレポートのデータ範囲を文書化する。
- 「全履歴削除」は DB record、FTS row、キャッシュを同じ操作で削除する。
- 貼り付け対象が secure field か確実に判定できない場合は、安全側に倒してコピーのみを提供する。
- OpenAI へ送る内容を送信前 UI で確認できるようにする。
- Telemetry を導入する場合も、本文、検索語、アプリのウィンドウタイトルは収集しない。

## 11. テスト計画

### 11.1 Unit test

- クエリ正規化、日本語、全角半角
- fuzzy、prefix、acronym、Alias のランキング
- 利用履歴の時間減衰
- app URL と Bundle ID の重複排除
- クリップボード重複抑止
- 保存期間と最大件数
- Pasteboard 復元の `changeCount` 競合
- スニペット構文とプレースホルダ
- event ring buffer と delimiter 判定
- SSE parser の任意分割
- AI キャンセル、失敗、部分応答の状態遷移
- DB migration

### 11.2 Integration test

- 一時 SQLite DB を使った repository と FTS 検索
- fake Pasteboard と fake Workspace を使った貼り付けフロー
- fixture app bundle を使った索引
- stub HTTP server を使った Responses API streaming
- Keychain wrapper の保存・取得・削除

### 11.3 UI test

- ホットキー相当の表示後に検索フィールドへフォーカスされる。
- キーボードだけで検索、選択、Action Panel、戻る操作ができる。
- 権限なし、API キーなし、空履歴の empty state を表示できる。
- AI の streaming と停止操作で表示が破綻しない。

### 11.4 手動 QA マトリクス

| 領域 | 主な組み合わせ |
|---|---|
| macOS | 最低対応版、最新安定版 |
| CPU | Apple Silicon。Intel 対応は対象 OS 決定時に判断 |
| IME | ABC、日本語ローマ字、日本語かな |
| 対象アプリ | Finder、Safari、Chrome、Slack、VS Code、Terminal、Office |
| 権限 | 未決定、許可、拒否、許可後に取り消し |
| AI | 正常、オフライン、401、429、5xx、途中切断、キャンセル |

## 12. 実装フェーズ

### Phase 0: プロジェクト基盤

作業:

- Xcode project、app target、unit/UI test target を作る。
- AppKit lifecycle とメニューバー常駐を用意する。
- `NSPanel` と SwiftUI の空パレットを表示する。
- グローバルショートカットを接続する。
- GRDB と初期 migration を導入する。
- dependency container、ログ、`os_signpost` の基盤を作る。
- CI で build と unit test を実行する。

Exit criteria:

- ホットキーで空パレットを繰り返し開閉できる。
- 表示の p95 を計測できる。
- clean checkout から build と test が成功する。

### Phase 1: アプリランチャー

作業:

- app bundle の走査、metadata 取得、重複排除。
- メモリ内索引、正規化、ランキング。
- 結果 UI、アイコン遅延ロード。
- `NSWorkspace` による起動。
- 利用履歴、Pin、Alias、再索引。

Exit criteria:

- パレットから主要アプリを 2〜3 キー程度で検索・起動できる。
- ランキング test と性能目標を満たす。

### Phase 2: クリップボード

作業:

- changeCount monitor と保存 pipeline。
- 履歴一覧、検索、Pin、削除。
- 再コピー、貼り付け、競合安全な復元。
- 除外アプリ、一時停止、保持ポリシー。

Exit criteria:

- テキスト、URL、ファイル URL を安全に再利用できる。
- 自己貼り付け、保存期限、競合の自動テストが通る。

### Phase 3: スニペット検索・挿入

作業:

- CRUD、タグ、検索。
- プレースホルダ parser と renderer。
- `PasteCoordinator` を使った挿入。
- Accessibility の説明、許可確認、fallback。

Exit criteria:

- スニペットを作成し、パレットから検索・挿入できる。
- 権限がない場合もコピー操作へ fallback できる。

### Phase 4: AI チャット

作業:

- Keychain 設定 UI。
- Responses API client と SSE parser。
- チャット UI、履歴、停止、再生成。
- Quick AI。
- 明示的な選択テキスト・クリップボード添付。
- 通信エラーと rate limit の表示。

Exit criteria:

- 複数ターンのローカル会話を再開できる。
- ストリーミング、キャンセル、途中切断を安全に処理できる。
- AI を開かない通常利用でネットワーク通信しない。

### Phase 5: スニペット自動展開

作業:

- `CGEventTap`、リングバッファ、delimiter 判定。
- IME・Secure Input・対象アプリ除外。
- event tap disable の復旧と fail-safe。
- 対象アプリでの手動 QA。

Exit criteria:

- 対応アプリで安定して展開できる。
- 日本語変換中、secure field、除外アプリで入力を変更しない。
- 不安定な環境では自動停止し、検索挿入は利用できる。

### Phase 6: ベータ品質・配布

作業:

- Instruments による CPU、memory、launch、energy 計測。
- Accessibility 文言、プライバシー説明、診断 export。
- ログイン時起動。
- Developer ID 署名、Hardened Runtime、Notarization、Stapling。
- Sparkle 更新 feed と署名。
- リリースチェックリストと rollback 手順。

Exit criteria:

- clean Mac への install、初回権限導線、update を再現できる。
- 性能目標と QA マトリクスを満たす。
- 秘密情報を含まない診断情報だけを export できる。

## 13. 推奨する実装順と依存関係

```text
Phase 0 基盤
    │
    ▼
Phase 1 App Launcher
    │
    ├──────────────┐
    ▼              ▼
Phase 2 Clipboard  Phase 4 AI
    │
    ▼
Phase 3 Snippet Insert
    │
    ▼
Phase 5 Auto Expansion
    │
    ▼
Phase 6 Distribution
```

最初の縦切りは、`ホットキー → パレット → アプリ検索 → 起動` とする。この時点で Provider、検索、ランキング、パネル制御を固め、その後の機能は同じ操作モデルへ追加する。

AI は Phase 2 と並行実装可能だが、初期段階では担当者を分けず、パレットと DB の境界が安定してから着手する。

## 14. 見積もり

一人で実装する場合の目安であり、特に Accessibility とアプリ横断 QA の結果で変動する。

| Phase | 目安 |
|---|---:|
| Phase 0 | 2〜4 日 |
| Phase 1 | 3〜5 日 |
| Phase 2 | 4〜7 日 |
| Phase 3 | 2〜4 日 |
| Phase 4 | 4〜7 日 |
| Phase 5 | 7〜14 日 |
| Phase 6 | 5〜10 日 |

- 自分で使える MVP: 約 3〜5 週間
- 配布可能なベータ: 約 6〜10 週間

## 15. 主なリスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| 日本語 IME 中の自動展開 | 入力破壊 | ASCII prefix、delimiter 必須、変換中無効、検索挿入 fallback |
| Pasteboard 復元の競合 | ユーザーの新しいコピーを消す | `changeCount` 一致時だけ復元 |
| Accessibility 権限拒否 | 直接貼り付け不可 | コピー操作と設定導線を残す |
| event tap timeout | 入力監視停止 | callback 最小化、再有効化、連続失敗時 fail-safe |
| クリップボード漏えい | 重大なプライバシー事故 | 除外、一時停止、保持期限、ログ禁止、明示的 AI 添付 |
| 大きな履歴で検索劣化 | UI 遅延 | FTS5、件数制限、バックグラウンド検索、世代管理 |
| AI の API 変更・費用変動 | 機能停止・費用増 | backend protocol、モデル設定集約、エラー分類 |
| SwiftUI の再描画負荷 | 表示遅延 | View tree を小さく保ち、AppKit controller と計測で管理 |
| 直接配布の署名・権限差異 | install 失敗 | clean Mac で署名、Notarization、初回起動を継続検証 |

## 16. 実装開始前に確定する事項

Phase 0 の開始時に、以下を短い ADR または Issue で確定する。

- 最低対応 macOS を 14 以降で確定するか。
- Bundle ID と署名 Team。
- MVP を個人利用に限定するか、最初から外部配布を想定するか。
- KeyboardShortcuts と GRDB の導入可否・固定バージョン。
- クリップボードの既定保存期間と最大件数。
- パスワード管理アプリの初期除外一覧。
- BYOK のみで開始するか。
- Intel Mac をサポート対象に含めるか。
- Telemetry を完全に入れないか、匿名の性能指標だけ導入するか。

## 17. 各 Phase の完了確認

各 Phase の完了時は、少なくとも次を実行する。

```bash
xcodebuild \
  -scheme Yorozu \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -scheme Yorozu \
  -destination 'platform=macOS' \
  test
```

加えて次を確認する。

- 変更対象に最も近い test が成功している。
- `git diff` に無関係な変更や秘密情報がない。
- `git status` に想定外の生成物がない。
- 実行していない QA を完了扱いにしていない。
- 性能または権限に影響する変更は、該当する手動確認を記録している。

## 18. 参考資料

### Apple / SQLite

- [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [SQLite FTS5 Extension](https://www.sqlite.org/fts5.html)

### OpenAI

- [Migrate to the Responses API](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Streaming API responses](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Responses API: Create](https://developers.openai.com/api/reference/resources/responses/methods/create)

### 外部ライブラリ候補

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [Sparkle](https://sparkle-project.org/)
