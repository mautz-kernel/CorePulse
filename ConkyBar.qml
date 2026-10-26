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
    property string activeView: "cpu" // cpu | ram | disk
    property var topProcesses: []
    property var mounts: []
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

    popoutWidth: activeView === "cpu" ? 940 : 700

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
                    onPressed: root.openDetail("cpu")
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
                    onPressed: root.openDetail("ram")
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
                    onPressed: root.openDetail("disk")
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
                    onPressed: root.openDetail("cpu")
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
                      : "CorePulse · Laufwerke"
            showCloseButton: true

            Row {
                id: detailTabs
                width: parent.width
                spacing: Theme.spacingS
                leftPadding: Theme.spacingM
                rightPadding: Theme.spacingM
                bottomPadding: Theme.spacingM

                Repeater {
                    model: ["cpu", "ram", "disk"]
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
                                : tab.modelData === "ram" ? "RAM" : "Laufwerke"
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
    }
}
