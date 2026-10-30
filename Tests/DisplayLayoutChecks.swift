import AppKit

@main
struct DisplayLayoutChecks {
    static func main() {
        let nativeFullScreen = DisplayLayout.fittedSize(
            viewport: CGSize(width: 1512, height: 945), preferredWidth: 1440)!
        precondition(nativeFullScreen == CGSize(width: 1440, height: 900))
        let entireDisplay = DisplayLayout.fittedSize(
            viewport: CGSize(width: 1512, height: 982), preferredWidth: 1440)!
        precondition(entireDisplay == CGSize(width: 1440, height: 935))
        let withStatus = DisplayLayout.fittedSize(
            viewport: CGSize(width: 1512, height: 919), preferredWidth: 1440)!
        precondition(withStatus.height < nativeFullScreen.height)
        for viewport in [
            CGSize(width: 1920, height: 1080), CGSize(width: 3440, height: 1440),
            CGSize(width: 1080, height: 1920), CGSize(width: 1512, height: 945),
        ] {
            for width in [640, 1440, 3840, 7680] {
                let result = DisplayLayout.fittedSize(viewport: viewport, preferredWidth: width)!
                precondition((640...7680).contains(Int(result.width)))
                precondition((480...4320).contains(Int(result.height)))
                let expectedHeight = result.width * viewport.height / viewport.width
                precondition(abs(result.height - expectedHeight) <= 0.5)
            }
        }
        precondition(DisplayLayout.fittedSize(viewport: .zero, preferredWidth: 1440) == nil)
        precondition(
            DisplayLayout.fittedSize(
                viewport: CGSize(width: CGFloat.infinity, height: 100), preferredWidth: 1440) == nil)
        print(
            "Passed: full-screen/notch/status-bar viewport sizing, landscape/ultrawide/portrait bounds, invalid layouts"
        )
    }
}
