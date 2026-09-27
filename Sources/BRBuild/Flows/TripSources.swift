import BRCore
import Foundation

/// The two Citi Bike trip-data series in the public `tripdata` bucket: New York (monthly
/// `YYYYMM-citibike-tripdata.zip`) and Jersey City + Hoboken (`JC-YYYYMM-citibike-tripdata[.csv].zip`).
/// A cross-Hudson trip appears in exactly one of them, so a month needs both.
public enum TripSystem: String, CaseIterable, Sendable, Codable, Comparable {
    case nyc = "NYC"
    case jc = "JC"

    public static func < (lhs: TripSystem, rhs: TripSystem) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A calendar month, `YYYYMM`.
public struct TripMonth: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...9999).contains(year) && (1...12).contains(month), "bad month \(year)-\(month)")
        self.year = year
        self.month = month
    }

    public init?(yyyymm: some StringProtocol) {
        guard yyyymm.count == 6, yyyymm.allSatisfy(\.isASCII), let value = Int(yyyymm), value >= 0 else { return nil }
        let year = value / 100, month = value % 100
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    public var yyyymm: String { String(format: "%04d%02d", year, month) }
    public var description: String { yyyymm }
    public var firstDay: ServiceDate { ServiceDate(year: year, month: month, day: 1) }
    public var lastDay: ServiceDate { adding(1).firstDay.adding(days: -1) }

    public func adding(_ months: Int) -> TripMonth {
        let index = year * 12 + (month - 1) + months
        return TripMonth(year: index / 12, month: index % 12 + 1)
    }

    public static func < (lhs: TripMonth, rhs: TripMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }

    /// A `--months` value: `YYYYMM-YYYYMM` (inclusive) or `YYYYMM,YYYYMM,…`, 1 to 12 consecutive
    /// months; `nil` for anything else.
    public static func parseList(_ text: String) -> [TripMonth]? {
        var months: [TripMonth]
        if text.contains("-") {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let first = TripMonth(yyyymm: parts[0]), let last = TripMonth(yyyymm: parts[1]), first <= last,
                  first.adding(11) >= last else { return nil }
            months = [first]
            while let current = months.last, current < last { months.append(current.adding(1)) }
        } else {
            var parsed: [TripMonth] = []
            for part in text.split(separator: ",", omittingEmptySubsequences: false) {
                guard let month = TripMonth(yyyymm: part.trimmingCharacters(in: .whitespaces)) else { return nil }
                parsed.append(month)
            }
            months = parsed
        }
        guard !months.isEmpty, months.count <= 12, zip(months, months.dropFirst()).allSatisfy({ $0.adding(1) == $1 }) else { return nil }
        return months
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let month = TripMonth(yyyymm: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected YYYYMM, got \(text)")
        }
        self = month
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(yyyymm)
    }
}

/// One object in the bucket listing.
public struct TripListingObject: Sendable, Equatable, Codable {
    public var key: String
    /// The ETag without its quotes, e.g. `d5f2a3ec3831ad8ef2de3da12102e550-60`.
    public var etag: String
    public var size: Int
    public var lastModified: String
}

/// A monthly trip-data file named in the listing.
public struct TripSourceFile: Sendable, Equatable, Codable {
    public var system: TripSystem
    public var month: TripMonth
    public var object: TripListingObject

    /// `https://s3.amazonaws.com/tripdata/<key>`, the key percent-encoded (one old JC key has a space).
    public var url: String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return TripSources.bucketURL + "/" + (object.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? object.key)
    }

    /// What `dataVersion` pins for this input: system, month, ETag and size.
    public var pin: String { "\(system.rawValue)\(month.yyyymm):\(object.etag):\(object.size)" }
}

/// Discovering the Citi Bike trip-data files: S3 ListObjectsV2 of the public `tripdata` bucket
/// (paged by continuation token), file-name recognition, and the choice of months.
public enum TripSources {
    public static let bucketURL = "https://s3.amazonaws.com/tripdata"

    public enum ListingError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case duplicateMonth(system: TripSystem, month: TripMonth, keys: [String])

