/// `ActionRunner` で同じ Action ID を実行する場合の受付方針。
public enum ActionDuplicatePolicy: Equatable, Sendable {
    /// 先に受け付けた処理が終了するまで、新しい要求を受け付けない。
    case ignoreNew

    /// 同じ Action ID の複数の処理が重なることを許可する。
    case allowConcurrent
}
