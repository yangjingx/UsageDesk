import Foundation

@main
struct DeepSeekParsingTests {
    static func main() throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"0.50","granted_balance":"0.00","topped_up_balance":"0.50"}]}"#.utf8)
        let snapshot = try DeepSeekAPI.parse(data, at: Date(timeIntervalSince1970: 100))
        precondition(snapshot.isAvailable)
        precondition(snapshot.balances.count == 2)
        precondition(snapshot.balances[0].currency == "CNY")
        precondition(snapshot.balances[0].total == Decimal(110))
        precondition(snapshot.balances[1].total == Decimal(string: "0.50"))
        precondition(snapshot.updatedAt == Date(timeIntervalSince1970: 100))

        let empty = try DeepSeekAPI.parse(Data(#"{"is_available":false,"balance_infos":[]}"#.utf8))
        precondition(!empty.isAvailable && empty.balances.isEmpty)

        let invalid = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"not money","granted_balance":"0","topped_up_balance":"0"}]}"#.utf8)
        do {
            _ = try DeepSeekAPI.parse(invalid)
            fatalError("Invalid amount was accepted")
        } catch DeepSeekAPIError.invalidAmount {
            // Expected.
        }
        print("DeepSeek parsing tests passed")
    }
}
