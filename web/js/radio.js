// Startseite und Radio-Modus - was sich daran ohne Browser pruefen laesst.
//
// Die Seite kennt drei Ansichten: die Startseite, den Party-Modus (die
// bisherige Liederliste mit Lobby und Mikrofonen) und den Radio-Modus. Im
// Radio wird nur zugehoert und mitgelesen: Nach einem Druck auf Start laeuft
// ein zufaelliges Lied aus den Suchtreffern, danach das naechste, bis man
// aufhoert. Mikrofone gibt es dort nicht, jede Stimme laeuft ungewertet mit.

// Welche Ansicht die Adresse meint: 'start', 'party' oder 'radio'.
//
// Links von vor der Startseite tragen kein "modus", meinen aber die
// Liederliste - vor allem Einladungen (/?lobby=123456) und geteilte Lieder
// (?lied=5). Die sollen weiter dort landen, nicht auf der Startseite.
export function modusAusZustand(z) {
  if (z.modus === 'party' || z.modus === 'radio') return z.modus;
  if (z.lobby || z.lied != null || z.singen) return 'party';
  return 'start';
}

// Wie viele der zuletzt gespielten Lieder nicht gleich wieder drankommen.
//
// Die Haelfte der Treffer, hoechstens 50: Bei einer engen Suche mit drei
// Liedern soll sich trotzdem etwas wiederholen duerfen, sonst waere die
// Auswahl nach dem ersten Durchgang gar nicht mehr zufaellig. Bei nur einem
// Treffer bleibt nichts zu sperren, das eine Lied laeuft dann eben wieder.
export const RADIO_VERLAUF_MAX = 50;

export function verlaufLaenge(gesamt) {
  if (!(gesamt > 0)) return 0;
  return Math.min(RADIO_VERLAUF_MAX, Math.floor(gesamt / 2));
}

export class RadioVerlauf {
  constructor() { this.liste = []; }

  // gesamt: wie viele Treffer die Suche gerade hat. Wird sie kleiner, wird
  // der Verlauf mit gekuerzt - die aeltesten Eintraege fallen zuerst.
  merke(index, gesamt) {
    this.liste.push(index);
    const n = verlaufLaenge(gesamt);
    while (this.liste.length > n) this.liste.shift();
  }

  kuerzlich(index) { return this.liste.includes(index); }

  leeren() { this.liste = []; }
}

// Wie man die Seite als App installiert, wenn der Browser keinen Knopf
// dafuer hergibt. Einen echten Knopf erlauben nur Chrome, Edge und Samsung
// Internet (Ereignis beforeinstallprompt); Safari und Firefox muss man
// sagen, wo es im Menue steht.
//
// beruehrpunkte: navigator.maxTouchPoints. Ein iPad gibt sich seit iPadOS 13
// als Mac aus - nur am Touchscreen ist es noch zu erkennen.
export function installHinweis(userAgent, beruehrpunkte = 0) {
  const ua = userAgent || '';
  if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && beruehrpunkte > 1)) {
    return 'Als App installieren: in Safari auf das Teilen-Symbol tippen und ' +
           '„Zum Home-Bildschirm“ wählen.';
  }
  if (/Android/.test(ua)) {
    return 'Als App installieren: im Browsermenü (⋮) „App installieren“ oder ' +
           '„Zum Startbildschirm hinzufügen“ wählen.';
  }
  return 'Als App installieren: in Chrome oder Edge über das Installieren-Symbol ' +
         'rechts in der Adressleiste. Firefox kann Seiten nicht als App installieren.';
}

// Wer im Radio "singt": niemand. Jede Stimme bekommt eine Bahn ohne
// Mikrofon, genau wie "— nicht werten —" im Party-Modus. Beim Duett also
// beide Stimmen, damit beide Texte zu sehen sind; die Anzeige laesst dann
// die Noten weg und zeigt nur den Text (siehe zeichneBahn in render.js).
export function radioBesetzung(song) {
  if (song.isDuet) {
    return song.tracks.map((tr, i) => ({ trackIndex: i, deviceId: null, name: tr.name }));
  }
  return [{ trackIndex: 0, deviceId: null, name: null }];
}
