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
// level indicator follows these lights' brightness. List only the sliders you use:
// touching an unlisted slider shows nothing.
var SLIDERS = ["Island", "Cabinets", "Overhead"]
var SLIDER_LIGHTS = ["light.kitchen_island", "light.kitchen_cabinets", "light.kitchen_overhead"]

// Optional: sliders left unassigned in the Brilliant app can be driven by HomeView itself
// (index-aligned with SLIDERS; null = Brilliant drives it). Lights dim 0-100; fans snap to
// `steps` (with optional `labels` for the on-screen indicator). Tap toggles.
// var SLIDER_CONTROL = [null, { entity: "light.ceiling_fan_light" },
//     { entity: "fan.ceiling_fan", steps: [0, 33, 66, 100], labels: ["Off", "Low", "Medium", "High"] }]

// Optional Now Playing: this room's media players in priority order (the first one playing
// wins), e.g. an Apple TV (shows AirPlay too) and a Sonos. Artwork, progress, controls.
var MEDIA = ["media_player.living_room_apple_tv", "media_player.kitchen_sonos"]

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

// Optional night mode (bedrooms): between these hours the screen is black with the
// backlight off; a tap wakes it for WAKE_MS. Sliders keep working throughout.
// Leave NIGHT out for an always-on panel (e.g. a kitchen).
var NIGHT = { start: 22, end: 7 }
var WAKE_MS = 30000
