// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The authors and licenses of the Stack Exchange posts a pack holds: `attribution-se.tsv`.
///
/// A case names its post as `post:<Id>#<n>` and its site in `meta.source`. The table has one row for every post
/// the cases name, read from `Posts.xml` of the dump of the site. Nothing is guessed: a post with no author, no
/// date or no license in the dump stops the pack.
struct StackExchangeAttribution {
    struct Post: Equatable {
        var id: String
        /// `question`, `answer`, or `type<N>` for the other kinds of the dump (the excerpts and wikis of tags).
        var type: String
        var site: String
        var url: String
        /// The display name the dump gives, or `user:<OwnerUserId>`, or both as `Name (user:<id>)`.
        var author: String
        /// The license the dump gives the post (`ContentLicense`), or, when it gives none, the one of the date rule.
        var license: String
        /// The license by the date rule, for the check against the dump; nil when the dump has no date.
        var licenseByDate: String?
    }

    static let header = "post_id\ttype\tsite\turl\tauthor\tlicense"

    /// Stack Exchange's own rule: posts before 2011-04-08 are CC BY-SA 2.5, before 2018-05-02 CC BY-SA 3.0, later
    /// ones CC BY-SA 4.0. `creation` is the `CreationDate` of the dump (`2012-01-02T03:04:05.000`).
    static func licenseByDate(_ creation: String) -> String? {
        let day = Array(creation.utf8.prefix(10))
        guard day.count == 10, day[4] == UInt8(ascii: "-"), day[7] == UInt8(ascii: "-"),
              day.enumerated().allSatisfy({ [4, 7].contains($0.offset) || ("0"..."9").contains(Character(UnicodeScalar($0.element))) })
        else { return nil }
        let text = String(decoding: day, as: UTF8.self)
        return text < "2011-04-08" ? "CC BY-SA 2.5" : text < "2018-05-02" ? "CC BY-SA 3.0" : "CC BY-SA 4.0"
    }

    /// The attribute as text: references unescaped, a tab or a line break a space (so that it cannot break a table).
    private static func value(_ name: String, in row: [UInt8]) -> String? {
        guard let raw = StackExchangeReader.attribute(name, in: row) else { return nil }
        let text = String(SourceText.unescapeXML(String(decoding: raw, as: UTF8.self)).map { $0.isNewline || $0 == "\t" ? " " : $0 })
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func post(fromRow row: [UInt8], site: String) throws -> Post {
        guard let id = value("Id", in: row) else { throw EvalError.input("pack: a row of \(site) has no Id") }
        let name = value("OwnerDisplayName", in: row)
        let user = value("OwnerUserId", in: row).map { "user:\($0)" }
        let author: String
        switch (name, user) {
        case let (name?, user?): author = "\(name) (\(user))"
        case let (name?, nil): author = name
        case let (nil, user?): author = user
        case (nil, nil):
            throw EvalError.input("pack: post \(id) of \(site) has no author in the dump (neither OwnerUserId nor OwnerDisplayName)")
        }
        let byDate = value("CreationDate", in: row).flatMap(licenseByDate)
        guard let license = value("ContentLicense", in: row) ?? byDate else {
            throw EvalError.input("pack: post \(id) of \(site) has no license and no date in the dump")
        }
        let kind = value("PostTypeId", in: row)
        let type = kind == "1" ? "question" : kind == "2" ? "answer" : "type\(kind ?? "?")"
        let letter = type == "answer" ? "a" : "q"
        return Post(id: id, type: type, site: site, url: "https://\(site)/\(letter)/\(id)", author: author,
                    license: license, licenseByDate: byDate)
    }

    /// The posts of `ids` (by site) read from the dumps `stackexchange/<site>.7z` of the cache.
    static func posts(ids: [String: Set<String>], cache: String) throws -> [Post] {
        var posts: [Post] = []
        for site in ids.keys.sorted() {
            guard let wanted = ids[site], !wanted.isEmpty else { continue }
            let path = (cache as NSString).appendingPathComponent("stackexchange/\(site).7z")
            var found: [String: Post] = [:]
            try LineStream.read(tool: "/usr/bin/tar", arguments: ["-xOf", path, "Posts.xml"]) { row in
                guard let id = StackExchangeReader.attribute("Id", in: row).map({ String(decoding: $0, as: UTF8.self) }),
                      wanted.contains(id)
                else { return true }
                found[id] = try post(fromRow: row, site: site)
                return found.count < wanted.count
            }
            if let missing = wanted.subtracting(found.keys).sorted(by: numeric).first {
                throw EvalError.input("pack: post \(missing) of \(site) is not in \(path)")
            }
            posts += found.values
        }
        return posts.sorted { $0.site != $1.site ? $0.site < $1.site : numeric($0.id, $1.id) }
    }

    private static func numeric(_ a: String, _ b: String) -> Bool {
        if let x = Int(a), let y = Int(b), x != y { return x < y }
        return a < b
    }

    static func table(_ posts: [Post]) -> String {
        header + "\n" + posts.map { [$0.id, $0.type, $0.site, $0.url, $0.author, $0.license].joined(separator: "\t") + "\n" }.joined()
    }

    /// The `(site, post id)` each case of the lines of a `.jsonl` names in `meta`.
    static func refs(inCases bytes: Data) -> [(site: String, id: String)] {
        bytes.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let meta = object["meta"] as? [String: Any], let ref = meta["ref"] as? String,
                  let site = meta["source"] as? String, ref.hasPrefix("post:")
            else { return nil }
            return (site, String(ref.dropFirst("post:".count).prefix { $0 != "#" }))
        }
    }
}
