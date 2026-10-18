// FanCurve: menu-bar panel and window for the fancurve service.
//
// The service (fancurve, running as root) does the fan control and writes
// status.json every two seconds. This app only shows that file and edits the
// settings file, so it needs no special rights.
import AppKit
import Charts
import SwiftUI

let stateDir = "/Library/Application Support/fancurve"
// How to (re)install the service. A build from a source checkout carries the
// checkout's path in Info.plist (fan.sh puts it there); the .pkg build does not.
let installHint: (text: String, command: String?) = {
  if let dir = Bundle.main.object(forInfoDictionaryKey: "FanCurveSource") as? String {
    let command = "sudo \"\(dir)/fan.sh\" install"
    return (command, command)
  }
  return ("FanCurve 설치 패키지(.pkg)를 다시 실행하세요", nil)
}()

func arg(_ name: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
  return a[i + 1]
}

func median(_ v: [Double]) -> Double? {
  guard !v.isEmpty else { return nil }
  let s = v.sorted()
  return s[s.count / 2]
}

// MARK: - Data

struct FanInfo: Decodable {
  let actual: Double?
  let target: Double?
  let min: Double
  let max: Double
}

struct Status: Decodable {
  let time: Double
  let mode: String
  let low, high, hot: Double
  let dry, controlling, conflict: Bool
  let cpu, gpu: Double?
  let hottest: Double
  let hottestKey: String
  let fans: [FanInfo]
  let history: [[Double?]]
}

struct Point: Identifiable {
  let id: Int
  let date: Date
  let cpu: Double?
  let gpu: Double?
}

struct Preset: Identifiable {
  let id: String
  let icon: String
  let low, high: Double
}

let presets = [
  Preset(id: "조용", icon: "moon.fill", low: 55, high: 90),
  Preset(id: "균형", icon: "circle.lefthalf.filled", low: 50, high: 80),
  Preset(id: "시원", icon: "snowflake", low: 45, high: 72),
]

@MainActor
final class Model: ObservableObject {
  @Published var status: Status?
  @Published var mode = "curve"
  @Published var low = 50.0
  @Published var high = 80.0
  @Published var saveError: String?
  var hot = 105.0
  let statePath: String
  let configPath: String
  private var timer: Timer?
  // The last few readings. Now and then the SMC returns one odd CPU value
  // (31.7 °C in the middle of a run); the median keeps it off the screen.
  private var recent: [(cpu: Double?, gpu: Double?)] = []

  init(statePath: String, configPath: String) {
    self.statePath = statePath
    self.configPath = configPath
    loadConfig()
    poll()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  func loadConfig() {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
    for line in text.split(separator: "\n") {
      let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard kv.count == 2 else { continue }
      switch kv[0] {
      case "mode": mode = kv[1]
      case "low": low = Double(kv[1]) ?? low
      case "high": high = Double(kv[1]) ?? high
      case "hot": hot = Double(kv[1]) ?? hot
      default: break
      }
    }
  }

  func poll() {
    guard let data = FileManager.default.contents(atPath: statePath),
      let s = try? JSONDecoder().decode(Status.self, from: data)
    else {
      status = nil
      return
    }
    if s.time != status?.time {
      recent.append((s.cpu, s.gpu))
      if recent.count > 3 { recent.removeFirst() }
    }
    status = s
  }

  // The settings file belongs to the user (fan.sh install sets that up), so a
  // plain in-place write is enough; the service picks it up within 2 s.
  func save() {
    let text = "mode=\(mode)\nlow=\(Int(low))\nhigh=\(Int(high))\nhot=\(Int(hot))\n"
    do {
      try text.write(toFile: configPath, atomically: false, encoding: .utf8)
      saveError = nil
    } catch {
      saveError = "설정을 저장하지 못했습니다. 먼저 설치하세요."
    }
  }

  var live: Bool {
    guard let s = status else { return false }
    return Date().timeIntervalSince1970 - s.time < 10
  }
  var current: Status? { live ? status : nil }
  var cpu: Double? { live ? median(recent.compactMap(\.cpu)) : nil }
  var gpu: Double? { live ? median(recent.compactMap(\.gpu)) : nil }
  var hotter: Double? { [cpu, gpu].compactMap { $0 }.max() }
  var gpuLeads: Bool { (gpu ?? -1) > (cpu ?? -1) }
  var rpm: Double? {
    let v = (current?.fans ?? []).compactMap(\.actual)
    return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
  }
  var target: Double? { current?.fans.first?.target }
  // Fanless Macs (MacBook Air) only get the temperatures.
  var hasFans: Bool { !(status?.fans.isEmpty ?? false) }
  var fanMin: Double { status?.fans.first?.min ?? 1000 }
  var fanMax: Double { status?.fans.first?.max ?? 3625 }
  var fanFrac: Double {
    guard let r = rpm else { return 0 }
    return min(max((r - fanMin) / (fanMax - fanMin), 0), 1)
  }
  func curveRPM(_ t: Double) -> Double {
    fanMin + min(max((t - low) / (high - low), 0), 1) * (fanMax - fanMin)
  }
  // History with each point replaced by the median of its five neighbours.
  var points: [Point] {
    let rows = (current?.history ?? []).compactMap { row -> (Date, Double?, Double?)? in
      guard row.count == 3, let t = row[0] else { return nil }
      return (Date(timeIntervalSince1970: t), row[1], row[2])
    }
    return rows.indices.map { i in
      let w = rows[max(0, i - 2)...min(rows.count - 1, i + 2)]
      return Point(id: i, date: rows[i].0, cpu: median(w.compactMap(\.1)), gpu: median(w.compactMap(\.2)))
    }
  }
  var subtitle: String {
    guard let s = current else { return "CPU·GPU 중 더 뜨거운 쪽을 따라갑니다" }
    switch s.mode {
    case "auto": return "Apple 기본 제어 중 · 온도만 표시"
    case "max": return "항상 최대 속도로 돌리는 중"
    default: return "\(gpuLeads ? "GPU" : "CPU") 온도를 따라가는 중"
    }
  }
  var menuTitle: String { hotter.map { "\(Int($0.rounded()))°" } ?? "–" }
}

// MARK: - Look
//
// After affectUI (affectui.com): a gray tray with a heading that holds a white
// card, ink and gray text, one blue accent, soft tinted chips for state, and
// calm motion (cubic-bezier(0.22, 1, 0.36, 1)). Colours are affectUI's tokens.

extension Color {
  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255, opacity: alpha)
  }

  // Follows the light or dark appearance of the view it is drawn in.
  init(light: Color, dark: Color) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
      })
  }
}

