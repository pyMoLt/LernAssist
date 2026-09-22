import SwiftUI
import AppKit
import Combine
import os

@main
struct LernAssistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            // Cmd+, leitet auf das ECHTE Einstellungen-Sheet um, statt das früheren toten
            // „Einstellungen"-Textfenster zu öffnen (Audit P4). Der Redirect löst denselben
            // .openSettingsRequested-Pfad aus wie /settings und schließt sich sofort.
            SettingsRedirectView()
        }
    }
}

/// Hilfsansicht für die Settings-Scene: postet beim Erscheinen sofort das Öffnen des echten
/// Einstellungen-Sheets und schließt das Szene-Fenster wieder. Der Button ist Fallback für
/// den Fall, dass ein dismissal nicht greift.
private struct SettingsRedirectView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Einstellungen")
                .font(.headline)
            Text("Das Einstellungen-Fenster der App öffnet sich gleich automatisch.\nFalls nicht:")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Einstellungen öffnen") {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }
        }
        .padding()
        .frame(width: 280, height: 140)
        .onAppear {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                dismiss()
                // Fallback (Erweitert-Tab-Hang-Verdacht): dismiss() wirkt in der Settings-Scene
                // nicht immer – dann blieb ein 280x140-Zombie-Fenster zurück, das Fokus stehlen
                // und die Bedienbarkeit blockieren kann. Der AppDelegate schließt es sicher.
                NotificationCenter.default.post(name: .closeSettingsRedirectWindow, object: nil)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSPanel?
    var viewModel: ChatViewModel?
    var statusItem: NSStatusItem?
    var localKeyboardShortcutMonitor: Any?
    var cancellables = Set<AnyCancellable>()
    /// Fenster des Berechtigungs-Assistenten (erster Start + erneut über Einstellungen).
    var permissionOnboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = ChatViewModel()
        self.viewModel = vm

        // Immer ein minimales App-Menü (v.a. für Cmd+Q) setzen, unabhängig von Dock-Icon/
        // Menüleisten-Symbol – siehe setupGlobalKeyboardShortcutFallback() für den Fall, dass die
        // App gar keine eigene System-Menüleiste zeigt (activation policy .accessory).
        setupMainMenu()
        setupGlobalKeyboardShortcutFallback()

        // Dock-Icon (isMenuBarApp) und Menüleisten-Symbol (showMenuBarIcon) sind bewusst zwei
        // unabhängige Einstellungen – vorher war das Menüleisten-Symbol zwingend an "kein
        // Dock-Icon" gekoppelt. Jetzt sind alle vier Kombinationen möglich, z.B. Dock-Icon UND
        // Menüleisten-Symbol gleichzeitig sichtbar, oder beides ausgeblendet (nur per Hotkey
        // erreichbar).
        //
        // Live an-/abschalten, sobald die Einstellung sich ändert – kein Neustart mehr nötig.
        // Vorher wurde setActivationPolicy nur EINMALIG beim Start gesetzt (der Toggle in den
        // Einstellungen speicherte den neuen Wert zwar, hatte bis zum nächsten Start aber
        // keinerlei Effekt). $isMenuBarApp liefert beim Abonnieren sofort den aktuellen Wert,
        // das übernimmt daher gleich auch das initiale Einrichten.
        vm.$isMenuBarApp
            .removeDuplicates()
            .sink { hide in
                NSApp.setActivationPolicy(hide ? .accessory : .regular)
                // Nach einem Policy-Wechsel zur Laufzeit reaktiviert AppKit die App nicht von
                // selbst neu – ohne das hier bleibt das Dock-Icon teils bis zum nächsten
                // Fokuswechsel sichtbar bzw. das Fenster verliert kurzzeitig den Vordergrund.
                NSApp.activate(ignoringOtherApps: true)
            }
            .store(in: &cancellables)

        // Live an-/abschalten, sobald die Einstellung sich ändert – kein Neustart mehr nötig.
        // $showMenuBarIcon liefert beim Abonnieren sofort den aktuellen Wert, das übernimmt daher
        // gleich auch das initiale Einrichten (kein separater "if vm.showMenuBarIcon { ... }" nötig).
        vm.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in
                if show { self?.setupStatusItem() } else { self?.removeStatusItem() }
            }
            .store(in: &cancellables)

        setupFloatingWindow(vm: vm)
        applyHotkeys(from: vm)

        // Wenn Settings geändert werden → Hotkeys neu verdrahten
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )

        // Berechtigungs-Assistent erneut anzeigen (aus Einstellungen → Erweitert)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPermissionOnboardingRequested),
            name: .showPermissionOnboarding,
            object: nil
        )

        // Settings-Scene-Redirect-Fenster (Cmd+,) sicher schließen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeSettingsRedirectWindowRequested),
            name: .closeSettingsRedirectWindow,
            object: nil
        )

        // Initialisiere Coding Environment asynchron im Hintergrund.
        // Task.detached statt DispatchQueue: CodingEnvironment ist `nonisolated`, aber ein
        // gewöhnliches `Task { }` würde hier trotzdem die Main-Actor-Affinität des aufrufenden
        // Kontexts (applicationDidFinishLaunching) erben – detached vermeidet das explizit.
        Task.detached(priority: .background) {
            await CodingEnvironment.shared.setupEnvironmentIfNeeded()
        }

        // Hang-Watchdog (Erweitert-Tab-Bug): Der Nutzer-Report "Tab öffnen → App hängt → nur
        // Force Quit" ließ sich weder im Ruhezustand noch über programmatische Reproduktion
        // auslösen. Der Watchdog erkennt jeden künftigen Main-Thread-Freeze selbstständig und
        // sichert dann einen vollständigen Backtrace via /usr/bin/sample in
        // ~/Library/Application Support/LernAssist/hang-report.txt – der nächste Freeze des
        // Nutzers wird damit ohne Live-Debugging vollständig diagnostizierbar.
        installHangWatchdog()

        // Berechtigungs-Assistent: beim ALLERERSTEN App-Start ein kleines Fenster zeigen, das
        // durch die benötigten Berechtigungen führt (Zugriffs-Hilfen für „Auswahl erklären“,
        // Bildschirmaufnahme für Screenshots) – mit Live-Status statt späterer Frust, wenn ein
        // Hotkey still nichts tut. „Fertig“ merkt sich den Abschluss; „Später“ zeigt das
        // Fenster beim nächsten Start erneut. Auch jederzeit aus den Einstellungen reopenbar.
        if !UserDefaults.standard.bool(forKey: "hasCompletedPermissionOnboarding") {
            showPermissionOnboarding()
        }

        // Debug-Affordance (Layout-Reproduktion): Lernassist --open-settings-tab=<Tab>
        // öffnet die Einstellungen nach dem Start direkt auf dem benannten Tab – für
        // automatisierte UI-Tests und Reproduktion von Tab-spezifischen Layout-Bugs.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings-tab=") }) {
            let tab = String(arg.dropFirst("--open-settings-tab=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil, userInfo: ["tab": tab])
            }
        }
        // Debug-Affordance (Erweitert-Hang-Reproduktion): --settings-then-tab=<Tab> öffnet die
        // Einstellungen auf dem DEFAULT-Tab (wie der Nutzer) und schaltet nach 2,5 s auf den
        // benannten Tab – nachstellbar über denselben Pfad wie der Sidebar-Klick.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--settings-then-tab=") }) {
            let tab = String(arg.dropFirst("--settings-then-tab=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                NotificationCenter.default.post(name: .debugSwitchSettingsTab, object: nil, userInfo: ["tab": tab])
            }
        }
        // Debug-Affordance (Resize-Hang-Reproduktion, Nutzer-Report "Lernmodus-Tab + App
        // resized → sofortiger Hänger"): --resize-stress[=<Tab>] öffnet die Einstellungen
        /// auf dem Tab (Default: Learning) und resiziert danach das Haupt-Panel mehrfach –
        // wie ein Nutzer, der das Fenster während des offenen Sheets zieht.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--resize-stress") }) {
            let tab: String
            if arg.contains("=") {
                tab = String(arg.dropFirst("--resize-stress=".count))
            } else {
                tab = "Learning"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil, userInfo: ["tab": tab])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.runResizeStress()
            }
        }
    }

    /// Resize-Stresstest (Debug): resiziert das Haupt-Panel in 7 Schritten über 5 s –
    /// simuliert Nutzer-Ziehen an der Fensterecke während eines offenen Settings-Sheets.
    private func runResizeStress() {
        guard let panel = window else { return }
        let sizes: [CGSize] = [
            CGSize(width: 950, height: 720),
            CGSize(width: 700, height: 520),
            CGSize(width: 1150, height: 820),
            CGSize(width: 620, height: 460),
            CGSize(width: 1020, height: 640),
            CGSize(width: 800, height: 600),
        ]
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { timer in
            guard step < sizes.count else { timer.invalidate(); return }
            var frame = panel.frame
            frame.size = sizes[step]
            panel.setFrame(frame, display: true)
            step += 1
        }
    }

    // MARK: - Berechtigungs-Assistent

    /// Zeigt das Berechtigungs-Fenster (idempotent: bereits geöffnet → nur nach vorn holen).
    func showPermissionOnboarding() {
        if let existing = permissionOnboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Berechtigungen einrichten"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // Nie beliebigen Panel-/Sheet-Hintergrund als Drag-Fläche verwenden. Unter macOS 26
        // kann ein Klick in ein SwiftUI-Sheet sonst eine nicht terminierende AppKit-Tracking-
        // Session starten (Hauptthread im Eventloop idle, aber keine Eingaben mehr erreichbar).
        // Bewegen bleibt über die explizite Griff-Fläche in ChatView möglich.
        panel.isMovableByWindowBackground = false
        panel.center()
        panel.contentView = NSHostingView(rootView: PermissionOnboardingView { [weak self] completed in
            self?.closePermissionOnboarding(completed: completed)
        })
        permissionOnboardingWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePermissionOnboarding(completed: Bool) {
        // completed=true setzt die View bereits selbst (AppStorage) – hier nur noch der
        // einmalige UserDefaults-Fallback für den Fall, dass die App vor dem nächsten Start
        // nicht mehr durch den SwiftUI-Pfad kommt (gleicher Standard-Defaults-Store).
        if completed {
            UserDefaults.standard.set(true, forKey: "hasCompletedPermissionOnboarding")
        }
        permissionOnboardingWindow?.orderOut(nil)
    }

    // MARK: - App-Menü / Beenden

    /// Minimales App-Menü mit u.a. Cmd+Q – relevant vor allem im `.regular`-Modus (Dock-Icon
    /// sichtbar), wo eine System-Menüleiste tatsächlich angezeigt wird.
    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "Über LernAssist", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "LernAssist ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "LernAssist beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Bearbeiten-Menü: OHNE dieses Menü brechen Cmd+C/V/X/A/Z in JEDEM Textfeld der App
        // komplett – AppKit routet diese Standard-Editierbefehle über die Key-Equivalents der
        // Edit-Menüpunkte zum First Responder, nicht über einen eingebauten Mechanismus der
        // Textfelder selbst. Vorher gab es GAR kein eigenes NSApp.mainMenu (SwiftUI stellte via
        // der WindowGroup/Settings-Scene automatisch ein Standardmenü inkl. Bearbeiten bereit);
        // das selbst gesetzte mainMenu oben (nur fürs Beenden) hat dieses Standardmenü ersetzt
        // und damit ohne eigenes Bearbeiten-Menü Copy/Paste/Cut/Undo/Redo/Alles-auswählen überall
        // in der App kaputtgemacht.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Bearbeiten")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Rückgängig", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// Zwei Zwecke in einem lokalen Event-Monitor:
    ///
    /// 1. Cmd+Q: `.accessory`-Apps (Dock-Icon ausgeblendet) bekommen keine eigene System-
    ///    Menüleiste, wodurch das Cmd+Q im App-Menü dort nicht zuverlässig greift.
    ///
    /// 2. Cmd+C/V/X/A: Trotz des Bearbeiten-Menüs in `setupMainMenu()` (das für die normale
    ///    Menü-Key-Equivalent-Auflösung nötig ist) routete Cmd+V in Textfeldern innerhalb des
    ///    manuell erstellten NSPanel weiterhin nicht zuverlässig zum First Responder – das Panel
    ///    wird nicht über eine normale SwiftUI-WindowGroup verwaltet, wodurch `performKeyEquivalent`
    ///    den First Responder des Feld-Editors offenbar nicht immer korrekt auflöst. Statt uns auf
    ///    diese Auflösung zu verlassen, senden wir die Standard-Editieraktion hier direkt und
    ///    zuverlässig per `NSApp.sendAction` an den First Responder – exakt der Mechanismus, den
    ///    auch ein Klick auf "Bearbeiten > Einfügen" nutzen würde, nur ohne den (hier offenbar
    ///    unzuverlässigen) Umweg über die Menü-Key-Equivalent-Auflösung.
    ///
    /// In beiden Fällen wird der Event durch `return nil` konsumiert, damit er nicht zusätzlich
    /// noch über das Bearbeiten-Menü ein zweites Mal verarbeitet wird (kein Doppel-Paste).
    func setupGlobalKeyboardShortcutFallback() {
        localKeyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                NSApp.terminate(nil)
                return nil
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                return nil
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            case "x":
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                return nil
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Fenster

    func setupFloatingWindow(vm: ChatViewModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Nie beliebigen Panel-/Sheet-Hintergrund als Drag-Fläche verwenden (Audit H7 –
        // Regression des dokumentierten Freeze-Fixes): Unter macOS 26 kann ein Klick in ein
        // SwiftUI-Sheet/Overlay sonst eine nicht terminierende AppKit-Tracking-Session starten
        // (App-Freeze). Bewegen bleibt über die explizite Griff-Fläche (WindowDragHandle) in
        // ChatView möglich.
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = false
        // Vibrancy-Hintergrund (Phase G): NSVisualEffectView mit behindWindow-Blending statt
        // einer opaken Fensterfarbe – das schwebende Panel übernimmt die Farben dessen, was
        // dahinter liegt, und gibt den Liquid-Glass-Steuerflächen visuelles "Futter"
        // (Glass wirkt auf flachem Hintergrund sonst tot).
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        panel.contentView = effect

        let hosting = NSHostingView(rootView: ChatView(viewModel: vm))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        // Fix (Skalierungs-Bug): Die SwiftUI-Fläche muss an ALLE Kanten des Effekt-Views
        // gepinnt sein. Autoresizing alleine reicht nicht – der Hosting-View startet ohne
        // eigenen Frame und skalierte deshalb nicht mit dem Fenster (Inhalt blieb in der
        // linken unteren Ecke "kleben", während das Fenster wuchs). Constraints sind hier
        // die robuste Lösung.
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.center()
        // Explizit sichtbar machen (Launch-Audit): Vorher verließ sich der Start darauf, dass
        // AppKit das Panel implizit anzeigt – je nach Startart (open, Dock, Autostart) kam es
        // aber vor, dass das Panel zwar existierte, aber nie geordnet wurde und der Nutzer
        // nur den Berechtigungs-Assistenten sah. Deterministisch und bei jedem Startpfad
        // identisch: direkt nach dem Aufbau nach vorn holen.
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }
    
    func setupStatusItem() {
        guard statusItem == nil else { return } // idempotent, falls schon vorhanden
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "LernAssist")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            // Standardmäßig reagiert der Button nur auf Linksklick – für einen eigenen
            // Rechtsklick-Kontextmenü (statt des Standard-NSMenu-Verhaltens, das links UND
            // rechts gleich behandeln würde) müssen beide Event-Typen explizit angemeldet werden.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    @objc func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
        } else {
            handleToggleWindow()
        }
    }

    /// Rechtsklick-Menü: Fenster öffnen OHNE den sonst üblichen automatischen Screenshot
    /// (Linksklick-Verhalten bleibt unverändert), sowie ein Weg, die App zuverlässig zu beenden.
    func showStatusItemMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Fenster öffnen", action: #selector(openWindowFromStatusMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "LernAssist beenden", action: #selector(quitFromStatusMenu), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc func openWindowFromStatusMenu() {
        showWindow()
    }

    @objc func quitFromStatusMenu() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkeys verdrahten

    /// Liest die Hotkey-Map aus dem ViewModel (aus settings.json) und registriert alle Aktionen.
    func applyHotkeys(from vm: ChatViewModel) {
        let mgr = GlobalHotkeyManager.shared
        mgr.unregisterAll()

        for action in HotkeyAction.allCases {
            guard let hotkey = vm.hotkeys[action] else { continue }
            mgr.register(action: action, hotkey: hotkey)
        }

        // Callbacks
        mgr.handlers[.toggleWindow]  = { [weak self] in self?.handleToggleWindow() }
        mgr.handlers[.screenshot]    = { [weak self] in self?.handleScreenshot() }
        mgr.handlers[.newChat]       = { [weak self] in self?.viewModel?.createNewChat() }
        mgr.handlers[.toggleSidebar] = {
            NotificationCenter.default.post(name: .toggleSidebar, object: nil)
        }
        mgr.handlers[.explainSelection] = { [weak self] in self?.handleExplainSelection() }
    }

    @objc func hotkeySettingsChanged() {
        if let vm = viewModel { applyHotkeys(from: vm) }
    }

    @objc func showPermissionOnboardingRequested() {
        showPermissionOnboarding()
    }

    /// Schließt alle "normalen" Fenster außer Haupt-Panel und Berechtigungs-Assistent – im
    /// Normalfall also genau das Settings-Scene-Redirect-Fenster (Cmd+,). Sheets (Einstellungs-
    /// Sheet) und das Haupt-Panel (NSPanel) bleiben unberührt.
    /// Audit M20: Quiz-/Karteikarten-/Artefakt-Fenster (NativeWindowManager, plain NSWindow mit
    /// In-Memory-Zustand) bleiben explizit verschont – vorher wurden sie mit weggeordnet und
    /// ihr Zustand war über den Cmd+,-Umweg verloren.
    @objc func closeSettingsRedirectWindowRequested() {
        for win in NSApp.windows where win.isVisible
            && win !== window
            && win !== permissionOnboardingWindow
            && !(win is NSPanel) // Haupt-Panel & SwiftUI-Sheets sind NSPanel-Subklassen
            && !NativeWindowManager.activeWindows.contains(where: { $0 === win }) {
            win.orderOut(nil)
        }
    }

    // MARK: - Hang-Watchdog

    /// Background-Thread, der alle 2 s ein Life-Zeichen vom Main-Dispatcher anfordert.
    /// Bleibt es 3x (≥6 s) aus, ist der Main-Thread blockiert – dann sichert ein
    /// 2-seitiger /usr/bin/sample-Lauf den kompletten Backtrace in hang-report.txt.
    /// Bewusst schwarzhungrig einfach gehalten; ein Report pro Freeze-Phase.
    private func installHangWatchdog() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var missedTicks = 0
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 2.0)
                guard self != nil else { return }
                let tick = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { tick.signal() }
                let responsive = tick.wait(timeout: .now() + 0.5) == .success
                missedTicks = responsive ? 0 : missedTicks + 1
                // 4 s statt 6 s Erkennung (Nutzer-Report: Force-Quit kam teils vor dem Report)
                // und 3 s Sample-Dauer für belastbarere Backtraces.
                if missedTicks >= 2 {
                    missedTicks = 0
                    let pid = Int(ProcessInfo.processInfo.processIdentifier)
                    let reportPath = NSHomeDirectory() + "/Library/Application Support/LernAssist/hang-report.txt"
                    AppLog.ui.error("Main-Thread-Blockade erkannt – sichere Backtrace nach \(reportPath)")
                    let sampler = Process()
                    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    sampler.arguments = [String(pid), "3", "-mayDie", "-file", reportPath]
                    try? sampler.run()
                    // Dem Sampler Zeit geben, bevor ein neuer Freeze-Check startet.
                    Thread.sleep(forTimeInterval: 8.0)
                }
            }
        }
    }

    // MARK: - Aktions-Implementierungen

    func handleToggleWindow() {
        guard let window else { return }
        // Sichtbar = ausblenden, unsichtbar = Screenshot + anzeigen (Audit P5): Vorher wurde
        // zusätzlich NSApp.isActive geprüft – ein sichtbares, aber INAKTIVES Panel (das Panel
        // ist .nonactivatingPanel und aktiviert die App nicht) ließ den Hotkey fälschlich in
        // den Screenshot-Zweig laufen, obwohl der Nutzer das offene Panel weg-toggleln wollte.
        if window.isVisible {
            window.orderOut(nil)
        } else {
            // Screenshot + Fenster zeigen
            handleScreenshot()
        }
    }

    func handleScreenshot() {
        window?.orderOut(nil)
        // Nutzt den zentralen, gehärteten ScreenshotManager statt eines weiteren eigenen
        // screencapture-Prozesses (Audit T5/T10): UUID-Dateiname statt Fixname, Polling statt
        // blindem 200-ms-Warten, Permission-Hinweis, executableURL statt deprecatedem launchPath.
        ScreenshotManager.shared.captureScreenshot { [weak self] image in
            self?.showWindow()
            if let image {
                NotificationCenter.default.post(name: .externalScreenshotCaptured, object: image)
            }
        }
    }

    // MARK: - Systemweites "Auswahl erklären" (Phase H)

    /// Hotkey-Aktion: Liest die aktuelle Textauswahl der aktiven App und legt sie als
    /// vorausgefüllte Frage ins Chat-Panel. Technik: Cmd+C an die aktive App simulieren und
    /// die Zwischenablage lesen (die originale Zwischenablage wird gesichert und danach
    /// wiederhergestellt). Das Simulieren von Tasten erfordert die Zugriffs-Hilfen-
    /// Berechtigung – fehlt sie, öffnet der Handler direkt die passende Systemeinstellung.
    func handleExplainSelection() {
        // Ohne Berechtigung direkt und mit Anleitung scheitern statt still nichts zu tun.
        guard AXIsProcessTrusted() else {
            viewModel?.addSystemMessage(text: "Für „Auswahl erklären“ benötigt LernAssist die Berechtigung „Zugriffshilfen“ (Systemeinstellungen → Datenschutz & Sicherheit → Zugriffs-Hilfen). Bitte dort aktivieren und danach erneut versuchen.")
            showWindow()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        readSystemSelection { [weak self] text in
            self?.showWindow()
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                // Feedback statt stillen Nichtstuns (Perf-Audit L2): Vorher erschien das Fenster
                // einfach leer, wenn die Ziel-App die Auswahl nicht geliefert hatte.
                self?.viewModel?.addSystemMessage(text: "Keine Textauswahl erkannt. Markiere zuerst Text in der Ziel-App und drücke dann den Hotkey erneut.")
                return
            }
            NotificationCenter.default.post(name: .externalExplainSelection, object: nil, userInfo: ["text": trimmed])
        }
    }

    /// Simuliert Cmd+C in der aktiven App, liest die Auswahl und stellt die vorherige
    /// Zwischenablage wieder her. Wartet nicht fix 250 ms, sondern pollt die Zwischenablage-
    /// changeCount (Perf-Audit L2) – langsame Apps hatten mit dem Fixwert noch nil geliefert,
    /// während schnelle unnötig lang warteten. Zeitbudget 1 s.
    private func readSystemSelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let baselineChangeCount = pasteboard.changeCount
        // Bestehende Zwischenablage sichern (alle Typen, inkl. Nicht-String-Formate).
        var backup: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) {
                backup.append((type, data))
            }
        }
        pasteboard.clearContents()

        // Cmd+C an die aktive App senden (Taste C = virtualKey 8).
        let source = CGEventSource(stateID: .combinedSessionState)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        cDown?.flags = .maskCommand
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        cUp?.flags = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)

        // Auf die neue Zwischenablage-Inhalte warten: pollt die changeCount der Zwischenablage,
        // bis die Ziel-App den Copy ausführt (oder nach 1 s aufgegeben wird).
        DispatchQueue.main.async {
            func poll(_ attempt: Int) {
                if pasteboard.changeCount != baselineChangeCount || attempt >= 20 {
                    let selection = pasteboard.string(forType: .string)
                    // Zwischenablage wiederherstellen.
                    pasteboard.clearContents()
                    if !backup.isEmpty {
                        pasteboard.writeObjects(backup.map { entry -> NSPasteboardItem in
                            let item = NSPasteboardItem()
                            item.setData(entry.data, forType: entry.type)
                            return item
                        })
                    }
                    completion(selection)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(attempt + 1) }
                }
            }
            poll(0)
        }
    }

    func showWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}

