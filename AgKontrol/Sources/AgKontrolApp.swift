import SwiftUI
import Network
import Foundation
import Combine
import UIKit
import Darwin

// Native, offline-first user interface. Network requests only run after a button tap.
@main
struct AgKontrolApp: App {
    var body: some Scene {
        WindowGroup {
            NetworkDashboard()
                .preferredColorScheme(.dark)
        }
    }
}

private enum Theme {
    static let background = Color(red: 0.043, green: 0.071, blue: 0.122)
    static let surface = Color(red: 0.079, green: 0.122, blue: 0.190)
    static let border = Color(red: 0.155, green: 0.215, blue: 0.300)
    static let cyan = Color(red: 0.32, green: 0.86, blue: 0.88)
    static let green = Color(red: 0.35, green: 0.86, blue: 0.62)
    static let orange = Color(red: 1.0, green: 0.69, blue: 0.36)
    static let muted = Color(red: 0.63, green: 0.72, blue: 0.83)
}

struct DNSOutcome {
    let addresses: [String]
    let failure: String?
}

// Resolves public domains with the device's own DNS settings. No external DNS API.
private enum DomainResolver {
    static func lookup(_ domain: String) -> DNSOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var pointer: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(domain, nil, &hints, &pointer)
        guard code == 0, let head = pointer else {
            return DNSOutcome(addresses: [], failure: String(cString: gai_strerror(code)))
        }
        defer { freeaddrinfo(head) }

        var found: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }
            if current.pointee.ai_family != AF_INET && current.pointee.ai_family != AF_INET6 {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(current.pointee.ai_addrlen),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let item = String(cString: host)
                if !found.contains(item) { found.append(item) }
            }
            if found.count >= 5 { break }
        }
        return DNSOutcome(addresses: found, failure: found.isEmpty ? "DNS adresi bulunamadi." : nil)
    }
}

private enum DeviceAddress {
    static func localIPv4() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let head = interfaces else { return "-" }
        defer { freeifaddrs(head) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback ?? "-"
    }
}

private struct IPResponse: Decodable {
    let ip: String
}

