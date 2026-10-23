//
//  ResultsExporter.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// The Excel Open XML workbook type, falling back to the file extension if the
    /// system has no declaration for it.
    nonisolated static var xlsx: UTType {
        UTType("org.openxmlformats.spreadsheetml.sheet")
            ?? UTType(filenameExtension: "xlsx")
            ?? .data
    }
}

/// Helpers for describing finishing positions.
nonisolated enum Placing {
    /// "1st", "2nd", "3rd", "4th" and so on.
    static func ordinal(_ place: Int) -> String {
        let suffix: String
        switch place % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch place % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(place)\(suffix)"
    }

    /// A medal for the top three places, nil otherwise.
    static func medal(_ place: Int) -> String? {
        switch place {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }
}

/// A finished Excel workbook ready to be handed to the file exporter.
nonisolated struct ResultsWorkbook: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .xlsx) { workbook in
            workbook.data
        }
    }
}

/// Builds an .xlsx workbook from the shoot results without any third-party libraries.
/// An .xlsx file is a zip archive of a handful of XML parts, so this writes those
/// parts by hand and packs them with a minimal "stored" (uncompressed) zip writer.
nonisolated enum ResultsExporter {

    static func makeWorkbook(
        title: String,
        shooters: [Shooter],
        placings: [Shooter.ID: Int],
        numberOfStands: Int,
        targetsPerStand: Int
    ) -> Data {
        var rows: [[Cell]] = []

        rows.append([.text(title)])
        rows.append([])

        // Header row.
        var header: [Cell] = [.text("Shooter")]
        for stand in 1...numberOfStands {
            for target in 1...targetsPerStand {
                header.append(.text("S\(stand) T\(target)"))
            }
            header.append(.text("Stand \(stand) Total"))
        }
        header.append(.text("Grand Total"))
        header.append(.text("Place"))
        rows.append(header)

        // One row per shooter.
        for shooter in shooters {
            var row: [Cell] = [.text(shooter.name.capitalized)]
            for stand in 0..<numberOfStands {
                for target in 0..<targetsPerStand {
                    let score = shooter.scores.indices.contains(stand) && shooter.scores[stand].indices.contains(target)
                        ? shooter.scores[stand][target]
                        : -1
                    row.append(score >= 0 ? .number(score) : .empty)
                }
                row.append(.number(shooter.standTotal(stand)))
            }
            row.append(.number(shooter.grandTotal))
            if let place = placings[shooter.id] {
                row.append(.text(Placing.ordinal(place)))
            } else {
                row.append(.empty)
            }
            rows.append(row)
        }

        let sheet = sheetXML(rows: rows)

        let entries: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(rootRelsXML.utf8)),
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelsXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        ]

        return ZipArchive.stored(entries: entries)
    }

    // MARK: - Cells

    enum Cell {
        case text(String)
        case number(Int)
        case empty
    }

    private static func sheetXML(rows: [[Cell]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>

        """
        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 1
            xml += "<row r=\"\(rowNumber)\">"
            for (columnIndex, cell) in row.enumerated() {
                let ref = "\(columnName(columnIndex))\(rowNumber)"
                switch cell {
                case .text(let value):
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escape(value))</t></is></c>"
                case .number(let value):
                    xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                case .empty:
                    break
                }
            }
            xml += "</row>\n"
        }
        xml += "</sheetData>\n</worksheet>"
        return xml
    }

    /// Converts a zero-based column index into Excel's lettering (A, B, …, Z, AA, AB, …).
    private static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(Character(UnicodeScalar(UInt8(65 + remainder)))) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Fixed package parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="Results" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """
}

/// A minimal zip writer that stores entries uncompressed. This is all an .xlsx
/// package needs, and it avoids depending on any compression library.
nonisolated enum ZipArchive {

    static func stored(entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        // Fixed DOS timestamp of 1980-01-01 00:00; the real date is not important here.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            // Local file header.
            archive.append(contentsOf: le32(0x0403_4B50))
            archive.append(contentsOf: le16(20))        // version needed to extract
            archive.append(contentsOf: le16(0x0800))    // flags: UTF-8 file names
            archive.append(contentsOf: le16(0))         // compression: stored
            archive.append(contentsOf: le16(dosTime))
            archive.append(contentsOf: le16(dosDate))
            archive.append(contentsOf: le32(crc))
            archive.append(contentsOf: le32(size))      // compressed size
            archive.append(contentsOf: le32(size))      // uncompressed size
            archive.append(contentsOf: le16(UInt16(nameBytes.count)))
            archive.append(contentsOf: le16(0))         // extra field length
            archive.append(contentsOf: nameBytes)
            archive.append(entry.data)

            // Matching central directory record.
            centralDirectory.append(contentsOf: le32(0x0201_4B50))
            centralDirectory.append(contentsOf: le16(20))   // version made by
            centralDirectory.append(contentsOf: le16(20))   // version needed
            centralDirectory.append(contentsOf: le16(0x0800))
            centralDirectory.append(contentsOf: le16(0))
            centralDirectory.append(contentsOf: le16(dosTime))
            centralDirectory.append(contentsOf: le16(dosDate))
            centralDirectory.append(contentsOf: le32(crc))
            centralDirectory.append(contentsOf: le32(size))
            centralDirectory.append(contentsOf: le32(size))
            centralDirectory.append(contentsOf: le16(UInt16(nameBytes.count)))
            centralDirectory.append(contentsOf: le16(0))    // extra length
            centralDirectory.append(contentsOf: le16(0))    // comment length
            centralDirectory.append(contentsOf: le16(0))    // disk number start
            centralDirectory.append(contentsOf: le16(0))    // internal attributes
            centralDirectory.append(contentsOf: le32(0))    // external attributes
            centralDirectory.append(contentsOf: le32(offset))
            centralDirectory.append(contentsOf: nameBytes)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        // End of central directory record.
        archive.append(contentsOf: le32(0x0605_4B50))
        archive.append(contentsOf: le16(0))                                 // this disk
        archive.append(contentsOf: le16(0))                                 // disk with central directory
        archive.append(contentsOf: le16(UInt16(entries.count)))
        archive.append(contentsOf: le16(UInt16(entries.count)))
        archive.append(contentsOf: le32(UInt32(centralDirectory.count)))
        archive.append(contentsOf: le32(centralDirectoryOffset))
        archive.append(contentsOf: le16(0))                                 // comment length

        return archive
    }

    // MARK: - Helpers

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24)
        ]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
