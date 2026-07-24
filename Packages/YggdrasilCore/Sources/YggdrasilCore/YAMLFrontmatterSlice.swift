struct YAMLFrontmatterSlice {
    let frontmatterRange: Range<String.Index>
    let newline: String

    init?(text: String) {
        if text.hasPrefix("---\r\n") {
            newline = "\r\n"
        } else if text.hasPrefix("---\n") {
            newline = "\n"
        } else {
            return nil
        }

        let contentStart = text.index(text.startIndex, offsetBy: 3 + newline.count)
        let closingPrefix = "\(newline)---"
        var searchStart = contentStart
        var closingRange: Range<String.Index>?

        while searchStart < text.endIndex,
              let candidate = text.range(
                  of: closingPrefix,
                  range: searchStart..<text.endIndex
              ) {
            let after = candidate.upperBound
            if after == text.endIndex || text[after...].hasPrefix(newline) {
                closingRange = candidate
                break
            }
            searchStart = candidate.upperBound
        }

        guard let closingRange else { return nil }
        frontmatterRange = contentStart..<closingRange.lowerBound
    }
}
