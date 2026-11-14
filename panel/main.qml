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
        "weather-windy-variant":"F059E","weather-lightning":"F0593","weather-lightning-rainy":"F067E","weather-hail":"F0592",
        "play":"F040A","pause":"F03E4","skip-next":"F04AD","skip-previous":"F04AE","volume-high":"F057E","volume-minus":"F075E",
        "volume-plus":"F075D","music":"F075A","television-play":"F0ECF","speaker":"F04C3"})
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
    // Sliders Brilliant doesn't drive (unassigned in the Brilliant app) can be driven by
    // HomeView itself: index-aligned with SLIDERS, e.g. [null, {entity: "light.x"},
    // {entity: "fan.y", steps: [0, 33, 66, 100]}]. Lights dim 0-100; fans snap to steps.
    readonly property var sliderCtl: cfg("SLIDER_CONTROL", [])
    function ctlFor(i) { return (i < sliderNames.length && sliderCtl[i] && sliderCtl[i].entity) ? sliderCtl[i] : null }
    function sliderEnt(i) { var c = ctlFor(i); return c ? c.entity : (sliderLights[i] || "") }
    // Now Playing: media players for this room, in priority order (first one playing wins).
    readonly property var mediaPlayers: cfg("MEDIA", [])
    readonly property string haHttp: cfg("HTTP", String(Cfg.WS).replace(/^ws/, "http").replace(/\/api\/websocket$/, ""))
    readonly property var ents: {
        var e = [weatherEntity]
        if (photoVersionEntity) e.push(photoVersionEntity)
        if (feed) e.push("sensor." + feed + "_date", "sensor." + feed + "_location", "sensor." + feed + "_favourite")
        var add = function (x) { if (x && e.indexOf(x) < 0) e.push(x) }
        add(delivery.box_flag); add(delivery.mail_flag); add(delivery.box_lock)
        for (var i = 0; i < locks.length; i++) add(locks[i][0])
        for (var j = 0; j < arrivingSensors.length; j++) add(arrivingSensors[j])
        for (var k = 0; k < sliderLights.length; k++) add(sliderLights[k])
        for (var q = 0; q < sliderCtl.length; q++) if (sliderCtl[q]) add(sliderCtl[q].entity)
        for (var mp = 0; mp < mediaPlayers.length; mp++) add(mediaPlayers[mp])
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
    property string card: ""        // "" | "locks" | "box" | "media"
    property var np: null           // the room's now-playing media (see recompute)
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

        var best = null, bestScore = 0
        for (var p = 0; p < mediaPlayers.length; p++) {
            var me = mediaPlayers[p], ms = v(me)
            var title = at(me, "media_title") || ""
            var score = ms === "playing" ? 2 : (ms === "paused" ? 1 : 0)
            if (score > bestScore && (title || at(me, "app_name"))) { best = me; bestScore = score }
        }
        var n = null
        if (best) {
            var pic = at(best, "entity_picture") || ""
            var artist = at(best, "media_artist") || at(best, "media_series_title") || ""
            var album = at(best, "media_album_name") || ""
            n = { id: best, playing: v(best) === "playing",
                  title: at(best, "media_title") || at(best, "app_name") || "",
                  sub: [artist, album].filter(function (x) { return x }).join(" \u2014 "),
                  app: at(best, "app_name") || at(best, "source") || "",
                  name: at(best, "friendly_name") || "",
                  art: pic ? (pic.indexOf("http") === 0 ? pic : haHttp + pic) : "",
                  video: at(best, "media_content_type") ? at(best, "media_content_type") !== "music" : (!!at(best, "app_name") && !artist),
                  feat: at(best, "supported_features") || 0,
                  vol: at(best, "volume_level"),
                  pos: at(best, "media_position"), posAt: at(best, "media_position_updated_at") || "",
                  dur: at(best, "media_duration") }
        }
        if (JSON.stringify(n) !== JSON.stringify(np)) np = n
        if (!np && card === "media") card = ""
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
            var wasOn = cur.s, wasBri = cur.a ? cur.a.brightness : undefined, wasPct = cur.a ? cur.a.percentage : undefined
            if (ch["+"]) {
                if (ch["+"].s !== undefined) cur.s = ch["+"].s
                if (ch["+"].a) for (var ak in ch["+"].a) cur.a[ak] = ch["+"].a[ak]
            }
            st[k] = cur
            var li = -1
            for (var si = 0; si < sliderNames.length; si++) if (sliderEnt(si) === k) li = si
            var lvlKey = k.indexOf("fan.") === 0 ? "percentage" : "brightness"
            if (li >= 0 && (cur.s !== wasOn || cur.a[lvlKey] !== (lvlKey === "brightness" ? wasBri : wasPct)) && !sliderActive && Date.now() - lastFinger > 5000) {
                sliderIdx = li
                sliderLevel = cur.s !== "on" ? 0 : (lvlKey === "percentage" ? (cur.a.percentage || 0) : Math.round((cur.a.brightness || 255) * 100 / 255))
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
    // Artwork: cover-cropped into a rounded rectangle (the Image itself stays invisible).
    component Art: Item {
        id: artItem
        property string src: ""
        property real radius: 24
        property string fallback: "music"
        Rectangle { anchors.fill: parent; radius: artItem.radius; color: "#33FFFFFF"; visible: artImg.status !== Image.Ready
            Ico { anchors.centerIn: parent; name: artItem.fallback; font.pixelSize: Math.min(artItem.width, artItem.height) * 0.42; opacity: 0.85 } }
        Image { id: artImg; source: artItem.src; asynchronous: true; opacity: 0; width: 1; height: 1
                sourceSize.width: 512; sourceSize.height: 512 }
        ShaderEffect {
            anchors.fill: parent
            visible: artImg.status === Image.Ready
            property variant src: artImg
            property size sz: Qt.size(width, height)
            property size isz: Qt.size(Math.max(1, artImg.implicitWidth), Math.max(1, artImg.implicitHeight))
            property real radius: artItem.radius
            fragmentShader: "
                varying highp vec2 qt_TexCoord0;
                uniform sampler2D src;
                uniform lowp float qt_Opacity;
                uniform highp vec2 sz;
                uniform highp vec2 isz;
                uniform highp float radius;
                void main() {
                    highp vec2 p = qt_TexCoord0 * sz;
                    highp float k = max(sz.x / isz.x, sz.y / isz.y);
                    highp vec2 disp = isz * k;
                    lowp vec4 c = texture2D(src, (p + (disp - sz) * 0.5) / disp);
                    highp vec2 q = abs(p - sz * 0.5) - (sz * 0.5 - vec2(radius));
                    highp float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
                    gl_FragColor = c * clamp(0.5 - d, 0.0, 1.0) * qt_Opacity;
                }"
        }
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
        // Now Playing: what this room's Apple TV / Sonos is playing. Tap for controls.
        Item {
            id: npPill
            visible: !!root.np
            width: 640; height: 136
            Glass { width: parent.width; height: parent.height; radius: 40
                    origin: Qt.point(chipCol.x + npPill.x, chipCol.y + npPill.y) }
            MouseArea { anchors.fill: parent; onClicked: { root.card = "media"; cardTimer.restart() } }
            Art { x: 20; y: 20; width: 96; height: 96; radius: 20; src: root.np ? root.np.art : ""
                  fallback: root.np && root.np.video ? "television-play" : "music" }
            Column {
                x: 136; anchors.verticalCenter: parent.verticalCenter; width: 640 - 136 - 124; spacing: 2
                T { width: parent.width; elide: Text.ElideRight; font.pixelSize: 30; font.weight: Font.DemiBold
                    text: root.np ? root.np.title : "" }
                T { width: parent.width; elide: Text.ElideRight; font.pixelSize: 22; opacity: 0.82
                    text: root.np ? (root.np.sub || root.np.app || root.np.name) : "" }
            }
            Rectangle {
                width: 88; height: 88; radius: 44; x: 640 - 108; anchors.verticalCenter: parent.verticalCenter
                color: "#EDFFFFFF"
                Ico { anchors.centerIn: parent; name: root.np && root.np.playing ? "pause" : "play"; color: "#1c1c1e"; font.pixelSize: 48 }
                MouseArea { anchors.fill: parent; anchors.margins: -12
                            onClicked: root.call("media_player", "media_play_pause", { entity_id: root.np.id }) }
            }
        }
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
        visible: root.card !== "" && root.card !== "media"
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

    // ------------------------------------------------------------ Now Playing card
    property real nowMs: Date.now()
    Timer { interval: 1000; repeat: true; running: root.card === "media" && !!root.np && root.np.playing; onTriggered: root.nowMs = Date.now() }
    function npPos() {
        if (!np || np.pos === undefined || np.pos === null || !np.dur) return -1
        var p = np.pos
        if (np.playing && np.posAt) p += Math.max(0, (nowMs - Date.parse(np.posAt)) / 1000)
        return Math.min(p, np.dur)
    }
    function fmt(t) {
        t = Math.max(0, Math.floor(t)); var h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, sec = t % 60
        return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (sec < 10 ? "0" : "") + sec
    }
    property real volPreview: -1
    component RoundBtn: Rectangle {
        property string icon: ""
        property bool primary: false
        signal tapped()
        width: primary ? 132 : 104; height: width; radius: width / 2
        color: primary ? "#EDFFFFFF" : "#29FFFFFF"; border.width: primary ? 0 : 1; border.color: "#40FFFFFF"
        Ico { anchors.centerIn: parent; name: parent.icon; font.pixelSize: parent.primary ? 70 : 52; color: parent.primary ? "#1c1c1e" : "white" }
        MouseArea { anchors.fill: parent; onClicked: { parent.tapped(); cardTimer.restart() } }
    }
    Item {
        anchors.fill: parent
        visible: root.card === "media" && !!root.np
        Rectangle { anchors.fill: parent; color: "#8C000000" }
        MouseArea { anchors.fill: parent; onClicked: root.card = "" }
        Item {
            id: mediaBox
            x: 32; width: 656; height: mediaCol.implicitHeight + 72
            anchors.verticalCenter: parent.verticalCenter
            Glass { width: parent.width; height: parent.height; radius: 52; origin: Qt.point(mediaBox.x, mediaBox.y) }
            MouseArea { anchors.fill: parent }
            Column {
                id: mediaCol
                x: 36; y: 36; width: parent.width - 72; spacing: 22
                Art { anchors.horizontalCenter: parent.horizontalCenter; radius: 34
                      width: root.np && root.np.video ? 584 : 460; height: root.np && root.np.video ? 328 : 460
                      src: root.np ? root.np.art : ""; fallback: root.np && root.np.video ? "television-play" : "music" }
                Column { width: parent.width; spacing: 4
                    T { width: parent.width; elide: Text.ElideRight; font.pixelSize: 40; font.weight: Font.DemiBold; text: root.np ? root.np.title : "" }
                    T { width: parent.width; elide: Text.ElideRight; font.pixelSize: 28; opacity: 0.82; visible: text !== ""; text: root.np ? root.np.sub : "" }
                    T { width: parent.width; elide: Text.ElideRight; font.pixelSize: 22; opacity: 0.6
                        text: root.np ? [root.np.name, root.np.app].filter(function (x) { return x }).join("  \u00B7  ") : "" } }
                Column { width: parent.width; spacing: 8; visible: root.npPos() >= 0
                    Rectangle { width: parent.width; height: 8; radius: 4; color: "#40FFFFFF"
                        Rectangle { height: parent.height; radius: 4; color: "#F2FFFFFF"
                                    width: root.np && root.np.dur ? parent.width * Math.max(0, root.npPos()) / root.np.dur : 0 } }
                    Item { width: parent.width; height: 26
                        T { font.pixelSize: 20; opacity: 0.7; text: root.fmt(root.npPos()) }
                        T { anchors.right: parent.right; font.pixelSize: 20; opacity: 0.7; text: root.np && root.np.dur ? "-" + root.fmt(root.np.dur - root.npPos()) : "" } } }
                Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 48
                    RoundBtn { icon: "skip-previous"; anchors.verticalCenter: parent.verticalCenter; visible: !!root.np && !!(root.np.feat & 16)
                               onTapped: root.call("media_player", "media_previous_track", { entity_id: root.np.id }) }
                    RoundBtn { icon: root.np && root.np.playing ? "pause" : "play"; primary: true
                               onTapped: root.call("media_player", "media_play_pause", { entity_id: root.np.id }) }
                    RoundBtn { icon: "skip-next"; anchors.verticalCenter: parent.verticalCenter; visible: !!root.np && !!(root.np.feat & 32)
                               onTapped: root.call("media_player", "media_next_track", { entity_id: root.np.id }) } }
                Row { width: parent.width; spacing: 18
                    visible: !!root.np && root.np.vol !== undefined && root.np.vol !== null && !!(root.np.feat & 4)
                    Ico { name: "volume-minus"; font.pixelSize: 44; anchors.verticalCenter: parent.verticalCenter; opacity: 0.85
                          MouseArea { anchors.fill: parent; anchors.margins: -16
                                      onClicked: { cardTimer.restart(); root.call("media_player", "volume_set", { entity_id: root.np.id, volume_level: Math.max(0, Math.round((root.np.vol - 0.05) * 100) / 100) }) } } }
                    Rectangle {
                        id: volBar
                        width: parent.width - 2 * (44 + 18); height: 64; radius: 32; color: "#40FFFFFF"; anchors.verticalCenter: parent.verticalCenter
                        readonly property real level: root.volPreview >= 0 ? root.volPreview : (root.np && root.np.vol ? root.np.vol : 0)
                        Rectangle { height: parent.height; radius: 32; color: "#F2FFFFFF"; width: Math.max(64 * (volBar.level > 0), parent.width * volBar.level) }
                        MouseArea { anchors.fill: parent
                            function lv(x) { return Math.max(0, Math.min(1, Math.round(x / width * 100) / 100)) }
                            onPressed: { root.volPreview = lv(mouse.x); cardTimer.restart() }
                            onPositionChanged: root.volPreview = lv(mouse.x)
                            onReleased: { root.call("media_player", "volume_set", { entity_id: root.np.id, volume_level: lv(mouse.x) }); volClear.restart() } }
                        Timer { id: volClear; interval: 1500; onTriggered: root.volPreview = -1 }
                    }
                    Ico { name: "volume-plus"; font.pixelSize: 44; anchors.verticalCenter: parent.verticalCenter; opacity: 0.85
                          MouseArea { anchors.fill: parent; anchors.margins: -16
                                      onClicked: { cardTimer.restart(); root.call("media_player", "volume_set", { entity_id: root.np.id, volume_level: Math.min(1, Math.round((root.np.vol + 0.05) * 100) / 100) }) } } }
                }
                // Players without an absolute volume (Apple TV) can still step it.
                Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 48
                    visible: !!root.np && (root.np.vol === undefined || root.np.vol === null) && !!(root.np.feat & 1024)
                    RoundBtn { icon: "volume-minus"; onTapped: root.call("media_player", "volume_down", { entity_id: root.np.id }) }
                    RoundBtn { icon: "volume-plus"; onTapped: root.call("media_player", "volume_up", { entity_id: root.np.id }) } }
                Btn { width: parent.width; label: "Done"; onTapped: root.card = "" }
            }
        }
    }

    // ------------------------------------------------------------ physical slider indicator
    // hv_sliders.py long-polls the cap-touch state; Brilliant's hidden UI still does the dimming.
    property bool sliderActive: false
    property real lastFinger: 0
    property int sliderIdx: 0
    property int sliderLevel: 0
    // A slider with no label in SLIDERS (unused) never shows the indicator.
    property bool hudShown: (sliderActive || hudLinger.running) && sliderIdx < sliderNames.length
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
                var was = root.sliderActive
                if (r.active && !was) { tapCheck.stop(); root.touchStart = Date.now() }   // a new touch cancels the tap check
                var tapNow = r.taps !== undefined && root.lastTaps >= 0 && r.taps !== root.lastTaps
                var c = root.ctlFor(r.slider)
                root.sliderIdx = r.slider
                root.sliderLevel = c && c.steps ? root.snap(r.level, c.steps) : r.level
                root.sliderActive = r.active
                if (r.active) root.lastFinger = Date.now()
                if (c) {
                    if (r.active) root.ctlDrag(r.slider, root.sliderLevel)
                    else if (was && !tapNow) root.ctlSend(r.slider, root.sliderLevel)
                }
                if (tapNow) root.tapped(r.tap_slider)
                if (r.taps !== undefined) root.lastTaps = r.taps
            } catch (e) {}
        }
        onStatusChanged: if (status === WebSocket.Error || status === WebSocket.Closed) sliderRetry.restart()
    }
    // Tap = Brilliant toggles the light. Offscreen its cached state can be stale, so a tap
    // sometimes "toggles" to what the light already is. If HA shows no change shortly after,
    // flip it ourselves.
    property int lastTaps: -1
    property string tapEntity: ""
    property string tapBefore: ""
    // HomeView-driven sliders: nothing is sent for the first 0.4 s of a touch (it may be a
    // tap, which toggles), then at most ~3 updates/s while dragging, and the final level on release.
    property real touchStart: 0
    property real ctlSentAt: 0
    property int ctlSentLevel: -1
    function snap(l, steps) { var b = steps[0]; for (var i = 0; i < steps.length; i++) if (Math.abs(steps[i] - l) < Math.abs(b - l)) b = steps[i]; return b }
    function ctlDrag(i, lvl) {
        if (Date.now() - touchStart < 400 || Date.now() - ctlSentAt < 300 || lvl === ctlSentLevel) return
        ctlSend(i, lvl)
    }
    function ctlSend(i, lvl) {
        var c = ctlFor(i); if (!c) return
        ctlSentAt = Date.now(); ctlSentLevel = lvl
        var fan = c.entity.indexOf("fan.") === 0
        if (lvl <= 0) call(fan ? "fan" : "light", "turn_off", { entity_id: c.entity })
        else if (fan) call("fan", "set_percentage", { entity_id: c.entity, percentage: lvl })
        else call("light", "turn_on", { entity_id: c.entity, brightness_pct: lvl })
    }
    function tapped(i) {
        var own = ctlFor(i)
        if (own) {
            var on = v(own.entity) === "on", fan = own.entity.indexOf("fan.") === 0
            ctlSentLevel = -1
            call(fan ? "fan" : "light", on ? "turn_off" : "turn_on", { entity_id: own.entity })
            if (on) { sliderIdx = i; sliderLevel = 0; hudLinger.restart() }
            return
        }
        var e = sliderLights[i]
        if (!e || i >= sliderNames.length || !st[e]) return
        tapEntity = e; tapBefore = st[e].s; tapCheck.restart()
        // The bar follows the finger, except a tap that turns the light off drops it to 0.
        if (tapBefore === "on") { sliderIdx = i; sliderLevel = 0; hudLinger.restart() }
    }
    Timer {
        id: tapCheck; interval: 2500
        onTriggered: {
            var cur = root.st[root.tapEntity]
            if (cur && cur.s === root.tapBefore && (cur.s === "on" || cur.s === "off")) {
                root.lastFinger = Date.now()   // our own fix's echo shouldn't pop the bar up again
                root.call("light", cur.s === "on" ? "turn_off" : "turn_on", { entity_id: root.tapEntity })
            }
        }
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
            T { anchors.horizontalCenter: parent.horizontalCenter; y: 588; font.pixelSize: 52; font.weight: Font.DemiBold
                text: { var c = root.ctlFor(root.sliderIdx)
                        if (c && c.steps && c.labels) { var k = c.steps.indexOf(root.sliderLevel); if (k >= 0) return c.labels[k] }
                        return root.sliderLevel + "%" } }
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
