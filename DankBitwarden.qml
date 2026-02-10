import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

QtObject {
    id: root

    // Services & Settings
    property var pluginService: null
    property string trigger: ""
    property bool copyToClipboard: false

    // Data
    property var _passwords: []
    property string _prevPass: ""
    property var _historyData: []
    
    // Loading State
    property bool _loading: false
    property int _pendingLoads: 0
    
    // Detailed Item Cache (for TOTP checks)
    property var _itemDetails: ({}) 
    property var _itemCheckQueue: []
    property bool _itemCheckRunning: false

    signal itemsChanged

    Component.onCompleted: {
        if (!pluginService)
            return;
        trigger = pluginService.loadPluginData("dankBitwarden", "trigger", "[");
        copyToClipboard = pluginService.loadPluginData("dankBitwarden", "copyToClipboard", false);
        Qt.callLater(loadPasswords);
    }

    onTriggerChanged: {
        if (pluginService)
            pluginService.savePluginData("dankBitwarden", "trigger", trigger);
    }

    // --- Core Logic ---

    function loadPasswords() {
        if (_loading) return;
        _loading = true;
        _pendingLoads = 1;
        const process = passwordsProcessComponent.createObject(root);
        process.running = true;
    }

    function onPasswordsLoaded(data) {
        if (!data?.length)
            return;
        _passwords = data;

        _pendingLoads--;
        if (_pendingLoads <= 0) {
            _loading = false;
            itemsChanged();
        }
    }

    function syncPasswords() {
        const process = syncProcessComponent.createObject(root);
        process.running = true;
    }

    function normalizeForSearch(s) {
        const str = (s ?? "").toString().toLowerCase();
        return str.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    }

    function getItems(query) {
        const q = normalizeForSearch(query).trim();
        let results = [];

        for (let i = 0; i < _passwords.length; i++) {
            const pass = _passwords[i];

            const name = pass?.name ?? "";
            const folder = pass?.folder ?? "";
            const user = pass?.user ?? "";

            const hay = normalizeForSearch((folder ? folder + "/" : "") + name);

            if (q.length === 0 || hay.includes(q)) {
                results.push({
                    name: (folder ? folder + "/" : "") + name,
                    icon: "material:password",
                    comment: user,
                    action: "type:" + pass.id,
                    categories: ["Dank Bitwarden"],
                    _passName: name,
                    _passId: pass.id,
                    _passUser: user,
                    _passFolder: folder,
                    _sortKey: pass.id == _prevPass ? 0 : 1 
                });
            }
        }

        const syncItem = {
            name: "Sync",
            icon: "material:sync",
            action: "sync:",
            categories: ["Dank Bitwarden"],
            _passName: "sync"
        };

        // Sync item should be sorted like any other item once typing starts
        if (q.length !== 0 && "sync".includes(q)) {
            results.push(syncItem);
        }

        results.sort((a, b) => {
            if (a._sortKey !== b._sortKey)
                return a._sortKey - b._sortKey;
            return a._passName.localeCompare(b._passName);
        });

        // If length is zero then add sync item to the beginning
        // so user knows its an option
        if (q.length === 0) {
            results.unshift(syncItem);
        }

        return results.slice(0, 50);
    }

    // --- Execution & Actions ---

    function executeItem(item) {
        if (!item?.action) return;

        const actionParts = item.action.split(":");
        const actionType = actionParts[0];

        if (actionType === "sync") {
            syncPasswords();
            return;
        }

        if (actionType === "type") {
            if (copyToClipboard) {
                Quickshell.execDetached([
                    "sh", "-c",
                    "rbw get --field password '" + item._passId + "' | tr -d '\\r\\n' | dms cl copy -o"
                ]);
                ToastService.showInfo("DankBitwarden", "Copied password for " + item._passName + " to clipboard");
            } else {
                Quickshell.execDetached([
                    "sh", "-c",
                    "sleep 0.15; " +
                    "app_id=$(niri msg --json focused-window | jq -r '.app_id // empty'); " +
                    "if echo \"$app_id\" | grep -Eqi '(librewolf|firefox|chromium|chrome|brave|vivaldi|zen)'; then " +
                    "  rbw get --field username '" + item._passId + "' | tr -d '\\r\\n' | ydotool type -f -; " +
                    "  ydotool key 15:1 15:0; " + // Tab
                    "fi; " +
                    "rbw get --field password '" + item._passId + "' | ydotool type -f -"
                ]);
            }
        }
    }

    function copyItemField(item, field) {
        _prevPass = item._passId;
        Quickshell.execDetached(["sh", "-c", "rbw get --field '" + field + "' '" + item._passId + "' | tr -d '\\r\\n' | dms cl copy -o"]);
        ToastService.showInfo("DankBitwarden", "Copied " + field + " of " + item._passName + " to clipboard");
    }

    function copyItemUsername(item) {
        _prevPass = item._passId;
        Quickshell.execDetached(["sh", "-c", "rbw get --field username '" + item._passId + "' | tr -d '\\r\\n' | dms cl copy"]);
        ToastService.showInfo("DankBitwarden", "Copied username of " + item._passName + " to clipboard");
    }

    function typeItemField(item, field) {
        _prevPass = item._passId;
        Quickshell.execDetached([
            "sh", "-c",
            "dms ipc call spotlight close >/dev/null 2>&1; " +
            "sleep 0.15; " +
            "rbw get --field '" + field + "' '" + item._passId + "' | tr -d '\\r\\n' | ydotool type -f -"
        ]);
    }

    function showHistoryFn(item) {
        historyProcess._passId = item._passId;
        historyProcess._passName = item._passName;
        historyProcess._stdoutText = "";
        historyProcess.exec({
            command: ["rbw", "history", item._passId]
        });
    }

    property Component historyWindowComponent: Component {
        Window {
            id: historyWin
            width: 500
            height: 400
            title: "Password History: " + historyProcess._passName
            visible: true
            color: Theme.background || "#1E1E1E"

            Column {
                anchors.fill: parent
                
                // Header
                Rectangle {
                    width: parent.width
                    height: 50
                    color: "transparent"
                    
                    Text {
                        anchors.centerIn: parent
                        text: "History: " + historyProcess._passName
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
                    model: root._historyData
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
                                Quickshell.execDetached(["sh", "-c", "echo -n '" + modelData.password + "' | dms cl copy -o"]);
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
    }

    // --- Context Menu & Logic ---

    function getContextMenuActions(item) {
        if (!item || !item._passId)
            return [];
            
        const passId = item._passId;
        const details = _itemDetails[passId];

        // 1. Username: Known immediately from item data
        const showUsername = !!item._passUser;

        // 2. Password: Always show
        const showPassword = true;

        // 3. TOTP & History: requires checking details
        let showTotp = false;
        let showHistory = false;
        let checkingDetails = false;

        if (details) {
            showTotp = details.hasTotp;
            showHistory = details.hasHistory;
        } else {
            // Not loaded yet, queue it.
            Qt.callLater(ensureItemDetails, passId);
            checkingDetails = true; 
        }

        const actions = [];

        if (showUsername) {
            actions.push({
                icon: "content_copy",
                text: I18n.tr("Copy Username"),
                action: () => copyItemUsername(item)
            });
        }
        
        actions.push({
            icon: "content_copy",
            text: I18n.tr("Copy Password"),
            action: () => copyItemField(item, "password")
        });

        if (checkingDetails) {
             actions.push({
                icon: "material:sync",
                text: I18n.tr("Checking Details..."), // Changed from Checking TOTP
                action: () => {}
            });
        } else {
            if (showTotp) {
                actions.push({
                    icon: "content_copy",
                    text: I18n.tr("Copy TOTP"),
                    action: () => copyItemField(item, "totp")
                });
            }
            if (showHistory) {
                actions.push({
                    icon: "history",
                    text: I18n.tr("Show Password History"),
                    action: () => {
                        Quickshell.execDetached(["sh", "-c", "dms ipc call spotlight close >/dev/null 2>&1"]);
                        showHistoryFn(item);
                    }
                });
            }
        }
        
        // Add Type actions matching Copy actions
        if (showUsername) {
            actions.push({
                icon: "keyboard",
                text: I18n.tr("Type Username"),
                action: () => typeItemField(item, "username")
            });
        }

        actions.push({
            icon: "keyboard",
            text: I18n.tr("Type Password"),
            action: () => typeItemField(item, "password")
        });

        if (showTotp) {
            actions.push({
                icon: "keyboard",
                text: I18n.tr("Type TOTP"),
                action: () => typeItemField(item, "totp")
            });
        }

        return actions;
    }

    // --- Item Details Checking (Queue) ---

    function ensureItemDetails(passId) {
        if (!passId) return;
        if (_itemDetails[passId] !== undefined) return;
        
        // Prevent duplicate queueing
        for(let i=0; i<_itemCheckQueue.length; i++) {
            if (_itemCheckQueue[i] === passId) return;
        }

        _itemCheckQueue.push(passId);
        runNextItemCheck();
    }

    function runNextItemCheck() {
        if (_itemCheckRunning || _itemCheckQueue.length === 0)
            return;

        const nextId = _itemCheckQueue.shift();
        _itemCheckRunning = true;
        
        detailsCheckProcess._passId = nextId;
        detailsCheckProcess._stdoutText = "";
        
        // Check both TOTP field and History content
        detailsCheckProcess.exec({
            command: [
                "sh", "-c", 
                "rbw get --field totp '" + nextId + "' 2>/dev/null || true; " +
                "echo '___SEP___'; " +
                "rbw history '" + nextId + "' 2>/dev/null | head -n 1 || true"
            ]
        });
    }

    // --- Processes ---

    property Component syncProcessComponent: Component {
        Process {
            id: syncProcess
            running: false
            command: ["rbw", "sync"]
            onExited: exitCode => {
                if (exitCode === 0) {
                    loadPasswords();
                } else {
                    console.warn("[DankBitwarden] Failed to sync passwords from rbw, make sure it is installed and you are logged in", "exit:", exitCode);
                }
                syncProcess.destroy();
            }
        }
    }

    property Component passwordsProcessComponent: Component {
        Process {
            id: passwordsProcess
            running: false
            command: ["rbw", "list", "--raw"]

            stdout: StdioCollector {
                onStreamFinished: {
                    try {
                        const data = JSON.parse(text);
                        root.onPasswordsLoaded(data);
                    } catch (e) {
                        console.error("[DankBitwarden] Failed to parse passwords:", e);
                    }
                    passwordsProcess.destroy();
                }
            }

            onExited: exitCode => {
                if (exitCode !== 0) {
                    console.warn("[DankBitwarden] Failed to load passwords from rbw, make sure it is installed and you are logged in", "exit:", exitCode);
                    root._pendingLoads--;
                    if (root._pendingLoads <= 0)
                      root._loading = false;
                    passwordsProcess.destroy();
                }
            }
        }
    }

    property Process detailsCheckProcess: Process {
        id: detailsCheckProcess
        
        property string _passId: ""
        property string _stdoutText: ""

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                detailsCheckProcess._stdoutText = text;
            }
        }

        onExited: exitCode => {
            let details = { hasTotp: false, hasHistory: false };
            
            const parts = detailsCheckProcess._stdoutText.split("___SEP___");
            
            if (parts.length >= 1) {
                 const totpOut = parts[0].trim();
                 if (totpOut.length > 0) details.hasTotp = true;
            }
            
            if (parts.length >= 2) {
                 const histOut = parts[1].trim();
                 if (histOut.length > 0) details.hasHistory = true;
            }

            // Force update _itemDetails to trigger any potential bindings
            let newDetails = {};
            for (let k in root._itemDetails) {
                newDetails[k] = root._itemDetails[k];
            }
            newDetails[detailsCheckProcess._passId] = details;
            root._itemDetails = newDetails;

            root._itemCheckRunning = false;
            root.runNextItemCheck();
        }
    }

    property Process historyProcess: Process {
        id: historyProcess
        property string _passId: ""
        property string _passName: ""
        property string _stdoutText: ""
        
        running: false
        command: []
        
        stdout: StdioCollector {
            onStreamFinished: historyProcess._stdoutText = text
        }
        
        onExited: exitCode => {
            if (exitCode === 0) {
                const lines = _stdoutText.split("\n");
                let parsed = [];
                for(let i=0; i<lines.length; i++) {
                    const line = lines[i];
                    if(!line) continue;
                    const idx = line.indexOf(": ");
                    if(idx > -1) {
                        parsed.push({
                            date: line.substring(0, idx),
                            password: line.substring(idx + 2)
                        });
                    }
                }
                root._historyData = parsed;
                historyWindowComponent.createObject(root);
            } else {
                 ToastService.showInfo("DankBitwarden", "Failed to get history");
            }
        }
    }
}