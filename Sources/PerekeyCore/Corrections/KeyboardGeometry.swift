// SPDX-License-Identifier: GPL-3.0-or-later

/// Which keys sit next to which on the physical keyboard.
///
/// Key codes are positions, not letters: key 5 is "g" in ABC and "п" in
/// Russian, and its neighbours are the same keys in both. The grid is the
/// ANSI one (`kVK_ANSI_*`); ISO keyboards differ only in the extra key next
/// to the left Shift, which types no letter in the layouts Perekey knows.
public enum KeyboardGeometry {
    /// The four letter rows, left to right, with the offset of the first key
    /// in key widths: the rows are staggered, so a key touches two keys of
    /// the row above and two of the row below.
    static let rows: [(offset: Double, keys: [UInt16])] = [
        (0.0, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]), // ` 1 2 3 4 5 6 7 8 9 0 - =
        (1.5, [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]), // q w e r t y u i o p [ ] \
        (1.75, [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]), // a s d f g h j k l ; '
        (2.25, [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]), // z x c v b n m , . /
    ]

    /// Neighbours by key code, computed once. Keys in the same row are
    /// neighbours when next to each other; keys in adjacent rows when their
    /// centres are less than a key width apart.
    private static let table: [[UInt16]] = {
        var centres: [(keyCode: UInt16, row: Int, x: Double)] = []
        for (row, line) in rows.enumerated() {
            for (index, keyCode) in line.keys.enumerated() {
                centres.append((keyCode, row, line.offset + Double(index) + 0.5))
            }
        }
        var table = [[UInt16]](repeating: [], count: 128)
        for key in centres {
            var neighbours: [UInt16] = []
            for other in centres where other.keyCode != key.keyCode {
                let distance = abs(other.x - key.x)
                let rowGap = abs(other.row - key.row)
                if (rowGap == 0 && distance < 1.5) || (rowGap == 1 && distance < 1) {
                    neighbours.append(other.keyCode)
                }
            }
            table[Int(key.keyCode)] = neighbours.sorted()
        }
        return table
    }()

    /// The keys around this one, lowest key code first; empty for keys off
    /// the letter rows (Space, Return, arrows).
    public static func neighbours(of keyCode: UInt16) -> [UInt16] {
        keyCode < 128 ? table[Int(keyCode)] : []
    }
}
