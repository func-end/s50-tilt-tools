// ContentView.swift: S50 Focus Check (iPad, Swift Playgrounds). Pick the Seestar stack image (full size) or a FITS
// frame; shows ASTAP-style corner tilt, class, softest corner, a 3x3 star-size map and advice. Runs fully offline.
// Every check is kept in the "Checked" list (History.swift).
import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// JPEG readings run lower than ASTAP on the FITS (stretched 8-bit data). Empirical calibration on 13 star-field
/// stacks from one S50 Pro, Oct 2026: ASTAP ~= 1.35 x JPEG value (rank correlation 0.98). Not a general ASTAP equivalence. FITS: no factor.
let jpegToASTAP: Float = 1.35

/// Below these star counts no score is shown. Vega 5-frame stack (Oct 1): 176 stars in the JPEG, 239 in the FITS stack,
/// app said 81% / 30% while ASTAP found no measurable stars. Lowest-count image in the validation set: 478 stars, 0.3 pt off.
/// Raw FITS frames are 2x2 binned, so they carry fewer stars (NGC 869 subs ~550-800, sparse fields 60-400).
func minStars(_ source: String) -> Int { source == "FITS raw frame" ? 200 : 400 }
func tooFewStarsMessage(_ r: TiltResult, _ name: String) -> String? {
    r.starCount >= minStars(r.source) ? nil :
        "\(name): only \(r.starCount) stars found, too few for a reliable tilt figure, so no score is shown. Use a rich star field such as NGC 869 (a good stack gives 1,500+ stars)."
}

/// Shared progress value updated from the worker thread (throttled to whole percents).
@Observable final class Meter { var fraction: Double = 0; var lastPct = -1
    func report(_ f: Double) { let pct = Int(f * 100); if pct != lastPct { lastPct = pct; DispatchQueue.main.async { self.fraction = f } } }
    func reset() { lastPct = -1; fraction = 0 }
}

