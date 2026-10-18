import Foundation

/// Splits a Windows command-line string (as stored in a .lnk shortcut) into
/// arguments using the rules of CommandLineToArgvW / the MSVC runtime:
/// - unquoted whitespace separates arguments;
/// - double quotes group text and are removed; `""` inside quotes is a literal quote;
/// - backslashes are literal, except before a quote: 2n backslashes + `"`
///   give n backslashes and toggle quoting, 2n+1 give n backslashes and a literal `"`.
enum WindowsCommandLine {
    static func split(_ commandLine: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inArgument = false
        var inQuotes = false
        let chars = Array(commandLine)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                var backslashes = 0
                while i < chars.count, chars[i] == "\\" { backslashes += 1; i += 1 }
                inArgument = true
                if i < chars.count, chars[i] == "\"" {
                    current += String(repeating: "\\", count: backslashes / 2)
                    if backslashes % 2 == 1 {
                        current.append("\"")
                        i += 1
                    }
                    // An even count leaves the quote to toggle quoting below.
                } else {
                    current += String(repeating: "\\", count: backslashes)
                }
                continue
            }
            if c == "\"" {
                inArgument = true
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"") // "" inside quotes is a literal quote
                    i += 2
                    continue
                }
                inQuotes.toggle()
                i += 1
                continue
            }
            if (c == " " || c == "\t") && !inQuotes {
                if inArgument {
                    arguments.append(current)
                    current = ""
                    inArgument = false
                }
                i += 1
                continue
            }
            current.append(c)
            inArgument = true
            i += 1
        }
        if inArgument { arguments.append(current) }
        return arguments
    }
}
