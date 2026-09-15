# ADR-0005: 失敗の最終報告を文字列で表現する

## 前提

Runner は成功・キャンセル・拒否・失敗を `ActionOutcome<Success>` として返す。
失敗の最終報告には比較可能な値が必要で、業務固有の回復判断は元のエラー型が使える場所で行う。

## 決定

`ActionFailure` は `typeName: String` と `message: String` を持つ `Equatable & Sendable` な値とする。
エラーからの構築では、型名を `String(reflecting: type(of: error))`、メッセージを
`String(describing: error)` で得る。

`ActionOutcome` は成功値に `Sendable` を要求し、成功値が `Equatable` の場合に比較可能とする。
Store の未処理エラー observer も `ActionFailure` を受け取る。

## 理由と制約

失敗を値としてログやテストで扱える。元のエラーを保持しないため、受け取り側で
downcast して業務エラーの種類ごとに回復することはできない。
その判断は operation 内で行うか、呼び出し側と合意した domain の結果型で表す。

outcome の成功・キャンセル・拒否・失敗による分岐は利用できる。
`typeName` や `message` の解析による業務分岐は行わない。文字列表現は安定した
エラーコードや永続化形式を保証しない。
