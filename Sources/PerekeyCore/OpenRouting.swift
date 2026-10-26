// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the URLs Finder or a browser hands to the app go: `perekey://` links
/// to the control commands, files to the transcription queue. Anything else is
/// dropped. A link never reaches the files: a web page can open a `perekey://`
/// URL, so it must not be able to start a recording or pick a file.
public struct OpenRouting: Equatable, Sendable {
    public var links: [URL] = []
    public var files: [URL] = []
    /// How many URLs were neither: counted for the log, never listed.
    public var ignored = 0

    public init(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else if url.scheme?.lowercased() == "perekey" {
                links.append(url)
            } else {
                ignored += 1
            }
        }
    }
}