enum Palette {
  static let page = Color(light: Color(hex: 0xf7f7f7), dark: Color(hex: 0x0f0f10))
  static let tray = Color(light: Color(hex: 0xf0f0f0), dark: Color(hex: 0x161618))
  static let card = Color(light: .white, dark: Color(hex: 0x232326))
  static let pill = Color(light: .white, dark: Color(hex: 0x2a2a2e))
  static let border = Color(light: Color(hex: 0xe5e5e5), dark: .white.opacity(0.08))
  static let line = Color(light: Color(hex: 0xf0f0f0), dark: .white.opacity(0.08))
  static let ink = Color(light: Color(hex: 0x171717), dark: Color(hex: 0xededed))
  static let text = Color(light: Color(hex: 0x404040), dark: Color(hex: 0xc8c8cc))
  static let muted = Color(light: Color(hex: 0x737373), dark: Color(hex: 0x8f8f8f))
  static let accent = Color(light: Color(hex: 0x2f6bff), dark: Color(hex: 0x6b95ff))
  static let accentSoft = Color(light: Color(hex: 0x2f6bff, alpha: 0.10), dark: Color(hex: 0x6d8bff, alpha: 0.14))
  static let shadow = Color(light: .black.opacity(0.06), dark: .black.opacity(0.4))
  static let cpu = Color(light: Color(hex: 0xe8890c), dark: Color(hex: 0xf0a64a))
  static let gpu = accent
}

enum Tone {
  case good, warn, bad, neutral, accent

  var fg: Color {
    switch self {
    case .good: Color(light: Color(hex: 0x1f8a4c), dark: Color(hex: 0x3fbf74))
    case .warn: Color(light: Color(hex: 0xb4590a), dark: Color(hex: 0xf0a050))
    case .bad: Color(light: Color(hex: 0xe5484d), dark: Color(hex: 0xf2777b))
    case .neutral: Palette.muted
    case .accent: Palette.accent
    }
  }

  var bg: Color {
    switch self {
    case .good: Color(light: Color(hex: 0xedfaf3), dark: Color(hex: 0x1f8a4c, alpha: 0.18))
    case .warn: Color(light: Color(hex: 0xfff4e6), dark: Color(hex: 0xf08c28, alpha: 0.16))
    case .bad: Color(light: Color(hex: 0xfff0f0), dark: Color(hex: 0xe5484d, alpha: 0.16))
    case .neutral: Color(light: Color(hex: 0xf5f5f5), dark: Color(hex: 0x2a2a2d))
    case .accent: Palette.accentSoft
    }
  }
}

let calm = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
let snapshotMode = arg("--snapshot") != nil

