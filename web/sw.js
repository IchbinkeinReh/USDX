// Dienstarbeiter: entschluesselt Lieddateien auf dem Weg zum Abspieler.
//
// Warum ueberhaupt hier und nicht in der Seite: Der Taktgeber des ganzen
// Spiels ist die Abspielposition des <audio>-Elements (siehe game.js). Daran
// haengen Springen, Dauer, Pause und der Gleichlauf in der Lobby. Wuerde die
// Seite den Ton selbst entschluesseln, muesste sie ihn auch selbst abspielen
// - und damit fiele genau dieser Taktgeber weg.
//
// Hier dagegen bleibt alles, wie es war: <audio>.src zeigt weiter auf
// /api/song/N/audio. Der Dienstarbeiter faengt die Anfrage ab, holt die
// verschluesselten Bytes, entschluesselt sie STUECKWEISE im Durchlauf und
// gibt eine ganz gewoehnliche Tonantwort zurueck. Das Element merkt nichts
// davon, und das ganze Lied liegt nie am Stueck im Speicher.
//
// Teilbereiche bleiben dabei heil: Woher ein Stueck kommt, steht in
// Content-Range der Antwort, und der Schluesselstrom laesst sich an genau
// dieser Stelle aufsetzen. Ohne das koennte man im Lied nicht springen.

import { chacha20XOR, nonceForFile, hexToBytes, geschuetzteDatei, startStelle }
  from './js/krypto.js';

// Im Speicher, nicht in IndexedDB oder im Cache: Der Schluessel gilt nur fuer
// diese Sitzung und hat auf der Platte nichts verloren. Der Preis ist, dass
// er nach einem Neustart des Dienstarbeiters fehlt - dafuer gibt es
// schluesselBesorgen().
let sitzung = null;   // { sid, key: Uint8Array }

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('message', (e) => {
  const d = e.data;
  if (!d || d.art !== 'schluessel') return;
  sitzung = { sid: d.sid, key: hexToBytes(d.key) };
  if (e.ports && e.ports[0]) e.ports[0].postMessage({ ok: true });
});

// Den Schluessel bei der Seite erfragen.
//
// Der Browser darf einen Dienstarbeiter jederzeit beenden und beim naechsten
// Zugriff neu starten - dann ist sitzung wieder null, obwohl die Seite noch
// offen ist und laengst einen Schluessel hat. Ohne diesen Rueckweg bliebe
// der Ton nach einer Pause stumm, und niemand saehe warum.
function frage(client) {
  return new Promise((fertig) => {
    const kanal = new MessageChannel();
    const uhr = setTimeout(() => fertig(null), 3000);
    kanal.port1.onmessage = (e) => {
      clearTimeout(uhr);
      const d = e.data;
      fertig(d && d.key ? { sid: d.sid, key: hexToBytes(d.key) } : null);
    };
    client.postMessage({ art: 'schluessel-bitte' }, [kanal.port2]);
  });
}

async function schluesselBesorgen(clientId) {
  if (sitzung) return sitzung;
  const eigner = clientId ? await self.clients.get(clientId) : null;
  const ziele = eigner ? [eigner] : await self.clients.matchAll();
  for (const c of ziele) {
    const antwort = await frage(c);
    if (antwort) {
      sitzung = antwort;
      return sitzung;
    }
  }
  return null;
}

function entschluesselnderStrom(key, nonce, stelle) {
  let offset = stelle;
  return new TransformStream({
    transform(stueck, steuerung) {
      const daten = new Uint8Array(stueck);
      chacha20XOR(key, nonce, offset, daten);
      offset += daten.length;
      steuerung.enqueue(daten);
    },
  });
}

async function hole(anfrage, clientId) {
  const url = new URL(anfrage.url);
  const datei = geschuetzteDatei(url.pathname);
  if (!datei) return fetch(anfrage);

  const s = await schluesselBesorgen(clientId);
  if (!s) {
    // Ohne Schluessel ist hier Schluss. Ausdruecklich KEIN Durchreichen der
    // verschluesselten Bytes: Das Element bekaeme Rauschen und meldete einen
    // unlesbaren Ton - ein Fehlerbild, das niemand auf eine fehlende Sitzung
    // zurueckfuehren wuerde.
    return new Response('Keine Sitzung im Dienstarbeiter', {
      status: 503,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }

  url.searchParams.set('sid', s.sid);

  // Den Teilbereich der urspruenglichen Anfrage mitnehmen. Ohne ihn liefe
  // jedes Springen im Lied auf einen Neuabruf von vorne hinaus.
  const kopf = new Headers();
  const bereich = anfrage.headers.get('Range');
  if (bereich) kopf.set('Range', bereich);

  const antwort = await fetch(url.toString(), {
    headers: kopf,
    credentials: 'same-origin',
    // Kein Zwischenspeicher des Dienstarbeiters dazwischen: Der Browser
    // verwaltet seinen Medienspeicher selbst, und zwei Schichten mit
    // Teilbereichen kommen sich nur in die Quere.
    cache: 'no-store',
  });

  if (!antwort.ok && antwort.status !== 206) return antwort;
  if (!antwort.body) return antwort;

  const nonce = nonceForFile(datei.index, datei.art);
  const strom = antwort.body.pipeThrough(
    entschluesselnderStrom(s.key, nonce, startStelle(antwort)));

  // Die Kopfzeilen bleiben, wie sie sind: Laenge, Typ und Content-Range
  // stimmen weiterhin, denn ein Stromverfahren aendert die Laenge nicht.
  return new Response(strom, {
    status: antwort.status,
    statusText: antwort.statusText,
    headers: antwort.headers,
  });
}

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;
  if (!geschuetzteDatei(url.pathname)) return;
  e.respondWith(hole(e.request, e.clientId || e.resultingClientId));
});
