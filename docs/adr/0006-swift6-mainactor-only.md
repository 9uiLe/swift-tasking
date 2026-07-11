# ADR-0006: Swift 6 言語モード専用・@MainActor 固定

- ステータス: 実装済み(README に一部明文あり — 作者確認待ちは @MainActor の範囲)
- 日付: 2026-07-03

## 文脈

task の所有権を明示するライブラリが、自身のデータ競合安全性を妥協していては
説得力がない。また、対象ドメイン(同期 UI コールバック、ViewModel)は
実質的に main actor 上の世界である。

## 決定

- Swift 6 言語モード(strict concurrency)専用。Swift 5 モードは意図的に非対応。
- UI 境界 product `Tasking` の `ViewTaskStore` / `ActionRunner` は `@MainActor`
  クラスとし、operation も
  `@MainActor @Sendable` で受ける。
- 非 UI task 所有は別 product `TaskingCore` の actor に隔離し、UI API の
  MainActor 契約を一般化しない (ADR-0010)。
- 対応 OS は concurrency が back-deploy される下限(iOS 13+ / macOS 10.15+)まで広げる。

## 補足: Swift 5 言語モードの消費側

パッケージ自体は Swift 6 language mode でビルドされるが、SwiftPM の依存として
Swift 5 language mode の target から import できる場合がある。この場合でも、
operation クロージャの capture は消費側 target の言語モードで検査される。

したがって Swift 5 target では、非 Sendable object の capture が警告なしに通ることがあり、
Tasking の strict concurrency 前提は保てない。Tasking を使う feature module は Swift 6
language mode に上げることをサポート境界とする。

## 根拠

- README の言葉: 「task 所有権を明示するパッケージなので、strict data-race
  checking は公開品質の一部」。
- UI 境界のツールと割り切ることで、ロック・actor hop の設計を持ち込まずに済み、
  実装が読み切れるサイズに収まる。ViewModel の可変状態(@MainActor)への
  書き込みが operation 内で自然に書ける。

## 代償

- `ViewTaskStore` / `ActionRunner` はバックグラウンドサービス・非 UI 文脈の
  重複制御には使えない。非 UI の単一 task 所有は `TaskSlot` に限定し、
  ActionRunner の一般 actor 版やキューは引き続きスコープ外とする。
- operation の同期部分は main actor 上で走るため、重い CPU 処理を直接書くと
  UI を止める(await で他の isolation に逃がす前提)。
- Swift 5 モードのプロジェクトは採用できず、間口は狭まる。

## 未解決の問い

- `TaskSlot` より広い非 UI Runner、複数ID store、キューが必要になったとき、
  TaskingCore を拡張するか別ライブラリへ委ねるか。
