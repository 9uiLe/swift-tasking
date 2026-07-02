# ADR-0002: CancellationContext は能力ではなく契約の可視化である

- ステータス: 実装済み(根拠はコードと README から復元 — 作者確認待ち)
- 日付: 2026-07-03

## 文脈

Swift のキャンセルは協調的で、`Task.isCancelled` / `Task.checkCancellation()` は
どこからでも呼べる ambient な状態である。つまり機能面では、ViewModel メソッドに
何も渡さなくてもキャンセル協調は書ける。問題は「このメソッドはキャンセルに
協調する責任を負っているか」が**シグネチャから読めない**ことにある。
協調しない長時間処理は、`cancel()` を呼んでも止まらない。

## 決定

`CancellationContext` という空に近い struct を導入し、`ViewTaskStore.start` /
`ActionRunner.run` の operation に必ず渡す。中身は `Task.isCancelled` と
`Task.checkCancellation()` の転送のみ。

## 根拠

- 値を受け取ったメソッドのシグネチャ(`func save(cancellation: CancellationContext)`)
  が「この処理は長く、キャンセルに協調すべきである」という契約の宣言になる。
  レビューで「cancellation を受けているのに一度も check() していない」を指摘できる。
- ambient な `Task.checkCancellation()` 直呼びに比べ、「どの task の
  キャンセル状態か」を呼び出し経路が保証する(store が渡した文脈 = store が
  所有する task)。
- capability token 化(構築を private にして偽造を防ぐ)はしない。
  強制よりも語彙の提供を優先する(ライブラリの原則「可視化はするが、
  肩代わりはしない」)。

## 代償

- 契約の実効性はチーム規律に依存する。`CancellationContext()` は誰でも作れるため、
  型システムによる強制はない。
- 「何もしないラッパーはノイズ」という批判は正当であり、採用判断の分かれ目になる。
  reviewability に価値を置かないチームには向かない。

## 未解決の問い

- 将来 deadline・進捗通知などをこの struct に載せる構想はあるか。あるなら
  「拡張点の予約」という追加の存在理由になる(docs に明記する価値がある)。
- init を非公開にして偽造不能にする選択肢を捨てた理由を作者の言葉で確認したい
  (テスト容易性のためか、強制を避ける思想ゆえか)。