/// A loaded photo waiting for the user's yes/no before it is measured. `previous` is set when it was checked before.
struct Pending { let cg: CGImage; let src: CGImageSource; let name: String; let label: String
    var assetID: String? = nil; var bookmark: Data? = nil; var previous: CheckRecord? = nil }

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var history = History()
    @State private var selected: CheckRecord.ID?
    @State private var photo: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var busy = false
    @State private var loading = false
    @State private var meter = Meter()
    @State private var pending: Pending?
    @State private var result: TiltResult?
    @State private var shown: Float = 0
    @State private var isJPEG = true
    @State private var label = ""
    @State private var fileName = ""
    @State private var checkedOn: Date?
    @State private var message = "Pick a full-size Seestar stack image or a FITS frame of a star field, e.g. NGC 869. \"Choose file\" shows names (Files app); \"Choose photo\" shows thumbnails, then asks you to confirm. Every check is saved in the list on the left."

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                if let h = history.hint { Text(h).font(.caption).foregroundStyle(.secondary) }
                ForEach(history.records) { r in HistoryRow(r: r, thumb: history.thumbs[r.id]).tag(r.id) }
                    .onDelete { idx in idx.map { history.records[$0] }.forEach { history.remove($0) } }
            }
            .overlay {
                if history.records.isEmpty {
                    ContentUnavailableView("Nothing checked yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Each photo or file you check is saved here with its score."))
                }
            }
            .navigationTitle("Checked (\(history.records.count))")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Button { startNew(); showPicker = true } label: { Label("Choose photo", systemImage: "photo") }
                            .buttonStyle(.borderedProminent)
                        Button { startNew(); showFiles = true } label: { Label("Choose file (by name)", systemImage: "doc") }
                            .buttonStyle(.bordered)
                    }.disabled(busy)
                    if loading { ProgressView("Opening photo…") }
                    if let p = pending {
                        ConfirmCard(p: p,
                                    yes: { let chosen = p; pending = nil; Task { await measure(chosen) } },
                                    no: { startNew(); showPicker = true },
                                    showSaved: { pending = nil; if let prev = p.previous { selected = prev.id; show(prev) } })
                    }
                    if busy {
                        ProgressView(value: meter.fraction) {
                            Text("Measuring stars… \(Int(meter.fraction * 100))%").font(.callout.monospacedDigit())
                        }.frame(maxWidth: 420)
                    }
                    if let r = result { ResultCard(r: r, shown: shown, isJPEG: isJPEG, label: label, fileName: fileName, checked: checkedOn) }
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    Text("Reference (one S50 Pro, Oct 2026): autofocus at 1042 gave 9.7% (Almost none). Bad nights were 30–50% (Severe/Extreme).")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("S50 Focus Check")
        }
        // photoLibrary: .shared() gives each pick its Photos identifier (no permission needed for that), used to spot repeats
        // and, with Photos access, deleted photos.
        .photosPicker(isPresented: $showPicker, selection: $photo, matching: .images, photoLibrary: .shared())
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .data], allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let url = urls.first { Task { await analyseFile(url) } }
        }
        .onChange(of: selected) { _, id in
            if let id, let r = history.records.first(where: { $0.id == id }) { pending = nil; show(r) }
        }
        .task { await history.prune() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await history.prune() } } }
    }

    func startNew() { pending = nil; photo = nil; selected = nil }

    /// Show a saved entry: its result card, or why it has no score.
    func show(_ r: CheckRecord) {
        fileName = r.name; label = r.label; checkedOn = r.checked; isJPEG = r.isJPEG
        if let s = r.score, let res = r.result {
            shown = s; result = res
            message = "Saved result. Measured \(res.starCount) stars. To re-measure, choose the photo again and tap Measure again."
        } else { result = nil; message = r.note ?? "No score for this one." }
    }

    /// Photos path: load the picked photo and show it for confirmation (Yes measures, No re-opens the picker).
    func loadPhoto(_ item: PhotosPickerItem) async {
        loading = true; result = nil; defer { loading = false }
        // Prefer the file form: its URL carries the photo's file name. Fall back to raw data (name unknown).
        var data: Data? = nil; var name = unknownName
        if let picked = try? await item.loadTransferable(type: PickedImage.self) {
            data = try? Data(contentsOf: picked.url); name = picked.url.lastPathComponent
        }
        if data == nil { data = try? await item.loadTransferable(type: Data.self) }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { message = "Could not open that photo."; return }
        let id = item.itemIdentifier
        pending = Pending(cg: cg, src: src, name: name, label: photoLabel(src, name: name), assetID: id,
                          previous: history.find(name: name, assetID: id))
    }

    /// Measure a confirmed (or by-name) image and save it to the list.
    func measure(_ p: Pending) async {
        fileName = p.name; label = p.label; checkedOn = nil
        if max(p.cg.width, p.cg.height) < 3000 {     // unsupported input: no score, no advice, not saved
            message = "This image is \(p.cg.width)×\(p.cg.height). The check needs the full-size image (2160×3840); the app's shared copy is too small to measure reliably."
            return
        }
        busy = true; result = nil; defer { busy = false }
        var rec: CheckRecord
        do {
            let m = meter; m.reset(); let cg = p.cg
            let r = try await Task.detached(priority: .userInitiated) { try analyse(cgImage: cg, progress: m.report) }.value
            if let warn = tooFewStarsMessage(r, p.name) {
                message = warn
                rec = CheckRecord(name: p.name, label: p.label, isJPEG: true, score: nil, note: warn, r: r, assetID: p.assetID, bookmark: p.bookmark)
            } else {
                isJPEG = true; shown = r.tiltPercent * jpegToASTAP; result = r
                message = "Measured \(r.starCount) stars from the image (\(p.cg.width)×\(p.cg.height)). Assumes the picture is upright as the Seestar app saved it. Saved to the list."
                rec = CheckRecord(name: p.name, label: p.label, isJPEG: true, score: shown, note: nil, r: r, assetID: p.assetID, bookmark: p.bookmark)
            }
        } catch {
            message = "\(p.name): \(error)"
            rec = CheckRecord(name: p.name, label: p.label, isJPEG: true, score: nil, note: message, r: nil, assetID: p.assetID, bookmark: p.bookmark)
        }
        history.add(rec, thumbFrom: p.src)
        if p.assetID != nil { await history.prune() }       // first Photos entry: asks for Photos access with context
    }

    /// Files path: an image picked by name is measured directly (the name was visible when choosing); FITS likewise.
    /// A file already in the list shows its saved result instead.
    func analyseFile(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        if let prev = history.find(name: name, assetID: nil) {
            selected = prev.id; show(prev)
            message = "Already checked on \(prev.checked.formatted(date: .abbreviated, time: .shortened)); showing the saved result. To measure it again, swipe it off the list and choose it again."
            return
        }
        guard let data = try? Data(contentsOf: url) else { message = "Could not open \(name)."; return }
        let bookmark = try? url.bookmarkData()
        if !["fit", "fits", "fts"].contains(url.pathExtension.lowercased()) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { message = "Could not open \(name)."; return }
            await measure(Pending(cg: cg, src: src, name: name, label: photoLabel(src, name: name), bookmark: bookmark)); return
        }
        busy = true; result = nil; checkedOn = nil; defer { busy = false }
        var rec: CheckRecord
        do {
            let m = meter; m.reset()
            let r = try await Task.detached(priority: .userInitiated) { try analyse(fitsData: data, progress: m.report) }.value
            label = r.source; fileName = name
            if let warn = tooFewStarsMessage(r, name) {
                message = warn
                rec = CheckRecord(name: name, label: r.source, isJPEG: false, score: nil, note: warn, r: r, assetID: nil, bookmark: bookmark)
            } else {
                isJPEG = false; shown = r.tiltPercent; result = r
                message = "Measured \(r.starCount) stars from \(name) (\(r.source)). Saved to the list."
                rec = CheckRecord(name: name, label: r.source, isJPEG: false, score: shown, note: nil, r: r, assetID: nil, bookmark: bookmark)
            }
        } catch {
            message = "\(name): \(error)"
            rec = CheckRecord(name: name, label: "FITS", isJPEG: false, score: nil, note: message, r: nil, assetID: nil, bookmark: bookmark)
        }
        history.add(rec, thumbFrom: nil)
    }
}

