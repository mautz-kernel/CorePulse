import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: tile

    property string iconName: "memory"
    property string value: "--"
    property int tileHeight: 38

    height: tileHeight
    width: metricRow.implicitWidth + 16
    radius: 8
    color: Theme.widgetBaseBackgroundColor

    Row {
        id: metricRow
        anchors.centerIn: parent
        spacing: 6

        DankIcon {
            name: tile.iconName
            size: 18
            color: Theme.widgetIconColor
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: tile.value
            color: Theme.widgetTextColor
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 13
            font.bold: true
        }
    }
}
