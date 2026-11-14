// macOS test harness for FocusCore.swift: prints tilt for each file (JPEG/PNG via ImageIO, .fit via the FITS path).
// Build (from the repository root): swiftc -O ios/S50FocusCheck.swiftpm/FocusCore.swift ios/harness/main.swift -o focuscheck
import Foundation
import CoreGraphics
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let t0 = Date()
    do {
        let r: TiltResult
        if path.lowercased().hasSuffix(".fit") || path.lowercased().hasSuffix(".fits") {
            r = try analyse(fitsData: try Data(contentsOf: url))
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { print("UNREADABLE \(path)"); continue }
            r = try analyse(cgImage: cg)
        }
        print(String(format: "%@\t%.1f\t%@\t%d\t%@\t%.2fs", url.lastPathComponent, r.tiltPercent, r.worstCorner, r.starCount,
                     r.astapClass, Date().timeIntervalSince(t0)))
    } catch { print("ERROR \(url.lastPathComponent): \(error)") }
}
