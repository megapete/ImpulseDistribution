//
//  ProfileWorkbook.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2026-11-13.
//
//  The "Save as Excel…" button on the three profile windows (AxialStressProfileWindow, StressProfileWindow, RadialProfileWindow):
//  each window lays its profiles out as `ProfileWorkbook.Sheet`s - a block of header rows, a table of numbers and one or more
//  charts that redraw what the window shows - and this file turns them into a real .xlsx with libxlsxwriter.
//
//  THIS IS THE ONLY FILE THAT TOUCHES THE C API, the same arrangement as PchMagneticFlux's XlsxReportWriter. Everything it exposes is
//  a Swift value type, so no `lxw_workbook *` crosses into a window or into SelfTest. That matters under
//  `SWIFT_STRICT_CONCURRENCY = complete`: the C pointer types are not Sendable, and `Write` is deliberately synchronous and
//  non-isolated so that none of them is ever live across an `await`.
//
//  The library is a SwiftPM dependency on github.com/jmcnamara/libxlsxwriter, from 1.2.4. It writes with `fopen`, so under the app
//  sandbox the destination has to be a path the user chose through an NSSavePanel (`user-selected.read-write`), or the container -
//  which is where SelfTest writes its copy.
//
//  WHY THE CHART POINTS TO CELLS RATHER THAN CARRYING ITS OWN NUMBERS. An Excel chart series is a reference into a sheet, so the
//  table IS the chart's data: anyone who edits a number sees the curve move, and a reader can never be looking at a chart and a
//  table that disagree. The few series that are not columns of the table - the worst-point dot and the vertical coil-end rules - are
//  written into a small "chart data" block to the right of the chart for the same reason, rather than being drawn as shapes.
//
//  WHAT DOES NOT COME ACROSS. The window's annotation block is a box drawn inside the plot; Excel's text boxes inside a chart are
//  clumsy and do not move with the data, so the same rows go in the header block above the table instead, word for word. The y axis
//  is left to Excel to scale, except that it starts at zero for the same reason the window's does (StressProfileView: a profile read
//  against an allowable is a picture of how much room is left).
//

import AppKit
import UniformTypeIdentifiers
import libxlsxwriter

/// A window that can be saved as a workbook. SelfTest writes one of these next to every graph PNG it renders, so the export is
/// exercised headless by the same run that exercises the drawing.
@MainActor
protocol ProfileWorkbookSource {

    /// One sheet per profile the window can show, in the window's own picker order.
    func WorkbookSheets() -> [ProfileWorkbook.Sheet]

    /// The sheet that is on screen, which is the one the workbook opens on.
    var workbookActiveSheet:Int { get }

    /// What the save panel offers as a file name, without the extension.
    var workbookFileName:String { get }
}

enum ProfileWorkbook {

    // MARK: The model

    /// One worksheet: a title, some label/value rows, a table and the charts drawn from it.
    struct Sheet:Sendable {

        /// The tab name. Sanitized and made unique on writing - Excel forbids []:*?/\ and stops at 31 characters, and the profile
        /// names ("Coil 2 to coil 3 (hilo)") can collide once they are cut down.
        let name:String
        let title:String
        /// Rows under the title, as (label, value). The window's annotation block and its note go here.
        let info:[InfoRow]
        let columns:[Column]
        let charts:[Chart]
    }

    struct InfoRow:Sendable {

        let label:String
        let value:String
    }

    /// One column of the table. All columns of a sheet are expected to be the same length; a short one is padded with blanks.
    struct Column:Sendable {

        let heading:String
        /// Decimals to show, or nil for Excel's General format - which is what a column of volts wants when a coil grounded at both
        /// ends puts nanovolts in it (see RadialProfileWindow.Volts).
        let decimals:Int?
        let values:[Value]
    }

    enum Value:Sendable {

        case number(Double)
        case text(String)
        case empty

        /// nil and non-finite numbers both become blanks, which an Excel scatter chart shows as a GAP - the same thing the
        /// window does with a point that has no allowable.
        static func of(_ value:Double?) -> Value {

            guard let value, value.isFinite else { return .empty }

            return .number(value)
        }
    }

