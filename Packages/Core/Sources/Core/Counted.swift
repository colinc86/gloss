extension Int {
    /// "1 row", "2 rows", "100,000 rows": a count, grouped as the Mac's region writes numbers, with its noun in the
    /// number that agrees with it. `plural` defaults to `noun` + "s".
    public func counted(_ noun: String, plural: String? = nil) -> String {
        "\(formatted()) \(self == 1 ? noun : plural ?? noun + "s")"
    }
}
