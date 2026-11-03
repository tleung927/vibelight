import QtQuick 2.0
import QtQuick.Controls 2.2

ItemDelegate {
    id: control
    property GridView grid

    highlighted: grid.activeFocus && grid.currentItem === this

    // Vibelight card: rounded surface, accent ring when focused, gentle lift on hover
    scale: (highlighted || hovered) ? 1.03 : 1.0
    Behavior on scale { NumberAnimation { duration: Theme.animFast; easing.type: Easing.OutCubic } }

    background: Rectangle {
        radius: Theme.radius
        color: (control.highlighted || control.hovered) ? Theme.cardHover : Theme.card
        border.width: control.highlighted ? 2 : 1
        border.color: control.highlighted ? Theme.accent : Theme.outline

        Behavior on color { ColorAnimation { duration: Theme.animFast } }
    }

    Keys.onLeftPressed: {
        grid.moveCurrentIndexLeft()
    }
    Keys.onRightPressed: {
        grid.moveCurrentIndexRight()
    }
    Keys.onDownPressed: {
        grid.moveCurrentIndexDown()
    }
    Keys.onUpPressed: {
        grid.moveCurrentIndexUp()

        // If we've reached the top of the grid, move focus to the toolbar
        if (grid.currentItem === this) {
            nextItemInFocusChain(false).forceActiveFocus(Qt.TabFocus)
        }
    }
    Keys.onReturnPressed: {
        clicked()
    }
    Keys.onEnterPressed: {
        clicked()
    }
}
