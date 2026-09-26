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
  // Dieser Test gilt dem ZEITPUNKT des Ladens, nicht der Tonspur - das
  // Probelied hat inzwischen eine Karaoke-Version, deren eigenes Verhalten
  // weiter unten geprueft wird (Abschnitt "Karaoke"). Ausdruecklich auf die
  // normale Spur gestellt, damit dieser Test unabhaengig davon bleibt.
  g.karaokeGewuenscht = false;
  g.bereiteMedien();
  return { nachAuswahl, nachBuehne: { src: g.audio.src } };
})()`);

check('Noten sind nach dem Auswaehlen da',
      laden.nachAuswahl.noten === true, JSON.stringify(laden));
check('aber der Ton haengt noch nicht am Element',
      laden.nachAuswahl.src === '', JSON.stringify(laden.nachAuswahl));
check('und es wurde nichts von Ton oder Video geholt',
      laden.nachAuswahl.abrufe === 0, JSON.stringify(laden.nachAuswahl));
check('auf der Buehne kommt der Ton dazu',
      /\/api\/song\/0\/audio/.test(laden.nachBuehne.src),
      JSON.stringify(laden.nachBuehne));
// Das Vorladen darf NICHT zaehlen: Wer die Buehne betritt und es sich
// anders ueberlegt, hat nicht gesungen. Gezaehlt wird getrennt, siehe
// zaehleAuffuehrung().
check('aber noch ohne Durchgang, zaehlt also nicht',
      !/[?&]lauf=/.test(laden.nachBuehne.src), JSON.stringify(laden.nachBuehne));

// Und beim tatsaechlichen Losgehen muss die Meldung rausgehen, sonst
// erschiene das Lied nie in web-gesungen.tsv.
const zaehlung = await werte(`(async () => {
  const m = await import('/js/game.js');
  const g = new m.Game(document.createElement('canvas'), {
    titel: document.createElement('div'),
    hinweis: { textContent: '' },
    video: null, bild: null,
  });
  await g.ladeLied(0);
  // Siehe die gleiche Anmerkung beim vorigen Test: bewusst auf die normale
  // Spur gestellt, unabhaengig von der Voreinstellung des Liedes.
  g.karaokeGewuenscht = false;
  const vorher = performance.getEntriesByType('resource').length;
  g.zaehleAuffuehrung();
  await new Promise((r) => setTimeout(r, 1500));
  const neu = performance.getEntriesByType('resource')
    .slice(vorher).map((e) => e.name)
    .filter((n) => /\\/api\\/song\\/0\\/audio/.test(n));
  return { neu };
})()`);
check('beim Losgehen wird die Auffuehrung gemeldet',
      zaehlung.neu.length === 1, JSON.stringify(zaehlung));
check('und zwar mit Durchgangskennung',
      /[?&]lauf=[^&]+/.test(zaehlung.neu[0] || ''), JSON.stringify(zaehlung));

console.log('Karaoke');

// Das Probelied hat seit tests/probelied/"ton [INSTR].m4a" eine
// Karaoke-Tonspur - andere Dauer als ton.mp3 (6,08 s), damit sich anhand der
// tatsaechlichen Wiedergabedauer nachweisen laesst, welche Datei wirklich
// ankam, nicht nur, welche Adresse angefordert wurde.
const kar = await werte(`(async () => {
  const kopf = await fetch('/api/song/0/txt');
  const m = await import('/js/game.js');
  const g = new m.Game(document.createElement('canvas'), {
    titel: document.createElement('div'),
    hinweis: { textContent: '' },
    video: null, bild: null,
  });
  await g.ladeLied(0);
  const nachLaden = { hatKaraoke: g.hatKaraoke, karaokeGewuenscht: g.karaokeGewuenscht };

  g.karaokeGewuenscht = true;
  g.bereiteMedien();
  await new Promise((ok) => {
    const t = setTimeout(ok, 15000);
    g.audio.addEventListener('loadedmetadata', () => { clearTimeout(t); ok(); }, { once: true });
  });
  const alsKaraoke = { src: g.audio.src, dauer: g.audio.duration };

  g.karaokeGewuenscht = false;
  g.bereiteMedien();
  await new Promise((ok) => {
    const t = setTimeout(ok, 15000);
    g.audio.addEventListener('loadedmetadata', () => { clearTimeout(t); ok(); }, { once: true });
  });
  const alsNormal = { src: g.audio.src, dauer: g.audio.duration };

  g.karaokeGewuenscht = true;
  // Geleert statt nur gezaehlt: Bis hierher sind schon etliche Abrufe
  // gelaufen (zwei volle Downloads oben, plus alles vor diesem Abschnitt im
  // selben Testlauf) - der Ringpuffer fuer Ressourcen-Zeitmessung ist
  // begrenzt, und ein Schnappschuss der LAENGE traf hier einmal knapp daneben,
  // weil aeltere Eintraege schon herausgefallen waren. Leeren macht den
  // naechsten Abruf eindeutig, egal wie voll der Puffer vorher war.
  performance.clearResourceTimings();
  g.zaehleAuffuehrung();
  let gezaehlt = [];
  for (let i = 0; i < 30; i++) {
    gezaehlt = performance.getEntriesByType('resource').map((e) => e.name)
      .filter((n) => /\\/api\\/song\\/0\\/karaoke/.test(n));
    if (gezaehlt.length > 0) break;
    await new Promise((r) => setTimeout(r, 200));
  }

  return {
    xKaraoke: kopf.headers.get('X-Karaoke'),
    nachLaden, alsKaraoke, alsNormal, gezaehlt,
  };
})()`);

check('X-Karaoke steht bei der Notendatei auf 1', kar.xKaraoke === '1', kar);
check('hatKaraoke wird aus der Kopfzeile gesetzt',
      kar.nachLaden.hatKaraoke === true, kar.nachLaden);
check('Voreinstellung ist Original, nicht Karaoke',
      kar.nachLaden.karaokeGewuenscht === false, kar.nachLaden);
check('mit Karaoke gewaehlt zeigt bereiteMedien() auf /karaoke',
      /\/karaoke(\?|$)/.test(kar.alsKaraoke.src), kar.alsKaraoke);
check('und liefert tatsaechlich die Instrumentalversion (8 s, nicht 6)',
      Math.abs(kar.alsKaraoke.dauer - 8) < 0.5, kar.alsKaraoke);
check('nach Umschalten zeigt bereiteMedien() auf /audio',
      /\/audio(\?|$)/.test(kar.alsNormal.src), kar.alsNormal);
check('und liefert wieder die normale Aufnahme (~6 s, nicht 8)',
      Math.abs(kar.alsNormal.dauer - 6.084) < 0.5, kar.alsNormal);
check('zaehleAuffuehrung() meldet die Auffuehrung unter /karaoke, wenn gewaehlt',
      kar.gezaehlt.length === 1, kar);

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