    /// An XY scatter chart with straight lines, which is what StressProfileView draws.
    struct Chart:Sendable {

        let title:String
        let xTitle:String
        let yTitle:String
        let xMinimum:Double?
        let xMaximum:Double?
        let xMajorUnit:Double?
        let series:[Series]
    }

    struct XY:Sendable {

        let x:Double
        let y:Double
    }

    struct Series:Sendable {

        enum Source:Sendable {

            /// Two columns of the sheet's table, by index.
            case columns(x:Int, y:Int)
            /// Points of its own, written into the chart-data block beside the chart.
            case points([XY])
        }

        enum Look:Sendable {

            /// A line through the points, no markers. Width in points.
            case line(color:UInt32, width:Double, dashed:Bool)
            /// Markers only: the worst point's dot.
            case dot(color:UInt32)
        }

        let name:String
        let source:Source
        let look:Look
        /// Whether the series gets a legend entry. The dot and the coil-end rules do not - the header rows say what they are.
        var inLegend:Bool = true
    }

    /// The colours StressProfileView uses, as Excel RGB. The system colours' light-appearance values: a workbook is printed on white.
    enum Colour {

        static let value:UInt32 = 0xFF3B30        // systemRed
        static let allowable:UInt32 = 0xFF9500    // systemOrange
        static let comparison:UInt32 = 0x007AFF   // systemBlue
        static let marker:UInt32 = 0x8E8E93       // systemGray
    }

    // MARK: Helpers the windows share

    /// The rows every sheet starts with, saying what the numbers are from.
    static func StandardInfo(designName:String?) -> [InfoRow] {

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var rows:[InfoRow] = []

        if let designName, !designName.isEmpty {

            rows.append(InfoRow(label: "Design file:", value: designName))
        }

        rows.append(InfoRow(label: "Saved:", value: formatter.string(from: Date())))
        rows.append(InfoRow(label: "Program:", value: "ImpulseDistribution \(version) (build \(build))"))

        return rows
    }

    /// The annotation block's rows, as header rows.
    static func Info(_ annotation:[(label:String, value:String)]) -> [InfoRow] {

        return annotation.map { InfoRow(label: $0.label.trimmingCharacters(in: .whitespaces), value: $0.value) }
    }

    /// An x range on the 100 mm grid StressProfileView uses for height, widened out to whole grid lines so Excel's ticks land on
    /// round numbers. Heights in metres in, millimetres out.
    static func HeightRange(_ heights:[Double]) -> (minimum:Double, maximum:Double)? {

        guard let low = heights.min(), let high = heights.max() else { return nil }

        let minimum = (low * 1000.0 / 100.0).rounded(.down) * 100.0
        let maximum = max((high * 1000.0 / 100.0).rounded(.up) * 100.0, minimum + 100.0)

        return (minimum, maximum)
    }

    /// A vertical rule at x from zero up to `top`, as a two-point series.
    static func VerticalRule(at x:Double, top:Double, name:String) -> Series {

        return Series(name: name,
                      source: .points([XY(x: x, y: 0.0), XY(x: x, y: top)]),
                      look: .line(color: Colour.marker, width: 1.0, dashed: false),
                      inLegend: false)
    }

    // MARK: Saving from a window

    /// Puts up a save panel on the window and writes the source's sheets where the user says.
    @MainActor
    static func Save(_ source:ProfileWorkbookSource, from window:NSWindow) {

        let sheets = source.WorkbookSheets()
        let active = source.workbookActiveSheet

        let savePanel = NSSavePanel()
        savePanel.title = "Save as Excel"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .spreadsheet]
        savePanel.nameFieldStringValue = SafeFileName(source.workbookFileName) + ".xlsx"
        savePanel.canCreateDirectories = true

