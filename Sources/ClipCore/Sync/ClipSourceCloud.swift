import Foundation

/// The hosted ClipSource Cloud service. Every hosted URL lives here, so a deployment changes one file.
/// The Info.plist keys `ClipSourceSupabaseURL` / `ClipSourceSupabaseAnonKey` (set by Scripts/bundle-app.sh and
/// project.yml from env) override the placeholders; `$CLIPSOURCE_CLOUD_URL` / `$CLIPSOURCE_CLOUD_ANON_KEY` override
/// both, for local testing.
public enum ClipSourceCloud {
    public static let placeholderURL = "https://YOUR-PROJECT.supabase.co"
    public static let placeholderAnonKey = ""
    /// Website: landing, pricing, account page and the web viewer at /app.
    public static let siteURL = URL(string: "https://clipsource.app")!

    public static let freeDeviceLimit = 2
    public static let freeRetentionDays = 7
    public static let proPriceMonthly = "$3/month"
    public static let proPriceYearly = "$24/year"

    public static var url: String {
        env("CLIPSOURCE_CLOUD_URL") ?? SyncConfig.bundled?.url ?? placeholderURL
    }

    public static var anonKey: String {
        env("CLIPSOURCE_CLOUD_ANON_KEY") ?? SyncConfig.bundled?.anonKey ?? placeholderAnonKey
    }

    /// False until this build has a real project URL and anon key.
    public static var isConfigured: Bool {
        url != placeholderURL && !anonKey.isEmpty && URL(string: url)?.host != nil
    }

    public static var accountURL: URL { siteURL.appendingPathComponent("account") }
    public static var pricingURL: URL { URL(string: "#pricing", relativeTo: siteURL)!.absoluteURL }

    private static func env(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }
        return value
    }
}

/// Plan, limits and devices of the signed-in account (`account_status` and `register_device` RPCs).
public struct CloudAccount: Decodable, Equatable, Sendable {
    public var plan: String
    public var subscriptionStatus: String?
    public var currentPeriodEnd: Date?
    /// Macs allowed; nil = unlimited. The web viewer never counts.
    public var deviceLimit: Int?
    public var retentionDays: Int
    /// Macs registered; `register_device` returns it without the device list.
    public var devicesUsed: Int?
    public var devices: [CloudDevice]
    /// Web viewer sessions allowed; nil = unlimited or not reported.
    public var webDeviceLimit: Int?
    /// Synced history cap (clips rows); nil = unlimited or not reported.
    public var maxRows: Int?
    public var rowsUsed: Int?

    public init(plan: String, subscriptionStatus: String? = nil, currentPeriodEnd: Date? = nil, deviceLimit: Int?,
                retentionDays: Int, devicesUsed: Int? = nil, devices: [CloudDevice] = [], webDeviceLimit: Int? = nil,
                maxRows: Int? = nil, rowsUsed: Int? = nil) {
        self.plan = plan
        self.subscriptionStatus = subscriptionStatus
        self.currentPeriodEnd = currentPeriodEnd
        self.deviceLimit = deviceLimit
        self.retentionDays = retentionDays
        self.devicesUsed = devicesUsed
        self.devices = devices
        self.webDeviceLimit = webDeviceLimit
        self.maxRows = maxRows
        self.rowsUsed = rowsUsed
    }

    public var isPro: Bool { plan == "pro" }
    public var planName: String { plan.prefix(1).uppercased() + plan.dropFirst() }
    /// Registered Macs: the server count, else counted from the device list.
    public var macCount: Int { devicesUsed ?? devices.filter { $0.kind == "mac" }.count }

    enum CodingKeys: String, CodingKey {
        case plan, devices
        case subscriptionStatus = "subscription_status"
        case currentPeriodEnd = "current_period_end"
        case deviceLimit = "device_limit"
        case retentionDays = "retention_days"
        case devicesUsed = "devices_used"
        case webDeviceLimit = "web_device_limit"
        case maxRows = "max_rows"
        case rowsUsed = "rows_used"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(String.self, forKey: .plan)
        subscriptionStatus = try c.decodeIfPresent(String.self, forKey: .subscriptionStatus)
        currentPeriodEnd = try c.decodeIfPresent(String.self, forKey: .currentPeriodEnd).flatMap(SupabaseClient.parseTimestamp)
        deviceLimit = try c.decodeIfPresent(Int.self, forKey: .deviceLimit)
        retentionDays = try c.decode(Int.self, forKey: .retentionDays)
        devicesUsed = try c.decodeIfPresent(Int.self, forKey: .devicesUsed)
        devices = try c.decodeIfPresent([CloudDevice].self, forKey: .devices) ?? []
        webDeviceLimit = try c.decodeIfPresent(Int.self, forKey: .webDeviceLimit)
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows)
        rowsUsed = try c.decodeIfPresent(Int.self, forKey: .rowsUsed)
    }
}

/// A device registered to the account. Its name is account metadata, stored in plaintext.
public struct CloudDevice: Decodable, Equatable, Identifiable, Sendable {
    public var deviceId: String
    public var name: String
    /// "mac" or "web".
    public var kind: String
    public var lastSeenAt: Date?
    /// True for the device whose session made the request.
    public var current: Bool

    public init(deviceId: String, name: String, kind: String, lastSeenAt: Date? = nil, current: Bool = false) {
        self.deviceId = deviceId
        self.name = name
        self.kind = kind
        self.lastSeenAt = lastSeenAt
        self.current = current
    }

    public var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case name, kind, current
        case deviceId = "device_id"
        case lastSeenAt = "last_seen_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt).flatMap(SupabaseClient.parseTimestamp)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
    }
}
