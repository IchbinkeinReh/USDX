// Sitzungsschluessel holen und den Dienstarbeiter aufstellen.
//
// Die Lieddateien gehen nur verschluesselt ueber die Leitung (siehe
// src/base/UWebCrypto.pas). Damit das Abspielen trotzdem unveraendert
// bleibt, entschluesselt ein Dienstarbeiter sie auf dem Weg zum
// <audio>-Element - siehe web/sw.js. Diese Einheit besorgt beides und sagt,
// ob es geklappt hat.
//
// Ohne sicheren Kontext (HTTPS oder localhost) gibt es keinen
// Dienstarbeiter. Dann gibt es auch kein Singen im Browser: getUserMedia
// verlangt denselben sicheren Kontext, das Mikrofon bliebe also ohnehin
// stumm. Es geht hier nichts verloren, was vorher ging.

import { pfad } from './game.js';

let sitzung = null;   // { sid, key }  - key als Hex, so wie der Server ihn nennt

export function sitzungsSchluessel() {
  return sitzung;
}

async function holeSitzung() {
  const r = await fetch(pfad('/api/session'), {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
  });
  if (!r.ok) throw new Error(`Sitzung abgelehnt (${r.status})`);
  const d = await r.json();
  if (!d || typeof d.sid !== 'string' || typeof d.key !== 'string')
    throw new Error('Sitzung ohne Schluessel');
  return { sid: d.sid, key: d.key };
}

// Den Schluessel an den Dienstarbeiter geben und auf seine Bestaetigung
// warten. Ohne das Warten koennte das erste Lied losgehen, bevor er ihn hat.
function schickeSchluessel(worker) {
  return new Promise((fertig, schiefgegangen) => {
    const kanal = new MessageChannel();
    const uhr = setTimeout(
      () => schiefgegangen(new Error('Dienstarbeiter antwortet nicht')), 3000);
    kanal.port1.onmessage = () => { clearTimeout(uhr); fertig(); };
    worker.postMessage(
      { art: 'schluessel', sid: sitzung.sid, key: sitzung.key }, [kanal.port2]);
  });
}

// Der Dienstarbeiter darf jederzeit beendet und neu gestartet werden. Fragt
// er danach nach dem Schluessel, bekommt er ihn - sonst bliebe der Ton nach
// einer Pause stumm.
function beantworteNachfragen() {
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (!e.data || e.data.art !== 'schluessel-bitte') return;
    if (!e.ports || !e.ports[0] || !sitzung) return;
    e.ports[0].postMessage({ sid: sitzung.sid, key: sitzung.key });
  });
}

// Stellt alles auf. Wirft, wenn es nicht geht - der Aufrufer zeigt das dann
// an, statt das Lied stumm scheitern zu lassen.
export async function starteSitzung() {
  if (!self.isSecureContext)
    throw new Error(
      'Ohne HTTPS geht es nicht: Die Lieder werden verschluesselt ' +
      'uebertragen, und der dafuer noetige Dienstarbeiter laeuft nur im ' +
      'sicheren Kontext. (Das Mikrofon uebrigens auch.)');
  if (!('serviceWorker' in navigator))
    throw new Error('Dieser Browser kennt keine Dienstarbeiter.');

  sitzung = await holeSitzung();
  beantworteNachfragen();

  // Als Modul angemeldet, weil sw.js selbst importiert. Der Geltungsbereich
  // ergibt sich aus dem Ort der Datei - deshalb liegt sie an der Wurzel und
  // nicht unter js/, sonst saehe sie /api/song/... gar nicht.
  const reg = await navigator.serviceWorker.register(pfad('/sw.js'),
                                                    { type: 'module' });
  await navigator.serviceWorker.ready;

  const worker = reg.active || navigator.serviceWorker.controller;
  if (!worker) throw new Error('Dienstarbeiter ist nicht angelaufen.');
  await schickeSchluessel(worker);

  // Beim allerersten Besuch steuert der Dienstarbeiter die Seite noch nicht;
  // Anfragen liefen dann an ihm vorbei und kaemen verschluesselt an. claim()
  // in sw.js aendert das, aber erst nach dem Aktivieren - hier wird darauf
  // gewartet, damit das erste Lied schon richtig laeuft.
  if (!navigator.serviceWorker.controller) {
    await new Promise((fertig) => {
      const weiter = () => {
        navigator.serviceWorker.removeEventListener('controllerchange', weiter);
        fertig();
      };
      navigator.serviceWorker.addEventListener('controllerchange', weiter);
      // Nicht ewig warten: Steuert er nach kurzer Zeit nicht, ist das ein
      // Fehler, den der Aufrufer anzeigen soll.
      setTimeout(weiter, 3000);
    });
  }
  if (!navigator.serviceWorker.controller)
    throw new Error('Dienstarbeiter steuert die Seite nicht.');
}
