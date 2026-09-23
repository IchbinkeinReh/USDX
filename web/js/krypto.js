// ChaCha20 (RFC 8439) - die Browserhaelfte von src/base/UWebCrypto.pas.
//
// Beide Seiten muessen Byte fuer Byte dasselbe rechnen. Sie tun das nicht,
// weil eine die andere aufruft, sondern weil beide gegen die Testwerte aus
// RFC 8439 geprueft sind - hier in web/tests/run.mjs, dort in
// tests/testwebcrypto.pas. Wer hier etwas aendert, aendert es dort mit.
//
// Warum ein Stromverfahren: Das Byte an Stelle N haengt nur von N ab. Damit
// laesst sich ein Teilbereich (Range) fuer sich entschluesseln, und der
// Browser kann mitten im Lied einsteigen, ohne den Anfang gesehen zu haben.
// Ohne das gaebe es weder Dauer-Anzeige noch Springen noch Vorschau.

// Die vier festen Woerter: "expand 32-byte k".
const ANFANG = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];

function rotL(x, n) {
  return ((x << n) | (x >>> (32 - n))) >>> 0;
}

// Ein Block Schluesselstrom (64 Byte) zur Blocknummer counter.
//
// Die Zustandsworte liegen in einem Int32Array: JavaScript rechnet mit
// Gleitkomma, und schon eine einzige Addition ueber 2^32 hinaus waere sonst
// nicht mehr dasselbe wie in Pascal. Im Int32Array wird abgeschnitten, also
// genau modulo 2^32 gerechnet - wie es das Verfahren verlangt.
export function chacha20Block(key, nonce, counter) {
  const s = new Int32Array(16);
  const anfang = new Int32Array(16);

  for (let i = 0; i < 4; i++) anfang[i] = ANFANG[i] | 0;
  for (let i = 0; i < 8; i++) {
    anfang[4 + i] =
      (key[i * 4] | (key[i * 4 + 1] << 8) |
       (key[i * 4 + 2] << 16) | (key[i * 4 + 3] << 24)) | 0;
  }
  anfang[12] = counter | 0;
  for (let i = 0; i < 3; i++) {
    anfang[13 + i] =
      (nonce[i * 4] | (nonce[i * 4 + 1] << 8) |
       (nonce[i * 4 + 2] << 16) | (nonce[i * 4 + 3] << 24)) | 0;
  }

  s.set(anfang);

  const vr = (a, b, c, d) => {
    s[a] = (s[a] + s[b]) | 0;  s[d] = rotL((s[d] ^ s[a]) >>> 0, 16) | 0;
    s[c] = (s[c] + s[d]) | 0;  s[b] = rotL((s[b] ^ s[c]) >>> 0, 12) | 0;
    s[a] = (s[a] + s[b]) | 0;  s[d] = rotL((s[d] ^ s[a]) >>> 0, 8) | 0;
    s[c] = (s[c] + s[d]) | 0;  s[b] = rotL((s[b] ^ s[c]) >>> 0, 7) | 0;
  };

  // 20 Runden = zehnmal Spalten- und Diagonalrunde.
  for (let runde = 0; runde < 10; runde++) {
    vr(0, 4,  8, 12);
    vr(1, 5,  9, 13);
    vr(2, 6, 10, 14);
    vr(3, 7, 11, 15);
    vr(0, 5, 10, 15);
    vr(1, 6, 11, 12);
    vr(2, 7,  8, 13);
    vr(3, 4,  9, 14);
  }

  const block = new Uint8Array(64);
  for (let i = 0; i < 16; i++) {
    const w = (s[i] + anfang[i]) >>> 0;
    block[i * 4]     = w & 0xff;
    block[i * 4 + 1] = (w >>> 8) & 0xff;
    block[i * 4 + 2] = (w >>> 16) & 0xff;
    block[i * 4 + 3] = (w >>> 24) & 0xff;
  }
  return block;
}

