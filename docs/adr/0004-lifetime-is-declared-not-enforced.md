# ADR-0004: ActionLifetime は宣言であり強制ではない

- ステータス: 確定(2026-07-03 グリリングで作者確認済み)
- 日付: 2026-07-03

## 文脈

「この task は画面が消えたら死ぬべきか、シーンと共に生きるべきか」という寿命の
意図は、素の `Task {}` ではコードのどこにも現れない。一方で寿命を機構的に
強制するには、view ライフサイクルへのフック(`onDisappear` / `ScenePhase` 監視)を
ライブラリが抱え込む必要があり、SwiftUI のバージョン差異・UIKit 併用・
カスタムスコープへの対応で表面積が膨らむ。

## 決定

`ActionLifetime` は **タグ(宣言)** とする。

- 組み込み値 `.screenBound` / `.sceneBound` / `.appBound` + 文字列リテラル拡張。
- store は lifetime を追跡し `cancel(lifetime:)` の一括キャンセル単位として使うが、
  ライフサイクルイベントへの自動接続は**しない**。`onDisappear` 等での
  `cancel(lifetime: .screenBound)` 呼び出しは利用者の手動配線。
- 安全網として `deinit` で全 task をキャンセルする(store の寿命が実際の上限)。

## 根拠

- 宣言だけでも「この保存は画面より長く生きる意図か?」がレビューで議論可能になる。
  これがライブラリの主目的(可視化)に対する最小実装。
- ライフサイクル自動接続を持たないことで、SwiftUI / UIKit / 任意のスコープ設計から
  中立でいられる。

## 代償

- **名前が実態より強い**。`.appBound` と宣言しても、store が `@State` 所有なら
  task は画面と共に(deinit で)キャンセルされる。実際の寿命上限は
  「store をどこが所有しているか」で決まり、この対応関係を利用者が理解して
  いないと事故る。
- 手動配線を忘れると `.screenBound` ですら deinit まで生き延びる
  (@State の解放タイミングは view の identity 消滅に依存)。

## 追記(2026-07-03 グリリング結果)

「lifetime の実効性 = store の所有位置」を第一級の説明として docs に置くことを
決定し、[lifetimes.md](../lifetimes.md) を追加した。各 lifetime に対する store の
推奨所有位置(screenBound = 画面の `@State`、sceneBound = シーンのルート view、
appBound = アプリ寿命のコンテナ)とアンチパターンを記載している。
「推奨例を示せるまで sceneBound/appBound を予約扱いにする」案は採らなかった。
