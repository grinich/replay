import Foundation

struct UpdateVersion: Comparable, CustomStringConvertible, Equatable {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        components = parts.compactMap { Int($0) }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
