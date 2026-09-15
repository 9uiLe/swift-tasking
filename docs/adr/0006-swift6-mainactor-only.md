# ADR-0006: Swift 6 と明示的な actor 隔離を前提にする

## 前提

task を受け付け、追跡し、終了させる処理には可変状態がある。
UI への状態反映と、非 UI の task 所有をそれぞれ適切な actor に隔離する。

## 決定

- Swift tools 6.0 と Swift 6 言語モードを使う。消費側の feature も Swift 6 言語モードを前提とする。
- `ViewTaskStore` / `ActionRunner` とその operation は MainActor に隔離する。
- `TaskSlot` は独立した actor とし、operation は `@Sendable` な async closure を受け取る。
- deployment target は iOS 13、macOS 10.15、tvOS 13、watchOS 6、visionOS 1 以上とする。
- default actor isolation と `NonisolatedNonsendingByDefault` は有効にしない。

## 理由と制約

Store / Runner の同期操作は MainActor 上で直列になり、ViewModel の状態を直接扱える。
Slot は UI の isolation を非 UI の所有者へ持ち込まずに task の置換を管理できる。

MainActor の operation に重い同期計算を書くと UI を占有する。
`await` を書くこと自体は、処理を別の executor に移す保証にならない。
計算を担当する actor や関数の isolation と負荷を確認する。

Swift 5 の消費側は、import できても capture が Swift 5 の規則で検査されるためサポート範囲外とする。
コンパイラの isolation 設定を変える場合は、特に Slot の operation の実行場所と
Swift tools の対応範囲を検証する。[導入と運用](../adoption.md) を参照する。
