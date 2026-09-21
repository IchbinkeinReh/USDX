// Prueft im ECHTEN Browser, was kein anderer Test erreicht: dass der
// Dienstarbeiter die Anfrage abfaengt und <audio> mit dem entschluesselten
// Strom etwas anfangen kann.
//
// Aufruf: node web/tests/browser.mjs <basis-url> <cdp-url>
// Gestartet von tests/browser.sh, das Server und Browser beistellt.
//
// Die Arbeitsteilung der Tests rund um die Verschluesselung:
//   testwebcrypto.pas  - ChaCha20 im Server gegen RFC 8439
//   web/tests/run.mjs  - ChaCha20 im Browser gegen dieselben Werte
//   web/tests/strom.mjs- beide zusammen ueber echtes HTTP, ohne Browser
//   dieser Test        - Dienstarbeiter und Tonausgabe, nur im Browser
//
// Gesprochen wird ueber CDP, von Hand. Node bringt seit 22 einen
// WebSocket-Client mit; Puppeteer o.ae. waere eine Abhaengigkeit, die das
// Projekt sonst nirgends braucht.

const BASIS = process.argv[2];
const CDP = process.argv[3];

// Die Tondatei des Probelieds: 6,0 s. Steht hier, weil die Pruefung der
// Dauer sonst nichts aussagt.
const DAUER = 6.0;

let bestanden = 0, fehlgeschlagen = 0;
function check(was, bedingung, detail = '') {
  if (bedingung) { bestanden++; console.log('  OK   ' + was); }
  else { fehlgeschlagen++; console.log('  FEHL ' + was + '   ' + detail); }
}

let id = 0;
const offen = new Map();

const ziel = await (await fetch(
  `${CDP}/json/new?${encodeURIComponent('about:blank')}`,
  { method: 'PUT' })).json();

const ws = new WebSocket(ziel.webSocketDebuggerUrl);
await new Promise((ok, f) => {
  ws.onopen = ok;
  ws.onerror = () => f(new Error('keine Verbindung zum Browser'));
});

const meldungen = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && offen.has(m.id)) {
    const { ok, f } = offen.get(m.id);
    offen.delete(m.id);
    if (m.error) f(new Error(m.error.message)); else ok(m.result);
    return;
  }
  if (m.method === 'Runtime.consoleAPICalled')
    meldungen.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
  if (m.method === 'Runtime.exceptionThrown')
    meldungen.push('AUSNAHME ' + m.params.exceptionDetails.text);
};

function ruf(method, params = {}) {
  const nr = ++id;
  ws.send(JSON.stringify({ id: nr, method, params }));
  return new Promise((ok, f) => {
    offen.set(nr, { ok, f });
    setTimeout(() => {
      if (offen.has(nr)) { offen.delete(nr); f(new Error('Zeit aus: ' + method)); }
    }, 30000);
  });
}

