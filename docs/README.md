# Tasking ドキュメント

- [用語集(Glossary)](glossary.md) — ドメイン語彙の定義と使い分け早見表
- [ポジショニング](positioning.md) — 解決する問題・設計思想・競合比較・良い点と悪い点・公開運用方針
- [ライフタイムの推奨構成](lifetimes.md) — store の所有位置で決まる lifetime の実効性と構成例
- [レシピ集](recipes.md) — プロトタイプ検証で見つかった state/cancellation の定型と落とし穴

## Architecture Decision Records

コードに体現されている設計判断の記録。各 ADR の「未解決の問い」は
グリリング(設計質問セッション)の継続事項で、回答が得られ次第更新する。

| ADR | 決定 |
|---|---|
| [0001](adr/0001-split-store-and-runner.md) | task を所有する型(ViewTaskStore)と実行を制御する型(ActionRunner)を分離する |
| [0002](adr/0002-cancellation-context-as-contract.md) | CancellationContext は能力ではなく契約の可視化である |
| [0003](adr/0003-viewtaskstore-does-not-carry-errors.md) | ViewTaskStore は業務エラーを運ばない |
| [0004](adr/0004-lifetime-is-declared-not-enforced.md) | ActionLifetime は宣言であり強制ではない |
| [0005](adr/0005-actionfailure-erases-error-types.md) | ActionFailure はエラー型を消去する |
| [0006](adr/0006-swift6-mainactor-only.md) | Swift 6 言語モード専用・@MainActor 固定 |
| [0007](adr/0007-store-is-not-observable.md) | store は Observable にしない(UI 状態は ViewModel の責務) |
| [0008](adr/0008-publication-naming-license-language.md) | 公開名称は swift-tasking・MIT ライセンス・二層言語構造(API 英語 / 設計 docs 日本語) |
| [0009](adr/0009-cancel-removes-tracking-immediately.md) | cancel は追跡を即時解除し、実終了待ちは ViewModel 側の責務に残す |
