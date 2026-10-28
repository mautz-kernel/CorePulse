import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string collectorPath: decodeURIComponent(
        String(Qt.resolvedUrl("collector.py")).replace(/^file:\/\//, ""))
    readonly property int historyLength: 30 // 30 Proben x 2 s
    readonly property int textSize: Math.max(11, Theme.barTextSize(
        root.barThickness,
        root.barConfig?.fontScale,
        root.barConfig?.maximizeWidgetText))
    readonly property int graphHeight: Math.max(16, root.widgetThickness - 9)
    readonly property var coreColors: [Theme.primary, Theme.tertiary, Theme.secondary, Theme.info]

    property var physData: []
    property var threadData: []
    property string activeView: "cpu" // cpu | ram | disk | power
    property var topProcesses: []
    property var mounts: []
    property var battery: ({})
    property string tlpProfile: "" // Zuletzt von tlpctl get bestätigtes Profil.
    property string requestedProfile: ""
    property string pendingProfile: "" // Sofortige visuelle Rückmeldung nach Klick.
    property bool profileVerifyPending: false // Nach Setter-Ende neuen Readback starten.
    property bool profileVerifyActive: false  // Gerade läuft der bestätigende Readback.
    property string tlpError: ""
    readonly property string displayProfile: pendingProfile !== "" ? pendingProfile : tlpProfile
    readonly property string powerSource: battery.ac_online === true ? "Netzbetrieb"
        : battery.ac_online === false ? "Akkubetrieb" : "Stromquelle unbekannt"
    readonly property string batteryPercentText: battery.present && battery.percent !== null
        && battery.percent !== undefined ? battery.percent + "%" : "--%"

    // Die Zeit ist eine Momentaufnahme. Fehlende oder unplausible Daten
    // werden nicht durch erfundene Restzeiten ersetzt.
    readonly property string batteryRemainingText: {
        if (!battery.present)
            return "Kein Akku erkannt";
        const status = String(battery.status || "").toLowerCase();
        const target = battery.charge_limit_pct;
        if (status === "full")
            return target !== null && target !== undefined && target < 100
                ? "Ladeziel " + target + "% erreicht" : "Voll geladen";
        if (status === "not charging") {
            if (battery.ac_online === true && target !== null && target !== undefined
                    && battery.percent !== null && battery.percent !== undefined
                    && Number(battery.percent) >= Number(target))
                return "Ladeziel " + target + "% erreicht";
            return "Ladevorgang pausiert";
        }
        if (status !== "charging" && status !== "discharging")
            return "Restzeit nicht verfügbar";
        if (battery.time_hours === null || battery.time_hours === undefined
                || !isFinite(Number(battery.time_hours)) || Number(battery.time_hours) <= 0)
            return status === "charging" ? "Ladezeit nicht verfügbar"
                : "Restlaufzeit nicht verfügbar";
        const minutes = Math.round(Number(battery.time_hours) * 60);
        if (minutes < 1 || minutes > 72 * 60)
            return "Restzeit nicht verfügbar";
        const h = Math.floor(minutes / 60);
        const min = minutes % 60;
        const duration = h > 0 ? h + " h " + ("0" + min).slice(-2) + " min"
            : min + " min";
        if (status === "discharging")
            return "ca. " + duration + " Restlaufzeit";
        return "ca. " + duration + " bis " +
            (target !== null && target !== undefined ? target + " %" : "Ladeende");
    }
    readonly property bool canChangeProfile: (tlpProfile === "balanced" || tlpProfile === "performance")
        && pendingProfile === "" && !profileSetter.running
    readonly property string profileIcon: displayProfile === "balanced" ? "ac_unit"
        : displayProfile === "performance" ? "local_fire_department"
        : displayProfile === "power-saver" ? "eco" : "help_outline"
    readonly property color profileColor: displayProfile === "balanced" ? Theme.info
        : displayProfile === "performance" ? Theme.warning : Theme.widgetIconColor
    property real memTotalGiB: -1
    property real memAvailableGiB: 0
    readonly property real memoryFraction: memTotalGiB > 0
        ? Math.min(1, Math.max(0, (memTotalGiB - memAvailableGiB) / memTotalGiB)) : 0
    property real cpuTotal: 0
    property string memText: "--"
    property string diskText: "--"
    property string tempText: "--"
    property string errorText: ""
    property bool hasSample: false
    property real maxFreqMhz: 0
    property real maxPerfPct: -1
    property bool thermalAvailable: false
    property var lastThermal: null
    property int throttleEvents: 0
    property int throttleHotSamples: 0

    popoutWidth: activeView === "cpu" ? 940 : (activeView === "power" ? 620 : 700)

    // Feste Breiten verhindern, dass RAM-, Speicher- und CPU-Ziffern die
    // nachfolgenden Icons bei jeder Aktualisierung verschieben.
    // Die Breiten werden aus der aktuellen DMS-Schrift gemessen.
    FontMetrics {
        id: numberMetrics
        font.family: Theme.defaultFontFamily
        font.pixelSize: root.textSize
        font.weight: Font.DemiBold
    }
    readonly property int cpuNumberWidth: Math.ceil(numberMetrics.advanceWidth("100%")) + 2
    readonly property int batteryNumberWidth: Math.ceil(numberMetrics.advanceWidth(
        root.battery.percent === 100 ? "100%" : "99%")) + 2
    readonly property int ramNumberWidth: Math.ceil(numberMetrics.advanceWidth("88.8/88.8G")) + 2
    readonly property int diskNumberWidth: Math.ceil(numberMetrics.advanceWidth("8888.8G")) + 2
    readonly property int tempNumberWidth: Math.ceil(numberMetrics.advanceWidth("100°C")) + 2

    function compactGiB(value) {
        return value === null || value === undefined || !isFinite(Number(value))
            ? "--" : Number(value).toFixed(1);
    }

    function updatedSamples(cpus, oldCpus) {
        const historyById = ({});
        for (let i = 0; i < oldCpus.length; i++)
            historyById[oldCpus[i].id] = oldCpus[i].samples || [];
        const next = [];
        for (let i = 0; i < cpus.length; i++) {
            const c = cpus[i];
            const h = (historyById[c.id] || []).slice(-(historyLength - 1));
            h.push(Number(c.usage) || 0);
            next.push({id: c.id, usage: Number(c.usage) || 0,
                          mhz: Number(c.mhz) || 0, maxMhz: Number(c.max_mhz) || 0, samples: h});
        }
        return next;
    }

    function acceptThermal(data) {
        const thermal = data || ({});
        thermalAvailable = !!thermal.available;
        if (!thermalAvailable) {
            lastThermal = null;
            throttleHotSamples = 0;
            return;
        }
        if (lastThermal !== null) {
            let packageDelta = 0;
            if (thermal.package_count !== null && thermal.package_count !== undefined &&
                lastThermal.package_count !== null && lastThermal.package_count !== undefined)
                packageDelta = Math.max(0, thermal.package_count - lastThermal.package_count);
            const oldCores = lastThermal.core_counts || [];
            const curCores = thermal.core_counts || [];
            let coreDelta = 0;
            for (let i = 0; i < Math.min(oldCores.length, curCores.length); i++) {
                if (oldCores[i] !== null && curCores[i] !== null)
                    coreDelta += Math.max(0, curCores[i] - oldCores[i]);
            }
            // Package/Core-Events können dasselbe Ereignis zählen: nicht addieren.
            const delta = Math.max(packageDelta, coreDelta);
            if (delta > 0) {
                throttleEvents += delta;
                throttleHotSamples = 15; // Hinweis ca. 30 Sekunden anzeigen.
            } else if (throttleHotSamples > 0) {
                throttleHotSamples--;
            }
        }
        lastThermal = thermal;
    }

    function acceptSample(line) {
        try {
            const data = JSON.parse(line);
            if (!Array.isArray(data.cores) || !Array.isArray(data.threads))
                return;
            physData = updatedSamples(data.cores.slice(0, 4), physData);
            threadData = updatedSamples(data.threads, threadData);
            cpuTotal = Number(data.cpu_total) || 0;
            topProcesses = Array.isArray(data.top_processes) ? data.top_processes : [];
            mounts = Array.isArray(data.mounts) ? data.mounts : [];
            battery = data.battery || ({});
            memText = compactGiB(data.mem_used_gib) + "/" + compactGiB(data.mem_total_gib) + "G";
            memTotalGiB = Number(data.mem_total_gib) || -1;
            memAvailableGiB = Math.max(0, memTotalGiB - (Number(data.mem_used_gib) || 0));
            diskText = compactGiB(data.disk_free_gib) + "G";
            tempText = (data.temps || []).length ? Math.round(data.temps[0].c) + "°C" : "--";
            maxFreqMhz = Number(data.policy_max_mhz) || 0;
            maxPerfPct = (data.intel_max_perf_pct === null || data.intel_max_perf_pct === undefined)
                ? -1 : Number(data.intel_max_perf_pct);
            acceptThermal(data.thermal);
            errorText = "";
            hasSample = true;
        } catch (e) {
            console.warn("CorePulse: JSON-Lesefehler: " + e);
        }
    }

    Process {
        id: collector
        command: ["/usr/bin/env", "python3", root.collectorPath]
        running: true
        stdout: SplitParser {
            onRead: line => root.acceptSample(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn("CorePulse Collector: " + line)
        }
        onExited: exitCode => {
            root.errorText = "Collector beendet (" + exitCode + ")";
            console.warn("CorePulse: " + root.errorText);
        }
    }

    function openDetail(view) {
        activeView = view;
        // Trigger through the DMS API so the native popout is anchored to
        // the entire BasePill and respects the current bar orientation.
        root.triggerPopout();
    }

    function refreshTlpProfile() {
        if (profileReader.running || profileSetter.running)
            return;
        // Als Readback gilt nur ein tlpctl get, das NACH dem Setter gestartet wurde.
        if (profileVerifyPending) {
            profileVerifyPending = false;
            profileVerifyActive = true;
        }
        profileReader.running = true;
    }

    function toggleTlpProfile() {
        if (!canChangeProfile)
            return;
        requestedProfile = tlpProfile === "balanced" ? "performance" : "balanced";
        tlpError = "";
        pendingProfile = requestedProfile; // ❄️/🔥 erscheint unmittelbar beim Klick.
        profileSetter.command = ["/usr/bin/tlpctl", requestedProfile];
        profileSetter.running = true;
    }

    Process {
        id: profileReader
        command: ["/usr/bin/tlpctl", "get"]
        running: false
        stdout: SplitParser {
            onRead: line => {
                const profile = line.trim();
                if (["balanced", "performance", "power-saver"].includes(profile))
                    root.tlpProfile = profile;
            }
        }
        stderr: SplitParser {
            onRead: line => root.tlpError = line.trim()
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.tlpProfile = "";
                if (!root.tlpError)
                    root.tlpError = "tlpctl get fehlgeschlagen";
            }
            if (root.profileVerifyActive) {
                root.profileVerifyActive = false;
                const expected = root.pendingProfile;
                root.pendingProfile = "";
                if (exitCode === 0 && root.tlpProfile === expected) {
                    root.tlpError = "";
                } else if (exitCode === 0) {
                    root.tlpError = "TLP meldet " + (root.tlpProfile || "kein Profil")
                        + " statt " + expected;
                }
            }
            // Falls beim Umschalten bereits ein älterer Read lief, jetzt
            // zwingend einen NEUEN Readback starten (kein veraltetes Ergebnis).
            if (root.profileVerifyPending)
                Qt.callLater(() => root.refreshTlpProfile());
        }
    }

    Process {
        id: profileSetter
        running: false
        stdout: SplitParser {
            onRead: line => console.log("CorePulse TLP: " + line)
        }
        stderr: SplitParser {
            onRead: line => root.tlpError = line.trim()
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.pendingProfile = ""; // Fehler: sofort zurück zum bestätigten Symbol.
                if (!root.tlpError)
                    root.tlpError = "TLP-Profilwechsel fehlgeschlagen";
            } else {
                // Bei Erfolg bleibt das neue Symbol sichtbar, bis tlpctl get
                // den tatsächlichen Zustand bestätigt oder widerlegt.
                root.profileVerifyPending = true;
            }
            Qt.callLater(() => root.refreshTlpProfile());
        }
    }

    Timer {
        interval: 8000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshTlpProfile()
    }

    // BasePill zeichnet den Hintergrund selbst (DMS-Theme, Transparenz, Radius).
    // Three independent click targets inside ONE native BasePill.
    // Default CPU, RAM and disks each open the matching popout tab.
    horizontalBarPill: Component {
        Row {
            spacing: 7
            anchors.verticalCenter: parent.verticalCenter

            Item {
                id: cpuSegment
                width: cpuLine.implicitWidth
                height: Math.max(cpuLine.implicitHeight, root.graphHeight)
                Row {
                    id: cpuLine
                    anchors.centerIn: parent
                    spacing: 7
                    DankIcon {
                        name: "memory"
                        size: root.iconSize
                        color: root.throttleHotSamples > 0 ? Theme.error : Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.hasSample ? Math.round(root.cpuTotal) + "%" : "--"
                        width: root.cpuNumberWidth
                        horizontalAlignment: Text.AlignRight
                        color: Theme.widgetTextColor
                        font.family: Theme.defaultFontFamily
                        font.pixelSize: root.textSize
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    MultiCpuGraph {
                        width: 112
                        height: root.graphHeight
                        maxSamples: root.historyLength
                        anchors.verticalCenter: parent.verticalCenter
                        series: root.physData.map((cpu, index) => ({
                            samples: cpu.samples,
                            color: root.coreColors[index % root.coreColors.length]
                        }))
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDetail("cpu")
                }
            }

            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                id: ramSegment
                width: ramLine.implicitWidth
                height: Math.max(ramLine.implicitHeight, root.graphHeight)
                Row {
                    id: ramLine
                    anchors.centerIn: parent
                    spacing: 7
                    DankIcon {
                        name: "developer_board"; size: root.iconSize
                        color: Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.memText
                        width: root.ramNumberWidth
                        horizontalAlignment: Text.AlignRight
                        color: Theme.widgetTextColor
                        font.family: Theme.defaultFontFamily
                        font.pixelSize: root.textSize
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDetail("ram")
                }
            }

            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                id: diskSegment
                width: diskLine.implicitWidth
                height: Math.max(diskLine.implicitHeight, root.graphHeight)
                Row {
                    id: diskLine
                    anchors.centerIn: parent
                    spacing: 7
                    DankIcon {
                        name: "storage"; size: root.iconSize
                        color: Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.diskText
                        width: root.diskNumberWidth
                        horizontalAlignment: Text.AlignRight
                        color: Theme.widgetTextColor
                        font.family: Theme.defaultFontFamily
                        font.pixelSize: root.textSize
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDetail("disk")
                }
            }

            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                id: tempSegment
                width: tempLine.implicitWidth
                height: Math.max(tempLine.implicitHeight, root.graphHeight)
                Row {
                    id: tempLine
                    anchors.centerIn: parent
                    spacing: 7
                    DankIcon {
                        name: "device_thermostat"; size: root.iconSize
                        color: Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.tempText
                        width: root.tempNumberWidth
                        horizontalAlignment: Text.AlignRight
                        color: Theme.widgetTextColor
                        font.family: Theme.defaultFontFamily
                        font.pixelSize: root.textSize
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDetail("cpu")
                }
            }

            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }

            // Stromquelle + Akkuladung als ein Segment (Linksklick: Energiedetails).
            Item {
                id: batterySegment
                width: batteryLine.implicitWidth
                height: Math.max(batteryLine.implicitHeight, root.graphHeight)
                Row {
                    id: batteryLine
                    anchors.centerIn: parent
                    spacing: 3
                    DankIcon {
                        name: root.battery.ac_online === true ? "power"
                            : root.battery.ac_online === false ? "battery_std" : "power_off"
                        size: Math.max(14, root.iconSize - 3)
                        color: Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -1
                    }
                    Text {
                        text: root.batteryPercentText
                        width: root.batteryNumberWidth
                        horizontalAlignment: Text.AlignRight
                        color: Theme.widgetTextColor
                        font.family: Theme.defaultFontFamily
                        font.pixelSize: root.textSize
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openDetail("power")
                }
            }

            // Nur am TLP-Symbol schaltet ein Rechtsklick BAL <-> PRF.
            Item {
                id: profileSegment
                width: root.iconSize + 2
                height: Math.max(root.iconSize, root.graphHeight)
                DankIcon {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1
                    name: root.profileIcon
                    size: Math.max(14, root.iconSize - 3)
                    color: root.profileColor
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton)
                            root.toggleTlpProfile();
                        else
                            root.openDetail("power");
                    }
                }
            }

            Text {
                visible: !root.hasSample
                text: root.errorText || "Lade…"
                color: Theme.widgetTextColor
                font.pixelSize: root.textSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2
            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "memory"; size: root.iconSize
                color: root.throttleHotSamples > 0 ? Theme.error : Theme.widgetIconColor
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.hasSample ? Math.round(root.cpuTotal) + "%" : "--"
                color: Theme.widgetTextColor
                font.pixelSize: root.textSize
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.tempText
                color: Theme.widgetTextColor
                font.pixelSize: root.textSize
            }
        }
    }

    // Detailfenster: acht Threads in zwei Reihen mit je vier Karten.
    // Die schmale Leistenansicht bleibt unverändert.
    popoutContent: Component {
        PopoutComponent {
            headerText: root.activeView === "cpu" ? "CorePulse · CPU-Details"
                      : root.activeView === "ram" ? "CorePulse · Arbeitsspeicher"
                      : root.activeView === "disk" ? "CorePulse · Laufwerke"
                      : "CorePulse · Energie"
            showCloseButton: true

            Row {
                id: detailTabs
                width: parent.width
                spacing: Theme.spacingS
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingM

                Repeater {
                    model: ["cpu", "ram", "disk", "power"]
                    Rectangle {
                        id: tab
                        required property int index
                        required property string modelData
                        readonly property bool selected: modelData === root.activeView
                        width: 128
                        height: 38
                        radius: Theme.cornerRadius
                        color: selected ? Theme.withAlpha(Theme.primary, 0.20)
                                        : Theme.withAlpha(Theme.surfaceVariantText, 0.07)
                        border.width: selected ? 1 : 0
                        border.color: Theme.primary
                        Text {
                            anchors.centerIn: parent
                            text: tab.modelData === "cpu" ? "CPU"
                                : tab.modelData === "ram" ? "RAM"
                                : tab.modelData === "disk" ? "Laufwerke" : "Energie"
                            font.pixelSize: Math.max(14, Theme.fontSizeMedium)
                            font.weight: parent.selected ? Font.DemiBold : Font.Normal
                            color: parent.selected ? Theme.primary : Theme.surfaceText
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.activeView = tab.modelData
                        }
                    }
                }
            }

            Column {
                id: details
                visible: root.activeView === "cpu"
                width: parent.width
                spacing: Theme.spacingM
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingM

                readonly property int detailFontSize: Math.max(14, Theme.fontSizeMedium)
                readonly property int titleFontSize: Math.max(16, Theme.fontSizeMedium + 1)
                readonly property real innerWidth: width - leftPadding - rightPadding

                Text {
                    text: root.threadData.length + " logische CPUs · 60 Sekunden Verlauf"
                    font.pixelSize: details.detailFontSize
                    color: Theme.surfaceVariantText
                }

                Grid {
                    id: cpuGrid
                    width: details.innerWidth
                    columns: 4
                    columnSpacing: Theme.spacingS
                    rowSpacing: Theme.spacingS
                    readonly property real cardWidth: Math.floor((width - columnSpacing * 3) / 4)

                    Repeater {
                        model: root.threadData.length
                        Item {
                            id: card
                            required property int index
                            readonly property var cpu: root.threadData[index]
                            readonly property color traceColor: root.coreColors[index % root.coreColors.length]
                            width: cpuGrid.cardWidth
                            height: 174

                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.surfaceVariantText, 0.055)
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.outline, 0.24)
                            }

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingXS

                                Item {
                                    width: parent.width
                                    height: 25

                                    Rectangle {
                                        width: 7
                                        height: 14
                                        radius: 3
                                        color: card.traceColor
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: "CPU " + card.cpu.id
                                        anchors.left: parent.left
                                        anchors.leftMargin: 13
                                        anchors.verticalCenter: parent.verticalCenter
                                        font.pixelSize: details.titleFontSize
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                    Text {
                                        text: Math.round(card.cpu.usage) + "%"
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        font.pixelSize: details.titleFontSize
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                MultiCpuGraph {
                                    width: parent.width
                                    height: 65
                                    maxSamples: root.historyLength
                                    series: [{
                                        samples: card.cpu.samples,
                                        color: card.traceColor
                                    }]
                                }

                                Text {
                                    width: parent.width
                                    text: card.cpu.mhz > 0
                                        ? (card.cpu.mhz / 1000).toFixed(2) + " GHz"
                                        : "Takt: –"
                                    font.pixelSize: details.detailFontSize
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                                Text {
                                    width: parent.width
                                    text: card.cpu.maxMhz > 0
                                        ? "Limit " + (card.cpu.maxMhz / 1000).toFixed(2) + " GHz"
                                        : "Limit nicht verfügbar"
                                    font.pixelSize: Math.max(12, details.detailFontSize - 1)
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: details.innerWidth
                    height: 1
                    color: Theme.outline
                    opacity: 0.35
                }

                Item {
                    width: details.innerWidth
                    height: 28
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "CPU gesamt: " + Math.round(root.cpuTotal) + "%"
                        font.pixelSize: details.detailFontSize
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "CPU-Package: " + root.tempText
                        font.pixelSize: details.detailFontSize
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }
                }

                Text {
                    text: root.maxFreqMhz > 0
                        ? "Aktuelles Kernel-Policy-Limit: " + (root.maxFreqMhz / 1000).toFixed(2) + " GHz (z. B. auto-cpufreq/TLP)"
                        : "Kernel-Policy-Limit: nicht verfügbar"
                    font.pixelSize: details.detailFontSize
                    color: Theme.surfaceVariantText
                }
                Text {
                    visible: root.maxPerfPct >= 0
                    text: "Intel P-State-Leistungslimit: " + root.maxPerfPct.toFixed(0) + "%"
                    font.pixelSize: details.detailFontSize
                    color: Theme.surfaceVariantText
                }
                Text {
                    width: details.innerWidth
                    wrapMode: Text.WordWrap
                    text: !root.thermalAvailable
                        ? "Thermal-Throttle-Zähler: nicht verfügbar"
                        : (root.throttleHotSamples > 0
                            ? "THERMAL THROTTLING erkannt!"
                            : "Thermal-Ereignisse seit Widgetstart: " + root.throttleEvents)
                    color: root.throttleHotSamples > 0 ? Theme.error : Theme.surfaceText
                    font.pixelSize: details.detailFontSize
                    font.weight: root.throttleHotSamples > 0 ? Font.Bold : Font.Normal
                }
                Text {
                    width: details.innerWidth
                    wrapMode: Text.WordWrap
                    text: "Hinweis: Das Policy-Limit ist keine garantierte Turbo-Frequenz. "
                        + "Ein niedriger Takt allein beweist kein Hitzethrottling."
                    font.pixelSize: Math.max(12, details.detailFontSize - 1)
                    color: Theme.surfaceVariantText
                }
            }

            Column {
                id: ramDetails
                visible: root.activeView === "ram"
                width: parent.width
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingL
                spacing: Theme.spacingM
                readonly property int detailSize: Math.max(14, Theme.fontSizeMedium)
                readonly property real usable: width - leftPadding - rightPadding

                Text {
                    text: "RAM: " + root.memText + "    ·    Frei/verfügbar: "
                        + (root.memTotalGiB >= 0 ? root.memAvailableGiB.toFixed(1) + " GiB" : "–")
                    font.pixelSize: ramDetails.detailSize + 1
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                Rectangle {
                    width: ramDetails.usable; height: 12
                    radius: 6
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.17)
                    Rectangle {
                        width: parent.width * root.memoryFraction
                        height: parent.height
                        radius: parent.radius
                        color: Theme.primary
                    }
                }
                Text {
                    text: "Größte Prozesse nach RAM-Belegung (RSS)"
                    font.pixelSize: ramDetails.detailSize + 1
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                Text {
                    visible: root.topProcesses.length === 0
                    text: "Keine lesbaren Prozessdaten verfügbar"
                    font.pixelSize: ramDetails.detailSize
                    color: Theme.surfaceVariantText
                }
                Repeater {
                    model: root.topProcesses.length
                    Item {
                        required property int index
                        readonly property var proc: root.topProcesses[index]
                        width: ramDetails.usable
                        height: 36
                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 245
                            elide: Text.ElideRight
                            text: (index + 1) + ".  " + proc.name
                            font.pixelSize: ramDetails.detailSize
                            color: Theme.surfaceText
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 258
                            anchors.verticalCenter: parent.verticalCenter
                            width: 110
                            text: "PID " + proc.pid
                            font.pixelSize: ramDetails.detailSize - 1
                            color: Theme.surfaceVariantText
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: proc.rss_mib.toFixed(1) + " MiB"
                            font.pixelSize: ramDetails.detailSize
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                        }
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 3
                            radius: 1.5
                            color: Theme.withAlpha(Theme.surfaceVariantText, 0.09)
                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: parent.width * Math.min(1, proc.rss_mib / Math.max(1, root.topProcesses[0].rss_mib))
                                color: Theme.tertiary
                            }
                        }
                    }
                }
                Text {
                    width: ramDetails.usable
                    wrapMode: Text.WordWrap
                    text: "RSS zählt auch gemeinsam genutzten Speicher. Die einzelnen Prozesse dürfen nicht einfach zur RAM-Gesamtnutzung addiert werden. Aktualisierung etwa alle 10 Sekunden."
                    font.pixelSize: Math.max(12, ramDetails.detailSize - 1)
                    color: Theme.surfaceVariantText
                }
            }

            Column {
                id: diskDetails
                visible: root.activeView === "disk"
                width: parent.width
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingL
                spacing: Theme.spacingM
                readonly property int detailSize: Math.max(14, Theme.fontSizeMedium)
                readonly property real usable: width - leftPadding - rightPadding

                Text {
                    text: "Lokale eingehängte Dateisysteme"
                    font.pixelSize: diskDetails.detailSize + 1
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                Text {
                    visible: root.mounts.length === 0
                    text: "Keine lokalen Laufwerke gefunden"
                    font.pixelSize: diskDetails.detailSize
                    color: Theme.surfaceVariantText
                }
                Flickable {
                    id: volumeScroll
                    width: diskDetails.usable
                    height: Math.min(430, volumeRows.implicitHeight)
                    contentWidth: width
                    contentHeight: volumeRows.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: volumeRows
                        width: volumeScroll.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.mounts.length
                            Column {
                                required property int index
                                readonly property var volume: root.mounts[index]
                                width: volumeRows.width
                                spacing: 5
                                Text {
                                    width: parent.width
                                    elide: Text.ElideMiddle
                                    text: volume.mountpoint + "    (" + volume.fstype + ")"
                                    font.pixelSize: diskDetails.detailSize
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                                Rectangle {
                                    width: parent.width
                                    height: 9
                                    radius: 4
                                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.16)
                                    Rectangle {
                                        height: parent.height
                                        width: parent.width * Math.min(1, Math.max(0, volume.used_pct / 100))
                                        radius: parent.radius
                                        color: volume.used_pct > 90 ? Theme.warning : Theme.primary
                                    }
                                }
                                Text {
                                    width: parent.width
                                    text: volume.used_gib.toFixed(1) + " GiB belegt  ·  "
                                        + volume.free_gib.toFixed(1) + " GiB verfügbar  ·  "
                                        + volume.total_gib.toFixed(1) + " GiB gesamt (" + volume.used_pct.toFixed(0) + " %)"
                                    font.pixelSize: diskDetails.detailSize - 1
                                    color: Theme.surfaceVariantText
                                }
                                Item { width: 1; height: 5 }
                            }
                        }
                    }
                }
                Text {
                    visible: volumeScroll.contentHeight > volumeScroll.height
                    text: "Für weitere Laufwerke in der Liste scrollen"
                    font.pixelSize: Math.max(12, diskDetails.detailSize - 1)
                    color: Theme.surfaceVariantText
                }
                Text {
                    width: diskDetails.usable
                    wrapMode: Text.WordWrap
                    text: "Nur lokal eingehängte Laufwerke. Nicht eingehängte Datenträger und Netzlaufwerke werden nicht abgefragt; Aktualisierung etwa alle 10 Sekunden."
                    font.pixelSize: Math.max(12, diskDetails.detailSize - 1)
                    color: Theme.surfaceVariantText
                }
            }

            Column {
                id: powerDetails
                visible: root.activeView === "power"
                width: parent.width
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingL
                spacing: Theme.spacingM
                readonly property int detailSize: Math.max(14, Theme.fontSizeMedium)
                readonly property real usable: width - leftPadding - rightPadding

                Text {
                    width: powerDetails.usable
                    wrapMode: Text.WordWrap
                    text: root.powerSource + "  ·  Akku " + root.batteryPercentText
                        + "  ·  " + root.batteryRemainingText
                    font.pixelSize: powerDetails.detailSize + 3
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                Rectangle {
                    width: powerDetails.usable; height: 12
                    radius: 6
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.17)
                    Rectangle {
                        height: parent.height
                        width: parent.width * Math.min(1, Math.max(0,
                            (Number(root.battery.percent) || 0) / 100))
                        radius: parent.radius
                        color: Theme.primary
                    }
                }
                Text {
                    width: powerDetails.usable
                    wrapMode: Text.WordWrap
                    text: "Akku: " + (root.battery.status || "nicht verfügbar")
                        + (root.battery.charge_limit_pct !== null
                            && root.battery.charge_limit_pct !== undefined
                            ? "  ·  Ladeziel: " + root.battery.charge_limit_pct + " %"
                            : "  ·  Ladeziel: nicht auslesbar (Einstellung möglich)")
                    font.pixelSize: powerDetails.detailSize
                    color: Theme.surfaceVariantText
                }
                Text {
                    visible: root.battery.health_pct !== null && root.battery.health_pct !== undefined
                    text: "Akkugesundheit: " + Number(root.battery.health_pct).toFixed(0) + " % der Designkapazität"
                    font.pixelSize: powerDetails.detailSize
                    color: Theme.surfaceVariantText
                }
                Text {
                    text: "TLP-Profil: " + (root.displayProfile || "nicht verfügbar")
                        + (root.pendingProfile !== "" ? " (Umschaltung läuft …)" : "")
                    font.pixelSize: powerDetails.detailSize + 2
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                Row {
                    spacing: Theme.spacingS
                    Repeater {
                        model: ["balanced", "performance"]
                        Rectangle {
                            id: profileButton
                            required property string modelData
                            readonly property bool selected: root.displayProfile === modelData
                            width: 218
                            height: 42
                            radius: Theme.cornerRadius
                            color: selected ? Theme.withAlpha(Theme.primary, 0.20)
                                : Theme.withAlpha(Theme.surfaceVariantText, 0.08)
                            border.width: selected ? 1 : 0
                            border.color: Theme.primary
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                DankIcon {
                                    name: profileButton.modelData === "balanced" ? "ac_unit" : "local_fire_department"
                                    size: 20
                                    color: profileButton.modelData === "balanced" ? Theme.info : Theme.warning
                                }
                                Text {
                                    text: profileButton.modelData === "balanced" ? "Balanced" : "Performance"
                                    font.pixelSize: powerDetails.detailSize
                                    color: Theme.surfaceText
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: root.canChangeProfile && !profileButton.selected
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.toggleTlpProfile()
                            }
                        }
                    }
                }
                Text {
                    width: powerDetails.usable
                    wrapMode: Text.WordWrap
                    text: "Rechtsklick auf ❄️/🔥 in der Leiste: Balanced ↔ Performance. "
                        + "Netzteil und TLP-Profil sind unabhängig voneinander."
                    font.pixelSize: powerDetails.detailSize
                    color: Theme.surfaceVariantText
                }
                Text {
                    visible: !!root.tlpError
                    width: powerDetails.usable
                    wrapMode: Text.WordWrap
                    text: root.tlpError
                    font.pixelSize: powerDetails.detailSize
                    color: Theme.error
                }
                Text {
                    width: powerDetails.usable
                    text: "P-State-Obergrenze: " + (root.maxPerfPct >= 0
                        ? root.maxPerfPct.toFixed(0) + " %" : "nicht verfügbar")
                        + "  ·  CPU-Package: " + root.tempText
                    font.pixelSize: powerDetails.detailSize
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