// MARK: - Notification-Namen

extension Notification.Name {
    static let externalScreenshotCaptured = Notification.Name("ExternalScreenshotCaptured")
    static let toggleSidebar              = Notification.Name("ToggleSidebar")
    static let hotkeySettingsChanged      = Notification.Name("HotkeySettingsChanged")
    /// Öffnet das Settings-Sheet, optional auf einem bestimmten Tab (userInfo["tab"] als String).
    static let openSettingsRequested      = Notification.Name("OpenSettingsRequested")
    /// Systemweite Auswahl wurde gelesen (Phase H) – userInfo["text"] kommt ins Eingabefeld.
    static let externalExplainSelection   = Notification.Name("ExternalExplainSelection")
    /// Fordert Karteikarten/Quiz aus einem konkreten Dokument an (Phase H) –
    /// userInfo: ["text": String, "mode": "flashcards" | "quiz"].
    static let studyDocumentRequested     = Notification.Name("StudyDocumentRequested")
    /// Öffnet den Berechtigungs-Assistenten (Erweitert-Tab; erster Start macht das automatisch).
    static let showPermissionOnboarding  = Notification.Name("ShowPermissionOnboarding")
    /// Schließt das Settings-Scene-Redirect-Fenster zuverlässig (Cmd+,).
    static let closeSettingsRedirectWindow = Notification.Name("CloseSettingsRedirectWindow")
    /// Debug (Erweitert-Hang-Reproduktion): schaltet das offene Settings-Sheet auf einen Tab.
    static let debugSwitchSettingsTab = Notification.Name("DebugSwitchSettingsTab")
}