        public var description: String {
            switch self {
            case .malformed(let why): "tripdata listing: \(why)"
            case .duplicateMonth(let system, let month, let keys): "tripdata lists \(system.rawValue) \(month) twice: \(keys.joined(separator: ", "))"
            }
        }
    }

    /// One page of a ListObjectsV2 response.
    public struct ListingPage: Sendable, Equatable {
        public var objects: [TripListingObject]
        /// `NextContinuationToken` when `IsTruncated` is true; `nil` on the last page.
        public var nextContinuationToken: String?
    }

    /// Parses a ListObjectsV2 XML page. Tolerant of element order and of child elements it does
    /// not use (`ChecksumAlgorithm`, `ChecksumType`, `Owner`, `StorageClass`, …), which a
    /// pattern over the whole `<Contents>` element would silently drop.
    public static func parseListing(_ xml: Data) throws -> ListingPage {
        let text = String(decoding: xml, as: UTF8.self)
        guard text.contains("<ListBucketResult") else { throw ListingError.malformed("not a ListBucketResult") }
        var objects: [TripListingObject] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<Contents>", range: cursor..<text.endIndex) {
            guard let close = text.range(of: "</Contents>", range: open.upperBound..<text.endIndex) else {
                throw ListingError.malformed("unterminated <Contents>")
            }
            let body = text[open.upperBound..<close.lowerBound]
            guard let key = element("Key", in: body) else { throw ListingError.malformed("<Contents> without <Key>") }
            guard let size = element("Size", in: body).flatMap({ Int($0) }), size >= 0 else {
                throw ListingError.malformed("\(key): no <Size>")
            }
            var etag = element("ETag", in: body) ?? ""
            if etag.hasPrefix("\""), etag.hasSuffix("\""), etag.count >= 2 { etag = String(etag.dropFirst().dropLast()) }
            objects.append(TripListingObject(key: key, etag: etag, size: size, lastModified: element("LastModified", in: body) ?? ""))
            cursor = close.upperBound
        }
        let truncated = element("IsTruncated", in: text[...]) == "true"
        let token = truncated ? element("NextContinuationToken", in: text[...]) : nil
        if truncated, token == nil { throw ListingError.malformed("IsTruncated without NextContinuationToken") }
        return ListingPage(objects: objects, nextContinuationToken: token)
    }

    /// The first `<name>…</name>` inside `body`, entity-decoded. Contents children are leaves, so
    /// the first match is the object's own.
    static func element(_ name: String, in body: Substring) -> String? {
        guard let open = body.range(of: "<\(name)>"), let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else {
            return nil
        }
        return decodeEntities(body[open.upperBound..<close.lowerBound])
    }

    static func decodeEntities(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].firstIndex(of: ";"), text.distance(from: index, to: semicolon) <= 10 {
                let entity = text[text.index(after: index)..<semicolon]
                var decoded: String?
                switch entity {
                case "quot": decoded = "\""
                case "amp": decoded = "&"
                case "lt": decoded = "<"
                case "gt": decoded = ">"
                case "apos": decoded = "'"
                default:
                    if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                        decoded = String(Character(scalar))
                    } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                        decoded = String(Character(scalar))
                    }
                }
                if let decoded {
                    result += decoded
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// The system and month a bucket key names, or `nil` for anything else (yearly archives such
    /// as `2013-citibike-tripdata.zip`, `index.html`). Accepts the irregular JC names seen in the
    /// bucket: `.zip` or `.csv.zip`, `JC-201708 citibike-…` (a space) and `JC-202207-citbike-…`.
    public static func recognize(_ key: String) -> (system: TripSystem, month: TripMonth)? {
        var name = Substring(key)
        guard name.hasSuffix(".zip") else { return nil }
        name = name.dropLast(4)
        if name.hasSuffix(".csv") { name = name.dropLast(4) }
        var system = TripSystem.nyc
        if name.hasPrefix("JC-") {
            system = .jc
            name = name.dropFirst(3)
        }
        guard name.count > 7, let month = TripMonth(yyyymm: name.prefix(6)) else { return nil }
        let separator = name[name.index(name.startIndex, offsetBy: 6)]
        guard separator == "-" || separator == " " else { return nil }
        let rest = name.dropFirst(7)
        guard rest == "citibike-tripdata" || rest == "citbike-tripdata" else { return nil }
        return (system, month)
    }

    /// Every monthly file in the listing, by system and month. Throws when one month of one
    /// system is listed under two keys (which one to use is a question for a human).
    public static func monthlyFiles(_ objects: [TripListingObject]) throws -> [TripSystem: [TripMonth: TripSourceFile]] {
        var files: [TripSystem: [TripMonth: TripSourceFile]] = [:]
        for object in objects {
            guard let (system, month) = recognize(object.key) else { continue }
            if let existing = files[system]?[month] {
                throw ListingError.duplicateMonth(system: system, month: month, keys: [existing.object.key, object.key].sorted())
            }
            files[system, default: [:]][month] = TripSourceFile(system: system, month: month, object: object)
        }
        return files
    }

    /// The months a build uses.
    public enum Choice: Equatable, Sendable {
        /// `months` (ascending) are published for every system.
        case window([TripMonth])
        /// The newest month published for every system is the one the current flows already ends
        /// with, and its inputs are unchanged: nothing new to build (fail soft, keep the file).
        case nothingNew(newest: TripMonth)
        /// Some system lacks a month the window needs (a hole in the middle of the series).
        case missing([String])
        /// Some system has no monthly file at all.
        case noCommonMonth
    }

    /// The newest `count` consecutive months published for every system: the window ends at the
    /// newest month present for both NYC and JC (a month only one has published yet is not used).
    /// `previousEnd` and `previousPins` describe the flows file in place (its last month, and the
    /// ``TripSourceFile/pin``s of its window); without them the window is always built.
    public static func choose(
        _ files: [TripSystem: [TripMonth: TripSourceFile]], count: Int = 3, previousEnd: TripMonth? = nil,
        previousPins: [String]? = nil
    ) -> Choice {
        var common: Set<TripMonth>?
        for system in TripSystem.allCases {
            let months = files[system].map { Set($0.keys) } ?? []
            common = common.map { $0.intersection(months) } ?? months
        }
        guard let newest = common?.max() else { return .noCommonMonth }
        let months = (0..<count).map { newest.adding($0 - (count - 1)) }
        let missing = TripSystem.allCases.flatMap { system in
            months.filter { files[system]?[$0] == nil }.map { "\(system.rawValue) \($0)" }
        }
        guard missing.isEmpty else { return .missing(missing) }
        if let previousEnd {
            // Never step back to an older window; rebuild the same one only when an input was
            // re-published (its ETag or size changed).
            if newest < previousEnd { return .nothingNew(newest: newest) }
            if newest == previousEnd, previousPins == nil || previousPins == pins(of: months, in: files) {
                return .nothingNew(newest: newest)
            }
        }
        return .window(months)
    }

    /// Every file of `months`, systems in name order within each month.
    public static func files(of months: [TripMonth], in files: [TripSystem: [TripMonth: TripSourceFile]]) -> [TripSourceFile] {
        months.flatMap { month in TripSystem.allCases.sorted().compactMap { files[$0]?[month] } }
    }

    static func pins(of months: [TripMonth], in files: [TripSystem: [TripMonth: TripSourceFile]]) -> [String] {
        self.files(of: months, in: files).map(\.pin)
    }
}
