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

/// Таблица немаршрутизируемых диапазонов: ответ РУ-маяка из них — перехват
/// по пути, а не прямой IP сети.
@Suite("Маршрутизируемость адреса")
struct IPAddressRoutabilityTests {
    @Test("Немаршрутизируемые v4 отсекаются", arguments: [
        "0.0.0.0", "0.1.2.3",                       // unspecified, «эта сеть»
        "127.0.0.1", "127.255.255.254",             // loopback
        "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1",  // частные
        "169.254.10.20",                            // link-local
        "100.64.0.1", "100.127.255.254",            // CGNAT
        "198.18.0.1", "198.19.255.254",             // fake-IP, бенчмарк
        "224.0.0.1", "239.255.255.250",             // multicast
        "240.0.0.1", "255.255.255.255",             // резерв, broadcast
    ])
    func rejectsNonRoutableV4(_ raw: String) throws {
        #expect(try #require(IPAddress(raw)).isGloballyRoutable == false)
    }

    // Края масок проверяются изнутри (адреса выше); снаружи — только
    // документационные и служебные адреса: реальных публичных адресов в
    // репозитории быть не должно.
    @Test("Документационные и служебные v4 проходят", arguments: [
        "1.1.1.1",
        "192.0.2.10", "198.51.100.10", "203.0.113.40",  // RFC 5737 — примеры репозитория
    ])
    func acceptsRoutableV4(_ raw: String) throws {
        #expect(try #require(IPAddress(raw)).isGloballyRoutable)
    }

    @Test("Немаршрутизируемые v6 отсекаются", arguments: [
        "::", "::1",                                // unspecified, loopback
        "fe80::1", "febf::1",                       // link-local
        "fec0::1",                                  // site-local (устаревший)
        "fc00::1", "fd12:3456::1",                  // ULA
        "ff02::1", "ff05::2",                       // multicast
        "::ffff:127.0.0.1", "::ffff:192.168.1.1",   // IPv4-mapped по правилам v4
        "::ffff:198.18.0.1",
    ])
    func rejectsNonRoutableV6(_ raw: String) throws {
        #expect(try #require(IPAddress(raw)).isGloballyRoutable == false)
    }

    @Test("Документационный префикс v6 и IPv4-mapped документационный проходят", arguments: [
        "2001:db8::40", "2001:db8:4c9c:18f8::3f",   // RFC 3849 — примеры репозитория
        "::ffff:192.0.2.10",
    ])
    func acceptsRoutableV6(_ raw: String) throws {
        #expect(try #require(IPAddress(raw)).isGloballyRoutable)
    }
}
