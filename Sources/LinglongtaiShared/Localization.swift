import Foundation

/// Display-time translation. Chinese is the source language: values, comparisons and stored
/// history all stay Chinese (several of them drive logic, see docs/APP_LOCALIZATION.md), and
/// text is translated only at the moment it reaches the screen.
///
/// Text without an entry comes back unchanged, so task titles and an agent's own wording pass
/// straight through. Status lines are often fixed phrases joined with " · "; when the whole line
/// has no entry, each part is looked up on its own.
public func L(_ text: String) -> String {
    let whole = lookup(text)
    guard whole == text, text.contains(" · ") else { return whole }
    return text.components(separatedBy: " · ").map(lookup).joined(separator: " · ")
}

/// Format-string variant for text built from numbers or names, e.g. `LF("%lld项进行中", count)`.
/// The key keeps the Chinese wording with format specifiers; plural forms live in
/// Localizable.stringsdict.
public func LF(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: lookup(format), locale: .current, arguments: arguments)
}

private func lookup(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