// Averages and the hot spot have different normal ranges.
func averageState(_ t: Double?) -> (String, Tone) {
  guard let t else { return ("–", .neutral) }
  return t < 70 ? ("여유", .good) : t < 85 ? ("따뜻함", .warn) : ("뜨거움", .bad)
}

func spotState(_ t: Double?) -> (String, Tone) {
  guard let t else { return ("–", .neutral) }
  return t < 95 ? ("여유", .good) : t < 103 ? ("따뜻함", .warn) : ("뜨거움", .bad)
}

// Rows rise 4 pt and fade in, one after another.
struct Arrive: ViewModifier {
  let delay: Double
  @State private var shown = snapshotMode

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : 4)
      .onAppear {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.52).delay(delay)) { shown = true }
      }
  }
}

extension View {
  func arrive(_ index: Int) -> some View { modifier(Arrive(delay: 0.12 + Double(index) * 0.07)) }
}

// MARK: - Pieces

final class Spinner {
  var angle = 0.0
  var last = Date()
  func advance(to date: Date, rpm: Double) -> Double {
    angle = (angle + date.timeIntervalSince(last) * rpm * 0.1).truncatingRemainder(dividingBy: 360)
    last = date
    return angle
  }
}

// Turns at a speed proportional to the real fan speed.
struct SpinningFan: View {
  let rpm: Double
  @State private var spinner = Spinner()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
      Image(systemName: "fan.fill").rotationEffect(.degrees(spinner.advance(to: ctx.date, rpm: rpm)))
    }
  }
}

// Brighter stops for the logo, which always sits on a dark background.
let logoHeat: [Color] = [
  Color(red: 0.20, green: 0.85, blue: 0.95), Color(red: 0.30, green: 0.90, blue: 0.55),
  Color(red: 1.00, green: 0.85, blue: 0.25), Color(red: 1.00, green: 0.55, blue: 0.20),
  Color(red: 0.98, green: 0.25, blue: 0.30),
]

// The logo: a fan inside a temperature arc. Also used, scaled up, as the app icon.
struct LogoMark: View {
  let size: CGFloat
  var rpm: Double? = nil

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.2245, style: .continuous)
    let line = StrokeStyle(lineWidth: size * 0.078, lineCap: .round)
    ZStack {
      shape.fill(
        LinearGradient(
          colors: [Color(red: 0.13, green: 0.16, blue: 0.32), Color(red: 0.04, green: 0.05, blue: 0.13)],
          startPoint: .top, endPoint: .bottom))
      shape.fill(
        RadialGradient(
          colors: [.white.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: size * 0.92))
      shape.strokeBorder(.white.opacity(0.16), lineWidth: max(0.5, size * 0.005))
      ZStack {
        Circle().trim(from: 0, to: 0.75).stroke(.white.opacity(0.10), style: line).rotationEffect(.degrees(135))
        Circle().trim(from: 0, to: 0.75)
          .stroke(
            AngularGradient(colors: logoHeat, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
            style: line
          )
          .rotationEffect(.degrees(135))
          .shadow(color: .orange.opacity(0.45), radius: size * 0.027)
        Group {
          if let rpm { SpinningFan(rpm: rpm) } else { Image(systemName: "fan.fill") }
        }
        .font(.system(size: size * 0.364, weight: .bold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: size * 0.015, y: size * 0.007)
      }
      .frame(width: size * 0.68, height: size * 0.68)
    }
    .frame(width: size, height: size)
  }
}

struct AppIcon: View {
  var body: some View {
    LogoMark(size: 824)
      .shadow(color: .black.opacity(0.30), radius: 18, y: 10)
      .frame(width: 1024, height: 1024)
  }
}

// A gray tray with a heading, holding a white card (affectUI's Change Summary).
struct Tray<Accessory: View, Content: View>: View {
  let title: String
  let icon: String
  let accessory: Accessory
  let content: Content

  init(
    _ title: String, icon: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.icon = icon
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    let card = RoundedRectangle(cornerRadius: 16, style: .continuous)
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: icon).font(.system(size: 12, weight: .medium))
          Text(title).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Palette.accent)
        Spacer(minLength: 8)
        accessory
          .font(.system(size: 12))
          .foregroundStyle(Palette.muted)
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 7)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: card)
        .overlay(card.strokeBorder(Palette.border))
        .shadow(color: Palette.shadow, radius: 1, y: 1)
    }
    .padding(5)
    .background(Palette.tray, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
  }
}

extension Tray where Accessory == EmptyView {
  init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
    self.init(title, icon: icon, accessory: { EmptyView() }, content: content)
  }
}

