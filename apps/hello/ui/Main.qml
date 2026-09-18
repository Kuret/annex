// The smallest complete Annex app, and the M2 proof.
//
// It exists to answer four questions on real hardware, which is why it is a
// deliberate app rather than a test fixture:
//
//   1. does the host load QML from the filesystem at all (no .rcc anywhere)
//   2. can an app import the shared library by relative path
//   3. does `signal close` reach the host and put the app away
//   4. does an open document draw over an app that is still loaded
//
// An app is a directory with a manifest and a QML entry point. That is the
// whole contract. No build step, no resource bundle, no registration.

import QtQuick 2.5
import "../../../lib/Style.js" as Style

Item {
    id: app
    anchors.fill: parent

    // The host connects to this; emitting it puts the app away. Same shape as
    // AppLoad, so an app written for that needs no change here.
    signal close

    // Called by the host before the app is unloaded. Somewhere to stop a timer
    // or flush state; optional.
    function unloading() {
        console.log("[hello] unloading")
    }

    // The host sets this after loading, so an app can find its own files
    // without knowing where it was installed.
    property string annexAppDir: ""

    Rectangle {
        anchors.fill: parent
        color: Style.paper

        Column {
            anchors.centerIn: parent
            width: parent.width - Style.margin * 2
            spacing: Style.gap * 2

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Style.ink
                font.pointSize: Style.titleSize
                text: "Hello from Annex"
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Style.muted
                font.pointSize: Style.bodySize
                text: "Loaded from the filesystem, with no resource bundle.\n\n" +
                      "Installed at:\n" + (app.annexAppDir || "(the host did not say)")
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Style.muted
                font.pointSize: Style.smallSize
                text: "Open a document from the library: it should cover this " +
                      "screen, and this screen should still be here when you " +
                      "close it."
            }
        }

        // Deliberately a plain Rectangle rather than a Button: the framework
        // has no component library yet, and the app should not need one to be
        // a complete app.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.margin * 2
            width: 320
            height: Style.buttonHeight
            color: closeArea.pressed ? Style.pressed : Style.paper
            border.width: 2
            border.color: Style.ink
            radius: 6

            Text {
                anchors.centerIn: parent
                color: Style.ink
                font.pointSize: Style.headingSize
                text: "Close"
            }

            MouseArea {
                id: closeArea
                anchors.fill: parent
                onClicked: app.close()
            }
        }
    }
}
