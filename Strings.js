.pragma library

// UI and notification strings. The language follows Qt.locale() (the shell's
// LANG) unless the `language` setting forces one. Unknown languages fall back
// to English. Day names are not here: the locale's dayName() localizes them.

var TABLES = {
  en: {
    all: "All",
    status_loading: "Loading…",
    status_watching: "Watching {s}",
    status_listening: "Listening to {s}",
    status_idle: "Nothing playing",
    today: "Today",
    meta_today: "{m} today",
    meta_limit: "limit {n} min",
    section_today: "TODAY",
    section_services: "BY SERVICE",
    section_week: "LAST 7 DAYS",
    daily_limit: "Daily limit",
    time_today: "Time today",
    no_limit: "No daily limit set",
    over_by: "{m} over the limit",
    left_until: "{m} left until the limit",
    week_total: "Week total: {t} · avg {a}/day",
    of_limit: " of {n} min",
    total: "Screen time",
    notif_limit_title: "{s} limit reached",
    notif_limit_body: "{m} today · {n} min limit",
    notif_still_title: "Still on {s}",
    notif_still_body: "{m} today · {o} over the limit",
    notif_warn_title: "Almost at your {s} limit",
    notif_warn_body: "{n} min left of today's {l} min",
    notif_total_limit_title: "Screen time limit reached",
    notif_total_still_title: "Still over your screen time limit",
    notif_total_warn_title: "Almost at your screen time limit"
  },
  pt: {
    all: "Todos",
    status_loading: "Carregando…",
    status_watching: "Assistindo {s}",
    status_listening: "Ouvindo {s}",
    status_idle: "Nada tocando",
    today: "Hoje",
    meta_today: "{m} hoje",
    meta_limit: "limite {n} min",
    section_today: "HOJE",
    section_services: "POR SERVIÇO",
    section_week: "ÚLTIMOS 7 DIAS",
    daily_limit: "Limite diário",
    time_today: "Tempo hoje",
    no_limit: "Sem limite diário configurado",
    over_by: "{m} além do limite",
    left_until: "Faltam {m} para o limite",
    week_total: "Total da semana: {t} · média {a}/dia",
    of_limit: " de {n} min",
    total: "Tempo de tela",
    notif_limit_title: "Limite de {s} atingido",
    notif_limit_body: "{m} hoje · limite de {n} min",
    notif_still_title: "Ainda no {s}",
    notif_still_body: "{m} hoje · {o} além do limite",
    notif_warn_title: "Quase no limite de {s}",
    notif_warn_body: "Faltam {n} min para os {l} min de hoje",
    notif_total_limit_title: "Limite de tempo de tela atingido",
    notif_total_still_title: "Ainda acima do limite de tempo de tela",
    notif_total_warn_title: "Quase no limite de tempo de tela"
  },
  es: {
    all: "Todos",
    status_loading: "Cargando…",
    status_watching: "Viendo {s}",
    status_listening: "Escuchando {s}",
    status_idle: "Nada reproduciendo",
    today: "Hoy",
    meta_today: "{m} hoy",
    meta_limit: "límite {n} min",
    section_today: "HOY",
    section_services: "POR SERVICIO",
    section_week: "ÚLTIMOS 7 DÍAS",
    daily_limit: "Límite diario",
    time_today: "Tiempo hoy",
    no_limit: "Sin límite diario configurado",
    over_by: "{m} por encima del límite",
    left_until: "Faltan {m} para el límite",
    week_total: "Total de la semana: {t} · media {a}/día",
    of_limit: " de {n} min",
    total: "Tiempo de pantalla",
    notif_limit_title: "Límite de {s} alcanzado",
    notif_limit_body: "{m} hoy · límite de {n} min",
    notif_still_title: "Todavía en {s}",
    notif_still_body: "{m} hoy · {o} por encima del límite",
    notif_warn_title: "Casi en tu límite de {s}",
    notif_warn_body: "Faltan {n} min para los {l} min de hoy",
    notif_total_limit_title: "Límite de tiempo de pantalla alcanzado",
    notif_total_still_title: "Todavía por encima del límite de tiempo de pantalla",
    notif_total_warn_title: "Casi en tu límite de tiempo de pantalla"
  }
}

// "pt_BR", "pt-BR", "pt_BR.UTF-8", "pt" -> "pt"; anything unknown -> "en".
function languageFor(localeName) {
  var code = String(localeName || "").trim().toLowerCase().split(/[._@-]/)[0]
  return TABLES[code] ? code : "en"
}

function t(lang, key, args) {
  var table = TABLES[lang] || TABLES.en
  var text = table[key] !== undefined ? table[key] : (TABLES.en[key] !== undefined ? TABLES.en[key] : key)
  if (args) {
    for (var name in args) text = text.split("{" + name + "}").join(String(args[name]))
  }
  return text
}