struct Row<Trailing: View>: View {
  let label: String
  var height: CGFloat = 40
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 12) {
      Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
      Spacer(minLength: 8)
      trailing
    }
    .padding(.horizontal, 14)
    .frame(minHeight: height)
  }
}

struct Hairline: View {
  var vertical = false

  var body: some View {
    Rectangle().fill(Palette.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
  }
}

struct Chip: View {
  let text: String
  let tone: Tone
  var dot = false

  var body: some View {
    HStack(spacing: 5) {
      if dot { Circle().fill(tone.fg).frame(width: 6, height: 6) }
      Text(text).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
    }
    .foregroundStyle(tone.fg)
    .padding(.horizontal, 7)
    .frame(height: 20)
    .background(tone.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

struct LineBar: View {
  let frac: Double
  var tint: Color = Palette.accent

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.line)
        Capsule().fill(tint).frame(width: max(4, g.size.width * frac))
      }
    }
    .frame(height: 4)
    .animation(calm, value: frac)
  }
}

struct Banner: View {
  let icon: String
  let title: String
  let detail: String
  let tone: Tone
  var copy: String? = nil

  var body: some View {
    let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.fg)
        .frame(width: 22, height: 22)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
        Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.muted)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
      if let copy {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(copy, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc").foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain)
        .help("명령 복사")
      }
    }
    .padding(10)
    .background(Palette.card, in: card)
    .overlay(card.strokeBorder(Palette.border))
  }
}

// MARK: - Sections

struct Header: View {
  @EnvironmentObject var model: Model

