// Verwaltungs- und Debug-Seite des ELRD-Backends. Ohne Bibliotheken.
"use strict";

const $ = (id) => document.getElementById(id);
const state = { key: sessionStorage.getItem("elrd.adminKey") || "", info: null, timer: null };

async function api(path, options = {}) {
  const response = await fetch("/admin/api" + path, {
    ...options,
    headers: { "Content-Type": "application/json", "X-Admin-Key": state.key, ...(options.headers || {}) },
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const message = body?.detail || body?.message || body?.title || `Fehler ${response.status}`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return body;
}

function text(value) { return value == null ? "" : String(value); }
function formatTime(value) {
  return value ? new Date(value).toLocaleString("de-DE", { dateStyle: "short", timeStyle: "medium" }) : "–";
}
function element(tag, attributes = {}, children = []) {
  const node = document.createElement(tag);
  Object.entries(attributes).forEach(([name, value]) => {
    if (name === "onclick") node.addEventListener("click", value);
    else if (name === "class") node.className = value;
    else node.setAttribute(name, value);
  });
  [].concat(children).forEach((child) => node.append(child instanceof Node ? child : document.createTextNode(text(child))));
  return node;
}

// MARK: Anmelden

$("loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  state.key = $("adminKey").value.trim();
  await start();
});

$("logout").addEventListener("click", () => {
  sessionStorage.removeItem("elrd.adminKey");
  location.reload();
});

async function start() {
  try {
    const status = await api("/status");
    sessionStorage.setItem("elrd.adminKey", state.key);
    $("login").hidden = true;
    $("app").hidden = false;
    $("logout").hidden = false;
    renderStatus(status);
    await loadOrganisations();
    await loadDebugInfo(status.debugEnabled);
    clearInterval(state.timer);
    state.timer = setInterval(refresh, 5000);
  } catch (error) {
    $("loginError").textContent = error.message;
    sessionStorage.removeItem("elrd.adminKey");
  }
}

async function refresh() {
  try {
    renderStatus(await api("/status"));
    if (state.info) await loadAlarms();
  } catch (error) {
    if (error.status === 401) location.reload();
  }
}

// MARK: Status

function renderStatus(status) {
  $("version").textContent = "Version " + status.version;
  const mqtt = status.mqtt;
  const mqttState = !mqtt.enabled
    ? element("span", { class: "bad" }, "ausgeschaltet")
    : mqtt.connected
      ? element("span", { class: "ok" }, "verbunden seit " + formatTime(mqtt.connectedSince))
      : element("span", { class: "bad" }, "nicht verbunden" + (mqtt.lastError ? " – " + mqtt.lastError : ""));
  const rows = [
    ["MQTT", mqttState],
    ["Broker", mqtt.broker],
    ["Abonnement", element("code", {}, mqtt.subscription)],
    ["Nachrichten empfangen", `${mqtt.messagesReceived} (zuletzt ${formatTime(mqtt.lastMessageAt)})`],
    ["Einsätze gespeichert", `${status.alarms} (Löschen nach ${status.retentionHours} h)`],
    ["Debug", status.debugEnabled ? "eingeschaltet" : "aus"],
  ];
  $("status").replaceChildren(...rows.flatMap(([label, value]) => [element("dt", {}, label), element("dd", {}, value)]));
}

// MARK: Organisationen

async function loadOrganisations() {
  const organisations = await api("/organisations");
  const selected = $("debugOrg").value;
  $("organisations").replaceChildren(...organisations.map((org) => element("tr", {}, [
    element("td", {}, element("code", {}, org.id)),
    element("td", {}, org.name),
    element("td", {}, element("code", {}, org.topic)),
    element("td", {}, "…" + org.apiKeyHint),
    element("td", {}, org.alarmCount),
    element("td", {}, [
      element("button", { class: "link", onclick: () => renewKey(org) }, "neuer Schlüssel"),
      element("button", { class: "link danger", onclick: () => removeOrganisation(org) }, "löschen"),
    ]),
  ])));
  $("debugOrg").replaceChildren(...organisations.map((org) => element("option", { value: org.id }, `${org.name} (${org.id})`)));
  if (organisations.some((org) => org.id === selected)) $("debugOrg").value = selected;
}

function showKey(result) {
  const box = $("newKey");
  box.hidden = false;
  box.replaceChildren(
    element("strong", {}, `App-Schlüssel für ${result.organisation.name}: `),
    element("code", {}, result.apiKey),
    element("div", {}, "Jetzt kopieren – er wird nicht noch einmal angezeigt. MQTT-Topic für FE2: " + result.organisation.topic),
  );
}

$("orgForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    const result = await api("/organisations", {
      method: "POST",
      body: JSON.stringify({ id: $("orgId").value.trim(), name: $("orgName").value.trim() }),
    });
    showKey(result);
    $("orgForm").reset();
    await loadOrganisations();
  } catch (error) {
    alert(error.message);
  }
});

async function renewKey(org) {
  if (!confirm(`Neuen Schlüssel für ${org.name} erzeugen? Der alte gilt sofort nicht mehr.`)) return;
  showKey(await api(`/organisations/${org.id}/key`, { method: "POST" }));
  await loadOrganisations();
}

