extension Int {
    /// "1 row", "2 rows": a count with its noun in the number that agrees with it. `plural` defaults to `noun` + "s".
    public func counted(_ noun: String, plural: String? = nil) -> String {
        "\(self) \(self == 1 ? noun : plural ?? noun + "s")"
    }
}