  var body: some View {
    HStack(spacing: 10) {
      LogoMark(size: 32, rpm: model.rpm ?? 0)
      VStack(alignment: .leading, spacing: 1) {
        Text("FanCurve").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
        Text("CPU·GPU 온도로 팬을 조절합니다").font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
      Spacer()
      status
    }
    .padding(.horizontal, 4)
  }

  @ViewBuilder var status: some View {
    if let s = model.current {
      if s.dry {
        Chip(text: "시험 모드", tone: .accent, dot: true)
      } else if s.conflict {
        Chip(text: "충돌", tone: .warn, dot: true)
      } else if s.mode == "auto" {
        Chip(text: "Apple 자동", tone: .neutral, dot: true)
      } else {
        Chip(text: "제어 중", tone: .good, dot: true)
      }
    } else {
      Chip(text: "꺼짐", tone: .bad, dot: true)
    }
  }
}

struct TempStat: View {
  let title: String
  let value: Double?
  let state: (String, Tone)
  var leading = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
        if leading {
          Image(systemName: "fan.fill").font(.system(size: 9)).foregroundStyle(Palette.accent)
            .help("팬이 이 온도를 따라갑니다")
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value.map { "\(Int($0.rounded()))" } ?? "–")
          .font(.system(size: 24, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(Palette.ink)
          .contentTransition(.numericText())
        Text("°C").font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
      Chip(text: state.0, tone: state.1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }
}

struct TempsTray: View {
  @EnvironmentObject var model: Model

  var body: some View {
    let following = model.current?.mode == "curve"
    Tray("온도", icon: "thermometer.medium") {
      Text(model.subtitle)
    } content: {
      HStack(spacing: 0) {
        TempStat(title: "CPU", value: model.cpu, state: averageState(model.cpu), leading: following && !model.gpuLeads)
          .arrive(0)
        Hairline(vertical: true)
        TempStat(title: "GPU", value: model.gpu, state: averageState(model.gpu), leading: following && model.gpuLeads)
          .arrive(1)
        Hairline(vertical: true)
        TempStat(title: "가장 뜨거운 곳", value: model.current?.hottest, state: spotState(model.current?.hottest))
          .arrive(2)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct HistoryChart: View {
  let points: [Point]
  var low: Double? = nil
  var high: Double? = nil
  var height: CGFloat = 118

  // Every two minutes on the minute, leaving out the last 75 s: a label that
  // close to the right edge would be cut off.
  var timeMarks: [Date] {
    guard let first = points.first?.date, let last = points.last?.date else { return [] }
    var t = (first.timeIntervalSince1970 / 120).rounded(.up) * 120
    var marks: [Date] = []
    while t <= last.timeIntervalSince1970 - 75 {
      marks.append(Date(timeIntervalSince1970: t))
      t += 120
    }
    return marks
  }

  var body: some View {
    Chart {
      ForEach(points) { p in
        if let c = p.cpu {
          LineMark(x: .value("시간", p.date), y: .value("온도", c), series: .value("구분", "CPU"))
            .foregroundStyle(by: .value("구분", "CPU"))
            .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        if let g = p.gpu {
          LineMark(x: .value("시간", p.date), y: .value("온도", g), series: .value("구분", "GPU"))
            .foregroundStyle(by: .value("구분", "GPU"))
            .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
      }
      if let low {
        RuleMark(y: .value("온도", low))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .foregroundStyle(Palette.muted.opacity(0.5))
          .annotation(position: .top, alignment: .leading, spacing: 1) {
            Text("팬 시작 \(Int(low))°").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.muted)
          }
      }
      if let high {
        RuleMark(y: .value("온도", high))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .foregroundStyle(Palette.muted.opacity(0.5))
          .annotation(position: .top, alignment: .leading, spacing: 1) {
            Text("최대 \(Int(high))°").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.muted)
          }
      }
    }
    .chartForegroundStyleScale(["CPU": Palette.cpu, "GPU": Palette.gpu])
    .chartLegend(.hidden)
    .chartYScale(domain: 30...100)
    .chartPlotStyle { $0.clipped() }
    .chartYAxis {
      AxisMarks(position: .leading, values: [40.0, 60.0, 80.0, 100.0]) { v in
        AxisGridLine().foregroundStyle(Palette.line)
        AxisValueLabel {
          if let d = v.as(Double.self) { Text("\(Int(d))°").font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: timeMarks) { _ in
        AxisGridLine().foregroundStyle(Palette.line)
        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
          .font(.system(size: 10))
          .foregroundStyle(Palette.muted)
      }
    }
    .frame(height: height)
    .overlay {
      if points.count < 2 {
        Text("데이터를 모으는 중").font(.system(size: 12)).foregroundStyle(Palette.muted)
      }
    }
  }
}

struct Legend: View {
  var body: some View {
    HStack(spacing: 10) {
      ForEach([("CPU", Palette.cpu), ("GPU", Palette.gpu)], id: \.0) { name, color in
        HStack(spacing: 4) {
          Circle().fill(color).frame(width: 6, height: 6)
          Text(name)
        }
      }
    }
  }
}

struct HistoryTray: View {
  @EnvironmentObject var model: Model
  var height: CGFloat

  var body: some View {
    Tray("최근 10분", icon: "chart.xyaxis.line") {
      Legend()
    } content: {
      HistoryChart(
        points: model.points,
        low: model.mode == "curve" ? model.low : nil,
        high: model.mode == "curve" ? model.high : nil,
        height: height
      )
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .arrive(1)
    }
  }
}

struct FanTray: View {
  @EnvironmentObject var model: Model
  var compact = false

  var body: some View {
    let fans = model.current?.fans ?? []
    Tray("팬", icon: "fan") {
      if let t = model.target { Text("목표 \(Int(t).formatted()) rpm").monospacedDigit() }
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(model.rpm.map { Int($0).formatted() } ?? "–")
              .font(.system(size: 24, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(Palette.ink)
              .contentTransition(.numericText())
            Text("rpm").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Chip(text: "\(Int((model.fanFrac * 100).rounded()))%", tone: .accent)
          }
          LineBar(frac: model.fanFrac)
        }
        .padding(14)
        .arrive(0)
        if compact {
          Hairline()
          HStack {
            ForEach(Array(fans.enumerated()), id: \.offset) { i, f in
              Text("팬 \(i + 1)  \(f.actual.map { Int($0).formatted() } ?? "–")")
            }
            Spacer()
            Text("\(Int(model.fanMin).formatted())–\(Int(model.fanMax).formatted()) rpm")
          }
          .font(.system(size: 11.5))
          .foregroundStyle(Palette.muted)
          .monospacedDigit()
          .padding(.horizontal, 14)
          .frame(height: 34)
        } else {
          ForEach(Array(fans.enumerated()), id: \.offset) { i, f in
            Hairline()
            Row(label: "팬 \(i + 1)") {
              Text("\(f.actual.map { Int($0).formatted() } ?? "–") rpm")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).monospacedDigit()
            }
            .arrive(i + 1)
          }
          Hairline()
          Row(label: "범위") {
            Text("\(Int(model.fanMin).formatted())–\(Int(model.fanMax).formatted()) rpm")
              .font(.system(size: 13)).foregroundStyle(Palette.muted).monospacedDigit()
          }
          .arrive(fans.count + 1)
        }
      }
    }
  }
}

struct CurveChart: View {
  @EnvironmentObject var model: Model
  var height: CGFloat = 118

  var body: some View {
    let mn = model.fanMin, mx = model.fanMax
    let pts = [(30.0, mn), (model.low, mn), (model.high, mx), (100.0, mx)]
    Chart {
      ForEach(pts.indices, id: \.self) { i in
        AreaMark(x: .value("온도", pts[i].0), y: .value("rpm", pts[i].1))
          .foregroundStyle(
            LinearGradient(
              colors: [Palette.accent.opacity(0.14), Palette.accent.opacity(0.0)], startPoint: .top,
              endPoint: .bottom))
        LineMark(x: .value("온도", pts[i].0), y: .value("rpm", pts[i].1))
          .foregroundStyle(Palette.accent)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      }
      if let t = model.hotter {
        let x = min(max(t, 30), 100)
        RuleMark(x: .value("온도", x))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
          .foregroundStyle(Palette.muted.opacity(0.5))
        PointMark(x: .value("온도", x), y: .value("rpm", model.curveRPM(x)))
          .symbol {
            Circle().fill(Palette.card).overlay(Circle().stroke(Palette.accent, lineWidth: 2.5)).frame(width: 11, height: 11)
          }
          .annotation(position: .top, spacing: 5) {
            Text("지금 \(Int(t.rounded()))°")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Palette.ink)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(Palette.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border))
              .shadow(color: Palette.shadow, radius: 2, y: 1)
          }
      }
    }
    .chartXScale(domain: 30...100)
    .chartYScale(domain: 0...(mx * 1.2))
    .chartXAxis {
      AxisMarks(values: [30.0, 50.0, 70.0, 90.0]) { v in
        AxisGridLine().foregroundStyle(Palette.line)
        AxisValueLabel {
          if let d = v.as(Double.self) { Text("\(Int(d))°").font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: [mn, mx]) { v in
        AxisGridLine().foregroundStyle(Palette.line)
        AxisValueLabel {
          if let d = v.as(Double.self) {
            Text(Int(d).formatted()).font(.system(size: 10)).foregroundStyle(Palette.muted)
          }
        }
      }
    }
    .frame(height: height)
    .animation(calm, value: model.low)
    .animation(calm, value: model.high)
  }
}

// affectUI's Segmented Control: a gray track with a white pill that slides.
struct Segmented: View {
  @Binding var selection: String
  @Namespace private var ns
  let options = [
    ("curve", "곡선", "chart.line.uptrend.xyaxis"), ("max", "항상 최대", "wind"), ("auto", "Apple 자동", "apple.logo"),
  ]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.0) { tag, title, icon in
        let on = selection == tag
        Button {
          withAnimation(calm) { selection = tag }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 12.5, weight: on ? .semibold : .medium))
          }
          .foregroundStyle(on ? Palette.ink : Palette.muted)
          .frame(maxWidth: .infinity)
          .frame(height: 26)
          .background {
            if on {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.pill)
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .matchedGeometryEffect(id: "pill", in: ns)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(Palette.tray, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct PresetStyle: ButtonStyle {
  let on: Bool

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    configuration.label
      .font(.system(size: 12, weight: on ? .semibold : .medium))
      .foregroundStyle(on ? Palette.accent : Palette.text)
      .frame(maxWidth: .infinity)
      .frame(height: 28)
      .background(on ? Palette.accentSoft : Palette.tray, in: shape)
      .overlay(shape.strokeBorder(on ? Palette.accent.opacity(0.3) : .clear))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(calm, value: configuration.isPressed)
      .contentShape(shape)
  }
}

struct TempSlider: View {
  @EnvironmentObject var model: Model
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let keepOrder: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
        Spacer()
        Text("\(Int(value))°C").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
          .monospacedDigit()
      }
      Slider(
        value: Binding(get: { value }, set: { value = $0.rounded() }), in: range,
        onEditingChanged: { editing in
          if !editing { model.save() }
        }
      )
      .controlSize(.small)
      .tint(Palette.accent)
      .onChange(of: value) { keepOrder() }
    }
  }
}

struct ControlsTray: View {
  @EnvironmentObject var model: Model
  var curveHeight: CGFloat = 118

  var body: some View {
    Tray("팬 조절", icon: "slider.horizontal.3") {
      switch model.mode {
      case "curve": Text("\(Int(model.low))° → \(Int(model.high))°").monospacedDigit()
      case "max": Text("항상 최대")
      default: Text("Apple 기본 제어")
      }
    } content: {
      VStack(alignment: .leading, spacing: 12) {
        Segmented(selection: $model.mode)
          .onChange(of: model.mode) { model.save() }
        switch model.mode {
        case "curve":
          CurveChart(height: curveHeight)
          HStack(spacing: 6) {
            ForEach(presets) { p in
              Button {
                withAnimation(calm) {
                  model.low = p.low
                  model.high = p.high
                }
                model.save()
              } label: {
                Label(p.id, systemImage: p.icon)
              }
              .buttonStyle(PresetStyle(on: model.low == p.low && model.high == p.high))
            }
          }
          TempSlider(title: "이 온도부터 빨라짐", value: $model.low, range: 30...85) {
            model.high = max(model.high, model.low + 5)
          }
          TempSlider(title: "이 온도에서 최대 속도", value: $model.high, range: 40...95) {
            model.low = min(model.low, model.high - 5)
          }
        case "max":
          Text("팬을 항상 최대 속도로 돌립니다.").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
        default:
          Text("Apple 기본 제어에 맡깁니다. 온도는 계속 보여 줍니다.").font(.system(size: 12.5))
            .foregroundStyle(Palette.muted)
        }
      }
      .padding(12)
      .arrive(2)
    }
  }
}

struct SafetyTray: View {
  @EnvironmentObject var model: Model

  var body: some View {
    Tray("안전장치", icon: "checkmark.shield") {
      if let s = model.current {
        Text("\(s.hottestKey) · \(String(format: "%.1f", s.hottest))°C").monospacedDigit()
      }
    } content: {
      VStack(spacing: 0) {
        Row(label: "센서 하나라도 \(Int(model.hot))°C 이상") { Chip(text: "팬 최대", tone: .bad) }.arrive(0)
        Hairline()
        Row(label: "온도를 못 읽거나 서비스가 멈추면") { Chip(text: "Apple 자동", tone: .neutral) }.arrive(1)
        Hairline()
        Row(label: "앱을 닫아도") { Chip(text: "제어 계속", tone: .good) }.arrive(2)
      }
    }
  }
}

struct NoFanTray: View {
  var body: some View {
    Tray("팬", icon: "fan") {
      Row(label: "이 Mac에는 팬이 없습니다") { Chip(text: "온도만 표시", tone: .neutral) }
    }
  }
}

struct Panel: View {
  @EnvironmentObject var model: Model
  // The same pieces are shown from the menu bar and, laid out wider, in the app window.
  var inWindow = false

  var body: some View {
    Group {
      if inWindow { windowLayout } else { menuLayout }
    }
    .animation(calm, value: model.status?.time)
  }

  var menuLayout: some View {
    VStack(alignment: .leading, spacing: 10) {
      Header()
      banners
      TempsTray()
      HistoryTray(height: 104)
      if model.hasFans {
        FanTray(compact: true)
        ControlsTray(curveHeight: 104)
      } else {
        NoFanTray()
      }
      footer
    }
    .padding(12)
    .frame(width: 372)
    .background(Palette.page)
  }

  var windowLayout: some View {
    VStack(alignment: .leading, spacing: 14) {
      Header()
      banners
      HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 14) {
          TempsTray()
          HistoryTray(height: 168)
          if model.hasFans { FanTray() }
        }
        .frame(width: 420)
        VStack(spacing: 14) {
          if model.hasFans {
            ControlsTray(curveHeight: 186)
            SafetyTray()
          } else {
            NoFanTray()
          }
        }
        .frame(width: 340)
      }
      footer
    }
    .padding(18)
    .padding(.top, 18)
    .frame(width: 810)
  }

  @ViewBuilder var banners: some View {
    if !model.live {
      Banner(
        icon: "exclamationmark", title: "팬 제어 서비스가 꺼져 있습니다", detail: installHint.text, tone: .bad,
        copy: installHint.command)
    } else if model.current?.conflict == true {
      Banner(
        icon: "exclamationmark", title: "다른 프로그램이 팬을 조절하고 있습니다",
        detail: "Macs Fan Control을 '자동'으로 두거나 종료하세요", tone: .warn)
    }
    if let e = model.saveError {
      Banner(icon: "xmark", title: e, detail: installHint.text, tone: .bad, copy: installHint.command)
    }
  }

  var footer: some View {
    HStack(spacing: 14) {
      Text(inWindow ? "창을 닫아도 메뉴 막대에 남고, 팬 제어는 계속됩니다" : "앱을 닫아도 팬 제어는 계속됩니다")
        .foregroundStyle(Palette.muted)
      Spacer()
      if !inWindow { OpenWindowButton() }
      Button("종료") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text)
        .help("메뉴 막대 아이콘까지 닫습니다. 팬 제어는 계속됩니다.")
    }
    .font(.system(size: 11.5))
    .padding(.horizontal, 6)
  }
}

struct OpenWindowButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      showMainWindow(openWindow)
    } label: {
      Label("창으로 열기", systemImage: "macwindow")
    }
    .buttonStyle(.plain)
    .foregroundStyle(Palette.text)
  }
}