// Ver- und entschluesselt daten an Ort und Stelle. offset ist die Stelle des
// ERSTEN Bytes in der vollstaendigen Datei, nicht im uebergebenen Stueck -
// daran haengt, dass ein Teilbereich richtig herauskommt.
export function chacha20XOR(key, nonce, offset, daten) {
  if (offset < 0) throw new Error('ChaCha20: negative Stelle');
  let zaehler = Math.floor(offset / 64);
  let im = offset % 64;
  let getan = 0;

  while (getan < daten.length) {
    const block = chacha20Block(key, nonce, zaehler);
    let nimm = 64 - im;
    if (nimm > daten.length - getan) nimm = daten.length - getan;
    for (let i = 0; i < nimm; i++) daten[getan + i] ^= block[im + i];
    getan += nimm;
    zaehler++;
    im = 0;
  }
  return daten;
}

// Reihenfolge wie TWebFileKind in UWebBridge.pas. Die Zahl geht in den
// Einmalwert ein, sie ist also Teil des Formats - nicht umsortieren.
export const ART_TXT = 0;
export const ART_AUDIO = 1;
export const ART_VIDEO = 2;
export const ART_BACKGROUND = 3;
export const ART_COVER = 4;
export const ART_PREVIEW = 5;
export const ART_AUDIO_INSTRUMENTAL = 6;

// Muss mit NonceForFile in UWebCrypto.pas uebereinstimmen. Geheim muss der
// Wert nicht sein, nur je Schluessel eindeutig - deshalb wird er gerechnet
// und nicht uebertragen.
export function nonceForFile(songIndex, art) {
  const n = new Uint8Array(12);
  n[0] = art & 0xff;
  // Liednummer als 64-Bit-Wert, kleinstwertiges Byte zuerst. Ueber Division
  // statt Schieben: JavaScripts Bitoperatoren rechnen mit 32 Bit, ab dem
  // fuenften Byte kaeme sonst Unsinn heraus.
  let wert = songIndex;
  for (let i = 0; i < 8; i++) {
    n[4 + i] = Math.floor(wert / Math.pow(2, i * 8)) & 0xff;
  }
  return n;
}

export function hexToBytes(hex) {
  if (typeof hex !== 'string' || hex.length % 2 !== 0)
    throw new Error('Hex erwartet');
  const b = new Uint8Array(hex.length / 2);
  for (let i = 0; i < b.length; i++) {
    const wert = parseInt(hex.substr(i * 2, 2), 16);
    if (Number.isNaN(wert)) throw new Error('Hex erwartet');
    b[i] = wert;
  }
  return b;
}

export function bytesToHex(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++)
    s += bytes[i].toString(16).padStart(2, '0');
  return s;
}

// Welche Adressen verschluesselt ausgeliefert werden - eine Stelle, damit
// Seite und Dienstarbeiter sich nicht auseinanderentwickeln. Liefert
// { index, art } oder null.
const GESCHUETZT = {
  txt: ART_TXT,
  audio: ART_AUDIO,
  video: ART_VIDEO,
  // Der Vorschau-Schnipsel geht denselben Weg. Er ist nur eine halbe
  // Minute - aber dreissigtausend halbe Minuten sind die Sammlung.
  preview: ART_PREVIEW,
  // Die Karaoke-Tonspur (ohne Gesang) - ein vollstaendiges Lied wie audio.
  karaoke: ART_AUDIO_INSTRUMENTAL,
};

// Wo im Strom das erste Byte einer Antwort steht.
//
// Aus der ANTWORT gelesen, nicht aus der Anfrage: Der Server darf ein
// kleineres Stueck schicken als gefragt (er tut es, siehe WEB_MAX_STUECK),
// und bei einer Antwort ohne Teilbereich faengt es schlicht bei 0 an. Wer
// hier die Anfrage nimmt, liegt genau dann falsch, wenn es darauf ankommt.
export function startStelle(antwort) {
  if (antwort.status !== 206) return 0;
  const bereich = antwort.headers.get('Content-Range') || '';
  const treffer = /bytes\s+(\d+)-/i.exec(bereich);
  return treffer ? parseInt(treffer[1], 10) : 0;
}

export function geschuetzteDatei(pfad) {
  const treffer = /^\/api\/song\/(\d+)\/([a-z]+)$/.exec(pfad);
  if (!treffer) return null;
  const art = GESCHUETZT[treffer[2]];
  if (art === undefined) return null;
  return { index: parseInt(treffer[1], 10), art };
}
