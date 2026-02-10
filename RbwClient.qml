import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

QtObject {
    id: client

    // Signals
    signal passwordsLoaded(var data)
    signal passwordLoadError(int code)
    signal syncFinished(int code)
    
    // detailsLoaded(passId, hasTotp, hasHistory)
    signal detailsLoaded(string passId, bool hasTotp, bool hasHistory)
    
    // historyReady(passId, string passName, var historyData)
    signal historyReady(string passId, string passName, var historyData)
    signal historyError(string passId)

    // Properties for state management regarding queue
    property var _itemCheckQueue: []
    property bool _itemCheckRunning: false

    // --- Public API ---

    function loadPasswords() {
        const process = passwordsProcessComponent.createObject(client);
        process.running = true;
    }

    function sync() {
        const process = syncProcessComponent.createObject(client);
        process.running = true;
    }

    // Queue a check for details (TOTP/History existence)
    function ensureItemDetails(passId) {
        if (!passId) return;
        
        // Check if already queued
        for(let i=0; i<_itemCheckQueue.length; i++) {
            if (_itemCheckQueue[i] === passId) return;
        }

        _itemCheckQueue.push(passId);
        runNextItemCheck();
    }

    function fetchHistory(passId, passName) {
        historyProcess._passId = passId;
        historyProcess._passName = passName;
        historyProcess._stdoutText = "";
        historyProcess.exec({
            command: ["rbw", "history", passId]
        });
    }

    // --- Internal Logic ---

    function runNextItemCheck() {
        if (_itemCheckRunning || _itemCheckQueue.length === 0)
            return;

        const nextId = _itemCheckQueue.shift();
        _itemCheckRunning = true;
        
        detailsCheckProcess._passId = nextId;
        detailsCheckProcess._stdoutText = "";
        
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
                client.syncFinished(exitCode);
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
                        client.passwordsLoaded(data);
                    } catch (e) {
                        console.error("[DankBitwarden] Failed to parse passwords:", e);
                        // Maybe signal error?
                    }
                    passwordsProcess.destroy();
                }
            }

            onExited: exitCode => {
                if (exitCode !== 0) {
                    client.passwordLoadError(exitCode);
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
            let hasTotp = false;
            let hasHistory = false;
            
            const parts = detailsCheckProcess._stdoutText.split("___SEP___");
            
            if (parts.length >= 1) {
                 const totpOut = parts[0].trim();
                 if (totpOut.length > 0) hasTotp = true;
            }
            
            if (parts.length >= 2) {
                 const histOut = parts[1].trim();
                 if (histOut.length > 0) hasHistory = true;
            }

            client.detailsLoaded(detailsCheckProcess._passId, hasTotp, hasHistory);

            client._itemCheckRunning = false;
            client.runNextItemCheck();
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
                client.historyReady(_passId, _passName, parsed);
            } else {
                 client.historyError(_passId);
            }
        }
    }
}
