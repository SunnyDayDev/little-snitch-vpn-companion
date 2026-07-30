import Testing

@Suite("IPAddress")
struct IPAddressTests {
    @Test("Разбирает IPv4")
    func parsesV4() throws {
        let ip = try #require(IPAddress("198.51.100.10"))
        #expect(ip.family == .v4)
        #expect(ip.bytes == [198, 51, 100, 10])
        #expect(ip.description == "198.51.100.10")
    }

    @Test("Отвергает мусор вместо IP", arguments: [
        "", "не ip", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-1",
        "gggg::1", ":1", "1:", "fe80::1%en0", "1.1.1.1/24", "<html>",
    ])
    func rejectsGarbage(_ raw: String) {
        #expect(IPAddress(raw) == nil)
    }

    @Test("Разбирает IPv6 маяка Cloudflare")
    func parsesV6() throws {
        let ip = try #require(IPAddress("2a09:bac5:4c9c:18f8:1d:3:0:3f"))
        #expect(ip.family == .v6)
        #expect(ip.bytes.count == 16)
    }

    @Test("Сравнение по байтам: регистр и сокращение не важны")
    func comparesByBytes() throws {
        let full = try #require(IPAddress("2a09:BAC5:0000:0000:0000:0000:0000:0001"))
        let short = try #require(IPAddress("2a09:bac5::1"))
        #expect(full == short)
        #expect(Set([full]).contains(short))
    }

    @Test("Разбирает краевые формы IPv6")
    func parsesEdgeForms() throws {
        #expect(try #require(IPAddress("::")).bytes.allSatisfy { $0 == 0 })
        #expect(try #require(IPAddress("::1")).bytes.last == 1)
        #expect(IPAddress("2a09::") != nil)
        // Встроенный IPv4 в последней группе
        let mapped = try #require(IPAddress("::ffff:1.1.1.1"))
        #expect(Array(mapped.bytes.suffix(4)) == [1, 1, 1, 1])
    }

    @Test("v4 и v6 с одинаковыми байтами не равны")
    func familiesDiffer() throws {
        let v4 = try #require(IPAddress("1.1.1.1"))
        let v6 = try #require(IPAddress("::ffff:1.1.1.1"))
        #expect(v4 != v6)
    }
}
