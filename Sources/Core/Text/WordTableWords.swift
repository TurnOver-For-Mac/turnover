// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Moved from Apps/Word on 26 Nov 2026: web tables say their size in the same words, and shared code may not reach into an app.
/// The words said of a Word table, apart from the cell so the tests can reach them.
package enum WordTableWords {
    /// "table with 3 rows and 2 columns": a table reached. One row or one column is said in the singular (a one-column
    /// table was "table with 4 rows and 1 columns", 24 Nov 2026).
    package nonisolated static func size(rows: Int, columns: Int) -> String {
        switch (rows == 1, columns == 1) {
        case (true, true): return String(localized: "table with 1 row and 1 column", comment: "A Word table reached: its size, one row and one column")
        case (true, false): return String(localized: "table with 1 row and \(String(columns)) columns", comment: "A Word table reached: its size, one row")
        case (false, true): return String(localized: "table with \(String(rows)) rows and 1 column", comment: "A Word table reached: its size, one column")
        case (false, false): return String(localized: "table with \(String(rows)) rows and \(String(columns)) columns", comment: "A Word table reached: its size")
        }
    }
}
