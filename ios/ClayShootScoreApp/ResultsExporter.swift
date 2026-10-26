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
    /// system has no declaration for it. Numbers, Excel and Google Sheets all open it.
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

/// A finished workbook ready to be handed to the file exporter.
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
///
/// The workbook is written so that it opens cleanly in Apple Numbers as well as
/// Excel: all text goes through a shared-strings table (Numbers ignores inline
/// strings), every cell carries an explicit style, and totals are real SUM
/// formulas with their values cached so nothing needs recalculating on open.
nonisolated enum ResultsExporter {

    static func makeWorkbook(
        title: String,
        shooters: [Shooter],
        placings: [Shooter.ID: Int],
        numberOfStands: Int,
        targetsPerStand: Int
    ) -> Data {
        // Column layout (zero based): name, then for each stand its targets and a
        // stand total, then the grand total and the finishing place.
        let columnsPerStand = targetsPerStand + 1
        let columnCount = 1 + numberOfStands * columnsPerStand + 2
        let grandTotalColumn = columnCount - 2
        let placeColumn = columnCount - 1
        let lastColumn = columnName(columnCount - 1)
        let headerRows = 4
        let firstDataRow = headerRows + 1

        func firstTargetColumn(_ stand: Int) -> Int { 1 + stand * columnsPerStand }
        func standTotalColumn(_ stand: Int) -> Int { firstTargetColumn(stand) + targetsPerStand }

        var rows: [[Cell]] = []
        var merges: [String] = []

        // Row 1 and 2: title and a short legend, each spanning the whole table.
        rows.append([Cell(.text(title), style: .title)])
        merges.append("A1:\(lastColumn)1")
        rows.append([Cell(.text(legend(shooters: shooters.count, stands: numberOfStands, targets: targetsPerStand)), style: .subtitle)])
        merges.append("A2:\(lastColumn)2")

        // Rows 3 and 4: a dark band naming each stand, with the target numbers and
        // total labels beneath it. "Shooter", "Total" and "Place" span both rows.
        var groupRow = [Cell](repeating: Cell(.empty, style: .header), count: columnCount)
        var detailRow = [Cell](repeating: Cell(.empty, style: .headerDetail), count: columnCount)

        groupRow[0] = Cell(.text("Shooter"), style: .header)
        detailRow[0] = Cell(.empty, style: .header)
        merges.append("A3:A4")

        for stand in 0..<numberOfStands {
            let first = firstTargetColumn(stand)
            groupRow[first] = Cell(.text("Stand \(stand + 1)"), style: .header)
            merges.append("\(columnName(first))3:\(columnName(standTotalColumn(stand)))3")
            for target in 0..<targetsPerStand {
                detailRow[first + target] = Cell(.text("\(target + 1)"), style: .headerDetail)
            }
            detailRow[standTotalColumn(stand)] = Cell(.text("Total"), style: .headerDetail)
        }

        groupRow[grandTotalColumn] = Cell(.text("Total"), style: .headerAccent)
        detailRow[grandTotalColumn] = Cell(.empty, style: .headerAccent)
        merges.append("\(columnName(grandTotalColumn))3:\(columnName(grandTotalColumn))4")
        groupRow[placeColumn] = Cell(.text("Place"), style: .headerAccent)
        detailRow[placeColumn] = Cell(.empty, style: .headerAccent)
        merges.append("\(columnName(placeColumn))3:\(columnName(placeColumn))4")

        rows.append(groupRow)
        rows.append(detailRow)

        // One row per shooter. Alternate rows are lightly banded.
        for (index, shooter) in shooters.enumerated() {
            let rowNumber = firstDataRow + index
            let banded = index % 2 == 1
            var row: [Cell] = [Cell(.text(shooter.name.capitalized), style: banded ? .nameBanded : .name)]
            var standTotalRefs: [String] = []

            for stand in 0..<numberOfStands {
                for target in 0..<targetsPerStand {
                    let score = shooter.scores.indices.contains(stand) && shooter.scores[stand].indices.contains(target)
                        ? shooter.scores[stand][target]
                        : -1
                    switch score {
                    case let hit where hit > 0:
                        row.append(Cell(.number(hit), style: .hit))
                    case 0:
                        row.append(Cell(.number(0), style: .miss))
                    default:
                        row.append(Cell(.empty, style: .notShot))
                    }
                }

                let firstRef = "\(columnName(firstTargetColumn(stand)))\(rowNumber)"
                let lastRef = "\(columnName(standTotalColumn(stand) - 1))\(rowNumber)"
                row.append(Cell(
                    .formula("SUM(\(firstRef):\(lastRef))", cached: shooter.standTotal(stand)),
                    style: banded ? .standTotalBanded : .standTotal
                ))
                standTotalRefs.append("\(columnName(standTotalColumn(stand)))\(rowNumber)")
            }

            row.append(Cell(
                .formula("SUM(\(standTotalRefs.joined(separator: ",")))", cached: shooter.grandTotal),
                style: .grandTotal
            ))
            row.append(placeCell(place: placings[shooter.id], banded: banded))
            rows.append(row)
        }

        // Column widths, in character units.
        var columns: [ColumnWidth] = [ColumnWidth(first: 1, last: 1, width: 24)]
        for stand in 0..<numberOfStands {
            let first = firstTargetColumn(stand) + 1
            columns.append(ColumnWidth(first: first, last: first + targetsPerStand - 1, width: 4.6))
            columns.append(ColumnWidth(first: standTotalColumn(stand) + 1, last: standTotalColumn(stand) + 1, width: 7.5))
        }
        columns.append(ColumnWidth(first: grandTotalColumn + 1, last: grandTotalColumn + 1, width: 10))
        columns.append(ColumnWidth(first: placeColumn + 1, last: placeColumn + 1, width: 10))

        var sharedStrings = SharedStrings()
        let sheet = sheetXML(
            rows: rows,
            lastColumn: lastColumn,
            columns: columns,
            merges: merges,
            rowHeights: [1: 34, 2: 20, 3: 24, 4: 20],
            frozenRows: headerRows,
            frozenColumns: 1,
            sharedStrings: &sharedStrings
        )

        let entries: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(rootRelsXML.utf8)),
            ("docProps/core.xml", Data(corePropertiesXML(title: title).utf8)),
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelsXML.utf8)),
            ("xl/styles.xml", Data(stylesXML.utf8)),
            ("xl/sharedStrings.xml", Data(sharedStrings.xml().utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        ]

        return ZipArchive.stored(entries: entries)
    }

    /// The one-line legend under the title, e.g. "4 shooters · 5 stands of 10 targets · 1 = hit, 0 = miss, blank = not shot".
    private static func legend(shooters: Int, stands: Int, targets: Int) -> String {
        let shooterWord = shooters == 1 ? "shooter" : "shooters"
        let standWord = stands == 1 ? "stand" : "stands"
        return "\(shooters) \(shooterWord) · \(stands) \(standWord) of \(targets) targets · 1 = hit, 0 = miss, blank = not shot"
    }

    /// The finishing place, with the top three picked out in medal colours.
    private static func placeCell(place: Int?, banded: Bool) -> Cell {
        guard let place else {
            return Cell(.empty, style: banded ? .placeBanded : .place)
        }
        let style: Style
        switch place {
        case 1: style = .gold
        case 2: style = .silver
        case 3: style = .bronze
        default: style = banded ? .placeBanded : .place
        }
        return Cell(.text(Placing.ordinal(place)), style: style)
    }

    // MARK: - Cells

    /// Cell styles. The raw values index the `cellXfs` list in `stylesXML`, so the
    /// two must stay in the same order.
    enum Style: Int {
        case normal
        case title
        case subtitle
        case header
        case headerDetail
        case headerAccent
        case name
        case nameBanded
        case hit
        case miss
        case notShot
        case standTotal
        case standTotalBanded
        case grandTotal
        case place
        case placeBanded
        case gold
        case silver
        case bronze
    }

    enum Value {
        case text(String)
        case number(Int)
        /// A formula together with its current result, so apps that do not
        /// recalculate on open still show the right figure.
        case formula(String, cached: Int)
        case empty
    }

    struct Cell {
        var value: Value
        var style: Style

        init(_ value: Value, style: Style = .normal) {
            self.value = value
            self.style = style
        }
    }

    struct ColumnWidth {
        /// One-based first and last column of the range this width applies to.
        var first: Int
        var last: Int
        var width: Double
    }

    /// Collects every piece of text in the workbook into the shared-strings table
    /// that cells refer to by index.
    struct SharedStrings {
        private(set) var strings: [String] = []
        private var indices: [String: Int] = [:]
        private var references = 0

        mutating func index(of text: String) -> Int {
            references += 1
            if let existing = indices[text] {
                return existing
            }
            strings.append(text)
            indices[text] = strings.count - 1
            return strings.count - 1
        }

        func xml() -> String {
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(references)" uniqueCount="\(strings.count)">
            """
            for text in strings {
                xml += "<si><t xml:space=\"preserve\">\(escape(text))</t></si>"
            }
            xml += "</sst>"
            return xml
        }
    }

    // MARK: - Worksheet

    private static func sheetXML(
        rows: [[Cell]],
        lastColumn: String,
        columns: [ColumnWidth],
        merges: [String],
        rowHeights: [Int: Double],
        frozenRows: Int,
        frozenColumns: Int,
        sharedStrings: inout SharedStrings
    ) -> String {
        // The order of these elements is fixed by the file format.
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """
        xml += "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>"
        xml += "<dimension ref=\"A1:\(lastColumn)\(max(rows.count, 1))\"/>"

        // Keep the header rows and name column in view while scrolling. Grid
        // lines are hidden because every cell draws its own light border.
        let topLeft = "\(columnName(frozenColumns))\(frozenRows + 1)"
        xml += "<sheetViews><sheetView workbookViewId=\"0\" showGridLines=\"0\">"
        xml += "<pane xSplit=\"\(frozenColumns)\" ySplit=\"\(frozenRows)\" topLeftCell=\"\(topLeft)\" activePane=\"bottomRight\" state=\"frozen\"/>"
        xml += "<selection pane=\"bottomRight\" activeCell=\"\(topLeft)\" sqref=\"\(topLeft)\"/>"
        xml += "</sheetView></sheetViews>"

        xml += "<sheetFormatPr defaultRowHeight=\"20\" customHeight=\"1\"/>"

        xml += "<cols>"
        for column in columns {
            xml += "<col min=\"\(column.first)\" max=\"\(column.last)\" width=\"\(column.width)\" customWidth=\"1\"/>"
        }
        xml += "</cols>"

        xml += "<sheetData>\n"
        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 1
            if let height = rowHeights[rowNumber] {
                xml += "<row r=\"\(rowNumber)\" ht=\"\(height)\" customHeight=\"1\">"
            } else {
                xml += "<row r=\"\(rowNumber)\">"
            }
            for (columnIndex, cell) in row.enumerated() {
                xml += cellXML(cell, reference: "\(columnName(columnIndex))\(rowNumber)", sharedStrings: &sharedStrings)
            }
            xml += "</row>\n"
        }
        xml += "</sheetData>"

        if !merges.isEmpty {
            xml += "<mergeCells count=\"\(merges.count)\">"
            for merge in merges {
                xml += "<mergeCell ref=\"\(merge)\"/>"
            }
            xml += "</mergeCells>"
        }

        // Landscape and shrunk to one page wide when printed.
        xml += "<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        xml += "<pageSetup orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"0\"/>"
        xml += "</worksheet>"
        return xml
    }

    private static func cellXML(_ cell: Cell, reference: String, sharedStrings: inout SharedStrings) -> String {
        let style = cell.style == .normal ? "" : " s=\"\(cell.style.rawValue)\""
        switch cell.value {
        case .text(let value):
            let index = sharedStrings.index(of: value)
            return "<c r=\"\(reference)\"\(style) t=\"s\"><v>\(index)</v></c>"
        case .number(let value):
            return "<c r=\"\(reference)\"\(style)><v>\(value)</v></c>"
        case .formula(let formula, let cached):
            return "<c r=\"\(reference)\"\(style)><f>\(escape(formula))</f><v>\(cached)</v></c>"
        case .empty:
            // A styled empty cell still needs writing so its fill and border show.
            return cell.style == .normal ? "" : "<c r=\"\(reference)\"\(style)/>"
        }
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

    // MARK: - Styles

    /// Fonts, fills, borders and the cell formats built from them. The `cellXfs`
    /// entries are listed in the same order as the `Style` enum.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="8">
    <font><sz val="11"/><color rgb="FF1F2937"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="18"/><color rgb="FF111827"/><name val="Helvetica Neue"/></font>
    <font><sz val="10"/><color rgb="FF6B7280"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="11"/><color rgb="FF1F2937"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="10"/><color rgb="FF166534"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="10"/><color rgb="FF991B1B"/><name val="Helvetica Neue"/></font>
    <font><b/><sz val="12"/><color rgb="FF1F2937"/><name val="Helvetica Neue"/></font>
    </fonts>
    <fills count="13">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF1F2937"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF374151"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFDCFCE7"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFEE2E2"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F4F6"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF9FAFB"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFDE68A"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE5E7EB"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFDBA74"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFEEF2FF"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF4338CA"/><bgColor indexed="64"/></patternFill></fill>
    </fills>
    <borders count="3">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border><left style="thin"><color rgb="FFE5E7EB"/></left><right style="thin"><color rgb="FFE5E7EB"/></right><top style="thin"><color rgb="FFE5E7EB"/></top><bottom style="thin"><color rgb="FFE5E7EB"/></bottom><diagonal/></border>
    <border><left style="thin"><color rgb="FF4B5563"/></left><right style="thin"><color rgb="FF4B5563"/></right><top style="thin"><color rgb="FF4B5563"/></top><bottom style="thin"><color rgb="FF4B5563"/></bottom><diagonal/></border>
    </borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="19">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf>
    <xf numFmtId="0" fontId="3" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="3" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="3" fillId="12" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" indent="1"/></xf>
    <xf numFmtId="0" fontId="4" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" indent="1"/></xf>
    <xf numFmtId="0" fontId="5" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="6" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="7" fillId="11" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="8" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="9" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    <xf numFmtId="0" fontId="4" fillId="10" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
    </cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """

    // MARK: - Fixed package parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    </Relationships>
    """

    private static func corePropertiesXML(title: String) -> String {
        let created = Date.now.formatted(.iso8601)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(escape(title))</dc:title>
        <dc:creator>Clay Shoot Score</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(created)</dcterms:created>
        </cp:coreProperties>
        """
    }

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="16000"/></bookViews>
    <sheets><sheet name="Results" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
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
