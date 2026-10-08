import Foundation

/// A minimal, format-preserving INI editor tailored to the AWS CLI's
/// `credentials` and `config` files.
///
/// Comments, blank lines, ordering and nested (indented) settings are kept
/// intact; only the sections and keys that are explicitly changed are touched.
public struct INIDocument: Equatable {
    public struct Section: Equatable {
        public var name: String
        var header: String
        var lines: [String]
    }

    private var preamble: [String]
    public private(set) var sections: [Section]

    public init(text: String = "") {
        var preamble: [String] = []
        var sections: [Section] = []

        var lines = text.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            if let name = Self.sectionName(of: line) {
                sections.append(Section(name: name, header: line, lines: []))
            } else if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        self.preamble = preamble
        self.sections = sections
    }

    public var sectionNames: [String] { sections.map(\.name) }

    public func hasSection(_ name: String) -> Bool { index(of: name) != nil }

    /// Top-level `key = value` pairs of a section, in file order.
    public func pairs(in section: String) -> [(key: String, value: String)] {
        guard let i = index(of: section) else { return [] }
        return sections[i].lines.compactMap(Self.keyValue)
    }

    public func value(_ key: String, in section: String) -> String? {
        pairs(in: section).first { $0.key == key }?.value
    }

    /// The raw body of a section without trailing blank lines.
    public func body(of section: String) -> [String] {
        guard let i = index(of: section) else { return [] }
        return Self.trimmingTrailingBlanks(sections[i].lines)
    }

    /// Sets a single key, updating it in place or appending it to the section.
    public mutating func setValue(_ value: String, for key: String, in section: String) {
        let line = "\(key) = \(value)"
        guard let i = index(of: section) else {
            appendSection(section, body: [line])
            return
        }
        if let j = sections[i].lines.firstIndex(where: { Self.keyValue($0)?.key == key }) {
            sections[i].lines[j] = line
        } else {
            let insertAt = Self.trimmingTrailingBlanks(sections[i].lines).count
            sections[i].lines.insert(line, at: insertAt)
        }
    }

    /// Replaces the whole body of a section, creating it if needed.
    /// An empty body removes the section.
    public mutating func setBody(_ body: [String], of section: String) {
        let body = Self.trimmingTrailingBlanks(body)
        guard !body.isEmpty else {
            removeSection(section)
            return
        }
        guard let i = index(of: section) else {
            appendSection(section, body: body)
            return
        }
        let trailing = sections[i].lines.count - Self.trimmingTrailingBlanks(sections[i].lines).count
        sections[i].lines = body + Array(repeating: "", count: trailing)
    }

    public mutating func removeSection(_ name: String) {
        sections.removeAll { $0.name == name }
    }

    public func render() -> String {
        var lines = preamble
        for section in sections {
            lines.append(section.header)
            lines.append(contentsOf: section.lines)
        }
        lines = Self.trimmingTrailingBlanks(lines)
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private func index(of name: String) -> Int? {
        sections.firstIndex { $0.name == name }
    }

    private mutating func appendSection(_ name: String, body: [String]) {
        if let last = sections.indices.last {
            if sections[last].lines.last.map({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true {
                sections[last].lines.append("")
            }
        } else if let last = preamble.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            preamble.append("")
        }
        sections.append(Section(name: name, header: "[\(name)]", lines: body))
    }

    static func sectionName(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        // Collapse inner whitespace so "[profile   foo]" == "profile foo".
        return inner.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != ";",
              let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    static func trimmingTrailingBlanks(_ lines: [String]) -> [String] {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
