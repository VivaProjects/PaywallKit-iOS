import Foundation

/// 仅日志开启时回调后台更新终态，宿主自行决定如何展示诊断提示。
public enum PaywallQueryUpdateDiagnostic: Sendable {
    /// 下载、校验与归档结束；更新数仅计发布身份或展示方式变化的点位。
    /// 同版本校验不计更新；失败数包含下载包或归档失败，不代表在线部署。
    case completed(updatedPlacements: Int, failures: Int)
    case failed
}
