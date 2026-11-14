// History.swift: the list of checked photos and files, kept between runs. A JSON file (history.json) plus one small JPEG
// thumbnail per entry, in Application Support/FocusCheckHistory inside the app's own storage. Entries whose photo (Photos
// library, needs full Photos read access) or file (Files, via a bookmark) has been deleted are dropped. Thumbnails carry
// pixels only, no metadata; a photo's GPS position is never read.
import SwiftUI
import Photos
import ImageIO
import UniformTypeIdentifiers

let unknownName = "(name not available)"

/// The measurement behind a saved score, enough to redraw the result card.
struct Measured: Codable {
    var tilt: Float; var worstCorner: String; var grid: [[Float]]; var starCount: Int; var medianHFD: Float; var source: String
}

struct CheckRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var label: String
    var checked: Date
    var assetID: String?          // Photos library item (deleted-photo check)
    var bookmark: Data?           // Files item (deleted-file check)
    var isJPEG: Bool
    var score: Float?             // figure shown (image: engine x 1.35; FITS: as measured); nil = no score
    var note: String?             // why there is no score
    var m: Measured?
    var hasThumb = false

    init(name: String, label: String, isJPEG: Bool, score: Float?, note: String?, r: TiltResult?, assetID: String?, bookmark: Data?) {
        self.name = name; self.label = label; checked = .now; self.isJPEG = isJPEG; self.score = score; self.note = note
        self.assetID = assetID; self.bookmark = bookmark
        m = r.map { Measured(tilt: $0.tiltPercent, worstCorner: $0.worstCorner, grid: $0.grid, starCount: $0.starCount,
                             medianHFD: $0.medianHFD, source: $0.source) }
    }
    var result: TiltResult? {
        m.map { TiltResult(tiltPercent: $0.tilt, worstCorner: $0.worstCorner, grid: $0.grid, starCount: $0.starCount,
                           medianHFD: $0.medianHFD, source: $0.source) }
    }
}

@Observable final class History {
    var records: [CheckRecord] = []           // newest first
    var thumbs: [UUID: CGImage] = [:]
    var hint: String?
    private let dir: URL
    private var file: URL { dir.appendingPathComponent("history.json") }
    private func thumbURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).jpg") }

    init(dir testDir: URL? = nil) {             // testDir: Mac test harness only
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = testDir ?? base.appendingPathComponent("FocusCheckHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([CheckRecord].self, from: d) { records = r }
        for r in records where r.hasThumb { thumbs[r.id] = loadThumb(r.id) }
    }

    /// Same photo: same Photos item, or same file name (Seestar names carry a timestamp).
    func find(name: String, assetID: String?) -> CheckRecord? {
        records.first { (assetID != nil && $0.assetID == assetID) || (name != unknownName && $0.name == name) }
    }

    /// Add a result; a re-measure replaces the earlier entry for that photo.
    func add(_ rec: CheckRecord, thumbFrom src: CGImageSource?) {
        var rec = rec
        if let old = find(name: rec.name, assetID: rec.assetID) { remove(old) }
        if let src, let t = Self.makeThumb(src), saveThumb(t, rec.id) { thumbs[rec.id] = t; rec.hasThumb = true }
        records.insert(rec, at: 0); save()
    }

    func remove(_ rec: CheckRecord) {
        records.removeAll { $0.id == rec.id }; thumbs[rec.id] = nil
        try? FileManager.default.removeItem(at: thumbURL(rec.id)); save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: file, options: .atomic) }
    }

    /// Drop entries whose photo or file is gone. Photos: needs full read access; limited access can't tell a deleted photo
    /// from one that simply wasn't shared, so nothing is dropped then. Files: only a definite "no such file" (or the file in
    /// the trash) drops an entry; other errors (e.g. iCloud offline) keep it.
    @MainActor func prune() async {
        var gone = records.filter { $0.bookmark.map(fileIsGone) ?? false }
        let ids = records.compactMap(\.assetID)
        if !ids.isEmpty {
            if Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") == nil {
                hint = "Deleted photos can't be detected (the app has no Photos access). Swipe a row left to remove it."
            } else {
                var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                if status == .authorized {
                    hint = nil
                    var alive = Set<String>()
                    PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in alive.insert(a.localIdentifier) }
                    gone += records.filter { $0.assetID.map { !alive.contains($0) } ?? false }
                } else {
                    hint = "Photos access is \(status == .limited ? "limited" : "off"), so deleted photos can't be detected. Allow full access in Settings › Privacy & Security › Photos, or swipe a row left to remove it."
                }
            }
        }
        for r in gone where records.contains(where: { $0.id == r.id }) { remove(r) }
    }

    private func fileIsGone(_ bookmark: Data) -> Bool {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            if url.path.contains("/.Trash/") { return true }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return !FileManager.default.fileExists(atPath: url.path)
        } catch {
            let e = error as NSError
            return e.domain == NSCocoaErrorDomain && (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError)
        }
    }

    static func makeThumb(_ src: CGImageSource) -> CGImage? {
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                                  kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }
    private func saveThumb(_ img: CGImage, _ id: UUID) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(thumbURL(id) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }
    private func loadThumb(_ id: UUID) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(thumbURL(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }
}

/// One row of the "Checked" list: thumbnail, name, target line, when checked, score.
struct HistoryRow: View {
    let r: CheckRecord; let thumb: CGImage?
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFill() }
                else { Image(systemName: r.isJPEG ? "photo" : "doc.text").font(.title2).foregroundStyle(.secondary) }
            }
            .frame(width: 44, height: 78).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(r.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Checked \(r.checked.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let s = r.score {
                    Text(String(format: "%.0f%%", s)).font(.title3.bold().monospacedDigit()).foregroundStyle(tiltTint(s))
                    Text(tiltClass(s)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No score").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(r.m.map { "\($0.starCount) stars" } ?? "too few stars").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// ASTAP class names and the card colours, shared by the result card and the list.
func tiltClass(_ v: Float) -> String {
    switch v { case ..<5.0001: return "None"; case ..<10.0001: return "Almost none"; case ..<15.0001: return "Mild"
    case ..<20.0001: return "Moderate"; case ..<30.0001: return "Severe"; default: return "Extreme" }
}
func tiltTint(_ v: Float) -> Color { v <= 12 ? .green : (v <= 25 ? .orange : .red) }
