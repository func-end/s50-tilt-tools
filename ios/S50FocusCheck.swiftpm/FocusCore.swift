// FocusCore.swift: star-size tilt check shared by the iPad app (Swift Playgrounds) and the macOS test harness.
// Foundation + CoreGraphics only. Works on the app's JPEG (or PNG/HEIC) and on FITS
// (Seestar raw Bayer subs binned 2x2, or 3-plane stacks averaged). Tilt uses ASTAP's corner formula on a 3x3 grid:
// 100 * (max - min corner median HFD) / overall median HFD. Values are approximate; JPEG values run lower than ASTAP.
import Foundation
import CoreGraphics

public struct Star { public let y: Float; public let x: Float; public let hfd: Float }

/// Progress callback: fraction 0...1 of the whole measurement (called from the worker thread).
public typealias Progress = (Double) -> Void

public struct TiltResult {
    public let tiltPercent: Float
    public let worstCorner: String          // "1A" top-left, "1C" top-right, "3A" bottom-left, "3C" bottom-right (app image)
    public let grid: [[Float]]              // 3x3 median HFD, rows top -> bottom
    public let starCount: Int
    public let medianHFD: Float
    public let source: String
    public var astapClass: String {
        switch tiltPercent { case ..<5.0001: return "None"; case ..<10.0001: return "Almost none"; case ..<15.0001: return "Mild"
        case ..<20.0001: return "Moderate"; case ..<30.0001: return "Severe"; default: return "Extreme" }
    }
    public var worstCornerName: String {
        ["1A": "top-left", "1C": "top-right", "3A": "bottom-left", "3C": "bottom-right"][worstCorner] ?? worstCorner
    }
}

public enum FocusCheckError: Error, CustomStringConvertible {
    case unreadable(String), tooFewStars(Int)
    public var description: String {
        switch self {
        case .unreadable(let m): return "Could not read the image: \(m)"
        case .tooFewStars(let n): return "Only \(n) usable stars. Use a star field (e.g. NGC 869), not a nebula or galaxy."
        }
    }
}

// MARK: - Image plane

public struct Plane {
    public var w: Int, h: Int, px: [Float]
    @inline(__always) func at(_ y: Int, _ x: Int) -> Float { px[y * w + x] }
}

/// Grey plane from a CGImage (mean of R, G, B; 0...1).
public func plane(from cg: CGImage, progress: Progress? = nil) throws -> Plane {
    let w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FocusCheckError.unreadable("no bitmap context") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var px = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { let i = y * w + x
            px[i] = (Float(rgba[4 * i]) + Float(rgba[4 * i + 1]) + Float(rgba[4 * i + 2])) / (3 * 255) }
        if y % 256 == 0 { progress?(Double(y) / Double(h)) }
    }
    return Plane(w: w, h: h, px: px)
}

/// Luminance plane from a Seestar FITS (BITPIX 16 with BZERO). NAXIS=2 raw Bayer: 2x2 binned (half size).
/// NAXIS=3 stack: planes averaged. Values normalised to 0...1. Row 0 = first FITS row (= top of the app image).
public func plane(fromFITS data: Data) throws -> (Plane, binned: Bool) {
    var cards: [String: String] = [:]; var off = 0; var done = false
    while !done && off + 2880 <= data.count {
        let block = data.subdata(in: off..<(off + 2880)); off += 2880
        for i in 0..<36 {
            let card = String(decoding: block.subdata(in: (i * 80)..<(i * 80 + 80)), as: UTF8.self)
            let key = card.prefix(8).trimmingCharacters(in: .whitespaces)
            if key == "END" { done = true; break }
            if card.count > 10, card.dropFirst(8).hasPrefix("= ") {
                let v = card.dropFirst(10).split(separator: "/").first.map(String.init) ?? ""
                cards[key] = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
        }
    }
    guard done, cards["BITPIX"] == "16", let n1 = Int(cards["NAXIS1"] ?? ""), let n2 = Int(cards["NAXIS2"] ?? "")
    else { throw FocusCheckError.unreadable("not a 16-bit FITS") }
    let n3 = Int(cards["NAXIS3"] ?? "1") ?? 1
    let bzero = Float(cards["BZERO"] ?? "0") ?? 0, bscale = Float(cards["BSCALE"] ?? "1") ?? 1
    let count = n1 * n2 * n3
    guard data.count >= off + count * 2 else { throw FocusCheckError.unreadable("truncated FITS") }
    var raw = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        let p = buf.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            let v = Int16(bitPattern: UInt16(p[2 * i]) << 8 | UInt16(p[2 * i + 1]))
            raw[i] = (Float(v) * bscale + bzero) / 65535
        }
    }
    if n3 >= 3 {
        var px = [Float](repeating: 0, count: n1 * n2)
        for i in 0..<(n1 * n2) { px[i] = (raw[i] + raw[n1 * n2 + i] + raw[2 * n1 * n2 + i]) / 3 }
        return (Plane(w: n1, h: n2, px: px), false)
    }
    let w = n1 / 2, h = n2 / 2; var px = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        let a = (2 * y) * n1 + 2 * x
        px[y * w + x] = (raw[a] + raw[a + 1] + raw[a + n1] + raw[a + n1 + 1]) / 4
    } }
    return (Plane(w: w, h: h, px: px), true)
}

