import QtQuick
import qs.Common

Column {
    id: core
    property int coreNumber: 1
    property real usage: 0
    property real mhz: 0
    property var samples: []
    property int fontSize: 13
    property int availableHeight: 28
    property color graphColor: Theme.widgetTextColor

    // Das Widget selbst ist so hoch wie die von DMS angebotene Fläche.
    // Keine fest verdrahteten 36 px mehr, die oben/unten überstehen.
    readonly property int textRowHeight: Math.max(10, Math.min(12, fontSize - 1))
    readonly property int graphHeight: Math.max(5, height - 2 * textRowHeight)

    width: 55
    height: availableHeight
    spacing: 0

    Text {
        width: parent.width
        height: core.textRowHeight
        color: Theme.widgetTextColor
        font.family: Theme.defaultMonoFontFamily
        font.pixelSize: Math.max(11, core.fontSize - 1)
        text: core.coreNumber + " " + Math.round(core.usage) + "%"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    Canvas {
        id: spark
        width: parent.width
        height: core.graphHeight
        antialiasing: true
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            const points = core.samples || [];
            if (points.length < 2)
                return;
            ctx.beginPath();
            ctx.strokeStyle = String(core.graphColor);
            ctx.lineWidth = 1.4;
            ctx.lineJoin = "round";
            for (let i = 0; i < points.length; i++) {
                const x = i * (width - 2) / Math.max(points.length - 1, 1) + 1;
                const n = Math.max(0, Math.min(100, Number(points[i]) || 0));
                const y = height - 1 - (n / 100) * (height - 2);
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            }
            ctx.stroke();
        }
    }

    Text {
        width: parent.width
        height: core.textRowHeight
        color: Theme.widgetTextColor
        font.family: Theme.defaultMonoFontFamily
        font.pixelSize: Math.max(11, core.fontSize - 1)
        text: core.mhz > 0 ? (core.mhz / 1000).toFixed(1) + "G" : "--G"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    onSamplesChanged: spark.requestPaint()
    onGraphColorChanged: spark.requestPaint()
}
