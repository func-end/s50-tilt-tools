// Mac test of the Checked-list store (History.swift) in a scratch folder: save/reload, thumbnails, repeats, replace, deleted-file prune.
// Setup: <dir>/data/Stacked_18_NGC 869_10.0s_IRCUT_20261007-200319.jpg (a full-size test JPEG) and <dir>/data/bad_POS1000_raw.fit.
// Build (from ios/S50FocusCheck.swiftpm): swiftc -sdk <MacOSX26.sdk> FocusCore.swift History.swift ContentView.swift ../harness/history_test/main.swift -o ht && ./ht <dir>
import Foundation
import ImageIO
let S = URL(fileURLWithPath: CommandLine.arguments[1]); let hdir = S.appendingPathComponent("hist")
let jpg = S.appendingPathComponent("data/Stacked_18_NGC 869_10.0s_IRCUT_20261007-200319.jpg"), fit = S.appendingPathComponent("data/bad_POS1000_raw.fit")
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m) }
@MainActor func run() async {
    var h = History(dir: hdir)
    check(h.records.isEmpty, "starts empty")
    let src = CGImageSourceCreateWithURL(jpg as CFURL, nil)!, cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let r = try! analyse(cgImage: cg)
    let name = jpg.lastPathComponent
    h.add(CheckRecord(name: name, label: photoLabel(src, name: name), isJPEG: true, score: r.tiltPercent * jpegToASTAP, note: nil, r: r, assetID: nil, bookmark: nil), thumbFrom: src)
    let rf = try! analyse(fitsData: Data(contentsOf: fit))
    h.add(CheckRecord(name: fit.lastPathComponent, label: rf.source, isJPEG: false, score: rf.tiltPercent, note: nil, r: rf, assetID: nil, bookmark: try? fit.bookmarkData()), thumbFrom: nil)
    check(h.records.count == 2 && h.records[0].name == "bad_POS1000_raw.fit", "two entries, newest first")
    h = History(dir: hdir)                                    // reload from disk
    check(h.records.count == 2, "persists across reload")
    let j = h.records[1]
    check(h.thumbs[j.id] != nil && j.hasThumb, "thumbnail saved and reloaded (\(h.thumbs[j.id].map { "\($0.width)x\($0.height)" } ?? "none"))")
    check(j.label == "NGC 869 · 2026-10-07 20:03 · 18 × 10.0 s · IRCUT", "label kept: \(j.label)")
    check(abs((j.result?.tiltPercent ?? -1) - r.tiltPercent) < 1e-4 && j.result?.grid == r.grid, "result card data round-trips")
    check(h.find(name: name, assetID: nil)?.id == j.id, "repeat found by name")
    check(h.find(name: unknownName, assetID: nil) == nil, "unknown name never matches")
    h.add(CheckRecord(name: name, label: j.label, isJPEG: true, score: 1, note: nil, r: r, assetID: "X/L0/001", bookmark: nil), thumbFrom: src)
    check(h.records.count == 2 && h.records[0].name == name && h.records[0].score == 1, "re-measure replaces the old entry")
    check(h.find(name: "other.jpg", assetID: "X/L0/001") != nil, "repeat found by Photos id")
    await h.prune()
    check(h.records.count == 2, "prune keeps existing file (hint: \(h.hint ?? "none"))")
    try! FileManager.default.removeItem(at: fit)
    await h.prune()
    check(h.records.count == 1 && h.records[0].name == name, "prune drops deleted file")
    h.remove(h.records[0])
    let left = (try? FileManager.default.contentsOfDirectory(atPath: hdir.path)) ?? []
    check(h.records.isEmpty && left == ["history.json"], "remove deletes entry and thumbnail (left: \(left))")
    let json = String(data: try! Data(contentsOf: hdir.appendingPathComponent("history.json")), encoding: .utf8)!
    check(json == "[]", "json empty after removal")
}
await run()
