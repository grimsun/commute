import Foundation

/// An RFC 4180 CSV file with a header row, as used by GTFS.
struct CSVTable {
    let columns: [String: Int]
    let rows: [[String]]

    init(data: Data) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = String(decoding: data, as: UTF8.self).unicodeScalars.makeIterator()
        var pending = iterator.next()

        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\n":
                row.append(field)
                field = ""
                if row != [""] {
                    rows.append(row)
                }
                row = []
            case "\r", "\u{FEFF}":
                continue
            default:
                field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        let header = rows.first ?? []
        columns = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) }, uniquingKeysWith: { first, _ in first })
        self.rows = Array(rows.dropFirst())
    }

    func has(_ column: String) -> Bool {
        columns[column] != nil
    }

    /// The trimmed value, or "" when the column or cell is missing.
    func value(_ row: [String], _ column: String) -> String {
        guard let index = columns[column], index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespaces)
    }
}