// MARK: - Measurement

private func median(_ v: [Float]) -> Float {
    if v.isEmpty { return 0 }
    let s = v.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Background: medians of `block`-pixel tiles, bilinearly interpolated.
private func background(_ p: Plane, block: Int) -> [Float] {
    let gw = max(1, p.w / block), gh = max(1, p.h / block)
    var g = [Float](repeating: 0, count: gw * gh)
    for gy in 0..<gh { for gx in 0..<gw {
        var v: [Float] = []; v.reserveCapacity(block * block / 4)
        var y = gy * block; while y < min(p.h, (gy + 1) * block) {
            var x = gx * block; while x < min(p.w, (gx + 1) * block) { v.append(p.at(y, x)); x += 2 }
            y += 2 }
        g[gy * gw + gx] = median(v)
    } }
    var bg = [Float](repeating: 0, count: p.w * p.h)
    for y in 0..<p.h {
        let fy = min(max((Float(y) + 0.5) / Float(block) - 0.5, 0), Float(gh - 1))
        let y0 = Int(fy), y1 = min(y0 + 1, gh - 1), ty = fy - Float(y0)
        for x in 0..<p.w {
            let fx = min(max((Float(x) + 0.5) / Float(block) - 0.5, 0), Float(gw - 1))
            let x0 = Int(fx), x1 = min(x0 + 1, gw - 1), tx = fx - Float(x0)
            let a = g[y0 * gw + x0] * (1 - tx) + g[y0 * gw + x1] * tx
            let b = g[y1 * gw + x0] * (1 - tx) + g[y1 * gw + x1] * tx
            bg[y * p.w + x] = a * (1 - ty) + b * ty
        }
    }
    return bg
}

private func separable(_ src: [Float], _ w: Int, _ h: Int, radius r: Int, progress: Progress? = nil, op: ([Float]) -> Float) -> [Float] {
    var tmp = [Float](repeating: 0, count: w * h), out = tmp
    var win = [Float](repeating: 0, count: 2 * r + 1)
    for y in 0..<h { for x in 0..<w {
        for k in -r...r { win[k + r] = src[y * w + min(max(x + k, 0), w - 1)] }
        tmp[y * w + x] = op(win)
    }; if y % 128 == 0 { progress?(0.5 * Double(y) / Double(h)) } }
    for y in 0..<h { for x in 0..<w {
        for k in -r...r { win[k + r] = tmp[min(max(y + k, 0), h - 1) * w + x] }
        out[y * w + x] = op(win)
    }; if y % 128 == 0 { progress?(0.5 + 0.5 * Double(y) / Double(h)) } }
    return out
}

/// Stars: isolated local maxima above `snr` x noise, unsaturated; HFD = 2 x interpolated half-flux radius about the
/// flux centroid within `aperture` px. `scale` converts the HFD to native sensor pixels (2 for binned raw subs).
public func measureStars(_ p: Plane, aperture R: Int = 8, saturation: Float = 0.92, snr: Float = 8, scale: Float = 1,
                         progress: Progress? = nil) -> [Star] {
    // stage weights (fractions of this function): background .15, smooth .25, max .25, peaks .10, star sizes .25
    let bg = background(p, block: 64); progress?(0.15)
    var s = [Float](repeating: 0, count: p.w * p.h)
    for i in 0..<s.count { s[i] = p.px[i] - bg[i] }
    let med = median(stride(from: 0, to: s.count, by: 7).map { s[$0] })
    let noise = 1.4826 * median(stride(from: 0, to: s.count, by: 7).map { abs(s[$0] - med) })
    let gk: [Float] = [0.0044, 0.054, 0.242, 0.399, 0.242, 0.054, 0.0044]
    let sm = separable(s, p.w, p.h, radius: 3, progress: { progress?(0.15 + 0.25 * $0) }) { w in zip(w, gk).reduce(0) { $0 + $1.0 * $1.1 } }
    let mx = separable(sm, p.w, p.h, radius: 5, progress: { progress?(0.40 + 0.25 * $0) }) { $0.max()! }
    var peaks: [(Int, Int)] = []
    for y in (R + 1)..<(p.h - R - 1) { for x in (R + 1)..<(p.w - R - 1) {
        let i = y * p.w + x
        if sm[i] == mx[i] && sm[i] > snr * noise && p.px[i] < saturation { peaks.append((y, x)) }
    }; if y % 256 == 0 { progress?(0.65 + 0.10 * Double(y) / Double(p.h)) } }
    var cell: [Int: [(Int, Int)]] = [:]; let cs = 12
    for pk in peaks { cell[(pk.0 / cs) * 100_000 + pk.1 / cs, default: []].append(pk) }
    var stars: [Star] = []
    for (k, (y, x)) in peaks.enumerated() {
        if k % 200 == 0 { progress?(0.75 + 0.25 * Double(k) / Double(max(peaks.count, 1))) }
        var neighbours = 0
        for dy in -1...1 { for dx in -1...1 {
            for q in cell[(y / cs + dy) * 100_000 + x / cs + dx] ?? [] where (q.0 - y) * (q.0 - y) + (q.1 - x) * (q.1 - x) < cs * cs { neighbours += 1 }
        } }
        if neighbours > 1 { continue }
        var vals: [(Float, Float, Float)] = []; var F: Float = 0, sy: Float = 0, sx: Float = 0
        for dy in -R...R { for dx in -R...R where dy * dy + dx * dx <= R * R {
            let v = max(s[(y + dy) * p.w + x + dx], 0); vals.append((Float(dy), Float(dx), v)); F += v; sy += v * Float(dy); sx += v * Float(dx)
        } }
        if F <= 0 { continue }
        let cy = sy / F, cx = sx / F
        let sorted = vals.map { (hypotf($0.0 - cy, $0.1 - cx), $0.2) }.sorted { $0.0 < $1.0 }
        var cum: Float = 0, prevR: Float = 0, prevC: Float = 0, rh: Float = -1
        for (r, v) in sorted {
            cum += v
            if cum >= F / 2 { rh = prevR + (r - prevR) * (F / 2 - prevC) / max(cum - prevC, 1e-9); break }
            prevR = r; prevC = cum
        }
        if rh > 0 { stars.append(Star(y: Float(y), x: Float(x), hfd: 2 * rh * scale)) }
    }
    progress?(1)
    return stars
}

/// ASTAP-style corner tilt on a 3x3 grid (needs >= 5 stars per corner cell).
public func cornerTilt(_ stars: [Star], width w: Int, height h: Int, source: String) throws -> TiltResult {
    guard stars.count >= 30 else { throw FocusCheckError.tooFewStars(stars.count) }
    var cells = [[Float]](repeating: [], count: 9)
    for st in stars {
        let r = min(Int(st.y) * 3 / h, 2), c = min(Int(st.x) * 3 / w, 2)
        cells[r * 3 + c].append(st.hfd)
    }
    let corners = ["1A": 0, "1C": 2, "3A": 6, "3C": 8]
    guard corners.values.allSatisfy({ cells[$0].count >= 5 }) else { throw FocusCheckError.tooFewStars(stars.count) }
    let cm = corners.mapValues { median(cells[$0]) }
    let all = median(stars.map { $0.hfd })
    let worst = cm.max { $0.value < $1.value }!.key
    let grid = (0..<3).map { r in (0..<3).map { c in median(cells[r * 3 + c]) } }
    return TiltResult(tiltPercent: 100 * (cm.values.max()! - cm.values.min()!) / all, worstCorner: worst, grid: grid,
                      starCount: stars.count, medianHFD: all, source: source)
}

/// One call for the app: JPEG/PNG/HEIC via CGImage, or FITS data.
public func analyse(cgImage: CGImage, progress: Progress? = nil) throws -> TiltResult {
    let p = try plane(from: cgImage, progress: { progress?(0.10 * $0) })
    let st = measureStars(p, aperture: 8, progress: { progress?(0.10 + 0.90 * $0) })
    return try cornerTilt(st, width: p.w, height: p.h, source: "image")
}

public func analyse(fitsData: Data, progress: Progress? = nil) throws -> TiltResult {
    progress?(0.02)
    let (p, binned) = try plane(fromFITS: fitsData); progress?(0.15)
    let st = measureStars(p, aperture: binned ? 7 : 8, saturation: 0.9, snr: 12, scale: binned ? 2 : 1,
                          progress: { progress?(0.15 + 0.85 * $0) })
    return try cornerTilt(st, width: p.w, height: p.h, source: binned ? "FITS raw frame" : "FITS stack")
}

/// Plain advice. Which way to move focus depends on the unit, so the tip is to try both sides.
public func advice(for r: TiltResult, isJPEG: Bool) -> String {
    if r.tiltPercent <= 12 { return "Even field (low corner contrast). Also check the stars look sharp overall; if everything is soft, re-run autofocus." }
    if r.worstCorner.hasPrefix("3") {
        return "Bottom side soft. Re-run autofocus. If it lands the same, try short runs 10-20 steps either side and keep the position that balances the field (untested tip)."
    }
    return "Top side soft. Re-run autofocus. If it lands the same, try short runs 10-20 steps either side and keep the position that balances the field (untested tip)."
}
