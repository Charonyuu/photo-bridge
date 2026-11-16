import SwiftUI

enum Palette {
    static let accent = Color(red: 0.145, green: 0.388, blue: 0.922)
    static let ok = Color(red: 0.08, green: 0.50, blue: 0.24)
    static let bad = Color(red: 0.76, green: 0.25, blue: 0.05)
    static let cloud = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let wait = Color(red: 0.39, green: 0.45, blue: 0.55)
    static let panel = Color(red: 0.965, green: 0.969, blue: 0.976)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if let p = model.pairing { BackupView(pairing: p) } else { PairView() }
            }
            .background(Color.white.ignoresSafeArea())
        }
        .tint(Palette.accent)
    }
}

// MARK: - 配對

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            PairIllustration().frame(width: 220, height: 150)
            Text("把照片備份到電腦").font(.title2.bold()).padding(.top, 28)
            Text("在電腦上打開 PhotoBridge 接收程式，\n用這支手機掃描畫面上的 QR Code。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)
            if let err = model.pairError {
                Text(err).font(.footnote).foregroundStyle(Palette.bad).padding(.top, 12)
            }
            Spacer()
            Button { scanning = true } label: {
                Label("掃描電腦 QR Code", systemImage: "qrcode.viewfinder")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
            Button("貼上配對連結") {
                if let s = UIPasteboard.general.string { model.pair(text: s) } else { model.pairError = "剪貼簿是空的" }
            }
            .font(.subheadline).padding(.top, 14)
            Text("手機和電腦要連同一個 Wi-Fi，不經過雲端。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 18)
        }
        .padding(24)
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                QRScannerView { code in
                    scanning = false
                    model.pair(text: code)
                }
                .ignoresSafeArea()
                Text("對準電腦畫面上的 QR Code")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule()).padding(.bottom, 40)
            }
        }
    }
}

/// 手機 → 電腦 的線條插圖
struct PairIllustration: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 220
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rad: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: rad * s)
            }
            let line = StrokeStyle(lineWidth: 2.5 * s, lineCap: .round, lineJoin: .round)
            let gray = Color(red: 0.6, green: 0.64, blue: 0.70)
            // 手機
            ctx.stroke(r(10, 20, 60, 110, 12), with: .color(gray), style: line)
            ctx.fill(r(20, 38, 40, 30, 4), with: .color(Palette.accent.opacity(0.15)))
            ctx.fill(r(20, 72, 18, 18, 3), with: .color(Palette.accent.opacity(0.3)))
            ctx.fill(r(42, 72, 18, 18, 3), with: .color(Palette.accent.opacity(0.15)))
            // 螢幕
            ctx.stroke(r(120, 22, 92, 66, 8), with: .color(gray), style: line)
            var stand = Path(); stand.move(to: CGPoint(x: 156 * s, y: 88 * s)); stand.addLine(to: CGPoint(x: 152 * s, y: 104 * s))
            stand.move(to: CGPoint(x: 176 * s, y: 88 * s)); stand.addLine(to: CGPoint(x: 180 * s, y: 104 * s))
            stand.move(to: CGPoint(x: 140 * s, y: 106 * s)); stand.addLine(to: CGPoint(x: 192 * s, y: 106 * s))
            ctx.stroke(stand, with: .color(gray), style: line)
            // QR 小方塊
            for (x, y) in [(132, 32), (180, 32), (132, 60)] {
                ctx.stroke(r(CGFloat(x), CGFloat(y), 18, 18, 3), with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 2 * s))
                ctx.fill(r(CGFloat(x) + 5, CGFloat(y) + 5, 8, 8, 1), with: .color(.black.opacity(0.7)))
            }
            ctx.fill(r(160, 40, 6, 6, 1), with: .color(.black.opacity(0.5)))
            ctx.fill(r(184, 62, 8, 8, 1), with: .color(.black.opacity(0.5)))
            // 波紋
            for (i, rad) in [14.0, 24.0, 34.0].enumerated() {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 78 * s, y: 75 * s), radius: rad * s, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                ctx.stroke(arc, with: .color(Palette.accent.opacity(1 - Double(i) * 0.25)), style: line)
            }
        }
    }
}

// MARK: - 備份

struct BackupView: View {
    let pairing: Pairing
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: BackupEngine

