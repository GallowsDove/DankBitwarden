import QtQuick
import QtQuick.Window
import Quickshell
import qs.Common
import qs.Services

Window {
    id: historyWin
    
    property string passName: ""
    property var historyData: []
    
    width: 500
    height: 400
    title: "Password History: " + passName
    visible: true
    color: Theme.background || "#1E1E1E"

    onClosing: historyWin.destroy()

    Column {
        anchors.fill: parent
        
        // Header
        Rectangle {
            width: parent.width
            height: 50
            color: "transparent"
            
            Text {
                anchors.centerIn: parent
                text: "History: " + historyWin.passName
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                font.bold: true
            }
            
            // Close Button
            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 10
                width: 30
                height: 30
                radius: 15
                color: closeArea.containsMouse ? Theme.surface : "transparent"
                
                Text {
                    anchors.centerIn: parent
                    text: "\ue5cd" // close
                    font.family: "Material Symbols Rounded"
                    font.pixelSize: 20
                    color: Theme.surfaceText
                }
                
                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: historyWin.close()
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.surfaceVariantText
                opacity: 0.2
            }
        }

        ListView {
            width: parent.width
            height: parent.height - 50
            model: historyWin.historyData
            clip: true
            
            delegate: Rectangle {
                width: parent.width
                height: 60
                color: rowArea.containsMouse ? Theme.surface : "transparent"
                
                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Quickshell.execDetached(["sh", "-c", "echo -n '" + modelData.password.replace(/'/g, "'\\''") + "' | dms cl copy -o"]);
                        ToastService.showInfo("DankBitwarden", "Copied old password");
                        historyWin.close();
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.surfaceVariantText
                    opacity: 0.2
                }
                
                Row {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 10
                    
                    // History Info
                    Column {
                        width: parent.width - 20 
                        anchors.verticalCenter: parent.verticalCenter
                        
                        Text { 
                            text: modelData.date
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                        Text { 
                            text: modelData.password
                            color: Theme.surfaceText
                            font.pixelSize: 14
                            width: parent.width
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
