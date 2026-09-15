# ADR-0015: 所有識別と照会のコストを抑える

## 前提

Store の同期 start は MainActor の実行時間を使い、Slot は置換ごとに所有 marker を作る。
内部 identity の生成と、照会時の走査を必要な範囲に限定する。

## 決定

- 公開する `ActionRunID` は UUID とする。内部の `TaskOwnership` は空の immutable な final class とする。
  等価性には参照の一致、ハッシュには `ObjectIdentifier` を使う。
- TaskLocal と所有台帳が marker を強参照する。marker は Store / Slot を参照しない。
- lifetime の存在確認は最初の一致で終了する。件数照会は全体を走査する。
- TaskLocal の所有文脈が空なら、自己待機の除外対象を求めるための走査を行わない。
- lifetime の第2索引を持たず、追跡情報は `ActionRuns` の単一索引に置く。
- 所有台帳の内部表現を `@inlinable` / `@usableFromInline` で公開しない。

## 理由と制約

参照 marker は乱数生成を必要とせず、TaskLocal に残る間はアドレスが再利用されない。
所有者そのもののアドレスを identity に使うと、所有者の解放後に継承先が持つ値と
再利用されたアドレスを区別できないため、独立した marker を保持する。

存在確認は一致が早いほど安くなる。一致がなければ全件を走査し、件数照会より遅い条件もある。
別索引なら照会を定数時間にできるが、登録・キャンセル・終了のたびに同期が必要になる。
この更新責務を増やす判断は、実アプリで lifetime 照会が支配的かを測って行う。

共通処理への inlining annotation は、独立した Release プロセスを交互に実行する11回の比較で
明確な利益を示していない。測定の裏付けなしに内部表現を公開する保守負担を増やさない。

[性能特性](../performance.md) に、測定した実装の識別情報、条件、時間、メモリ、比較対象を記録する。
