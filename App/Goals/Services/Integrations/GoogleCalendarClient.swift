import Foundation
import GoalsCore

/// One of the user's Google calendars, for the "busy calendars" picker.
struct GoogleCalendarInfo: Identifiable, Hashable, Sendable {
    let id: String
    let summary: String
    let isPrimary: Bool
}

enum GoogleCalendarError: LocalizedError {
    case unauthorized
    case rateLimited
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Google Calendar access expired — reconnect in Settings."
        case .rateLimited: return "Google Calendar is rate-limiting requests — try again later."
        case .http(let code): return "Google Calendar request failed (\(code))."
        case .decoding: return "Unexpected response from Google Calendar."
        }
    }
}

/// Thin REST client for the Google Calendar v3 API. Transport DTOs stay
/// private here; outward it speaks `BusyEvent` / `DesiredCalendarEvent` and
/// plain values. Auth is injected as a token provider so the GoogleSignIn SDK
/// never leaks into this file.
@MainActor
struct GoogleCalendarClient {
    let session: URLSession
    let tokenProvider: () async throws -> String

    private static let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    init(session: URLSession = .shared, tokenProvider: @escaping () async throws -> String) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: Calendars

    func calendarList() async throws -> [GoogleCalendarInfo] {
        var items: [CalendarListEntry] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "250"),
                         URLQueryItem(name: "minAccessRole", value: "reader")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: CalendarListPage = try await get("users/me/calendarList", query: query)
            items.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return items.map {
            GoogleCalendarInfo(id: $0.id, summary: $0.summaryOverride ?? $0.summary ?? $0.id,
                               isPrimary: $0.primary ?? false)
        }
    }

    func createCalendar(summary: String) async throws -> String {
        struct NewCalendar: Encodable { let summary: String }
        struct Created: Decodable { let id: String }
        let created: Created = try await send("POST", "calendars", body: NewCalendar(summary: summary))
        return created.id
    }

    // MARK: Events — import

    /// All concrete events in `[timeMin, timeMax)`, recurring ones expanded.
    /// Cancelled events, free ("transparent") blocks and self-declined invites
    /// are not busy time.
    func events(calendarID: String, timeMin: Date, timeMax: Date) async throws -> [BusyEvent] {
        var items: [GEvent] = []
        var pageToken: String?
        let fmt = Self.rfc3339
        repeat {
            var query = [URLQueryItem(name: "singleEvents", value: "true"),
                         URLQueryItem(name: "maxResults", value: "2500"),
                         URLQueryItem(name: "timeMin", value: fmt.string(from: timeMin)),
                         URLQueryItem(name: "timeMax", value: fmt.string(from: timeMax))]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let path = "calendars/\(escape(calendarID))/events"
            let page: EventsPage = try await get(path, query: query)
            items.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil

        return items.compactMap { event in
            guard event.status != "cancelled",
                  event.transparency != "transparent",
                  event.selfResponseStatus != "declined" else { return nil }
            guard let start = event.start?.parsedDate, let end = event.end?.parsedDate,
                  let id = event.id else { return nil }
            return BusyEvent(externalID: id,
                             calendarID: calendarID,
                             title: event.summary,
                             start: start,
                             end: end,
                             isAllDay: event.start?.date != nil)
        }
    }

    // MARK: Events — export

    func insertEvent(calendarID: String, _ desired: DesiredCalendarEvent, calendar: Calendar) async throws -> String {
        struct Created: Decodable { let id: String }
        let created: Created = try await send(
            "POST", "calendars/\(escape(calendarID))/events",
            body: eventBody(for: desired, calendar: calendar))
        return created.id
    }

    func patchEvent(calendarID: String, eventID: String,
                    _ desired: DesiredCalendarEvent, calendar: Calendar) async throws {
        struct Patched: Decodable { let id: String? }
        let _: Patched = try await send(
            "PATCH", "calendars/\(escape(calendarID))/events/\(escape(eventID))",
            body: eventBody(for: desired, calendar: calendar))
    }

    func deleteEvent(calendarID: String, eventID: String) async throws {
        let url = Self.base.appendingPathComponent("calendars/\(escape(calendarID))/events/\(escape(eventID))")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await authedData(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Already gone is success for a delete.
        guard (200...299).contains(code) || code == 404 || code == 410 else {
            throw error(for: code)
        }
    }

    private func eventBody(for desired: DesiredCalendarEvent, calendar: Calendar) -> GEventBody {
        let tz = calendar.timeZone.identifier
        let fmt = Self.rfc3339Local(calendar.timeZone)
        let start = desired.day.date(atMinute: desired.window.start, calendar: calendar)
        let end = desired.day.date(atMinute: desired.window.end, calendar: calendar)
        return GEventBody(
            summary: desired.title,
            description: desired.notes,
            start: .init(dateTime: fmt.string(from: start), timeZone: tz),
            end: .init(dateTime: fmt.string(from: end), timeZone: tz))
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: Self.base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let request = URLRequest(url: components.url!)
        let (data, response) = try await authedData(for: request)
        return try decode(data, response: response)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B) async throws -> T {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await authedData(for: request)
        return try decode(data, response: response)
    }

    /// Attach a fresh token; on a 401, refresh once and retry.
    private func authedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        var authed = request
        authed.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: authed)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            authed.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
            return try await session.data(for: authed)
        }
        return (data, response)
    }

    private func decode<T: Decodable>(_ data: Data, response: URLResponse) throws -> T {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw error(for: code) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw GoogleCalendarError.decoding
        }
        return value
    }

    private func error(for code: Int) -> GoogleCalendarError {
        switch code {
        case 401: return .unauthorized
        case 403, 429: return .rateLimited
        default: return .http(code)
        }
    }

    private func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func rfc3339Local(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f
    }
}

// MARK: - Private DTOs

private struct CalendarListPage: Decodable {
    let items: [CalendarListEntry]?
    let nextPageToken: String?
}

private struct CalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let primary: Bool?
}

private struct EventsPage: Decodable {
    let items: [GEvent]?
    let nextPageToken: String?
}

private struct GEvent: Decodable {
    struct Time: Decodable {
        let dateTime: String?
        let date: String?   // all-day events use date-only

        var parsedDate: Date? {
            if let dateTime {
                return GEvent.parseRFC3339(dateTime)
            }
            if let date {
                // Date-only (all-day): midnight UTC is fine — these are only
                // used when the user opts all-day events into busy time.
                return GEvent.parseRFC3339(date + "T00:00:00Z")
            }
            return nil
        }
    }
    struct Attendee: Decodable {
        let selfAttendee: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey {
            case selfAttendee = "self"
            case responseStatus
        }
    }

    let id: String?
    let status: String?
    let summary: String?
    let transparency: String?
    let start: Time?
    let end: Time?
    let attendees: [Attendee]?

    var selfResponseStatus: String? {
        attendees?.first { $0.selfAttendee == true }?.responseStatus
    }

    static func parseRFC3339(_ raw: String) -> Date? {
        if let d = withFractional.date(from: raw) { return d }
        return plain.date(from: raw)
    }

    // ISO8601DateFormatter is documented thread-safe, hence nonisolated(unsafe).
    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private struct GEventBody: Encodable {
    struct Time: Encodable {
        let dateTime: String
        let timeZone: String
    }
    let summary: String
    let description: String?
    let start: Time
    let end: Time
}
