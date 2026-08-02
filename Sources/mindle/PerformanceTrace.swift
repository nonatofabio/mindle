import Foundation
import os

enum PerformanceTrace {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nonatofabio.mindle",
        category: .pointsOfInterest
    )

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try work()
    }

    static func fileTreePublished(rowCount: Int) {
        os_signpost(
            .event,
            log: log,
            name: "FileTreePublished",
            "%{public}d visible rows",
            rowCount
        )
    }
}