/// Shows the picked photo with its name, target/date and size. New photo: Yes measures it, No goes back to the picker.
/// Photo already in the list: show the saved result, measure again, or choose another.
struct ConfirmCard: View {
    let p: Pending; let yes: () -> Void; let no: () -> Void; let showSaved: () -> Void
    var tooSmall: Bool { max(p.cg.width, p.cg.height) < 3000 }
    @ViewBuilder var buttons: some View {
        if p.previous != nil {
            Button(action: showSaved) { Label("Show saved result", systemImage: "clock.arrow.circlepath") }.buttonStyle(.borderedProminent)
            Button(action: yes) { Label("Measure again", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).disabled(tooSmall)
        } else {
            Button(action: yes) { Label("Yes, measure", systemImage: "checkmark") }.buttonStyle(.borderedProminent).disabled(tooSmall)
        }
        Button(action: no) { Label("No, choose another", systemImage: "arrow.uturn.backward") }.buttonStyle(.bordered)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.previous == nil ? "Measure this photo?" : "Already checked").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                Image(decorative: p.cg, scale: 1).resizable().scaledToFit().frame(maxWidth: 180, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.headline).lineLimit(3).truncationMode(.middle)
                    Text(p.label).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(p.cg.width) × \(p.cg.height) px").font(.caption).foregroundStyle(.secondary)
                    if let prev = p.previous {
                        Text("Checked \(prev.checked.formatted(date: .abbreviated, time: .shortened)): \(prev.score.map { String(format: "%.0f%% %@", $0, tiltClass($0)) } ?? "no score")")
                            .font(.subheadline.weight(.semibold))
                    }
                    if tooSmall {
                        Text("Too small to measure: needs the full-size image (2160×3840).").font(.caption).foregroundStyle(.red)
                    }
                    ViewThatFits {
                        HStack(spacing: 12) { buttons }
                        VStack(alignment: .leading, spacing: 8) { buttons }
                    }.padding(.top, 6)
                }
            }
        }
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Picked photo received as a file, so its name is known (no Photos permission needed).
struct PickedImage: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedImage(url: dst)
        }
    }
}

