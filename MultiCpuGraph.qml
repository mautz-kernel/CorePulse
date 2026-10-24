import QtQuick
import qs.Common

// Ein Canvas für mehrere übereinander gezeichnete Verlaufskurven.
Canvas {
    id: graph
    property var series: [] // [{samples: [0..100], color: Theme.primary}, ...]
    property int maxSamples: 30

    implicitWidth: width
    implicitHeight: height
    antialiasing: true
    renderStrategy: Canvas.Cooperative
    onSeriesChanged: requestPaint()
    onMaxSamplesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        if (width < 4 || height < 4)
            return;
        const step = (width - 2) / Math.max(1, maxSamples - 1);
        for (let k = 0; k < series.length; k++) {
            const trace = series[k];
            if (!trace || !trace.samples || trace.samples.length < 2)
                continue;
            const vals = trace.samples;
            const startX = width - 1 - (vals.length - 1) * step;
            ctx.beginPath();
            ctx.lineJoin = "round";
            ctx.lineCap = "round";
            ctx.lineWidth = 1.8;
            ctx.strokeStyle = String(trace.color);
            for (let i = 0; i < vals.length; i++) {
                const value = Math.max(0, Math.min(100, Number(vals[i]) || 0));
                const x = startX + i * step;
                const y = height - 2 - (height - 4) * value / 100;
                if (i === 0)
                    ctx.moveTo(x, y);
                else
                    ctx.lineTo(x, y);
            }
            ctx.stroke();
        }
    }
}
