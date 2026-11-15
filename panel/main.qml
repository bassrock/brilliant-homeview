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
        "volume-plus":"F075D","music":"F075A","television-play":"F0ECF","speaker":"F04C3",
        "fan":"F0210","fan-off":"F081D","ceiling-light":"F0769","ceiling-fan-light":"F1798","lightbulb":"F0335","lightbulb-outline":"F0336",
        "roller-shade":"F1A6B","roller-shade-closed":"F1A6C","thermostat":"F0393","minus":"F0374","plus":"F0415","fire":"F0238",
        "snowflake":"F0717","power":"F0425"})
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
    // Optional room card: tap the photo for this room's basics. ROOM = {name, controls: [{entity, name, icon,
    // steps, labels}]}; entity may be a list (driven together, state from the first). Lights dim,
    // shades set position, fans with `steps` get Off/Low/... buttons, climate gets -/+.
    readonly property var room: cfg("ROOM", null)
    readonly property var roomCtl: room && room.controls ? room.controls : []
    function ids(c) { return c.entity }
    function pri(c) { return typeof c.entity === "string" ? c.entity : c.entity[0] }
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
        for (var r = 0; r < roomCtl.length; r++) [].concat(roomCtl[r].entity).forEach(add)
        return e
    }

    // ------------------------------------------------------------ state (plain values, recomputed on change)
    property var st: ({})
    property string clockText: "--:--"
    property string dateText: ""
    property string wxText: ""
    property string wxIcon: "weather-cloudy"
    property string capDate: "Memories"
    property string capSub: ""
    property bool capFav: false
    property string photoVer: "0"
    property var chips: []          // [{icon, color, text, act}]
    property var openLocks: []
    property string boxLock: "unknown"
    property bool boxInside: false
    property string card: ""        // "" | "locks" | "box" | "mail" | "arriving" | "done:<i>" | "media"
    property var dismissed: ({})    // done-alert entity -> state it was dismissed in
    property int arrivingCount: 0
    readonly property var doneCard: card.indexOf("done:") === 0 ? doneAlerts[parseInt(card.slice(5))] : null
    property var np: null           // the room's now-playing media (see recompute)
    property int stRev: 0           // bumps on every state event (the room card binds to it)
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
        capSub = loc && loc !== "unknown" && loc !== "unavailable" ? loc.split(",").slice(0, 2).join(",").trim() : ""   // where it was taken
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
        else if (delivery.mail_flag && v(delivery.mail_flag) === "on") out.push({ icon: "mailbox", color: "#64D2FF", act: "mail", text: "Mail is here" })
        else if (arriving > 0) out.push({ icon: "truck-delivery", color: "#64D2FF", act: hasBox ? "box" : "arriving", text: arriving + (arriving === 1 ? " delivery" : " deliveries") + " today" })
        arrivingCount = arriving
        // "It's done" alerts: tap -> Got It hides the chip until that entity's state changes again.
        for (var d = 0; d < doneAlerts.length; d++) {
            var al = doneAlerts[d], cur = v(al.entity)
            if (dismissed[al.entity] !== undefined && dismissed[al.entity] !== cur) delete dismissed[al.entity]
            if ((al.states || ["on"]).indexOf(cur) >= 0 && dismissed[al.entity] === undefined)
                out.push({ icon: al.icon || "check-circle", color: al.color || "#30D158", text: al.text, act: "done:" + d })
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
    Component.onCompleted: { tick(); card = cfg("START_CARD", "") }   // START_CARD: dev screenshots

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
        stRev++
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
    // Tap the photo itself (not a chip or the caption) for the room card.
    MouseArea { anchors.fill: parent; enabled: !root.faceHidden && root.roomCtl.length > 0 && root.card === ""
                onClicked: { root.card = "room"; cardTimer.restart() } }

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
                T { text: root.capSub; visible: text !== ""; font.pixelSize: 22; opacity: 0.82; width: Math.min(implicitWidth, 520); elide: Text.ElideRight } } }
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
        visible: root.card !== "" && root.card !== "media" && root.card !== "room"
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
                T { font.pixelSize: 44; font.weight: Font.DemiBold
                    text: root.card === "locks" ? "Doors" : root.card === "mail" ? "Mailbox" : root.card === "arriving" ? "Deliveries"
                          : root.doneCard ? root.doneCard.text : (root.delivery.box_name || "Package Box") }
                T { width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 26; opacity: 0.85
                    text: root.card === "locks" ? (root.openLocks.length ? root.openLocks.join(", ") + (root.openLocks.length === 1 ? " is" : " are") + " unlocked" : "All doors are locked")
                          : root.card === "mail" ? "The mail has been delivered. Tap Picked Up once you've grabbed it."
                          : root.card === "arriving" ? root.arrivingCount + (root.arrivingCount === 1 ? " delivery is" : " deliveries are") + " on the way today."
                          : root.doneCard ? "Tap Got It to clear this until the next cycle."
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
                Btn { visible: root.card === "mail"; width: cardCol.width; label: "Picked Up"
                      onTapped: { root.call("input_boolean", "turn_off", { entity_id: root.delivery.mail_flag }); root.card = "" } }
                Btn { visible: !!root.doneCard; width: cardCol.width; label: "Got It"
                      onTapped: { var d = root.dismissed; d[root.doneCard.entity] = root.v(root.doneCard.entity); root.dismissed = d; root.card = ""; root.recompute() } }
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

    // ------------------------------------------------------------ room card (tap the photo)
    function lvlOf(c) {   // 0-100: brightness, fan speed, shade position
        var e = pri(c), d = e.split(".")[0], s = v(e)
        if (d === "cover") { var p = at(e, "current_position"); return p !== undefined && p !== null ? p : (s === "open" ? 100 : 0) }
        if (s !== "on") return 0
        if (d === "fan") return at(e, "percentage") || 100
        var b = at(e, "brightness"); return b ? Math.max(1, Math.round(b * 100 / 255)) : 100
    }
    function setLvl(c, l) {
        var d = pri(c).split(".")[0]
        if (d === "cover") call("cover", "set_cover_position", { entity_id: ids(c), position: l })
        else if (l <= 0) call(d, "turn_off", { entity_id: ids(c) })
        else if (d === "fan") call("fan", "set_percentage", { entity_id: ids(c), percentage: l })
        else call("light", "turn_on", { entity_id: ids(c), brightness_pct: l })
    }
    function toggleCtl(c) {
        var e = pri(c), d = e.split(".")[0], s = v(e)
        if (d === "cover") call("cover", s === "opening" || s === "closing" ? "stop_cover" : s === "closed" ? "open_cover" : "close_cover", { entity_id: ids(c) })
        else call(d, s === "on" ? "turn_off" : "turn_on", { entity_id: ids(c) })
    }
    function canDim(c) {
        var e = pri(c), d = e.split(".")[0]
        if (d === "cover") return !!((at(e, "supported_features") || 0) & 4)
        if (d === "light") { var m = at(e, "supported_color_modes") || []; return m.length > 0 && !(m.length === 1 && m[0] === "onoff") }
        return false
    }
    function ctlIcon(c, on) {
        if (c.icon) return c.icon
        var d = pri(c).split(".")[0]
        return d === "fan" ? (on ? "fan" : "fan-off") : d === "cover" ? (on ? "roller-shade" : "roller-shade-closed")
             : d === "climate" ? "thermostat" : (on ? "lightbulb" : "lightbulb-outline")
    }
    function ctlState(c, l) {
        var e = pri(c), d = e.split(".")[0], s = v(e)
        if (s === undefined || s === "unavailable" || s === "unknown") return "Unavailable"
        if (d === "cover") return s === "opening" ? "Opening" : s === "closing" ? "Closing" : l >= 100 ? "Open" : l <= 0 ? "Closed" : l + "% open"
        if (d === "fan" && c.steps) { var k = c.steps.indexOf(snap(l, c.steps)); return s !== "on" ? "Off" : (c.labels ? c.labels[k] : l + "%") }
        if (s !== "on") return "Off"
        return canDim(c) ? l + "%" : "On"
    }
    component TileLabel: Row {
        property string icon: ""
        property string title: ""
        property string sub: ""
        property color fg: "white"
        property color iconFg: fg
        x: 32; anchors.verticalCenter: parent.verticalCenter; spacing: 22
        Ico { name: parent.icon; color: parent.iconFg; font.pixelSize: 50; anchors.verticalCenter: parent.verticalCenter }
        Column { anchors.verticalCenter: parent.verticalCenter
            T { text: parent.parent.title; color: parent.parent.fg; font.pixelSize: 30; font.weight: Font.DemiBold }
            T { text: parent.parent.sub; color: parent.parent.fg; font.pixelSize: 24; opacity: 0.8 } }
    }
    Item {
        anchors.fill: parent
        visible: root.card === "room"
        Rectangle { anchors.fill: parent; color: "#8C000000" }
        MouseArea { anchors.fill: parent; onClicked: root.card = "" }
        Item {
            id: roomBox
            x: 32; width: 656; height: roomCol.implicitHeight + 72
            anchors.verticalCenter: parent.verticalCenter
            Glass { width: parent.width; height: parent.height; radius: 52; origin: Qt.point(roomBox.x, roomBox.y) }
            MouseArea { anchors.fill: parent }
            Column {
                id: roomCol
                x: 36; y: 36; width: parent.width - 72; spacing: 18
                T { text: root.room && root.room.name ? root.room.name : "This Room"; font.pixelSize: 44; font.weight: Font.DemiBold; bottomPadding: 6 }
                Repeater {
                    model: root.card === "room" ? root.roomCtl : []
                    Item {
                        id: tile
                        readonly property var c: modelData
                        readonly property string ent: root.pri(c)
                        readonly property string dom: ent.split(".")[0]
                        readonly property bool stepped: dom === "fan" && !!c.steps
                        readonly property string s: (root.stRev, root.v(ent) || "")
                        readonly property bool ok: s !== "" && s !== "unavailable" && s !== "unknown"
                        readonly property bool dims: (root.stRev, root.canDim(c))
                        property int preview: -1
                        readonly property int level: preview >= 0 ? preview : (root.stRev, root.lvlOf(c))
                        readonly property bool lit: dom === "cover" ? level > 0 : s === "on"
                        readonly property string title: c.name || root.at(ent, "friendly_name") || ent
                        width: roomCol.width
                        height: dom === "climate" ? 136 : stepped ? 196 : 124
                        opacity: ok ? 1 : 0.45
                        Timer { id: holdPreview; interval: 4000; onTriggered: tile.preview = -1 }

                        // Lights, shades, on/off fans: one pill. Tap toggles, slide sets the level.
                        Item {
                            visible: tile.dom !== "climate" && !tile.stepped
                            anchors.fill: parent
                            Rectangle { id: pill; anchors.fill: parent; radius: 40; color: "#29FFFFFF"; border.width: 1; border.color: "#40FFFFFF" }
                            TileLabel { icon: root.ctlIcon(tile.c, tile.lit); title: tile.title; sub: (root.stRev, root.ctlState(tile.c, tile.level)) }
                            Item {
                                clip: true; height: parent.height
                                width: tile.lit ? (tile.dims ? Math.max(80, parent.width * tile.level / 100) : parent.width) : 0
                                Rectangle { width: pill.width; height: pill.height; radius: 40; color: "#F2FFFFFF" }
                                TileLabel { fg: "#1c1c1e"; iconFg: tile.dom === "light" ? "#FF9F0A" : tile.dom === "cover" ? "#0A84FF" : "#1c1c1e"
                                            icon: root.ctlIcon(tile.c, tile.lit); title: tile.title; sub: (root.stRev, root.ctlState(tile.c, tile.level)) }
                            }
                            MouseArea {
                                anchors.fill: parent; enabled: tile.ok
                                property real x0: 0
                                property int base: 0
                                property bool dragging: false
                                onPressed: { x0 = mouse.x; base = tile.level; dragging = false; cardTimer.restart() }
                                onPositionChanged: {
                                    if (!tile.dims) return
                                    if (!dragging && Math.abs(mouse.x - x0) > 24) dragging = true
                                    if (dragging) { holdPreview.stop(); tile.preview = Math.max(0, Math.min(100, Math.round(base + (mouse.x - x0) / width * 100))) }
                                }
                                onReleased: {
                                    if (dragging) { root.setLvl(tile.c, tile.preview); holdPreview.restart() }
                                    else root.toggleCtl(tile.c)
                                    cardTimer.restart()
                                }
                            }
                        }

                        // Fans with steps: Off / Low / Medium / High.
                        Item {
                            visible: tile.stepped
                            anchors.fill: parent
                            Row { x: 8; height: 60; spacing: 14
                                Ico { name: root.ctlIcon(tile.c, tile.lit); font.pixelSize: 40; anchors.verticalCenter: parent.verticalCenter }
                                T { text: tile.title; font.pixelSize: 30; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter } }
                            Row {
                                id: seg
                                y: 72; spacing: 12
                                Repeater {
                                    model: tile.stepped ? tile.c.steps : []
                                    Rectangle {
                                        readonly property bool on: tile.ok && root.snap(tile.s === "on" ? tile.level : 0, tile.c.steps) === modelData
                                        width: (tile.width - 12 * (tile.c.steps.length - 1)) / tile.c.steps.length; height: 124; radius: 40
                                        color: on ? "#F2FFFFFF" : "#29FFFFFF"; border.width: on ? 0 : 1; border.color: "#40FFFFFF"
                                        T { anchors.centerIn: parent; font.pixelSize: 28; font.weight: Font.DemiBold; color: parent.on ? "#1c1c1e" : "white"
                                            text: tile.c.labels ? tile.c.labels[index] : (modelData ? modelData + "%" : "Off") }
                                        MouseArea { anchors.fill: parent; enabled: tile.ok
                                            onClicked: { root.setLvl(tile.c, modelData); tile.preview = modelData; holdPreview.restart(); cardTimer.restart() } }
                                    }
                                }
                            }
                        }

                        // Thermostat: current temperature, target with - / +.
                        Item {
                            id: clim
                            visible: tile.dom === "climate"
                            anchors.fill: parent
                            readonly property real cur: (root.stRev, parseFloat(root.at(tile.ent, "current_temperature")))
                            readonly property real tgtHa: (root.stRev, parseFloat(root.at(tile.ent, "temperature")))
                            readonly property real step: (root.stRev, parseFloat(root.at(tile.ent, "target_temp_step")) || 1)
                            readonly property string act: (root.stRev, root.at(tile.ent, "hvac_action") || "")
                            property real pending: NaN
                            readonly property real tgt: isNaN(pending) ? tgtHa : pending
                            Rectangle { anchors.fill: parent; radius: 40; color: "#29FFFFFF"; border.width: 1; border.color: "#40FFFFFF" }
                            TileLabel {
                                icon: clim.act === "heating" ? "fire" : clim.act === "cooling" ? "snowflake" : "thermostat"
                                iconFg: clim.act === "heating" ? "#FF9F0A" : clim.act === "cooling" ? "#64D2FF" : "white"
                                title: tile.title
                                sub: "Now " + (isNaN(clim.cur) ? "--" : Math.round(clim.cur) + "°") + "  ·  " +
                                     (tile.s === "off" ? "Off" : clim.act === "heating" ? "Heating" : clim.act === "cooling" ? "Cooling" : tile.s === "cool" ? "Cool" : tile.s === "heat" ? "Heat" : "Idle")
                            }
                            Row {
                                anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                visible: tile.ok && tile.s !== "off" && !isNaN(clim.tgt)
                                RoundBtn { icon: "minus"; width: 80; anchors.verticalCenter: parent.verticalCenter
                                           onTapped: { clim.pending = clim.tgt - clim.step; climSend.restart() } }
                                T { width: 86; horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter
                                    font.pixelSize: 48; font.weight: Font.DemiBold; text: Math.round(clim.tgt) + "°" }
                                RoundBtn { icon: "plus"; width: 80; anchors.verticalCenter: parent.verticalCenter
                                           onTapped: { clim.pending = clim.tgt + clim.step; climSend.restart() } }
                            }
                            Timer { id: climSend; interval: 1200
                                    onTriggered: { root.call("climate", "set_temperature", { entity_id: root.ids(tile.c), temperature: clim.pending }); climClear.restart() } }
                            Timer { id: climClear; interval: 5000; onTriggered: clim.pending = NaN }
                        }
                    }
                }
                Item { width: 1; height: 4 }
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