// MARK: - App

let mainWindowID = "main"
let launchedInBackground = CommandLine.arguments.contains("--background")

@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
  openWindow(id: mainWindowID)
  NSApp.activate()
}

// Lets the app delegate open the SwiftUI window when the app is launched
// again from Finder, Spotlight or the Dock while it already runs.
@MainActor
enum WindowBridge {
  static var open: (() -> Void)?
  static var launched = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Do not bring back an open window at the next login.
    UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { MainActor.assumeIsolated { WindowBridge.open?() } }
    return true
  }
}

struct MenuLabel: View {
  let title: String
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "fan.fill")
      Text(title).monospacedDigit()
    }
    .onAppear {
      WindowBridge.open = { showMainWindow(openWindow) }
      if !launchedInBackground && !WindowBridge.launched {
        WindowBridge.launched = true
        showMainWindow(openWindow)
      }
    }
  }
}

struct FanCurveApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = Model(
    statePath: arg("--state") ?? "\(stateDir)/status.json",
    configPath: arg("--config") ?? "\(stateDir)/config")

  var body: some Scene {
    // The menu-bar item comes first, so launching the app opens no window by
    // itself; MenuLabel opens one unless the app was started at login.
    MenuBarExtra {
      Panel().environmentObject(model)
    } label: {
      MenuLabel(title: model.menuTitle)
    }
    .menuBarExtraStyle(.window)

    // While the window is open the app shows in the Dock; when it closes,
    // only the menu-bar icon stays.
    Window("FanCurve", id: mainWindowID) {
      Panel(inWindow: true)
        .environmentObject(model)
        .background(Palette.page.ignoresSafeArea())
        .onAppear {
          NSApp.setActivationPolicy(.regular)
          NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
  }
}

// MARK: - Command-line helpers

@MainActor
func writePNG(_ rep: NSBitmapImageRep, to path: String) {
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

// `FanCurve --make-icon out.png` draws the 1024 px app icon.
@MainActor
func makeIcon(to path: String) {
  let renderer = ImageRenderer(content: AppIcon())
  renderer.scale = 1
  guard let image = renderer.cgImage else { return }
  writePNG(NSBitmapImageRep(cgImage: image), to: path)
}

// Frame for README screenshots: rounded corners, a hairline edge and a soft
// shadow, plus the traffic lights for the app window.
struct ScreenshotFrame: View {
  let image: NSImage
  let dark: Bool
  let trafficLights: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: trafficLights ? 12 : 14, style: .continuous)
    Image(nsImage: image)
      .overlay(alignment: .topLeading) {
        if trafficLights {
          HStack(spacing: 8) {
            ForEach([0xff5f57, 0xfebc2e, 0x28c840], id: \.self) { c in
              Circle().fill(Color(hex: UInt32(c))).frame(width: 12, height: 12)
            }
          }
          .padding(14)
        }
      }
      .clipShape(shape)
      .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5))
      .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 26, y: 14)
      .padding(44)
  }
}