final class NetworkDiagnosticsModel: ObservableObject {
    @Published var pathDescription = "Kontrol ediliyor"
    @Published var routeReady = false
    @Published var cellularOrMetered = false
    @Published var lowDataMode = false
    @Published var localIP = "-"
    @Published var publicIP = "-"
    @Published var httpsTime = "-"
    @Published var dnsIPs = "-"
    @Published var dnsDuration = "-"
    @Published var downloadSpeed = "-"
    @Published var lastMessage = "Kontrol icin bir butona dokunun."
    @Published var running = false
    @Published var lastChecked = "Henuz test yapilmadi"

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "agkontrol.pathmonitor")
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 35
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        localIP = DeviceAddress.localIPv4()

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.routeReady = (path.status == .satisfied)
                if !self.routeReady {
                    self.pathDescription = "Baglanti yok"
                } else if path.usesInterfaceType(.wifi) {
                    self.pathDescription = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    self.pathDescription = "Hucresel veri"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.pathDescription = "Ethernet"
                } else {
                    self.pathDescription = "Diger baglanti"
                }
                self.cellularOrMetered = path.isExpensive
                self.lowDataMode = path.isConstrained
                self.localIP = DeviceAddress.localIPv4()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        session.invalidateAndCancel()
    }

    func refreshLocalIP() {
        localIP = DeviceAddress.localIPv4()
    }

    func runStandardChecks(domain: String) {
        guard !running else { return }
        running = true
        refreshLocalIP()
        lastMessage = "Genel IP ve HTTPS kontrol ediliyor..."

        Task { @MainActor in
            await retrievePublicIP()
            await measureHTTPS()
            await resolveDomain(domain)
            lastChecked = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            lastMessage = "Temel kontroller tamamlandi."
            running = false
        }
    }

    func runDNS(domain: String) {
        guard !running else { return }
        running = true
        lastMessage = "DNS cozumlemesi yapiliyor..."
        Task { @MainActor in
            await resolveDomain(domain)
            lastMessage = "DNS kontrolu tamamlandi."
            running = false
        }
    }

    func runDownload() {
        guard !running else { return }
        running = true
        lastMessage = "Yaklasik 2 MB veri indiriliyor..."
        downloadSpeed = "Olculuyor..."

        Task { @MainActor in
            await measureDownload()
            lastChecked = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            lastMessage = "Indirme testi bitti."
            running = false
        }
    }

    @MainActor private func retrievePublicIP() async {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                publicIP = "Sunucu yanit vermedi"
                return
            }
            publicIP = try JSONDecoder().decode(IPResponse.self, from: data).ip
        } catch {
            publicIP = "Erisilemedi"
        }
    }

    @MainActor private func measureHTTPS() async {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else { return }
        var results: [Double] = []
        for _ in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let start = Date()
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else { continue }
                results.append(Date().timeIntervalSince(start) * 1000)
            } catch { continue }
        }
        if results.isEmpty {
            httpsTime = "Olculemedi"
        } else {
            let average = results.reduce(0, +) / Double(results.count)
            httpsTime = "\(Int(average.rounded())) ms"
        }
    }

    @MainActor private func resolveDomain(_ raw: String) async {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expression = "^[a-z0-9][a-z0-9.-]{0,252}$"
        guard domain.range(of: expression, options: .regularExpression) != nil,
              domain.contains("."), !domain.contains("..") else {
            dnsIPs = "Gecerli bir alan adi yazin"
            dnsDuration = "-"
            return
        }

        let start = Date()
        let result: DNSOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: DomainResolver.lookup(domain))
            }
        }
        dnsDuration = "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
        dnsIPs = result.addresses.isEmpty ? (result.failure ?? "Cozumlenemedi") : result.addresses.joined(separator: "  /  ")
    }

    @MainActor private func measureDownload() async {
        let urlString = "https://speed.cloudflare.com/__down?bytes=2000000&v=\(UUID().uuidString)"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode), data.count >= 500_000 else {
                downloadSpeed = "Olculemedi"
                return
            }
            let seconds = max(Date().timeIntervalSince(start), 0.001)
            let mbps = (Double(data.count) * 8) / seconds / 1_000_000
            downloadSpeed = String(format: "%.1f Mbps", mbps)
        } catch {
            downloadSpeed = "Erisilemedi"
        }
    }

    func summary(domain: String) -> String {
        [
            "Ag Kontrol - Tanilama Raporu",
            "Tarih: \(lastChecked)",
            "Ag yolu: \(pathDescription)",
            "Ag yolu hazir: \(routeReady ? "Evet" : "Hayir")",
            "Yerel IP: \(localIP)",
            "Genel IP: \(publicIP)",
            "HTTPS yanit suresi: \(httpsTime) (ICMP ping degil)",
            "DNS: \(domain)",
            "DNS adresleri: \(dnsIPs)",
            "DNS cozumleme suresi: \(dnsDuration)",
            "Ornek indirme hizi: \(downloadSpeed) (tek baglanti, ~2 MB)",
            "Dusuk veri modu: \(lowDataMode ? "Acik" : "Kapali")",
            "Olcumler tanisal ve yaklasiktir."
        ].joined(separator: "\n")
    }
}

