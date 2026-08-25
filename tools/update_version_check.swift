import Foundation

@main
private struct UpdateVersionCheck {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("UpdateVersion check failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(UpdateVersion("v0.4.2") == UpdateVersion("0.4.2"), "leading v")
        expect(UpdateVersion("1.10.0")! > UpdateVersion("1.9.9")!, "numeric comparison")
        expect(UpdateVersion("2.0") == UpdateVersion("2.0.0"), "trailing zero equivalence")
        expect(UpdateVersion("0.4.3")! > UpdateVersion("0.4.2")!, "new release")
        expect(UpdateVersion("v1.2/evil") == nil, "reject unsafe tag")
        expect(UpdateVersion("1..2") == nil, "reject empty component")
        print("UpdateVersion checks passed")
    }
}