    private var shown: Summary { engine.phase == .idle ? (engine.lastRun?.summary ?? Summary()) : engine.summary }
    private var problems: [Problem] { engine.phase == .idle ? (engine.lastRun?.problems ?? []) : engine.problems }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                computerRow
                headline
                ProgressSegments(summary: shown, processed: engine.isBusy ? engine.processed : nil)
                stats
                actionButton
                icloudToggle
                statusText
                if !problems.isEmpty {
                    NavigationLink { ProblemsView(problems: problems) } label: {
                        HStack {
                            Image(systemName: "exclamationmark.circle")
                            Text("查看 \(problems.count) 個沒備份成功的項目")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundStyle(.primary)
                }
                notes
            }
            .padding(20)
        }
        .navigationTitle("照片備份")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var computerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(Palette.accent)
                .frame(width: 40, height: 40).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.name).font(.headline)
                Text(pairing.lastHost ?? pairing.hosts.first ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("更換電腦") { model.unpair() }.font(.subheadline).disabled(engine.isBusy)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(shown.done.formatted()).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text("/ \(shown.total.formatted()) 項已備份").font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private var titleText: String {
        switch engine.phase {
        case .idle: return engine.lastRun.map { "上次備份 \($0.finishedAt.formatted(date: .abbreviated, time: .shortened))\($0.completed ? "" : "（中途停止）")" } ?? "還沒備份過"
        case .connecting: return "連線到電腦中…"
        case .running: return "備份中，已檢查 \(engine.processed.formatted()) / \(engine.summary.total.formatted()) 項"
        case .stopping: return "正在停止…"
        case .finished: return "備份完成"
        case .stopped: return "已停止，下次會從沒傳完的地方繼續"
        case .failed: return "備份中斷"
        }
    }

    private var stats: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatBox(label: "已備份", value: shown.done, color: Palette.ok)
                StatBox(label: "失敗", value: shown.failed, color: Palette.bad)
            }
            GridRow {
                StatBox(label: "只在 iCloud", value: shown.icloud, color: Palette.cloud)
                StatBox(label: "尚未備份", value: shown.pending, color: Palette.wait)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if engine.isBusy {
            Button(role: .destructive) { engine.stop() } label: {
                Text(engine.phase == .stopping ? "停止中…" : "停止").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).disabled(engine.phase == .stopping)
        } else {
            Button { engine.start(pairing: pairing) } label: {
                Text(engine.lastRun == nil ? "開始備份" : "重新檢查並補傳").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
        }
    }

    private var icloudToggle: some View {
        Toggle(isOn: $engine.includeICloud) {
            VStack(alignment: .leading, spacing: 2) {
                Text("也從 iCloud 下載").font(.subheadline.weight(.medium))
                Text("手機上沒有原始檔的照片，先從 iCloud 抓下來再傳。比較慢，會用到網路和一點手機空間，傳完就刪。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(engine.isBusy)
        .padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusText: some View {
        if case .failed(let msg) = engine.phase {
            Text(msg).font(.subheadline).foregroundStyle(Palette.bad)
        } else if engine.isBusy {
            VStack(alignment: .leading, spacing: 4) {
                if !engine.current.isEmpty { Text("正在傳：\(engine.current)").lineLimit(1) }
                Text("這次新傳 \(engine.uploadedFiles.formatted()) 個檔案（\(ByteCountFormatter.string(fromByteCount: engine.bytesSent, countStyle: .file))），電腦上已有而略過 \(engine.skippedFiles.formatted()) 個")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        if engine.limitedAccess {
            Text("你只開放了部分照片給 App，沒開放的不會備份。到「設定 > 照片備份 > 照片」改成「完整存取」。")
                .font(.footnote).foregroundStyle(Palette.bad)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("說明").font(.footnote.weight(.semibold))
            Group {
                Text("每個檔案傳完都用 SHA-256 比對，電腦收到的跟手機上的一模一樣才算「已備份」。")
                Text("「只在 iCloud」是開了最佳化儲存空間、手機上沒有原始檔的項目，不算備份成功。打開「也從 iCloud 下載」再按一次就會補齊。")
                Text("備份時請讓 App 保持在畫面上。想快一點：手機接上充電、關掉低耗電模式，電腦用網路線，手機連 5GHz Wi-Fi。")
                Text("App 只讀取照片，不會刪除或修改手機和 iCloud 上的任何東西。")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

struct StatBox: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.footnote).foregroundStyle(.secondary)
            }
            Text(value.formatted()).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProgressSegments: View {
    let summary: Summary
    let processed: Int?
    var body: some View {
        GeometryReader { geo in
            let total = max(summary.total, 1)
            let w = geo.size.width
            HStack(spacing: 0) {
                Rectangle().fill(Palette.ok).frame(width: w * CGFloat(summary.done) / CGFloat(total))
                Rectangle().fill(Palette.bad).frame(width: w * CGFloat(summary.failed) / CGFloat(total))
                Rectangle().fill(Palette.cloud).frame(width: w * CGFloat(summary.icloud) / CGFloat(total))
                Spacer(minLength: 0)
            }
            .frame(width: w, alignment: .leading)
            .background(Palette.panel)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.3), value: summary)
        }
        .frame(height: 10)
    }
}

// MARK: - 沒成功的清單

struct ProblemsView: View {
    let problems: [Problem]
    @State private var filter: Problem.Status? = nil

    var body: some View {
        List {
            Picker("篩選", selection: $filter) {
                Text("全部 \(problems.count)").tag(Problem.Status?.none)
                Text("失敗 \(problems.filter { $0.status == .failed }.count)").tag(Problem.Status?.some(.failed))
                Text("iCloud \(problems.filter { $0.status == .icloud }.count)").tag(Problem.Status?.some(.icloud))
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            ForEach(problems.filter { filter == nil || $0.status == filter }) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.filename).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(p.status == .icloud ? "只在 iCloud" : "失敗").font(.caption)
                            .foregroundStyle(p.status == .icloud ? Palette.cloud : Palette.bad)
                    }
                    if let d = p.created { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(p.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("沒備份成功的項目")
        .navigationBarTitleDisplayMode(.inline)
    }
}