async function werte(ausdruck) {
  const r = await ruf('Runtime.evaluate',
    { expression: ausdruck, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails)
    throw new Error(r.exceptionDetails.text + ' ' +
      (r.exceptionDetails.exception?.description ?? ''));
  return r.result.value;
}

await ruf('Page.enable');
await ruf('Runtime.enable');
await ruf('Page.navigate', { url: BASIS + '/' });

// Auf den Dienstarbeiter warten, statt blind zu schlafen: Anmelden und
// Uebernehmen brauchen beim ersten Aufruf einen Augenblick.
const bereit = await werte(`(async () => {
  for (let i = 0; i < 60; i++) {
    if (navigator.serviceWorker && navigator.serviceWorker.controller) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
})()`);

console.log('Dienstarbeiter');
check('sicherer Kontext', await werte('self.isSecureContext') === true);
check('Dienstarbeiter steuert die Seite', bereit === true);

// Der Nachweis, dass er wirklich dazwischensitzt: Die Seite fragt OHNE sid.
// Kaeme die Anfrage so beim Server an, waere sie 403. Ein 200 mit lesbarem
// Inhalt kann es also nur geben, wenn der Dienstarbeiter die Sitzung
// angehaengt und den Strom entschluesselt hat.
const txt = await werte(`(async () => {
  const r = await fetch('/api/song/0/txt');
  const t = await r.text();
  return { status: r.status, anfang: t.slice(0, 30), laenge: t.length };
})()`);
check('Noten kommen mit 200 statt 403', txt.status === 200, JSON.stringify(txt));
check('und sind entschluesselt lesbar',
      String(txt.anfang).includes('#TITLE:Probeton'), JSON.stringify(txt));

console.log('Ton');

// Der eigentliche Punkt: unveraenderte Adresse am <audio>, und der Decoder
// des Browsers macht etwas damit. Geht hier irgendetwas schief, kommt statt
// Ton nur Rauschen an - und genau das soll auffallen.
const ton = await werte(`(async () => {
  const a = new Audio();
  a.preload = 'auto';
  a.muted = true;
  a.src = '/api/song/0/audio';
  const wie = await new Promise((ok) => {
    const t = setTimeout(() => ok('zeit aus'), 20000);
    a.addEventListener('loadedmetadata', () => { clearTimeout(t); ok('metadaten'); });
    a.addEventListener('error', () => {
      clearTimeout(t); ok('fehler ' + (a.error && a.error.code)); });
    a.load();
  });
  if (wie !== 'metadaten') return { wie };

  // Springen: beweist, dass der Strom auch in der Mitte stimmt und nicht
  // nur der Anfang zufaellig passt.
  const sprungZiel = ${DAUER} * 0.6;
  const gesprungen = await new Promise((ok) => {
    const t = setTimeout(() => ok('zeit aus'), 20000);
    a.addEventListener('seeked', () => { clearTimeout(t); ok('gesprungen'); },
                       { once: true });
    a.currentTime = sprungZiel;
  });

  const vorher = a.currentTime;
  let spiel = 'ok';
  try { await a.play(); } catch (e) { spiel = 'verweigert: ' + e.name; }
  await new Promise((r) => setTimeout(r, 1200));
  return { wie, gesprungen, vorher, spiel,
           dauer: a.duration, nachher: a.currentTime, laeuft: !a.paused };
})()`);

check('<audio> laedt die Metadaten', ton.wie === 'metadaten', JSON.stringify(ton));
check('und meldet die richtige Dauer',
      Math.abs(ton.dauer - DAUER) < 0.35, JSON.stringify(ton));
check('Springen im Lied klappt', ton.gesprungen === 'gesprungen',
      JSON.stringify(ton));
check('und landet an der richtigen Stelle',
      Math.abs(ton.vorher - DAUER * 0.6) < 0.35, JSON.stringify(ton));
check('Wiedergabe laeuft an', ton.spiel === 'ok' && ton.laeuft === true,
      JSON.stringify(ton));
check('und die Abspielposition laeuft weiter',
      ton.nachher > ton.vorher, JSON.stringify(ton));

console.log('Nichts vorladen, solange niemand singt');

// In der Liste wird hin und her getippt. Haengt dabei schon die Tondatei am
// Element, laufen je Antippen ein paar Megabyte los - und schlimmer: Gezaehlt
// wird beim ersten Byte Ton, das blosse Antippen galt also als Auffuehrung.
const laden = await werte(`(async () => {
  const m = await import('/js/game.js');
  const g = new m.Game(document.createElement('canvas'), {
    titel: document.createElement('div'),
    hinweis: { textContent: '' },
    video: null, bild: null,
  });
  // Gezaehlt wird nur, was WAEHREND des Ladens dazukommt - die Pruefungen
  // weiter oben haben selbst schon Ton geholt und stuenden sonst mit drin.
  const medienAbrufe = () => performance.getEntriesByType('resource')
    .map((e) => e.name)
    .filter((n) => /\\/api\\/song\\/0\\/(audio|video)/.test(n)).length;
  const vorher = medienAbrufe();
  await g.ladeLied(0);
  // Ein Abruf braucht einen Moment, bis er in der Liste steht.
  await new Promise((r) => setTimeout(r, 1500));
  const nachAuswahl = {
    src: g.audio.src,
    abrufe: medienAbrufe() - vorher,
    noten: !!g.song,
  };
  g.bereiteMedien();
  return { nachAuswahl, nachStart: { src: g.audio.src } };
})()`);

check('Noten sind nach dem Auswaehlen da',
      laden.nachAuswahl.noten === true, JSON.stringify(laden));
check('aber der Ton haengt noch nicht am Element',
      laden.nachAuswahl.src === '', JSON.stringify(laden.nachAuswahl));
check('und es wurde nichts von Ton oder Video geholt',
      laden.nachAuswahl.abrufe === 0, JSON.stringify(laden.nachAuswahl));
check('erst beim Singen kommt der Ton dazu',
      /\/api\/song\/0\/audio/.test(laden.nachStart.src), JSON.stringify(laden.nachStart));
// Ohne Durchgang zaehlt der Server nicht (siehe UWebZaehler.Zaehle).
check('und zwar mit Durchgangskennung',
      /[?&]lauf=[^&]+/.test(laden.nachStart.src), JSON.stringify(laden.nachStart));

console.log('Vorschau');

// Der Schnipsel ist eine eigene Datei mit eigenem Endpunkt. Er muss
// abspielbar sein, hoechstens eine halbe Minute dauern - und vor allem darf
// er NICHT ueber /audio laufen, denn daran haengt die Zaehlung.
const vorschau = await werte(`(async () => {
  const a = new Audio();
  a.preload = 'auto';
  a.muted = true;
  a.src = '/api/song/0/preview';
  const wie = await new Promise((ok) => {
    const t = setTimeout(() => ok('zeit aus'), 20000);
    a.addEventListener('loadedmetadata', () => { clearTimeout(t); ok('metadaten'); });
    a.addEventListener('error', () => {
      clearTimeout(t); ok('fehler ' + (a.error && a.error.code)); });
    a.load();
  });
  if (wie !== 'metadaten') return { wie };
  let spiel = 'ok';
  try { await a.play(); } catch (e) { spiel = 'verweigert: ' + e.name; }
  await new Promise((r) => setTimeout(r, 900));
  return { wie, spiel, dauer: a.duration, pos: a.currentTime, laeuft: !a.paused };
})()`);

check('Vorschau laedt ueber ihren eigenen Endpunkt',
      vorschau.wie === 'metadaten', JSON.stringify(vorschau));
check('und laesst sich abspielen',
      vorschau.spiel === 'ok' && vorschau.laeuft === true &&
      vorschau.pos > 0.2, JSON.stringify(vorschau));
// Das Probelied ist 6 s lang, der Schnipsel also kuerzer als die Grenze.
// Geprueft wird die Grenze selbst: Laenger als eine halbe Minute darf er nie
// sein, egal wie lang das Lied ist.
check('und dauert hoechstens eine halbe Minute',
      vorschau.dauer > 0 && vorschau.dauer <= 30.5, JSON.stringify(vorschau));

if (meldungen.length) {
  console.log();
  console.log('  Meldungen aus der Seite:');
  for (const z of meldungen.slice(0, 10)) console.log('    ' + z);
}

console.log();
console.log(`${bestanden} bestanden, ${fehlgeschlagen} fehlgeschlagen`);
ws.close();
process.exit(fehlgeschlagen > 0 ? 1 : 0);
