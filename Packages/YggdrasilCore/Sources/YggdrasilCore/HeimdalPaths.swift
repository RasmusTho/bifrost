import Foundation

/// Relative paths (from the vault root) of the `_heimdal/**` control-state
/// notes, per `app/heimdal/*` in the hub repo. Kept in one place so path
/// drift between the Python backend and this client is a one-line diff.
public enum HeimdalPaths {
    public static let root = "_heimdal"
    public static let watchlist = "_heimdal/watchlist.md"
    public static let never = "_heimdal/never.md"
    public static let interests = "_heimdal/interests.md"
    public static let consent = "_heimdal/consent.md"
    public static let settings = "_heimdal/settings.md"
    public static let entityReview = "_heimdal/entities/review.md"
    public static let steeringLog = "_heimdal/steering.log.md"
    public static let sourcesDirectory = "_heimdal/sources"
    public static let attentionDirectory = "_heimdal/attention"
    public static let devicesDirectory = "_heimdal/devices"
    public static let capturesDirectory = "_heimdal/captures"

    public static func source(id: String) -> String {
        "\(sourcesDirectory)/\(id).md"
    }

    public static func attention(date: String) -> String {
        "\(attentionDirectory)/\(date).md"
    }

    public static func device(id: String) -> String {
        "\(devicesDirectory)/\(id).md"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        // "Today" is a local-day concept for a human-facing daily log — a
        // UTC-pinned formatter would file the note under the wrong day for
        // any user west of UTC in the evening (or east of it after midnight
        // UTC), so this intentionally uses the device's current time zone.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func attention(for date: Date) -> String {
        attention(date: dateFormatter.string(from: date))
    }
}
