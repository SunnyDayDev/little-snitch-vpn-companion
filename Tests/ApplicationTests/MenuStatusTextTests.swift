import Testing

@Suite("Тексты статуса в меню")
struct MenuStatusTextTests {
    private let ip = IPAddress("198.51.100.40")!

    private func detector(_ state: EgressState = .protected,
                          explanation: DetectorStatusExplanation = .none,
                          mode: ProtectionMode = .reactive) -> DetectorSnapshot {
        DetectorSnapshot(id: .primary, name: "Основной", isEnabled: true, mode: mode,
                         proxy: .direct, groups: ["VPN down"], state: state,
                         explanation: explanation)
    }

    private func presentation(_ detectors: [DetectorSnapshot], observeOnly: Bool = false) -> MenuStatusText {
        var snapshot = MonitoringSnapshot()
        snapshot.detectors = detectors
        snapshot.overall = AggregateStatus.summarize(detectors.map {
            .init(id: $0.id, isEnabled: $0.isEnabled, mode: $0.mode, state: $0.state)
        }, isPaused: detectors.allSatisfy { $0.state == .paused })
        snapshot.groupsStateKnown = true
        snapshot.activeLeakGroups = detectors.contains { $0.state != .protected } ? ["VPN down"] : []
        var settings = AppSettings()
        settings.observeOnly = observeOnly
        return MenuStatusText(snapshot: snapshot, settings: settings)
    }

    @Test("Точные признаки Protected и отсутствие лишних полей", arguments: 0..<4)
    func protectedText(variant: Int) {
        let evidence: DetectorStatusExplanation = switch variant {
        case 0: .protected(ProtectionEvidence(expectedIP: nil, warp: .on))
        case 1: .protected(ProtectionEvidence(expectedIP: ip, warp: nil))
        case 2: .protected(ProtectionEvidence(expectedIP: ip, warp: .plus))
        default: .none
        }
        let expected = ["warp=on", "198.51.100.40", "198.51.100.40 · warp=plus", ""][variant]
        var value = detector(explanation: evidence)
        value.trace = BeaconTrace(ip: IPAddress("203.0.113.5")!, warp: .off, colo: "AMS")
        #expect(presentation([value]).subtitle == expected)
        #expect(presentation([value]).title == "Защищено")
        #expect(MenuStatusText.detectorState(for: value)
            == "защищён" + (expected.isEmpty ? "" : " · " + expected))
    }

    @Test("Несколько детекторов сохраняют собственные признаки и сводку")
    func multipleProtected() {
        let first = detector(explanation: .protected(ProtectionEvidence(expectedIP: nil, warp: .on)))
        var second = detector(explanation: .protected(ProtectionEvidence(expectedIP: ip, warp: nil)))
        second = DetectorSnapshot(id: DetectorID("proxy"), name: "Прокси", isEnabled: true,
                                  mode: .reactive, proxy: .direct, groups: [], state: .protected,
                                  explanation: second.explanation)
        #expect(presentation([first, second]).subtitle == "2 детектора · оба защищены")
        #expect(MenuStatusText.detectorState(for: first) == "защищён · warp=on")
        #expect(MenuStatusText.detectorState(for: second) == "защищён · 198.51.100.40")
    }

    @Test("Диагноз утечки появляется один раз при одном и нескольких детекторах",
          arguments: 0..<3, [false, true])
    func leakDiagnosis(kind: Int, multiple: Bool) {
        let diagnosis: LeakDiagnosis = switch kind {
        case 0: .forbiddenServer(ip)
        case 1: .directRuIP(ip)
        default: .foreignEgress
        }
        let reason = ["цепочка вышла напрямую с запрещённого сервера",
                      "полный обход VPN: прямой IP сети", "egress не соответствует правилам защиты"][kind]
        let value = detector(.leak, explanation: .leak(ip, diagnosis))
        var other = detector()
        other = DetectorSnapshot(id: DetectorID("other"), name: "Другой", isEnabled: true,
                                 mode: .reactive, proxy: .direct, groups: [], state: .protected)
        let text = presentation(multiple ? [other, value] : [value])
        #expect(MenuStatusText.detectorState(for: value) == "утечка · 198.51.100.40")
        #expect(text.subtitle == "198.51.100.40 — " + reason)
        #expect(text.banner?.message.contains(reason) == false)
        #expect(text.banner?.message.contains("после подтверждения защиты") == true)
        #expect(text.banner?.title == "Заблокированы: VPN down")
        if multiple { #expect(text.banner?.message.contains("Основной") == true) }
        let observing = presentation([value], observeOnly: true)
        #expect(observing.subtitle == text.subtitle)
        #expect(observing.banner?.title == "Режим наблюдения")
        #expect(observing.banner?.message.contains("не тронуты") == true)
        #expect(observing.banner?.message.contains("снимется") == false)
    }

    @Test("Причина Offline независима от режима", arguments: 0..<3, [ProtectionMode.reactive, .strict])
    func offline(kind: Int, mode: ProtectionMode) {
        let causes: [DetectorStatusExplanation.OfflineCause] = [.noNetwork, .beaconUnavailable, .unknown]
        let value = detector(.offline, explanation: .offline(causes[kind]), mode: mode)
        let reason = ["нет сети", "маяк недоступен", "нет результата проверки"][kind]
        let text = presentation([value])
        #expect(text.subtitle == reason + (mode == .strict ? " — трафик закрыт"
            : " — состояние групп не меняется"))
        if mode == .strict {
            #expect(text.banner?.title == "Закрыто — нет подтверждения защиты")
            #expect(text.banner?.message.contains("возвращения сети") == false)
        } else { #expect(text.banner == nil) }
        let observing = presentation([value], observeOnly: true)
        #expect(observing.banner == nil)
        #expect(!observing.subtitle.contains("трафик закрыт"))
        #expect(MenuStatusText.detectorState(for: value, observeOnly: true) == "офлайн")
    }

    @Test("Проверка нейтральна, пауза и выключенное состояние остаются краткими")
    func checkingPausedDisabled() {
        var value = detector(.checking, mode: .strict)
        #expect(presentation([value]).title == "Проверка")
        #expect(presentation([value]).subtitle == "ждём подтверждения защиты")
        #expect(presentation([value]).banner?.title == "Закрыто — ждём подтверждения VPN")
        value.state = .paused
        #expect(MenuStatusText.detectorState(for: value) == "пауза")
        #expect(presentation([value]).title == "Пауза")
        #expect(presentation([value]).subtitle == "мониторинг на паузе — трафик закрыт")
        #expect(presentation([value]).banner?.title == "Пауза: трафик закрыт")
        #expect(presentation([value], observeOnly: true).subtitle == "мониторинг остановлен вручную")
        value.isEnabled = false
        #expect(MenuStatusText.detectorState(for: value) == "выключен")
    }
}
