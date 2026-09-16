# ADR-0005: 失敗の報告を比較可能な値にする

## 前提

Runner の終了結果や Store の診断では、失敗をログやテストで扱える形式が必要になる。
エラーの種類に応じた回復は、元のエラー型が利用できる処理本体で判断する。

## 決定

`ActionFailure` は `typeName: String` と `message: String` を持つ `Equatable & Sendable` な値とする。
エラーから構築する場合、型名は `String(reflecting: type(of: error))`、メッセージは
`String(describing: error)` で取得する。

`ActionOutcome<Success>` は成功値に `Sendable` を要求し、成功値が `Equatable` の場合に等価比較を提供する。
Store の未処理エラー通知先も `ActionFailure` を受け取る。

## 理由と制約

報告先は任意のエラー型やその参照を保持せず、値として失敗を受け取れる。
元のエラーを復元したり downcast したりすることはできない。
型ごとの回復は処理本体で行うか、アプリケーションが定めた結果型に変換する。

結果の成功・キャンセル・拒否・失敗による分岐は可能である。
型名やメッセージの文字列は、安定したエラーコードや永続化形式としては扱わない。
