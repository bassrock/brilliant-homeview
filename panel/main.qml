// Brilliant HomeView: an Apple-style photo face for Brilliant smart-home panels
// (720x1280 portrait, Qt 5.15, eglfs), driven by Home Assistant.
//
// Brilliant's own switch-ui keeps running OFFSCREEN (systemd drop-in), so the
// cap-touch sliders and the Brilliant backend behave exactly as before; this app
// owns the screen and touchscreen. Everything home-specific lives in config.js.
//
// Kept deliberately light for the i.MX6: few bindings, a minute clock tick,
// glass panes that sample a pre-blurred image in a tiny shader, crossfading photos.
import QtQuick 2.15
import QtQuick.Window 2.15
import QtWebSockets 1.15
import "config.js" as Cfg

Window {
    id: root
    visible: true
    width: 720
    height: 1280
    color: "#000000"

    FontLoader { source: "fonts/Inter-300.ttf" }
    FontLoader { source: "fonts/Inter-500.ttf" }
    FontLoader { source: "fonts/Inter-600.ttf" }
    FontLoader { id: mdiFont; source: "fonts/mdi.ttf" }
    readonly property var icons: ({"lock":"F033E","lock-open-variant":"F0FC6","heart":"F02D1","image-outline":"F0976",
        "package-variant-closed":"F03D7","mailbox":"F06EE","truck-delivery":"F053E","washing-machine":"F072A","tumble-dryer":"F0917","check-circle":"F05E0","dishwasher":"F0AAC","garage-open":"F06DA","door-open":"F081C",
        "weather-fog":"F0591","weather-cloudy":"F0590","weather-partly-cloudy":"F0595","weather-sunny":"F0599","weather-night":"F0594",
        "weather-rainy":"F0597","weather-pouring":"F0596","weather-snowy":"F0598","weather-snowy-rainy":"F067F","weather-windy":"F059D",
        "weather-windy-variant":"F059E","weather-lightning":"F0593","weather-lightning-rainy":"F067E","weather-hail":"F0592"})
    function ic(n) { return String.fromCodePoint(parseInt(icons[n] || "F0590", 16)) }
    readonly property var cond: ({"fog":"Foggy","cloudy":"Cloudy","partlycloudy":"Partly Cloudy","sunny":"Sunny","clear-night":"Clear",
        "rainy":"Rain","pouring":"Heavy Rain","snowy":"Snow","snowy-rainy":"Snow","windy":"Windy","windy-variant":"Windy",
        "lightning":"Storms","lightning-rainy":"Storms","hail":"Hail"})
    function condIcon(c) { return cond[c] ? "weather-" + ({"partlycloudy":"partly-cloudy","clear-night":"night"}[c] || c) : "weather-cloudy" }

    // ------------------------------------------------------------ configuration (config.js)
    function cfg(name, fallback) { return Cfg[name] !== undefined ? Cfg[name] : fallback }
    readonly property string weatherEntity: cfg("WEATHER", "weather.forecast_home")
    readonly property var locks: cfg("LOCKS", [])                       // [[entity_id, "Name"], ...]
    readonly property var delivery: cfg("DELIVERY", {})                 // see config.example.js
    readonly property var arrivingSensors: delivery.arriving || []
    readonly property var doneAlerts: cfg("DONE", [])                   // [{entity, states, icon, text}]
    readonly property bool clock24: cfg("CLOCK_24H", false)
    // Optional night window {start: 22, end: 7} (hours, decimals ok): the screen goes dark
    // (Brilliant's own screen schedule is set to match); a tap wakes it for WAKE_MS.
    readonly property var nightCfg: cfg("NIGHT", null)
    readonly property int wakeMs: cfg("WAKE_MS", 30000)
    // The immich_frames feed for this panel (sensor.<feed>_date, button.<feed>_next, ...).
    readonly property string feed: cfg("FEED", "")
    readonly property string photoVersionEntity: cfg("PHOTO_VERSION", "")
    readonly property var sliderNames: cfg("SLIDERS", ["Slider 1", "Slider 2", "Slider 3"])
    // The HA lights each physical slider dims. Brilliant's hidden UI stops forwarding
    // slider touches to Linux once it goes idle, so the on-screen indicator follows
    // these lights' real brightness (plus the raw touch stream whenever it does report).
    readonly property var sliderLights: cfg("SLIDER_LIGHTS", [])
    readonly property var ents: {
        var e = [weatherEntity]
        if (photoVersionEntity) e.push(photoVersionEntity)
        if (feed) e.push("sensor." + feed + "_date", "sensor." + feed + "_location", "sensor." + feed + "_favourite")
        var add = function (x) { if (x && e.indexOf(x) < 0) e.push(x) }
        add(delivery.box_flag); add(delivery.mail_flag); add(delivery.box_lock)
        for (var i = 0; i < locks.length; i++) add(locks[i][0])
        for (var j = 0; j < arrivingSensors.length; j++) add(arrivingSensors[j])
        for (var k = 0; k < sliderLights.length; k++) add(sliderLights[k])
        for (var d = 0; d < doneAlerts.length; d++) add(doneAlerts[d].entity)
        return e
    }

    // ------------------------------------------------------------ state (plain values, recomputed on change)
    property var st: ({})
    property string clockText: "--:--"
    property string dateText: ""
    property string wxText: ""
    property string wxIcon: "weather-cloudy"
    property string capDate: "Memories"
    property string capSub: "From Immich"
    property bool capFav: false
    property string photoVer: "0"
    property var chips: []          // [{icon, color, text, act}]
    property var openLocks: []
    property string boxLock: "unknown"
    property bool boxInside: false
    property string card: ""        // "" | "locks" | "box"
    function call(domain, service, data) {
        ws.sendTextMessage(JSON.stringify({ id: ++msgId, type: "call_service", domain: domain, service: service, service_data: data }))
    }
    function lockId(name) { for (var i = 0; i < locks.length; i++) if (locks[i][1] === name) return locks[i][0]; return "" }

    function v(id) { var x = st[id]; return x ? x.s : undefined }
    function at(id, k) { var x = st[id]; return x && x.a ? x.a[k] : undefined }

    function recompute() {
        var c = v(weatherEntity) || ""
        var t = parseFloat(at(weatherEntity, "temperature"))
        wxText = (isNaN(t) ? "--" : Math.round(t)) + "°  " + (cond[c] || "")
        wxIcon = condIcon(c)
        var d = v("sensor." + feed + "_date") || ""
        var m = d.match(/^(\d+) ([A-Za-z]+), (\d+)$/)
        capDate = m ? m[2] + " " + m[1] + ", " + m[3] : (d && d !== "unknown" ? d : "Memories")
        var loc = v("sensor." + feed + "_location") || ""
        capSub = loc && loc !== "unknown" ? loc.split(",").slice(0, 2).join(",") : "From Immich"
        capFav = v("sensor." + feed + "_favourite") === "Yes"
        photoVer = v(photoVersionEntity) || photoVer

        var out = []
        var open = []
        for (var i = 0; i < locks.length; i++) {
            var s = v(locks[i][0]); if (!s || s === "unavailable" || s === "unknown") continue
            if (s !== "locked") open.push(locks[i][1])
        }
        if (open.length) out.push({ icon: "lock-open-variant", color: "#FF9F0A", act: "locks", text: open.length === 1 ? open[0] + " unlocked" : open.length + " doors unlocked" })
        openLocks = open
        var arriving = 0
        for (var j = 0; j < arrivingSensors.length; j++) arriving += parseFloat(v(arrivingSensors[j])) || 0
        var hasBox = !!delivery.box_lock
        boxInside = !!delivery.box_flag && v(delivery.box_flag) === "on"
        boxLock = hasBox ? (v(delivery.box_lock) || "unknown") : "unknown"
        if (boxInside) out.push({ icon: "package-variant-closed", color: "#FFB340", act: hasBox ? "box" : "", text: delivery.box_text || "Package waiting" })
        else if (delivery.mail_flag && v(delivery.mail_flag) === "on") out.push({ icon: "mailbox", color: "#64D2FF", act: "", text: "Mail is here" })
        else if (arriving > 0) out.push({ icon: "truck-delivery", color: "#64D2FF", act: hasBox ? "box" : "", text: arriving + (arriving === 1 ? " delivery" : " deliveries") + " today" })
        for (var d = 0; d < doneAlerts.length; d++) {
            var al = doneAlerts[d]
            if ((al.states || ["on"]).indexOf(v(al.entity)) >= 0) out.push({ icon: al.icon || "check-circle", color: al.color || "#30D158", text: al.text })
        }
        if (JSON.stringify(out) !== JSON.stringify(chips)) chips = out
    }

    function tick() {
        var n = new Date()
        var h = n.getHours() % 12 || 12, mi = n.getMinutes()
        if (clock24) h = n.getHours()
        clockText = h + ":" + (mi < 10 ? "0" : "") + mi
        dateText = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][n.getDay()] + ", " +
                   ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][n.getMonth()] +
                   " " + n.getDate()
        minute.interval = (60 - n.getSeconds()) * 1000 + 50
        minute.restart()
    }
    Timer { id: minute; repeat: false; onTriggered: root.tick() }
    Component.onCompleted: tick()

    // ------------------------------------------------------------ HA websocket
    property int msgId: 1
    WebSocket {
        id: ws
        url: Cfg.WS
        active: true
        onStatusChanged: if (status === WebSocket.Error || status === WebSocket.Closed) reconnect.restart()
        onTextMessageReceived: {
            var m = JSON.parse(message)
            if (m.type === "auth_required") ws.sendTextMessage(JSON.stringify({ type: "auth", access_token: Cfg.TOKEN }))
            else if (m.type === "auth_ok") ws.sendTextMessage(JSON.stringify({ id: ++root.msgId, type: "subscribe_entities", entity_ids: root.ents }))
            else if (m.type === "event" && m.event) root.applyEvent(m.event)
        }
    }
    Timer { id: reconnect; interval: 5000; onTriggered: { ws.active = false; ws.active = true } }

    function applyEvent(ev) {
        var k
        if (ev.a) for (k in ev.a) st[k] = { s: ev.a[k].s, a: ev.a[k].a || {} }
        if (ev.c) for (k in ev.c) {
            var cur = st[k] || { s: undefined, a: {} }, ch = ev.c[k]
            var wasOn = cur.s, wasBri = cur.a ? cur.a.brightness : undefined
            if (ch["+"]) {
                if (ch["+"].s !== undefined) cur.s = ch["+"].s
                if (ch["+"].a) for (var ak in ch["+"].a) cur.a[ak] = ch["+"].a[ak]
            }
            st[k] = cur
            var li = sliderLights.indexOf(k)
            if (li >= 0 && (cur.s !== wasOn || cur.a.brightness !== wasBri) && !sliderActive && Date.now() - lastFinger > 2000) {
                sliderIdx = li
                sliderLevel = cur.s === "on" ? Math.round((cur.a.brightness || 255) * 100 / 255) : 0
                hudLinger.restart()
            }
        }
        recompute()
    }

    // ------------------------------------------------------------ photos (crossfade)
    function photo(n) { return Cfg.PHOTO + "/" + n + ".jpg?v=" + photoVer }
    property bool frontA: true
    readonly property bool faceHidden: hudLayer.opacity === 1 || screenBlack
    onPhotoVerChanged: (frontA ? imgB : imgA).source = photo("full")
    Image { id: imgA; visible: !root.faceHidden; anchors.fill: parent; cache: false; asynchronous: true; fillMode: Image.PreserveAspectCrop
            opacity: root.frontA ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 900 } }
            onStatusChanged: if (status === Image.Ready && !root.frontA) { root.frontA = true; frost.source = root.photo("frost") } }
    Image { id: imgB; visible: !root.faceHidden; anchors.fill: parent; cache: false; asynchronous: true; fillMode: Image.PreserveAspectCrop
            opacity: root.frontA ? 0 : 1; Behavior on opacity { NumberAnimation { duration: 900 } }
            onStatusChanged: if (status === Image.Ready && root.frontA) { root.frontA = false; frost.source = root.photo("frost") } }
    Image { id: frost; width: 720; height: 1280; cache: false; asynchronous: true; opacity: 0 }

    // ------------------------------------------------------------ components
    component Glass: ShaderEffect {
        property variant src: frost
        property real radius: 46
        property point origin: Qt.point(x, y)
        property size sz: Qt.size(width, height)
        fragmentShader: "
            varying highp vec2 qt_TexCoord0;
            uniform sampler2D src;
            uniform lowp float qt_Opacity;
            uniform highp float radius;
            uniform highp vec2 origin;
            uniform highp vec2 sz;
            void main() {
                highp vec2 p = qt_TexCoord0 * sz;
                lowp vec3 c = mix(texture2D(src, (origin + p) / vec2(720.0, 1280.0)).rgb, vec3(1.0), 0.16);
                highp vec2 q = abs(p - sz * 0.5) - (sz * 0.5 - vec2(radius));
                highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                lowp float al = clamp(0.5 - d, 0.0, 1.0) * qt_Opacity;
                lowp float edge = clamp(1.0 - abs(d + 0.75), 0.0, 1.0) * 0.30;
                gl_FragColor = vec4(mix(c, vec3(1.0), edge) * al, al);
            }"
    }
    component T: Text { font.family: "Inter"; color: "white"; font.pixelSize: 28; font.weight: Font.Medium }
    component Ico: Text { property string name: ""; text: root.ic(name); font.family: mdiFont.name; font.pixelSize: 40; color: "white" }

    // ------------------------------------------------------------ face
    Column {
        visible: !root.faceHidden
        x: 50; y: 64
        T { text: root.dateText; font.pixelSize: 38; opacity: 0.94 }
        T { text: root.clockText; font.pixelSize: 236; font.weight: Font.Light; font.letterSpacing: -10; x: -10; height: 250 }
        Row { spacing: 16
            Ico { name: root.wxIcon; font.pixelSize: 48; anchors.verticalCenter: parent.verticalCenter }
            T { text: root.wxText; font.pixelSize: 40; anchors.verticalCenter: parent.verticalCenter } }
    }

    // Only what needs attention right now; nothing at all when all is well.
    Column {
        id: chipCol
        visible: !root.faceHidden
        x: 40
        anchors.bottom: cap.top
        anchors.bottomMargin: 20
        spacing: 16
        Repeater {
            model: root.chips
            Item {
                id: chip
                width: chipRow.implicitWidth + 72; height: 96
                Glass { width: parent.width; height: parent.height; radius: 48
                        origin: Qt.point(chipCol.x + chip.x, chipCol.y + chip.y) }
                Row { id: chipRow; anchors.centerIn: parent; spacing: 16
                    Ico { name: modelData.icon; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                    T { text: modelData.text; font.pixelSize: 32; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter } }
                MouseArea { anchors.fill: parent; enabled: !!modelData.act; onClicked: { root.card = modelData.act; cardTimer.restart() } }
            }
        }
    }

    Item {
        id: cap
        visible: !root.faceHidden
        x: 40; width: Math.min(640, capRow.implicitWidth + 80); height: 116
        anchors.bottom: parent.bottom; anchors.bottomMargin: 44
        Glass { width: parent.width; height: parent.height; radius: 58; origin: Qt.point(cap.x, cap.y) }
        MouseArea { anchors.fill: parent; enabled: root.feed !== ""; onClicked: root.call("button", "press", { entity_id: "button." + root.feed + "_next" }) }
        Row { id: capRow; anchors.verticalCenter: parent.verticalCenter; x: 36; spacing: 18
            Ico { name: root.capFav ? "heart" : "image-outline"; color: root.capFav ? "#FF6482" : "white"; anchors.verticalCenter: parent.verticalCenter }
            Column { anchors.verticalCenter: parent.verticalCenter
                T { text: root.capDate; font.pixelSize: 30; font.weight: Font.DemiBold; width: Math.min(implicitWidth, 520); elide: Text.ElideRight }
                T { text: root.capSub; font.pixelSize: 22; opacity: 0.82; width: Math.min(implicitWidth, 520); elide: Text.ElideRight } } }
    }

    // ------------------------------------------------------------ action card (tap a chip)
    Timer { id: cardTimer; interval: 20000; onTriggered: root.card = "" }
    component Btn: Rectangle {
        property string label: ""
        property bool lit: false
        signal tapped()
        signal held()
        height: 96; radius: 48; color: lit ? "#EDFFFFFF" : "#29FFFFFF"; border.width: 1; border.color: "#40FFFFFF"
        T { anchors.centerIn: parent; text: parent.label; font.pixelSize: 30; font.weight: Font.DemiBold; color: parent.lit ? "#1c1c1e" : "white" }
        MouseArea { anchors.fill: parent; pressAndHoldInterval: 700
            onClicked: { parent.tapped(); cardTimer.restart() }
            onPressAndHold: { parent.held(); cardTimer.restart() } }
    }
    Item {
        anchors.fill: parent
        visible: root.card !== ""
        Rectangle { anchors.fill: parent; color: "#8C000000" }
        MouseArea { anchors.fill: parent; onClicked: root.card = "" }
        Item {
            id: cardBox
            x: 32; width: 656; height: cardCol.implicitHeight + 72
            anchors.verticalCenter: parent.verticalCenter
            Glass { width: parent.width; height: parent.height; radius: 52; origin: Qt.point(cardBox.x, cardBox.y) }
            MouseArea { anchors.fill: parent }
            Column {
                id: cardCol
                x: 36; y: 36; width: parent.width - 72; spacing: 18
                T { text: root.card === "locks" ? "Doors" : (root.delivery.box_name || "Package Box"); font.pixelSize: 44; font.weight: Font.DemiBold }
                T { width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 26; opacity: 0.85
                    text: root.card === "locks" ? (root.openLocks.length ? root.openLocks.join(", ") + (root.openLocks.length === 1 ? " is" : " are") + " unlocked" : "All doors are locked")
                          : (root.boxInside ? "A package is waiting. Box is " + root.boxLock + "." : "Box is " + root.boxLock + ".") }
                Repeater { model: root.card === "locks" ? root.openLocks : []
                    Btn { width: cardCol.width; label: "Lock " + modelData; onTapped: root.call("lock", "lock", { entity_id: root.lockId(modelData) }) } }
                Btn { visible: root.card === "locks" && root.openLocks.length > 1; width: cardCol.width; label: "Lock All Doors"
                      onTapped: root.call("lock", "lock", { entity_id: root.locks.map(function (l) { return l[0] }) }) }
                Btn { visible: root.card === "box"; width: cardCol.width; label: "Lock Box"; lit: root.boxLock === "locked"
                      onTapped: root.call("lock", "lock", { entity_id: root.delivery.box_lock }) }
                Btn { visible: root.card === "box"; width: cardCol.width; label: "Hold to Unlock Box"; lit: root.boxLock === "unlocked"
                      onHeld: root.call("lock", "unlock", { entity_id: root.delivery.box_lock }) }
                Btn { visible: root.card === "box" && root.boxInside && !!root.delivery.picked_up_script; width: cardCol.width; label: "Mark Picked Up"
                      onTapped: root.call("script", "turn_on", { entity_id: root.delivery.picked_up_script }) }
                Btn { width: cardCol.width; label: "Done"; onTapped: root.card = "" }
            }
        }
    }

    // ------------------------------------------------------------ physical slider indicator
    // hv_sliders.py long-polls the cap-touch state; Brilliant's hidden UI still does the dimming.
    property bool sliderActive: false
    property real lastFinger: 0
    property int sliderIdx: 0
    property int sliderLevel: 0
    property bool hudShown: sliderActive || hudLinger.running
    Timer { id: hudLinger; interval: 1800 }
    onSliderActiveChanged: if (!sliderActive) hudLinger.restart()
    // hv_sliders.py streams finger position over one persistent local WebSocket (~30/s).
    WebSocket {
        id: sliderWs
        url: "ws://127.0.0.1:8765/ws"
        active: true
        onTextMessageReceived: {
            try {
                var r = JSON.parse(message)
                root.sliderIdx = r.slider; root.sliderLevel = r.level; root.sliderActive = r.active
                if (r.active) root.lastFinger = Date.now()
            } catch (e) {}
        }
        onStatusChanged: if (status === WebSocket.Error || status === WebSocket.Closed) sliderRetry.restart()
    }
    Timer { id: sliderRetry; interval: 3000; onTriggered: { sliderWs.active = false; sliderWs.active = true } }


    // Opaque, cheap layer: a pre-darkened photo + plain card. While it's fully up the face
    // underneath isn't drawn at all, so each slider frame is a couple of quads.
    Item {
        id: hudLayer
        anchors.fill: parent
        opacity: root.hudShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
        Image { anchors.fill: parent; source: root.photo("soft"); cache: false; asynchronous: true }
        Rectangle { anchors.fill: parent; color: "#59000000"; visible: root.nightActive }
        Rectangle {
            id: hud
            width: 320; height: 680; radius: 64
            anchors.centerIn: parent
            color: "#38FFFFFF"; border.width: 1; border.color: "#4DFFFFFF"
            T { anchors.horizontalCenter: parent.horizontalCenter; y: 38; width: 280; horizontalAlignment: Text.AlignHCenter
                text: root.sliderNames[root.sliderIdx] || ("Slider " + (root.sliderIdx + 1))
                font.pixelSize: 32; font.weight: Font.DemiBold; elide: Text.ElideRight }
            Rectangle {
                x: 85; y: 104; width: 150; height: 460; radius: 48; color: "#40FFFFFF"
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Math.max(parent.radius * 2 * (root.sliderLevel > 0), parent.height * root.sliderLevel / 100)
                            radius: 48; color: "#F2FFFFFF"; visible: root.sliderLevel > 0 }
            }
            T { anchors.horizontalCenter: parent.horizontalCenter; y: 588; text: root.sliderLevel + "%"; font.pixelSize: 52; font.weight: Font.DemiBold }
        }
    }

    // ------------------------------------------------------------ night mode
    property bool nightWindow: false
    property real wakeUntil: 0
    readonly property bool nightActive: nightWindow
    property bool screenBlack: false
    function evalNight() {
        var n = new Date(), h = n.getHours() + n.getMinutes() / 60
        var w = false
        if (nightCfg) w = nightCfg.start > nightCfg.end ? (h >= nightCfg.start || h < nightCfg.end) : (h >= nightCfg.start && h < nightCfg.end)
        nightWindow = w
        var black = w && Date.now() >= wakeUntil && !hudShown
        if (black !== screenBlack) { screenBlack = black; screenMode() }
    }
    // Night mode is enforced by Brilliant itself: the helper rewrites Brilliant's screen
    // schedule (in UTC) to our day window, plus a short window when woken at night.
    function screenMode() {
        if (!nightCfg) return
        var mode = !nightWindow ? "day" : (screenBlack ? "night" : "wake")
        var left = Math.max(5, Math.round((wakeUntil - Date.now()) / 1000))
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:8765/screen?mode=" + mode + "&start=" + nightCfg.start + "&end=" + nightCfg.end +
               "&off=" + (-new Date().getTimezoneOffset()) + "&wake=" + left)
        x.send()
    }
    function wake(ms) { wakeUntil = Date.now() + ms; evalNight(); screenMode(); nightWake.interval = ms + 200; nightWake.restart() }
    // Re-assert the screen state every tick (and at start): the helper outlives app restarts.
    Timer { id: nightTick; interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: { root.evalNight(); root.screenMode() } }
    Timer { id: nightWake; repeat: false; onTriggered: root.evalNight() }
    onHudShownChanged: { if (hudShown && nightWindow) wake(4000); else evalNight() }

    // Black, and it swallows the waking tap so nothing underneath fires by accident.
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: root.screenBlack
        z: 2000
        MouseArea { anchors.fill: parent; onPressed: root.wake(root.wakeMs) }
    }
    // Any touch counts as activity at night (doesn't consume the event).
    MouseArea { anchors.fill: parent; z: 1999; enabled: root.nightWindow && !root.screenBlack; propagateComposedEvents: true
                onPressed: { root.wake(root.wakeMs); mouse.accepted = false } }
}