struct NetworkDashboard: View {
    @StateObject private var model = NetworkDiagnosticsModel()
    @State private var domain = "example.com"
    @State private var copied = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    connectionPanel
                    overviewTiles
                    testsPanel
                    dnsPanel
                    explanationPanel
                    Text("AG KONTROL  |  iPad + iPhone  |  v1.0")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .tracking(1.1)
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(Theme.cyan.opacity(0.15))
                    .frame(width: 62, height: 62)
                Image(systemName: "network")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Theme.cyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("A\u{011F} Kontrol")
                    .font(.system(size: 31, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("Ba\u{011F}lant\u{0131} & internet tan\u{0131}lama")
                    .font(.subheadline)
                    .foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AKTIF AG YOLU")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.7)
                        .foregroundColor(Theme.muted)
                    Text(model.pathDescription)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.routeReady ? Theme.green : Theme.orange)
                        .frame(width: 8, height: 8)
                    Text(model.routeReady ? "Yol haz\u{0131}r" : "Yol yok")
                        .font(.caption).bold()
                        .foregroundColor(model.routeReady ? Theme.green : Theme.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background((model.routeReady ? Theme.green : Theme.orange).opacity(0.1))
                .clipShape(Capsule())
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 15) {
                Label(model.cellularOrMetered ? "Maliyetli a\u{011F}" : "Normal a\u{011F}", systemImage: "antenna.radiowaves.left.and.right")
                Spacer(minLength: 4)
                Label(model.lowDataMode ? "Az veri a\u{00E7}\u{0131}k" : "Az veri kapal\u{0131}", systemImage: "leaf")
            }
            .font(.caption)
            .foregroundColor(Theme.muted)
        }
        .panelStyle()
    }

    private var overviewTiles: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            MetricTile(title: "YEREL IP", value: model.localIP, symbol: "wifi", accent: Theme.cyan)
            MetricTile(title: "GENEL IP", value: model.publicIP, symbol: "globe", accent: Theme.green)
            MetricTile(title: "HTTPS GECIKME", value: model.httpsTime, symbol: "timer", accent: Theme.orange)
            MetricTile(title: "INDIRME (ORNEK)", value: model.downloadSpeed, symbol: "arrow.down.circle", accent: Theme.cyan)
        }
    }

    private var testsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Test merkezi", symbol: "waveform.path.ecg")
            Text("Genel IP, HTTPS yan\u{0131}t s\u{00FC}resi ve DNS kontrol\u{00FC}.")
                .font(.footnote)
                .foregroundColor(Theme.muted)
            Button {
                model.runStandardChecks(domain: domain)
            } label: {
                HStack {
                    if model.running {
                        ProgressView().tint(Theme.background)
                    } else {
                        Image(systemName: "bolt.horizontal.circle.fill")
                    }
                    Text(model.running ? "Test yap\u{0131}l\u{0131}yor..." : "Ba\u{011F}lant\u{0131}y\u{0131} test et")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.background)
                .padding(16)
                .background(Theme.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .disabled(model.running)

            Button {
                model.runDownload()
            } label: {
                HStack {
                    Image(systemName: "speedometer")
                    Text("Yakla\u{015F}\u{0131}k indirme h\u{0131}z\u{0131}n\u{0131} \u{00F6}l\u{00E7} (2 MB)")
                    Spacer()
                    Image(systemName: "arrow.down")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(16)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .disabled(model.running)

            Text(model.lastMessage)
                .font(.caption)
                .foregroundColor(Theme.muted)
            Text("Son kontrol: \(model.lastChecked)")
                .font(.caption2)
                .foregroundColor(Theme.muted)

            Button {
                UIPasteboard.general.string = model.summary(domain: domain)
                copied = true
            } label: {
                Label(copied ? "Rapor kopyaland\u{0131}" : "Tan\u{0131} raporunu kopyala", systemImage: "doc.on.doc")
                    .font(.footnote).bold()
                    .foregroundColor(Theme.cyan)
            }
            .buttonStyle(.plain)
        }
        .panelStyle()
    }

    private var dnsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("DNS \u{00E7}\u{00F6}z\u{00FC}mleme", symbol: "server.rack")
            HStack(spacing: 10) {
                TextField("Alan ad\u{0131} (example.com)", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("DNS alan ad\u{0131}")
                Button {
                    model.runDNS(domain: domain)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Theme.background)
                        .padding(12)
                        .background(Theme.green)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(model.running)
                .accessibilityLabel("DNS kontrol et")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("\u{00C7}\u{00F6}z\u{00FC}mlenen adresler")
                    .font(.caption)
                    .foregroundColor(Theme.muted)
                Text(model.dnsIPs)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("DNS s\u{00FC}resi: \(model.dnsDuration) (\u{00F6}nbellekten gelebilir)")
                    .font(.caption2)
                    .foregroundColor(Theme.muted)
            }
        }
        .panelStyle()
    }

    private var explanationPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("\u{00D6}l\u{00E7}\u{00FC}mler hakk\u{0131}nda", symbol: "info.circle")
            Text("A\u{011F} yolu haz\u{0131}r, tek ba\u{015F}\u{0131}na internete eri\u{015F}imi garanti etmez. HTTPS gecikmesi ger\u{00E7}ek ICMP ping de\u{011F}ildir. 2 MB'l\u{0131}k tek ak\u{0131}\u{015F} indirme testi yakla\u{015F}\u{0131}k bir h\u{0131}z verir; mobil veri kullanabilir.")
                .font(.footnote)
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Genel IP sorgusu: api.ipify.org  |  HTTPS/indirme: Cloudflare. Bu servisler IP adresinizi g\u{00F6}rebilir. \u{00D6}l\u{00E7}\u{00FC}mler sadece siz ba\u{015F}latt\u{0131}\u{011F}\u{0131}n\u{0131}zda yap\u{0131}l\u{0131}r.")
                .font(.caption2)
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }

    private func sectionTitle(_ label: String, symbol: String) -> some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(.white)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(accent)
                Spacer()
            }
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundColor(Theme.muted)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55)
                .lineLimit(2)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 19))
    }
}

private extension View {
    func panelStyle() -> some View { modifier(PanelStyle()) }
}
