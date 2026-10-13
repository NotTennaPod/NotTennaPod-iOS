/// Identity text (GUIDs, media addresses, file names, sources) compares like Java's `String.equals`:
/// exact UTF-16 code units. Swift `==` would treat canonically equivalent Unicode as equal.
func exactlyEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case (.some(let lhs), .some(let rhs)): lhs.utf16.elementsEqual(rhs.utf16)
    default: false
    }
}
