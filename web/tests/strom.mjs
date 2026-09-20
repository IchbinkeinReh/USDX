// Prueft die Rechnung des Dienstarbeiters gegen den LAUFENDEN Server.
//
// Aufruf: node web/tests/strom.mjs <basis-url> <pfad-zur-tondatei> <liednummer>
// Wird von tests/headless.sh gestartet, wo ohnehin ein Server laeuft.
//
// Warum das noetig ist: testwebcrypto und web/tests/run.mjs pruefen beide
// Haelften einzeln gegen RFC 8439. Dass Server und Browser dann auch
// ZUSAMMEN dasselbe tun - ueber echtes HTTP, mit echten Teilbereichen und
// einer Antwort, die in mehreren Stuecken ankommt - zeigt erst dieser Test.
//
// Was er NICHT abdeckt: das Abfangen der Anfrage durch den Dienstarbeiter
// und den Decoder des Browsers. Dafuer braucht es einen Browser.

import { readFileSync } from 'node:fs';
import { chacha20XOR, nonceForFile, hexToBytes, startStelle,
         geschuetzteDatei } from '../js/krypto.js';

const BASIS = process.argv[2];
const TONDATEI = process.argv[3];
// Welches Lied die Tondatei traegt - die Reihenfolge haengt an den Ordnern,
// deshalb wird sie uebergeben und nicht geraten.
const NR = process.argv[4] ?? '0';

let bestanden = 0, fehlgeschlagen = 0;
const check = (was, ok, detail = '') => {
  if (ok) { bestanden++; console.log('  OK   ' + was); }
  else { fehlgeschlagen++; console.log('  FEHL ' + was + '   ' + detail); }
};

const sitzung = await (await fetch(BASIS + '/api/session',
                                   { method: 'POST' })).json();
const key = hexToBytes(sitzung.key);

// Wortgleich mit entschluesselnderStrom in web/sw.js.
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

async function hole(pfad, bereich) {
  const datei = geschuetzteDatei(pfad);
  const url = new URL(BASIS + pfad);
  url.searchParams.set('sid', sitzung.sid);
  const kopf = new Headers();
  if (bereich) kopf.set('Range', bereich);
  const antwort = await fetch(url, { headers: kopf });
  const strom = antwort.body.pipeThrough(entschluesselnderStrom(
    key, nonceForFile(datei.index, datei.art), startStelle(antwort)));
  const stuecke = [];
  for await (const s of strom) stuecke.push(Buffer.from(s));
  return { status: antwort.status, body: Buffer.concat(stuecke) };
}

const original = readFileSync(TONDATEI);

let r = await hole(`/api/song/${NR}/audio`);
check('ganze Datei kommt byteweise heil an',
      (r.status === 200 || r.status === 206) && r.body.equals(original),
      `${r.status}, ${r.body.length} statt ${original.length}`);

// Ohne diese Probe wuerde der Test auch dann gruen, wenn gar nicht
// verschluesselt wird - entschluesseln von Klartext faellt sonst nicht auf.
const roh = Buffer.from(await (await fetch(
  `${BASIS}/api/song/${NR}/audio?sid=${sitzung.sid}`)).arrayBuffer());
check('ueber die Leitung geht etwas anderes als die Datei',
      roh.length === original.length && !roh.equals(original));

// Teilbereiche. Die krummen Grenzen sind Absicht: Genau an einer
// 64-Byte-Blockgrenze faellt ein falsch aufgesetzter Strom NICHT auf.
const ende = original.length - 1;
for (const [von, bis] of [[0, 99], [1, 64], [63, 65], [64, 200],
                          [1000, 5000], [ende - 100, ende]]) {
  if (bis > ende || von < 0 || von > bis) continue;
  r = await hole(`/api/song/${NR}/audio`, `bytes=${von}-${bis}`);
  const soll = original.subarray(von, bis + 1);
  check(`Teilbereich ${von}-${bis}`,
        r.status === 206 && r.body.equals(soll),
        `${r.status}, ${r.body.length} statt ${soll.length}`);
}

// So fragt der Browser beim Abspielen.
const mitte = Math.floor(original.length / 2);
r = await hole(`/api/song/${NR}/audio`, `bytes=${mitte}-`);
check('offenes Ende geht bis zum Schluss',
      r.body.equals(original.subarray(mitte)), String(r.body.length));

r = await hole(`/api/song/${NR}/txt`);
check('Noten kommen lesbar an', r.body.toString('utf8').includes('#TITLE:'),
      r.body.toString('utf8').slice(0, 40));

console.log();
console.log(`${bestanden} bestanden, ${fehlgeschlagen} fehlgeschlagen`);
process.exit(fehlgeschlagen > 0 ? 1 : 0);
