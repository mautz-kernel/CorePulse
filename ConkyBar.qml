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

    popoutWidth: 455

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
                          mhz: Number(c.mhz) || 0, samples: h});
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
            memText = compactGiB(data.mem_used_gib) + "/" + compactGiB(data.mem_total_gib) + "G";
            diskText = compactGiB(data.disk_free_gib) + "G";
            tempText = (data.temps || []).length ? Math.round(data.temps[0].c) + "°C" : "--";
            maxFreqMhz = Number(data.policy_max_mhz) || 0;
            maxPerfPct = (data.intel_max_perf_pct === null || data.intel_max_perf_pct === undefined)
                ? -1 : Number(data.intel_max_perf_pct);
            acceptThermal(data.thermal);
            errorText = "";
            hasSample = true;
        } catch (e) {
            console.warn("ConkyBar: JSON-Lesefehler: " + e);
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
            onRead: line => console.warn("ConkyBar Collector: " + line)
        }
        onExited: exitCode => {
            root.errorText = "Collector beendet (" + exitCode + ")";
            console.warn("ConkyBar: " + root.errorText);
        }
    }

    // BasePill zeichnet den Hintergrund selbst (DMS-Theme, Transparenz, Radius).
    horizontalBarPill: Component {
        Row {
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
            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }
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
            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }
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
            Rectangle {
                width: 1; height: Math.min(20, root.graphHeight)
                color: Theme.widgetTextColor; opacity: 0.17
                anchors.verticalCenter: parent.verticalCenter
            }
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

    popoutContent: Component {
        PopoutComponent {
            headerText: "ConkyBar · CPU-Details"
            showCloseButton: true

            Column {
                id: details
                width: parent.width
                spacing: Theme.spacingXS
                leftPadding: Theme.spacingS
                rightPadding: Theme.spacingS
                bottomPadding: Theme.spacingS

                Text {
                    text: "8 logische CPUs · Verlauf 60 Sekunden"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
                Repeater {
                    model: root.threadData.length
                    Row {
                        property var cpu: root.threadData[index]
                        spacing: Theme.spacingS
                        height: 28
                        Text {
                            width: 53; height: parent.height
                            text: "CPU " + cpu.id
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            verticalAlignment: Text.AlignVCenter
                        }
                        Text {
                            width: 44; height: parent.height
                            text: Math.round(cpu.usage) + "%"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }
                        MultiCpuGraph {
                            width: 155; height: 22
                            anchors.verticalCenter: parent.verticalCenter
                            maxSamples: root.historyLength
                            series: [{samples: cpu.samples,
                                      color: root.coreColors[index % root.coreColors.length]}]
                        }
                        Text {
                            width: 85; height: parent.height
                            text: cpu.mhz > 0 ? (cpu.mhz / 1000).toFixed(2) + " GHz" : "-- GHz"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
                Rectangle {
                    width: parent.width - Theme.spacingM
                    height: 1
                    color: Theme.outline
                    opacity: 0.35
                }
                Text {
                    text: "Package: " + root.tempText + "  ·  Gesamt: " + Math.round(root.cpuTotal) + "%"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }
                Text {
                    text: root.maxFreqMhz > 0 ?
                        "Kernel-Taktlimit (ggf. TLP): " + (root.maxFreqMhz / 1000).toFixed(2) + " GHz" :
                        "Kernel-Taktlimit: nicht verfügbar"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
                Text {
                    visible: root.maxPerfPct >= 0
                    text: "Intel P-State-Leistungslimit: " + root.maxPerfPct.toFixed(0) + "%"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
                Text {
                    text: !root.thermalAvailable ?
                        "Thermal-Throttle-Zähler: nicht verfügbar" :
                        (root.throttleHotSamples > 0 ? "THERMAL THROTTLING erkannt!" :
                         "Thermal-Ereignisse seit Widgetstart: " + root.throttleEvents)
                    color: root.throttleHotSamples > 0 ? Theme.error : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: root.throttleHotSamples > 0 ? Font.Bold : Font.Normal
                }
            }
        }
    }
}