// `FanCurve --snapshot out.png [--dark] [--window] [--scale 2] [--framed]`
// renders the panel to a PNG without showing anything on screen. Used to check
// the layout and to make the README screenshots.
@MainActor
func snapshot(to path: String) {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  let model = Model(
    statePath: arg("--state") ?? "\(stateDir)/status.json",
    configPath: arg("--config") ?? "\(stateDir)/config")
  let dark = CommandLine.arguments.contains("--dark")
  let inWindow = CommandLine.arguments.contains("--window")
  let scale = CGFloat(Double(arg("--scale") ?? "1") ?? 1)
  let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  let host = NSHostingView(
    rootView: Panel(inWindow: inWindow).environmentObject(model).background(Palette.page))
  host.appearance = appearance
  let size = host.fittingSize
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
  window.appearance = appearance
  window.contentView = host
  RunLoop.main.run(until: Date().addingTimeInterval(1))
  host.layoutSubtreeIfNeeded()
  // A bitmap with more pixels than points renders at that scale.
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
  else { return }
  rep.size = size
  host.cacheDisplay(in: host.bounds, to: rep)
  guard CommandLine.arguments.contains("--framed") else {
    writePNG(rep, to: path)
    return
  }
  let image = NSImage(size: size)
  image.addRepresentation(rep)
  let renderer = ImageRenderer(
    content: ScreenshotFrame(image: image, dark: dark, trafficLights: inWindow).environment(\.colorScheme, dark ? .dark : .light))
  renderer.scale = scale
  guard let framed = renderer.cgImage else { return }
  writePNG(NSBitmapImageRep(cgImage: framed), to: path)
}

@main
enum Main {
  static func main() {
    if let out = arg("--snapshot") {
      MainActor.assumeIsolated { snapshot(to: out) }
    } else if let out = arg("--make-icon") {
      MainActor.assumeIsolated { makeIcon(to: out) }
    } else {
      FanCurveApp.main()
    }
  }
}
