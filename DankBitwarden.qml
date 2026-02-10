import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

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

        // 3. TOTP: requires checking details
        let showTotp = false;
        let checkingTotp = false;

        if (details) {
            showTotp = details.hasTotp;
        } else {
            // Not loaded yet, queue it.
            ensureItemDetails(passId);
            checkingTotp = true; 
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

        if (checkingTotp) {
             actions.push({
                icon: "material:sync",
                text: I18n.tr("Checking TOTP..."),
                action: () => {} // No-op
            });
        } else if (showTotp) {
            actions.push({
                icon: "content_copy",
                text: I18n.tr("Copy TOTP"),
                action: () => copyItemField(item, "totp")
            });
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
        
        // Use field check which is more reliable for existence than raw JSON
        detailsCheckProcess.exec({
            command: ["rbw", "get", "--field", "totp", nextId]
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
            let details = { hasTotp: false };
            
            if (exitCode === 0) {
                const output = detailsCheckProcess._stdoutText.trim();
                if (output.length > 0) {
                    details.hasTotp = true;
                }
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
}