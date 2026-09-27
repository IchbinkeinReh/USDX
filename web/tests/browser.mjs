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

// geste: als echte Nutzergeste ausfuehren - fuer Klicks, hinter denen die
// Seite Vollbild oder Ton anfordert.
async function werte(ausdruck, { geste = false } = {}) {
  const r = await ruf('Runtime.evaluate',
    { expression: ausdruck, awaitPromise: true, returnByValue: true,
      userGesture: geste });
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

console.log('Startseite und Radio');

// Wartet in der Seite, bis BEDINGUNG (ein Ausdruck) wahr ist.
async function warteAuf(bedingung, ms = 20000) {
  return werte(`(async () => {
    const ende = Date.now() + ${ms};
    while (Date.now() < ende) {
      try { if (${bedingung}) return true; } catch (e) {}
      await new Promise((r) => setTimeout(r, 200));
    }
    return false;
  })()`);
}
const sichtbar = (id) => `!document.getElementById('${id}').classList.contains('aus')`;

// Frisch laden: Die Abschnitte oben haben die Seite nur als Huelle benutzt.
await ruf('Page.navigate', { url: BASIS + '/' });
check('die Seite wird bereit',
      await warteAuf(`document.documentElement.dataset.bereit === '1'`));
// Installierbar? Chrome prueft das selbst - Manifest, Symbole, Dienstarbeiter,
// sicherer Kontext. Leere Fehlerliste heisst: Der Browser bietet die
// Installation an.
const installierbar = await ruf('Page.getInstallabilityErrors');
check('Chrome haelt die Seite fuer installierbar',
      Array.isArray(installierbar.installabilityErrors) &&
      installierbar.installabilityErrors.length === 0,
      JSON.stringify(installierbar.installabilityErrors));
const manifest = await ruf('Page.getAppManifest');
check('Manifest ohne Fehler geladen',
      manifest.errors.length === 0 && /"short_name": "UltraStar"/.test(manifest.data || ''),
      JSON.stringify(manifest.errors));
const symbole = await werte(`Promise.all(['/icons/icon-192.png', '/icons/icon-512.png',
    '/icons/icon-maskable-512.png', '/icons/apple-touch-icon.png'].map(async (p) => {
  const r = await fetch(p);
  const b = await createImageBitmap(await r.blob());
  return p + ' ' + r.status + ' ' + b.width;
}))`);
check('alle App-Symbole laden in der richtigen Groesse',
      symbole.join() === ['/icons/icon-192.png 200 192', '/icons/icon-512.png 200 512',
        '/icons/icon-maskable-512.png 200 512', '/icons/apple-touch-icon.png 200 180'].join(),
      JSON.stringify(symbole));

check('ohne Angaben erscheint die Startseite',
      await warteAuf(`${sichtbar('startseite')} && !(${sichtbar('auswahl')})`));
check('mit beiden Knoepfen',
      await werte(`!!document.getElementById('zur_party') &&
                   !!document.getElementById('zum_radio')`));

await werte(`document.getElementById('zum_radio').click()`, { geste: true });
// Die Liste kommt erst, wenn der Vorschau-Schnipsel des Probelieds gebaut
// ist - der Server blendet Lieder ohne ihn aus.
const radioBereit = await warteAuf(
  `${sichtbar('auswahl')} && !document.getElementById('radio_start').disabled`);
check('Radio: Liste mit Start-Knopf', radioBereit);
const radioAnsicht = await werte(`({
  url: location.search,
  lobby: ${sichtbar('lobby_leiste')},
  zufall: ${sichtbar('zufall')},
  start: ${sichtbar('radio_start')},
})`);
check('Radio steht in der Adresse, die Lobby nicht',
      /modus=radio/.test(radioAnsicht.url) && !/lobby=/.test(radioAnsicht.url),
      JSON.stringify(radioAnsicht));
check('ohne Lobby-Leiste und ohne Zufallsknopf',
      !radioAnsicht.lobby && !radioAnsicht.zufall && radioAnsicht.start,
      JSON.stringify(radioAnsicht));

await werte(`document.getElementById('radio_start').click()`, { geste: true });
check('Start spielt ein Lied auf der Buehne',
      await warteAuf(`${sichtbar('buehne')} &&
                      document.getElementById('buehne').dataset.radioLied === '1'`));
const aufBuehne = await werte(`({
  vorbereitung: ${sichtbar('vorbereitung')},
  mikrofone: document.querySelectorAll('#stimmen select').length,
  knopf: document.getElementById('zurueck').textContent,
  start: document.getElementById('startflaeche').style.display,
})`);
check('keine Mikrofonauswahl, kein "Los geht\'s"',
      !aufBuehne.vorbereitung && aufBuehne.mikrofone === 0 &&
      aufBuehne.start === 'none', JSON.stringify(aufBuehne));
check('der Zurueck-Knopf heisst "Radio beenden"',
      aufBuehne.knopf === 'Radio beenden', JSON.stringify(aufBuehne));
// Die Blende braucht 0,4 s; danach muss die Einblendung wirklich zu sehen
// sein - die Klasse allein sagt das nicht (einmal verdeckte sie eine
// staerkere CSS-Regel).
await new Promise((r) => setTimeout(r, 600));
const titelAn = await werte(`({
  an: getComputedStyle(document.getElementById('radio_titel')).opacity === '1',
  mitspieler: ${sichtbar('mitspieler')},
  text: document.getElementById('radio_titel').textContent.replace(/\\s+/g, ' ').trim(),
})`);
check('beim Liedwechsel stehen Interpret und Titel sichtbar in der Mitte',
      titelAn.an && titelAn.text.includes('Testlauf') && titelAn.text.includes('Probeton'),
      JSON.stringify(titelAn));
check('keine Mitspielerzeile im Radio', !titelAn.mitspieler, JSON.stringify(titelAn));
await new Promise((r) => setTimeout(r, 3000));
check('und verschwinden nach drei Sekunden wieder',
      await werte(`getComputedStyle(document.getElementById('radio_titel')).opacity === '0' &&
                   document.getElementById('buehne').dataset.radioLied === '1'`));

// Das Probelied dauert 6 s. Danach muss ohne weiteres Zutun das naechste
// kommen - bei nur einem Treffer eben dasselbe noch einmal.
check('nach dem Ende laeuft von selbst das naechste Lied',
      await warteAuf(`document.getElementById('buehne').dataset.radioLied === '2'`,
                     20000));

await werte(`document.getElementById('zurueck').click()`, { geste: true });
const nachRadio = await warteAuf(`!(${sichtbar('buehne')}) && ${sichtbar('auswahl')}`);
check('"Radio beenden" fuehrt zur Liste zurueck', nachRadio);
await new Promise((r) => setTimeout(r, 7000));
check('und danach startet nichts mehr',
      await werte(`document.getElementById('buehne').dataset.radioLied === '2' &&
                   document.getElementById('buehne').classList.contains('aus')`));

// Angehalten gibt es Knoepfe: Karaoke, vorheriges und naechstes Lied.
document_start: {
  await werte(`document.getElementById('buehne').dataset.radioLied = ''`);
  await werte(`document.getElementById('radio_start').click()`, { geste: true });
  if (!await warteAuf(`document.getElementById('buehne').dataset.radioLied === '1'`)) {
    check('Radio fuer den Pausentest gestartet', false);
    break document_start;
  }
  const tippe = `document.getElementById('bild_flaeche').dispatchEvent(
    new PointerEvent('pointerdown', { bubbles: true, clientX: 50, clientY: 50 }))`;
  await werte(tippe, { geste: true });
  check('Pause im Radio zeigt die Knopfleiste',
        await warteAuf(`${sichtbar('radio_pause')}`, 3000));
  const leiste = await werte(`({
    zurueck: document.getElementById('radio_zurueck').disabled,
    karaoke: ${sichtbar('radio_karaoke')},
    text: document.getElementById('radio_karaoke').textContent,
  })`);
  check('beim ersten Lied gibt es kein vorheriges', leiste.zurueck === true,
        JSON.stringify(leiste));
  check('das Probelied hat Karaoke, also steht der Knopf da',
        leiste.karaoke && leiste.text === 'Karaoke-Version', JSON.stringify(leiste));

  await werte(`performance.clearResourceTimings()`);
  await werte(`document.getElementById('radio_karaoke').click()`, { geste: true });
  check('Karaoke umgeschaltet, Knopf bietet jetzt das Original an',
        await warteAuf(`document.getElementById('radio_karaoke').textContent ===
                        'Original mit Gesang' &&
                        !document.getElementById('radio_karaoke').disabled`));
  check('und dafuer wird die Karaoke-Spur geholt',
        await warteAuf(`performance.getEntriesByType('resource')
                          .some((e) => e.name.includes('/api/song/0/karaoke'))`, 5000));
  check('die Pause bleibt dabei stehen', await werte(`${sichtbar('radio_pause')}`));

  await werte(`document.getElementById('radio_vor').click()`, { geste: true });
  check('"Nächstes Lied" spielt das naechste',
        await warteAuf(`document.getElementById('buehne').dataset.radioLied === '2' &&
                        !(${sichtbar('radio_pause')})`));

  await werte(tippe, { geste: true });
  await warteAuf(`${sichtbar('radio_pause')}`, 3000);
  check('jetzt gibt es ein vorheriges',
        await werte(`!document.getElementById('radio_zurueck').disabled`));
  check('und Karaoke gilt fuer das neue Lied weiter',
        await werte(`document.getElementById('radio_karaoke').textContent ===
                     'Original mit Gesang'`));
  await werte(`document.getElementById('radio_zurueck').click()`, { geste: true });
  check('"Vorheriges Lied" spielt es',
        await warteAuf(`document.getElementById('buehne').dataset.radioLied === '3' &&
                        !(${sichtbar('radio_pause')})`));

  await werte(`document.getElementById('zurueck').click()`, { geste: true });
  await warteAuf(`${sichtbar('auswahl')}`);
}

// Auf manchen Handys kommt das Vollbild-Versprechen nie zurueck. Das Radio
// darf darauf nicht warten - frueher blieb es bei "Lied wird ausgesucht".
await werte(`(() => {
  window.__echtesVollbild = Element.prototype.requestFullscreen;
  Element.prototype.requestFullscreen = () => new Promise(() => {});
  document.getElementById('buehne').dataset.radioLied = '';
})()`);
await werte(`document.getElementById('radio_start').click()`, { geste: true });
check('Radio spielt auch, wenn das Vollbild nie antwortet',
      await warteAuf(`document.getElementById('buehne').dataset.radioLied === '1'`),
      JSON.stringify(await werte(`({ nr: document.getElementById('buehne').dataset.radioLied,
        hinweis: document.getElementById('ergebnis').textContent,
        buehne: ${sichtbar('buehne')}, meldung: document.getElementById('radio_meldung').textContent,
        weiter: ${sichtbar('radio_weiter_flaeche')} })`)));
await werte(`document.getElementById('zurueck').click()`, { geste: true });
await warteAuf(`${sichtbar('auswahl')}`);

// Verweigert der Browser das Losspielen ohne Antippen, soll gefragt werden,
// statt das Lied als kaputt zu verbuchen.
await werte(`(() => {
  window.__echtesPlay = HTMLMediaElement.prototype.play;
  let einmal = true;
  HTMLMediaElement.prototype.play = function () {
    if (einmal) { einmal = false;
      return Promise.reject(new DOMException('gesperrt', 'NotAllowedError')); }
    return window.__echtesPlay.call(this);
  };
  document.getElementById('buehne').dataset.radioLied = '';
})()`);
await werte(`document.getElementById('radio_start').click()`, { geste: true });
check('gesperrter Autostart: "Weiter hören" erscheint',
      await warteAuf(`${sichtbar('radio_weiter_flaeche')}`));
await werte(`document.getElementById('radio_weiter').click()`, { geste: true });
check('und ein Tipp darauf spielt das Lied',
      await warteAuf(`document.getElementById('buehne').dataset.radioLied === '1' &&
                      !(${sichtbar('radio_weiter_flaeche')})`));
await werte(`document.getElementById('zurueck').click()`, { geste: true });
await warteAuf(`${sichtbar('auswahl')}`);
await werte(`(() => {
  Element.prototype.requestFullscreen = window.__echtesVollbild;
  HTMLMediaElement.prototype.play = window.__echtesPlay;
})()`);

await werte(`document.getElementById('zur_startseite').click()`, { geste: true });
check('der Haus-Knopf fuehrt zur Startseite',
      await warteAuf(`${sichtbar('startseite')} && location.search === ''`));

await werte(`document.getElementById('zur_party').click()`, { geste: true });
const party = await warteAuf(`${sichtbar('lobby_leiste')} && ${sichtbar('zufall')} &&
                               /modus=party/.test(location.search) &&
                               /lobby=[0-9]{6}/.test(location.search)`);
check('Party: Lobby-Leiste, Zufallsknopf, Lobby-Nummer in der Adresse', party,
      JSON.stringify(await werte(`({ url: location.search,
        lobby: ${sichtbar('lobby_leiste')}, zufall: ${sichtbar('zufall')},
        auswahl: ${sichtbar('auswahl')} })`)));

// Einladungen von vor der Startseite tragen kein modus - sie muessen
// trotzdem in der Party landen.
await ruf('Page.navigate', { url: BASIS + '/?lobby=000000' });
await warteAuf(`document.documentElement.dataset.bereit === '1'`);
check('alter Einladungslink landet in der Party',
      await warteAuf(`${sichtbar('lobby_leiste')} && !(${sichtbar('startseite')}) &&
                      /modus=party/.test(location.search)`));

if (meldungen.length) {
  console.log();
  console.log('  Meldungen aus der Seite:');
  for (const z of meldungen.slice(0, 10)) console.log('    ' + z);
}

console.log();
console.log(`${bestanden} bestanden, ${fehlgeschlagen} fehlgeschlagen`);
ws.close();
process.exit(fehlgeschlagen > 0 ? 1 : 0);
