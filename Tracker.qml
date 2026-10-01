pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import "Strings.js" as Strings

// Headless tracker shared by every bar instance: decides every few seconds
// which service (if any) is being watched or listened to, accumulates seconds
// per service per calendar day, persists them to
// ~/.local/state/omarchy/screen-time/days.json and fires limit notifications.
// Panel.qml only draws what lives here.
Item {
  id: root
  visible: false

  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function clampInt(value, lo, hi, fallback) {
    var n = Math.round(Number(value))
    if (!isFinite(n)) n = fallback
    return Math.max(lo, Math.min(hi, n))
  }

  function isOn(name, fallback) {
    return String(setting(name, fallback)).toLowerCase() !== "off"
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/screen-time"
  readonly property string statePath: stateDir + "/days.json"
  readonly property string legacyPath: home + "/.local/state/omarchy/youtube-time/days.json"

  // ---------------------------------------------------------------- language

  readonly property string languageSetting: String(setting("language", "System"))
  readonly property string lang: Strings.languageFor(
    languageSetting.toLowerCase() === "system" || languageSetting === "" ? Qt.locale().name : languageSetting)
  function t(key, args) { return Strings.t(root.lang, key, args) }

  // ---------------------------------------------------------------- services
  //
  // Detection rules. `title` needles are matched case-insensitively inside
  // window titles (Chrome: "<page> - Netflix - Google Chrome", Firefox:
  // "<page> — Mozilla Firefox"), `appId` needles inside the app id (PWAs).
  // `audio` says whether the service plays through the browser's MPRIS player,
  // which is what lets a background tab or an unfocused window count as
  // "listening" (Chrome exposes a media session for YouTube, Twitch and
  // Netflix; Netflix reports "Netflix" as the track title).

  readonly property var catalog: [
    { id: "youtube",   name: "YouTube",   glyph: "󰗃", title: ["- youtube", "youtube music", "youtube -", "youtube —"], appId: ["youtube"],   audio: true,  limitKey: "limitYoutubeMin",   trackKey: "trackYoutube" },
    { id: "twitch",    name: "Twitch",    glyph: "󰕈", title: ["- twitch", "twitch -", "twitch —"],                    appId: ["twitch"],    audio: true,  limitKey: "limitTwitchMin",    trackKey: "trackTwitch" },
    { id: "netflix",   name: "Netflix",   glyph: "󰝆", title: ["- netflix", "netflix -", "netflix —"],                 appId: ["netflix"],   audio: true,  limitKey: "limitNetflixMin",   trackKey: "trackNetflix" },
    { id: "instagram", name: "Instagram", glyph: "󰋾", title: ["instagram"],                                           appId: ["instagram"], audio: false, limitKey: "limitInstagramMin", trackKey: "trackInstagram" }
  ]

  readonly property var services: enabledServices(settings)
  function enabledServices(s) {
    var out = []
    for (var i = 0; i < catalog.length; i++)
      if (isOn(catalog[i].trackKey, "On")) out.push(catalog[i])
    return out
  }

  function serviceById(id) {
    for (var i = 0; i < catalog.length; i++) if (catalog[i].id === id) return catalog[i]
    return null
  }

  function limitMinFor(id) {
    if (id === "all") return clampInt(setting("dailyLimitMin", 0), 0, 1440, 0)
    var svc = serviceById(id)
    return svc ? clampInt(setting(svc.limitKey, 60), 0, 1440, 60) : 0
  }

  function serviceName(id) {
    if (id === "all") return t("total")
    var svc = serviceById(id)
    return svc ? svc.name : String(id || "")
  }

  // MPRIS players that are browsers. Only these can be "listening".
  readonly property var browserNeedles: ["chromium", "chrome", "firefox", "zen", "brave", "vivaldi", "librewolf", "edge", "opera", "epiphany"]

  readonly property int pollSec: clampInt(setting("pollIntervalSec", 5), 1, 60, 5)
  readonly property int warnBeforeMin: clampInt(setting("warnBeforeMin", 10), 0, 120, 10)
  readonly property int repeatEveryMin: clampInt(setting("repeatEveryMin", 15), 0, 240, 15)
  readonly property bool looseMatch: isOn("looseMatch", "On")

  // ---------------------------------------------------------------- state
  //
  // days: date (YYYY-MM-DD) -> { serviceId -> seconds }

  property var days: ({})
  property bool loaded: false
  property bool dirty: false

  property double nowMs: Date.now()
  readonly property string today: dateKey(new Date(nowMs))
  readonly property var todayMap: days[today] || ({})
  readonly property int todaySeconds: sumMap(todayMap)
  readonly property var recentDays: buildRecentDays(days, today)

  function secondsFor(id, map) {
    var m = map || todayMap
    if (id === "all") return sumMap(m)
    return Number(m[id] || 0)
  }

  function sumMap(map) {
    var total = 0
    for (var key in (map || {})) total += Number(map[key] || 0)
    return total
  }

  // Per-id view used by the panel: seconds, limit, ratio, flags.
  function summary(id) {
    var seconds = secondsFor(id)
    var limitMin = limitMinFor(id)
    var limitSeconds = limitMin * 60
    var over = limitSeconds > 0 && seconds >= limitSeconds
    return {
      id: id,
      seconds: seconds,
      limitMin: limitMin,
      limitSeconds: limitSeconds,
      ratio: limitSeconds > 0 ? seconds / limitSeconds : -1,
      overLimit: over,
      nearLimit: limitSeconds > 0 && !over && warnBeforeMin > 0 && seconds >= limitSeconds - warnBeforeMin * 60
    }
  }

  // Any limit (a service's or the total) reached today.
  readonly property bool anyOverLimit: computeAnyOver(todayMap, settings)
  function computeAnyOver(map, s) {
    if (summary("all").overLimit) return true
    for (var i = 0; i < services.length; i++) if (summary(services[i].id).overLimit) return true
    return false
  }

  // What is being counted right now.
  property bool active: false
  property string activeService: ""   // service id
  property string reason: ""          // "watching" | "listening" | ""
  property string currentTitle: ""

  // A browser player, once tied to a service window, stays tied while it
  // keeps playing: the usual flow is "press play, switch tab/workspace", and
  // autoplay changes the title with the tab still in the background. The tie
  // is dropped when the player vanishes or when a window of another site is
  // seen showing the player's current track.
  property var confirmedPlayers: ({})   // dbusName -> { service, track }

  // Notification bookkeeping, per day and per id ("all" or a service id).
  property string notifyDate: ""
  property var notifyState: ({})        // id -> { warned, limitNotified, lastMs }

  signal tracked()

  // The panel tab in view. Lives here so every bar instance (one per monitor)
  // shows the same tab and IPC `select` works whichever instance answers.
  property string selectedTab: "all"
  // How many bar copies currently show their panel (debug aid for IPC).
  property int openCount: 0

  // Changing any limit starts that day's notifications over, so lowering or
  // raising it mid-day still produces the "reached" notice at the new value.
  onSettingsChanged: root.notifyState = {}

  // ---------------------------------------------------------------- dates

  function dateKey(d) {
    return d.getFullYear()
      + "-" + String(d.getMonth() + 1).padStart(2, "0")
      + "-" + String(d.getDate()).padStart(2, "0")
  }

  function buildRecentDays(map, todayKey) {
    var out = []
    var base = new Date(String(todayKey) + "T00:00:00")
    if (isNaN(base.getTime())) base = new Date()
    for (var i = 6; i >= 0; i--) {
      var d = new Date(base.getTime())
      d.setDate(base.getDate() - i)
      var key = dateKey(d)
      var m = (map || {})[key] || {}
      out.push({ date: key, services: m, seconds: sumMap(m) })
    }
    return out
  }

  function formatMinutes(seconds) {
    var m = Math.floor(Number(seconds || 0) / 60)
    var h = Math.floor(m / 60)
    if (h > 0) return h + "h " + String(m % 60).padStart(2, "0") + "m"
    return m + "m"
  }

  // ---------------------------------------------------------------- detection

  function containsAny(haystack, needles) {
    var text = String(haystack || "").toLowerCase()
    if (text === "") return false
    for (var i = 0; i < needles.length; i++)
      if (text.indexOf(needles[i]) !== -1) return true
    return false
  }

  function serviceForToplevel(t) {
    if (!t) return null
    for (var i = 0; i < services.length; i++) {
      var svc = services[i]
      if (containsAny(t.title, svc.title) || containsAny(t.appId, svc.appId)) return svc
    }
    return null
  }

  function isBrowserPlayer(p) {
    if (!p) return false
    return containsAny(p.dbusName, browserNeedles)
      || containsAny(p.identity, browserNeedles)
      || containsAny(p.desktopEntry, browserNeedles)
  }

  function detect() {
    var tops = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var windows = []       // { service, title } for every service window
    var otherTitles = []   // titles of every non-service window
    var focused = null
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var title = String(t.title || "")
      var svc = serviceForToplevel(t)
      if (svc) {
        windows.push({ service: svc, title: title })
        if (t.activated) focused = { service: svc, title: title }
      } else if (title !== "") {
        otherTitles.push(title)
      }
    }

    // Watching: the focused window belongs to a service, playing or not.
    if (focused)
      return { active: true, service: focused.service.id, reason: "watching", title: focused.title, players: root.confirmedPlayers }

    // Listening: a browser is playing audio that can be tied to a service.
    var players = Mpris.players ? Mpris.players.values : []
    var confirmed = {}
    var hit = null
    var browserPlaying = false
    for (var j = 0; j < players.length; j++) {
      var p = players[j]
      if (!p || !isBrowserPlayer(p)) continue
      var key = String(p.dbusName || p.identity || "")
      var track = String(p.trackTitle || "").trim()
      var trackLower = track.toLowerCase()
      var tie = root.confirmedPlayers[key] || null

      if (trackLower !== "") {
        var matchedService = null
        for (var k = 0; k < windows.length; k++)
          if (windows[k].service.audio && windows[k].title.toLowerCase().indexOf(trackLower) === 0) { matchedService = windows[k].service; break }
        // The track itself can name the service ("Netflix"); that ties the
        // player even when the window title carries an episode name instead.
        for (var a = 0; a < services.length && !matchedService; a++)
          if (containsAny(trackLower, services[a].appId)) matchedService = services[a]
        var elsewhere = false
        for (var o = 0; o < otherTitles.length && !matchedService; o++)
          if (otherTitles[o].toLowerCase().indexOf(trackLower) === 0) { elsewhere = true; break }

        if (matchedService) tie = { service: matchedService.id, track: track }   // a service window shows this track
        else if (elsewhere) tie = null                                            // another site shows this track
        else if (tie && !root.looseMatch && track !== tie.track && !p.isPlaying) tie = null
      }

      if (tie) confirmed[key] = tie
      if (!p.isPlaying) continue
      browserPlaying = true
      if (tie && !hit && serviceById(tie.service))
        hit = { service: tie.service, title: track !== "" ? track : serviceName(tie.service) }
    }

    if (hit) return { active: true, service: hit.service, reason: "listening", title: hit.title, players: confirmed }

    // Nothing tied yet (e.g. the shell started after playback began) but a
    // browser is playing and an audio service window exists: count it when allowed.
    if (root.looseMatch && browserPlaying) {
      for (var w = 0; w < windows.length; w++)
        if (windows[w].service.audio)
          return { active: true, service: windows[w].service.id, reason: "listening", title: windows[w].title, players: confirmed }
    }

    return { active: false, service: "", reason: "", title: "", players: confirmed }
  }

  // What the detector sees, for `omarchy-shell <id> debug`.
  function debugSnapshot() {
    var tops = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var players = Mpris.players ? Mpris.players.values : []
    var windows = [], audio = []
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var svc = serviceForToplevel(t)
      windows.push({ title: String(t.title || ""), appId: String(t.appId || ""), activated: !!t.activated, service: svc ? svc.id : "" })
    }
    for (var j = 0; j < players.length; j++) {
      var p = players[j]
      audio.push({ dbusName: String(p.dbusName || ""), identity: String(p.identity || ""), desktopEntry: String(p.desktopEntry || ""),
                   isPlaying: !!p.isPlaying, trackTitle: String(p.trackTitle || ""), browser: isBrowserPlayer(p) })
    }
    return { loaded: root.loaded, lang: root.lang, active: root.active, service: root.activeService, reason: root.reason,
             confirmedPlayers: root.confirmedPlayers, today: root.todayMap, windows: windows, players: audio }
  }

  // ---------------------------------------------------------------- ticking

  Timer {
    id: poll
    interval: root.pollSec * 1000
    running: root.loaded
    repeat: true
    onTriggered: root.tick()
  }

  function tick() {
    root.nowMs = Date.now()
    var result = detect()
    root.active = result.active
    root.activeService = result.service
    root.reason = result.reason
    root.currentTitle = result.title
    root.confirmedPlayers = result.players || {}

    if (!result.active) return

    var next = Object.assign({}, root.days)
    var dayMap = Object.assign({}, next[root.today] || {})
    dayMap[result.service] = Number(dayMap[result.service] || 0) + root.pollSec
    next[root.today] = dayMap
    root.days = next
    root.dirty = true
    root.tracked()
    checkThresholds(result.service)
    save()
  }

  function checkThresholds(serviceId) {
    if (root.notifyDate !== root.today) {
      root.notifyDate = root.today
      root.notifyState = {}
    }
    checkOne(serviceId, false)
    checkOne("all", true)
  }

  function checkOne(id, isTotal) {
    var s = summary(id)
    if (s.limitSeconds <= 0) return
    var state = Object.assign({ warned: false, limitNotified: false, lastMs: 0 }, root.notifyState[id] || {})
    var name = serviceName(id)
    var changed = false

    if (s.overLimit) {
      if (!state.limitNotified) {
        state.limitNotified = true
        state.lastMs = root.nowMs
        changed = true
        notify("critical", id, t(isTotal ? "notif_total_limit_title" : "notif_limit_title", { s: name }),
               t("notif_limit_body", { m: formatMinutes(s.seconds), n: s.limitMin }))
      } else if (root.repeatEveryMin > 0 && root.nowMs - state.lastMs >= root.repeatEveryMin * 60000) {
        state.lastMs = root.nowMs
        changed = true
        notify("critical", id, t(isTotal ? "notif_total_still_title" : "notif_still_title", { s: name }),
               t("notif_still_body", { m: formatMinutes(s.seconds), o: formatMinutes(s.seconds - s.limitSeconds) }))
      }
    } else if (s.nearLimit && !state.warned) {
      state.warned = true
      changed = true
      var left = Math.max(1, Math.ceil((s.limitSeconds - s.seconds) / 60))
      notify("normal", id, t(isTotal ? "notif_total_warn_title" : "notif_warn_title", { s: name }),
             t("notif_warn_body", { n: left, l: s.limitMin }))
    }

    if (changed) {
      var nextState = Object.assign({}, root.notifyState)
      nextState[id] = state
      root.notifyState = nextState
    }
  }

  // ---------------------------------------------------------------- notifications

  Process {
    id: notifyProcess
    running: false
  }

  function notify(urgency, id, headline, body) {
    if (notifyProcess.running) return
    var svc = serviceById(id)
    var glyph = svc ? svc.glyph : "󰔂"
    notifyProcess.command = ["omarchy-notification-send", "-u", urgency, "-g", glyph, "--app-name", "Screen Time", headline, body]
    notifyProcess.running = true
  }

  // ---------------------------------------------------------------- persistence

  // Load once at startup through a plain shell read: creates the state
  // directory, then prints the file. When the new file does not exist yet,
  // the YouTube-only file from the previous plugin version is read instead
  // and migrated on the first save.
  Process {
    id: loadProcess
    command: ["bash", "-c", "mkdir -p \"$1\" && { cat \"$2\" 2>/dev/null || cat \"$3\" 2>/dev/null || true; }", "--", root.stateDir, root.statePath, root.legacyPath]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.days = root.parse(this.text)
        root.nowMs = Date.now()
        root.loaded = true
        root.tick()
      }
    }
  }

  // Writer only; loading goes through loadProcess above.
  FileView {
    id: stateFile
    path: root.statePath
    preload: false
    watchChanges: false
    printErrors: false
    onSaveFailed: function(error) { console.warn("screen-time", "Could not save", root.statePath, error) }
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || "{}"))
      var out = {}
      if (parsed && typeof parsed === "object") {
        var source = parsed.days && typeof parsed.days === "object" ? parsed.days : parsed
        for (var key in source) {
          if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) continue
          var entry = source[key]
          var dayMap = {}
          if (typeof entry === "number" || typeof entry === "string") {
            // v1 (youtube-time): date -> seconds
            var n = Number(entry)
            if (isFinite(n) && n > 0) dayMap.youtube = Math.round(n)
          } else if (entry && typeof entry === "object") {
            for (var id in entry) {
              var v = Number(entry[id])
              if (isFinite(v) && v > 0) dayMap[id] = Math.round(v)
            }
          }
          if (Object.keys(dayMap).length > 0) out[key] = dayMap
        }
      }
      return out
    } catch (e) {
      console.warn("screen-time", "Ignoring bad state file", root.statePath, e)
      return {}
    }
  }

  // Keep 60 days on disk; the panel only shows seven.
  function pruned(map) {
    var cutoff = new Date(root.nowMs)
    cutoff.setDate(cutoff.getDate() - 60)
    var cutKey = dateKey(cutoff)
    var out = {}
    for (var key in map) if (key >= cutKey) out[key] = map[key]
    return out
  }

  function save() {
    if (!root.dirty || !root.loaded) return
    root.dirty = false
    var payload = { version: 2, updatedAt: new Date(root.nowMs).toISOString(), days: pruned(root.days) }
    stateFile.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  // Zero today's counter for one service, or for every service with "all".
  function resetToday(id) {
    var next = Object.assign({}, root.days)
    if (!id || id === "all") {
      delete next[root.today]
    } else {
      var dayMap = Object.assign({}, next[root.today] || {})
      delete dayMap[id]
      if (Object.keys(dayMap).length > 0) next[root.today] = dayMap
      else delete next[root.today]
    }
    root.days = next
    root.dirty = true
    root.notifyState = {}
    save()
  }

  Component.onCompleted: {
    console.info("screen-time", "tracker started")
    loadProcess.running = true
  }
}