        savePanel.beginSheetModal(for: window) { response in

            guard response == .OK, let url = savePanel.url else { return }

            do {

                // Synchronous on purpose: no lxw pointer crosses an await.
                try ProfileWorkbook.Write(sheets: sheets, activeSheet: active, to: url)
            }
            catch {

                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// A file name with the characters the Finder or the save panel would trip on taken out.
    static func SafeFileName(_ name:String) -> String {

        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-").trimmingCharacters(in: .whitespaces)

        return cleaned.isEmpty ? "Profile" : cleaned
    }

    // MARK: Writing

    struct WriteError:LocalizedError {

        let code:UInt32
        let path:String

        var errorDescription:String? {

            let reason = String(cString: lxw_strerror(lxw_error(rawValue: code)))
            return "The spreadsheet could not be written to \(path): \(reason)"
        }
    }

    /// Where things go on a sheet, in cells. The chart's size is set as a scale of Excel's default 480 x 288 pixels, chosen to come
    /// out close to the window's own 900 x 520.
    private enum Layout {

        static let chartXScale = 1.875
        static let chartYScale = 1.75
        /// Rows from one chart's top to the next: 504 pixels of chart over Excel's 20-pixel rows, and a little air.
        static let rowsPerChart:UInt32 = 27
        /// Columns the chart covers at Excel's default 64-pixel width, rounded up. The chart-data block starts past it.
        static let columnsPerChart:UInt16 = 15
    }

    /// Writes the sheets to an .xlsx file, replacing anything already there.
    ///
    /// - Parameters:
    ///   - sheets: one worksheet each, in order. An empty array still produces a valid workbook.
    ///   - activeSheet: the sheet the workbook opens on. Out of range is ignored.
    ///   - url: where to write. Must be a file URL.
    nonisolated static func Write(sheets:[Sheet], activeSheet:Int, to url:URL) throws {

        guard let workbook = workbook_new(url.path) else {

            throw WriteError(code: LXW_ERROR_CREATING_XLSX_FILE.rawValue, path: url.path)
        }

        let formats = FormatCache(workbook: workbook)
        var usedNames:Set<String> = []

        for (index, sheet) in sheets.enumerated() {

            let name = UniqueSheetName(sheet.name, used: &usedNames)

            guard let worksheet = workbook_add_worksheet(workbook, name) else {

                // The workbook still has to be closed, or the temporary files it has already made are left behind.
                _ = workbook_close(workbook)
                throw WriteError(code: LXW_ERROR_MEMORY_MALLOC_FAILED.rawValue, path: url.path)
            }

            Write(sheet: sheet, named: name, into: worksheet, workbook: workbook, formats: formats)

            if index == activeSheet {

                worksheet_activate(worksheet)
            }
        }

        let result = workbook_close(workbook)

        guard result == LXW_NO_ERROR else {

            throw WriteError(code: result.rawValue, path: url.path)
        }
    }

    private static func Write(sheet:Sheet, named name:String, into worksheet:UnsafeMutablePointer<lxw_worksheet>, workbook:UnsafeMutablePointer<lxw_workbook>, formats:FormatCache) {

        // ---- the title and the header rows ----

        worksheet_write_string(worksheet, 0, 0, sheet.title, formats.title)

        var row:UInt32 = 2

        for info in sheet.info {

            worksheet_write_string(worksheet, row, 0, info.label, formats.label)
            worksheet_write_string(worksheet, row, 1, info.value, nil)
            row += 1
        }

        // ---- the table ----

        let headerRow = row + 1
        let firstDataRow = headerRow + 1
        let rowCount = sheet.columns.map { $0.values.count }.max() ?? 0
        let lastDataRow = firstDataRow + UInt32(max(rowCount, 1)) - 1

        // Column A also carries the header rows' labels, so it is as wide as the longest of those; the value beside each one spills
        // to the right over the empty cells, which is why column B is not widened for them.
        let labelWidth = sheet.info.map { Double($0.label.count) }.max() ?? 0.0

        for (index, column) in sheet.columns.enumerated() {

            let col = UInt16(clamping: index)
            let width = max(12.0, Double(column.heading.count) * 0.55 + 2.0, index == 0 ? labelWidth + 1.0 : 0.0)

            worksheet_set_column(worksheet, col, col, width, nil)
            worksheet_write_string(worksheet, headerRow, col, column.heading, formats.header)

            for (offset, value) in column.values.enumerated() {

                let at = firstDataRow + UInt32(offset)

                switch value {

                case .number(let number):
                    worksheet_write_number(worksheet, at, col, number, formats.number(decimals: column.decimals))
                case .text(let text):
                    worksheet_write_string(worksheet, at, col, text, nil)
                case .empty:
                    break
                }
            }
        }

        if sheet.columns.isEmpty {

            worksheet_set_column(worksheet, 0, 0, max(12.0, labelWidth + 1.0), nil)
        }

        // The headings stay put while the table scrolls.
        worksheet_freeze_panes(worksheet, firstDataRow, 0)

        // ---- the charts, side by side with the table ----

        let chartColumn = UInt16(clamping: sheet.columns.count + 1)
        var helperColumn = chartColumn + Layout.columnsPerChart + 1

        for (chartIndex, spec) in sheet.charts.enumerated() {

            guard let chart = workbook_add_chart(workbook, UInt8(LXW_CHART_SCATTER_STRAIGHT.rawValue)) else {

                continue
            }

            chart_title_set_name(chart, spec.title)
            chart_axis_set_name(chart.pointee.x_axis, spec.xTitle)
            chart_axis_set_name(chart.pointee.y_axis, spec.yTitle)
            chart_axis_set_min(chart.pointee.y_axis, 0.0)

            if let minimum = spec.xMinimum { chart_axis_set_min(chart.pointee.x_axis, minimum) }
            if let maximum = spec.xMaximum { chart_axis_set_max(chart.pointee.x_axis, maximum) }
            if let unit = spec.xMajorUnit { chart_axis_set_major_unit(chart.pointee.x_axis, unit) }

            chart_legend_set_position(chart, UInt8(LXW_CHART_LEGEND_BOTTOM.rawValue))
            chart_show_blanks_as(chart, UInt8(LXW_CHART_BLANKS_AS_GAP.rawValue))

            var hiddenFromLegend:[Int16] = []

            for (seriesIndex, spec) in spec.series.enumerated() {

                guard let series = chart_add_series(chart, nil, nil) else {

                    continue
                }

                switch spec.source {

                case .columns(let x, let y):
                    chart_series_set_categories(series, name, firstDataRow, UInt16(clamping: x), lastDataRow, UInt16(clamping: x))
                    chart_series_set_values(series, name, firstDataRow, UInt16(clamping: y), lastDataRow, UInt16(clamping: y))

                case .points(let points):
                    // Two columns of the chart-data block: the series name over an x and a y heading, then the points.
                    worksheet_set_column(worksheet, helperColumn, helperColumn + 1, 11.0, nil)
                    worksheet_write_string(worksheet, headerRow - 1, helperColumn, spec.name, formats.label)
                    worksheet_write_string(worksheet, headerRow, helperColumn, "x", formats.header)
                    worksheet_write_string(worksheet, headerRow, helperColumn + 1, "y", formats.header)

                    for (offset, point) in points.enumerated() {

                        let at = firstDataRow + UInt32(offset)
                        worksheet_write_number(worksheet, at, helperColumn, point.x, nil)
                        worksheet_write_number(worksheet, at, helperColumn + 1, point.y, nil)
                    }

                    let last = firstDataRow + UInt32(max(points.count, 1)) - 1
                    chart_series_set_categories(series, name, firstDataRow, helperColumn, last, helperColumn)
                    chart_series_set_values(series, name, firstDataRow, helperColumn + 1, last, helperColumn + 1)

                    helperColumn += 3
                }

                chart_series_set_name(series, spec.name)

                switch spec.look {

                case .line(let colour, let width, let dashed):
                    var line = lxw_chart_line()
                    line.color = colour
                    line.width = Float(width)
                    line.dash_type = dashed ? UInt8(LXW_CHART_LINE_DASH_DASH.rawValue) : UInt8(LXW_CHART_LINE_DASH_SOLID.rawValue)
                    chart_series_set_line(series, &line)
                    chart_series_set_marker_type(series, UInt8(LXW_CHART_MARKER_NONE.rawValue))

                case .dot(let colour):
                    var noLine = lxw_chart_line()
                    noLine.none = 1
                    chart_series_set_line(series, &noLine)
                    chart_series_set_marker_type(series, UInt8(LXW_CHART_MARKER_CIRCLE.rawValue))
                    chart_series_set_marker_size(series, 7)
                    var fill = lxw_chart_fill()
                    fill.color = colour
                    chart_series_set_marker_fill(series, &fill)
                    var border = lxw_chart_line()
                    border.color = colour
                    chart_series_set_marker_line(series, &border)
                }

                if !spec.inLegend {

                    hiddenFromLegend.append(Int16(clamping: seriesIndex))
                }
            }

            if !hiddenFromLegend.isEmpty {

                // The list is terminated by -1, C-style.
                hiddenFromLegend.append(-1)
                _ = hiddenFromLegend.withUnsafeMutableBufferPointer { chart_legend_delete_series(chart, $0.baseAddress) }
            }

            var options = lxw_chart_options()
            options.x_scale = Layout.chartXScale
            options.y_scale = Layout.chartYScale

            worksheet_insert_chart_opt(worksheet, headerRow + UInt32(chartIndex) * Layout.rowsPerChart, chartColumn, chart, &options)
        }
    }

    /// Excel's restrictions on a worksheet name, and uniqueness - which Excel judges without regard to case.
    private static func UniqueSheetName(_ name:String, used:inout Set<String>) -> String {

        let forbidden:Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
        var cleaned = String(name.map { forbidden.contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)

        while cleaned.hasPrefix("'") { cleaned.removeFirst() }
        while cleaned.hasSuffix("'") { cleaned.removeLast() }

        if cleaned.isEmpty { cleaned = "Sheet" }

        var candidate = String(cleaned.prefix(31))
        var counter = 2

        while used.contains(candidate.lowercased()) {

            let suffix = " (\(counter))"
            candidate = String(cleaned.prefix(31 - suffix.count)) + suffix
            counter += 1
        }

        used.insert(candidate.lowercased())

        return candidate
    }

    /// Builds each format once. libxlsxwriter owns every format it hands out and frees them with the workbook, so they are not
    /// released here.
    private final class FormatCache {

        private let workbook:UnsafeMutablePointer<lxw_workbook>
        private var numbers:[Int:UnsafeMutablePointer<lxw_format>] = [:]

        let title:UnsafeMutablePointer<lxw_format>?
        let label:UnsafeMutablePointer<lxw_format>?
        let header:UnsafeMutablePointer<lxw_format>?

        init(workbook:UnsafeMutablePointer<lxw_workbook>) {

            self.workbook = workbook

            title = workbook_add_format(workbook)
            format_set_bold(title)
            format_set_font_size(title, 14.0)

            label = workbook_add_format(workbook)
            format_set_bold(label)

            header = workbook_add_format(workbook)
            format_set_bold(header)
            format_set_text_wrap(header)
            format_set_bottom(header, UInt8(LXW_BORDER_THIN.rawValue))
            format_set_align(header, UInt8(LXW_ALIGN_CENTER.rawValue))
            format_set_align(header, UInt8(LXW_ALIGN_VERTICAL_BOTTOM.rawValue))
        }

        /// nil for General, which is what libxlsxwriter writes when no format is given.
        func number(decimals:Int?) -> UnsafeMutablePointer<lxw_format>? {

            guard let decimals else { return nil }

            if let existing = numbers[decimals] { return existing }

            guard let format = workbook_add_format(workbook) else { return nil }

            format_set_num_format(format, decimals <= 0 ? "0" : "0." + String(repeating: "0", count: decimals))
            numbers[decimals] = format

            return format
        }
    }
}