/// "NGC 869 · 2026-10-07 20:07" from the Seestar's own tags: target in TIFF ImageDescription; date from the JSON record the
/// Seestar stores in Exif CameraOwnerName (ImageIO drops its non-standard TIFF DateTime "2026.10.07 ..."). That record also
/// holds the site's GPS position, which is deliberately not read or shown.
/// Target · date for the card. A Seestar file name ("Stacked_19_M 27_10.0s_LP_20261001-201058.jpeg") wins: on
/// 2026-10-08 an M 27 photo's embedded record said "M 57" (the next target), so the record is only a fallback.
func photoLabel(_ src: CGImageSource, name: String = "") -> String {
    let pattern = #"^Stacked_(\d+)_(.+)_([\d.]+)s_([^_]+)_(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})\d{2}"#
    if let re = try? NSRegularExpression(pattern: pattern),
       let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
        let g = (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: name).map { String(name[$0]) } ?? "" }
        return "\(g[2]) · \(g[5])-\(g[6])-\(g[7]) \(g[8]):\(g[9]) · \(g[1]) × \(g[3]) s · \(g[4])"
    }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
    var target = (tiff?[kCGImagePropertyTIFFImageDescription] as? String)?.trimmingCharacters(in: .whitespaces)
    var when = (tiff?[kCGImagePropertyTIFFDateTime] as? String) ?? (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    if let owner = exif?[kCGImagePropertyExifCameraOwnerName] as? String, let d = owner.data(using: .utf8),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let res = j["result"] as? [String: Any] {
        if when == nil { when = res["date"] as? String }
        if target == nil || target == "" { target = res["obj_name"] as? String }
    }
    let parts = [target, when.map { String($0.prefix(16)) }].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? "Photo (no name or date in the file)" : parts.joined(separator: " · ")
}

struct ResultCard: View {
    let r: TiltResult; let shown: Float; let isJPEG: Bool; let label: String; let fileName: String; var checked: Date? = nil
    var cls: String { tiltClass(shown) }
    var tint: Color { tiltTint(shown) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName).font(.headline).lineLimit(2).truncationMode(.middle)
                if !label.isEmpty { Text(label).font(.subheadline).foregroundStyle(.secondary) }
                if let checked { Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%.0f%%", shown)).font(.system(size: 56, weight: .bold, design: .rounded)).foregroundStyle(tint)
                VStack(alignment: .leading) {
                    Text(cls).font(.title2.bold())
                    Text(isJPEG ? "≈ ASTAP tilt (image; calibrated on one unit's data)" : "ASTAP-style corner tilt (FITS)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label(accuracyNote, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                .padding(10).background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Softest corner: \(r.worstCornerName)").font(.headline)
            Text(String(format: "Median star size: %.2f px%@", r.medianHFD, isJPEG ? " (image pixels)" : " (sensor pixels)"))
                .font(.caption).foregroundStyle(.secondary)
            Text(adviceText).font(.body)
            Text("Star size by area (as in the app image)").font(.caption).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let v = r.grid[row][col]; let lo = r.grid.flatMap { $0 }.min() ?? v; let hi = r.grid.flatMap { $0 }.max() ?? v
                            let t = hi > lo ? Double((v - lo) / (hi - lo)) : 0
                            Text(String(format: "%.1f", v)).font(.callout.monospacedDigit())
                                .frame(width: 72, height: 56)
                                .background(Color(red: 0.85 * t + 0.15, green: 0.85 * (1 - t) + 0.15, blue: 0.25).opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    /// Error figures: app engine × 1.35 vs ASTAP on the FITS of 18 stacks (see README).
    var accuracyNote: String {
        isJPEG
            ? "Approximate: this estimates ASTAP's figure from the picture. On the stacks it was validated on (one S50 Pro) it was usually within about 3 points of ASTAP on the FITS file, but 7–10 points off on nebula fields and short stacks (M 27: 19% here vs 12% in ASTAP). Between about 10% and 30%, confirm with the FITS file (Choose file)."
            : "ASTAP's corner method, not ASTAP itself: on the validation frames (one S50 Pro) it was within about 4 points of ASTAP."
    }
    var adviceText: String {
        if shown <= 12 { return "Even field (low corner contrast). Also check the stars look sharp overall; if everything is soft, re-run autofocus." }
        return r.worstCorner.hasPrefix("3")
            ? "Bottom side soft. Re-run autofocus. If it lands the same, try short runs 10–20 steps either side and keep the position that balances the field (untested tip)."
            : "Top side soft. Re-run autofocus. If it lands the same, try short runs 10–20 steps either side and keep the position that balances the field (untested tip)."
    }
}
