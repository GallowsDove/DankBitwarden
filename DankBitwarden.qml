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
    
    // Loading State
    property bool _loading: false
    property int _pendingLoads: 0
    
    // Detailed Item Cache (for TOTP checks)
    property var _itemDetails: ({}) 

    signal itemsChanged

    property RbwClient rbwService: RbwClient {
        onPasswordsLoaded: data => root.onPasswordsLoaded(data)
        onPasswordLoadError: code => {
            console.warn("[DankBitwarden] Failed to load passwords from rbw", "exit:", code);
            root._pendingLoads--;
            if (root._pendingLoads <= 0) root._loading = false;
        }
        onSyncFinished: code => {
            if (code === 0) {
                root.loadPasswords();
            } else {
                console.warn("[DankBitwarden] Failed to sync passwords", "exit:", code);
            }
        }
        onDetailsLoaded: (passId, hasTotp, hasHistory) => {
            let details = { hasTotp: hasTotp, hasHistory: hasHistory };
            let newDetails = {};
            for (let k in root._itemDetails) {
                newDetails[k] = root._itemDetails[k];
            }
            newDetails[passId] = details;
            root._itemDetails = newDetails;
        }
        onHistoryReady: (passId, passName, historyData) => {
             historyWindowComponent.createObject(root, {
                 passName: passName,
                 historyData: historyData
             });
        }
        onHistoryError: passId => {
            ToastService.showInfo("DankBitwarden", "Failed to get history");
        }
    }

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
        rbwService.loadPasswords();
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
        rbwService.sync();
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
b
    property Component historyWindowComponent: Component {
        HistoryWindow {}
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
            // Not loaded yet, queue it. Use callLater to avoid binding loop.
            Qt.callLater(rbwService.ensureItemDetails, passId);
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
                text: I18n.tr("Loading..."),
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
                        rbwService.fetchHistory(item._passId, item._passName);
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

}