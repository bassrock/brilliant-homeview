.pragma library
// Brilliant HomeView panel configuration. Copy to config.js (install.sh does this),
// fill in, and keep it 0600 on the panel: it holds a Home Assistant token.

// Home Assistant websocket and a long-lived access token (Profile > Security).
var WS = "ws://homeassistant.local:8123/api/websocket"
var TOKEN = "PASTE_LONG_LIVED_ACCESS_TOKEN"

// Photos rendered for this panel by the panel_photo integration (see homeassistant/).
// Default panel:  .../api/panel_photo/<key>            + sensor.panel_photo_version
// Extra panels:   .../api/panel_photo/<key>/<name>     + sensor.panel_photo_<name>_version
var PHOTO = "http://homeassistant.local:8123/api/panel_photo/CHANGE_ME_KEY"
var PHOTO_VERSION = "sensor.panel_photo_version"

// Optional: the immich_frames feed behind the photos, for the caption (date, place,
// favourite) and tap-caption-for-next-photo. sensor.<FEED>_date, button.<FEED>_next.
var FEED = "kitchen_panel"

var WEATHER = "weather.forecast_home"
var CLOCK_24H = false

// Physical slider labels (top to bottom) and the HA light each one dims. The on-screen
// level indicator follows these lights' brightness.
var SLIDERS = ["Island", "Cabinets", "Overhead"]
var SLIDER_LIGHTS = ["light.kitchen_island", "light.kitchen_cabinets", "light.kitchen_overhead"]

// Attention chips. Nothing shows when everything is fine.
// Unlocked doors: tap the chip for Lock buttons.
var LOCKS = [
    ["lock.front_door", "Front Door"],
    ["lock.back_door", "Back Door"],
]

// Deliveries (all optional). box_lock enables the package-box card.
var DELIVERY = {
    box_flag: "input_boolean.package_in_box",     // on = package waiting
    box_text: "Package in porch box",
    box_name: "Porch Box",
    box_lock: "lock.package_box",
    picked_up_script: "script.package_box_picked_up",
    mail_flag: "input_boolean.mail_present",
    arriving: [                                    // numeric "arriving today" sensors, summed
        "sensor.mail_amazon_packages",
        "sensor.mail_ups_delivering",
    ],
}

// "It's done" alerts: shown while `entity` is in one of `states`.
var DONE = [
    { entity: "sensor.washer_state", states: ["complete"], icon: "washing-machine", text: "Washer is done" },
    { entity: "binary_sensor.dryer_end_of_cycle", states: ["on"], icon: "tumble-dryer", text: "Dryer is done" },
]

// Return to the photo face after this much idle time (only matters for open cards).
var IDLE_MS = 45000