async function removeOrganisation(org) {
  if (!confirm(`${org.name} samt allen Einsätzen löschen?`)) return;
  await api(`/organisations/${org.id}`, { method: "DELETE" });
  await loadOrganisations();
}

// MARK: Debug

async function loadDebugInfo(enabled) {
  $("debugOff").hidden = enabled;
  $("debugOn").hidden = !enabled;
  if (!enabled) return;
  state.info = await api("/debug/info");
  $("samples").replaceChildren(...state.info.samples.map((sample) =>
    element("button", { onclick: () => createSample(sample.id) }, `+ ${sample.keyword}: ${sample.title}`)));
  await loadAlarms();
}

function selectedOrg() {
  const org = $("debugOrg").value;
  if (!org) throw new Error("Bitte zuerst eine Organisation anlegen.");
  return org;
}

function say(message, isError = false) {
  const box = $("debugMessage");
  box.hidden = false;
  box.className = isError ? "notice error" : "notice";
  box.textContent = message;
}

async function deliver(path, body) {
  try {
    const result = await api(`/debug/${selectedOrg()}${path}`, {
      method: "POST",
      body: JSON.stringify({ ...body, via: $("via").value }),
    });
    say(`${result.via === "mqtt" ? "MQTT" : "Direkt"}: ${result.message}`);
    setTimeout(loadAlarms, result.via === "mqtt" ? 600 : 0);
  } catch (error) {
    say(error.message, true);
  }
}

const createSample = (sampleId) => deliver("/alarms", { sampleId });
const simulate = (alarm, change) => deliver(`/alarms/${alarm.id}/simulate`, { change });

$("sendRaw").addEventListener("click", () => deliver("/raw", { json: $("rawJson").value }));
$("refresh").addEventListener("click", () => loadAlarms());
$("debugOrg").addEventListener("change", () => loadAlarms());
$("clearAll").addEventListener("click", async () => {
  if (!confirm("Alle Einsätze dieser Organisation löschen?")) return;
  await api(`/debug/${selectedOrg()}/alarms`, { method: "DELETE" });
  await loadAlarms();
});

async function loadAlarms() {
  const org = $("debugOrg").value;
  if (!org || !state.info) {
    $("alarms").replaceChildren(element("p", { class: "hint" }, "Keine Organisation."));
    return;
  }
  const alarms = await api(`/debug/${org}/alarms`);
  if (alarms.length === 0) {
    $("alarms").replaceChildren(element("p", { class: "hint" }, "Noch keine Einsätze. Oben einen Testeinsatz anlegen."));
    return;
  }
  // Offene <details> (JSON) beim Neuzeichnen offen lassen.
  const open = new Set([...document.querySelectorAll(".alarm details[open]")].map((node) => node.dataset.id));
  $("alarms").replaceChildren(...alarms.map((alarm) => renderAlarm(alarm, open.has(alarm.id))));
}

function renderAlarm(alarm, jsonOpen) {
  const node = $("alarmTemplate").content.firstElementChild.cloneNode(true);
  const data = alarm.data || {};
  if (alarm.closedAt) node.classList.add("closed");
  node.querySelector(".keyword").textContent = data.keyword || "ohne Stichwort";
  node.querySelector(".description").textContent = data.keyword_description || "";
  const badges = [
    `Stand ${alarm.revision}`,
    alarm.isTest ? "Test" : null,
    alarm.closedAt ? "geschlossen" : null,
    alarm.source,
  ].filter(Boolean).map((label) => element("span", { class: "pill" }, label));
  node.querySelector(".badges").replaceChildren(...badges);
  node.querySelector(".meta").textContent =
    `Einsatznummer ${alarm.externalId} · eingegangen ${formatTime(alarm.receivedAt)} · geändert ${formatTime(alarm.updatedAt)}`;
  const location = data.location || {};
  const coordinate = Array.isArray(location.coordinate) ? ` (${location.coordinate[1]}, ${location.coordinate[0]})` : "";
  node.querySelector(".address").textContent =
    [[location.street, location.house].filter(Boolean).join(" "), [location.postalCode, location.city].filter(Boolean).join(" ")]
      .filter(Boolean).join(", ") + coordinate;
  const vehicles = (data.vehicles || []).map((vehicle) => vehicle.radioName || vehicle.name).filter(Boolean);
  const patients = (data.patient || []).length;
  node.querySelector(".detail").textContent =
    `Fahrzeuge: ${vehicles.join(", ") || "–"} · Patienten: ${patients}`;
  const actions = state.info.changes.map((change) =>
    element("button", { class: "secondary", onclick: () => simulate(alarm, change.id) }, change.title));
  actions.push(element("button", {
    class: "link danger",
    onclick: async () => { await api(`/debug/${alarm.organisationId || selectedOrg()}/alarms/${alarm.id}`, { method: "DELETE" }); loadAlarms(); },
  }, "löschen"));
  node.querySelector(".actions").replaceChildren(...actions);
  const details = node.querySelector("details");
  details.dataset.id = alarm.id;
  details.open = jsonOpen;
  node.querySelector(".json").textContent = JSON.stringify(alarm, null, 2);
  return node;
}

if (state.key) start();
