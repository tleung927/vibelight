pragma Singleton
import QtQuick 2.9

// Vibelight design tokens. Every colour, radius and spacing used by the restyled
// views comes from here so the look can be tuned in one place (and so upstream
// QML merges only conflict on the lines that actually reference the theme).
QtObject {
    // Surfaces, darkest to lightest
    readonly property color bg:          "#0E1015"
    readonly property color surface:     "#151922"
    readonly property color card:        "#1B202B"
    readonly property color cardHover:   "#232A38"
    readonly property color outline:     "#2A3243"

    // Text
    readonly property color text:        "#E8ECF4"
    readonly property color textDim:     "#8B95A8"

    // Brand accent (violet to cyan)
    readonly property color accent:      "#8B7CFF"
    readonly property color accent2:     "#3DD6F5"

    // Status colours
    readonly property color online:      "#3DDC97"
    readonly property color offline:     "#FF6B6B"
    readonly property color locked:      "#FFC857"

    // Shape and motion
    readonly property int radius:        14
    readonly property int radiusSmall:   8
    readonly property int animFast:      120
    readonly property int animNormal:    200

    readonly property string brandName:  "Vibelight"
    readonly property string fontFamily: Qt.platform.os === "windows" ? "Segoe UI Variable Display" : ""
}
