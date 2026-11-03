import QtQuick 2.9
import QtQuick.Controls 2.2

// GroupBox drawn as a Vibelight card: rounded surface, hairline border and a
// bold section heading. Drop-in replacement for GroupBox in SettingsView.
GroupBox {
    id: control

    padding: 16

    background: Rectangle {
        // Standard GroupBox trick: start the frame below the heading so the
        // title sits above the card instead of being drawn inside its border.
        y: control.topPadding - control.bottomPadding
        width: parent.width
        height: parent.height - control.topPadding + control.bottomPadding
        radius: Theme.radius
        color: Theme.card
        border.width: 1
        border.color: Theme.outline
    }

    label: Label {
        x: control.leftPadding
        width: control.availableWidth
        text: control.title
        font.bold: true
        font.family: Theme.fontFamily
        elide: Text.ElideRight
    }
}
