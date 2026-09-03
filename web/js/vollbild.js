// Vollbild und Querformat fuers Singen.
//
// Auf dem Handy ist Hochformat unbrauchbar: Die Notenzeile braucht Breite,
// und im Hochformat bleiben je Zeile ein paar Zentimeter, auf denen weder
// Noten noch Text zu erkennen sind.
//
// Was der Browser dabei zulaesst, ist sehr unterschiedlich:
//
//   * Vollbild verlangt eine Nutzergeste. Es muss also aus dem Klick auf
//     "Singen" heraus angefordert werden, nicht spaeter aus der Schleife.
//   * Das Drehen laesst sich nur im Vollbild festhalten, und nur dort, wo
//     es die Screen Orientation API gibt - auf iPhones gibt es sie nicht.
//   * Safari auf dem iPhone kennt Vollbild nur fuer Videos, nicht fuer
//     beliebige Elemente.
//
// Deshalb ist hier alles einzeln abgesichert und nichts davon Voraussetzung:
// Klappt es nicht, wird trotzdem gesungen, nur eben im Fenster.

// Groesste kurze Bildschirmseite, die noch als Handy gilt.
//
// Handys liegen bei 360 bis 430, aufklappbare Geraete im zugeklappten
// Zustand etwas darueber. Tablets fangen bei 768 an - die sind bewusst
// NICHT gemeint: Dort ist genug Platz, und ein erzwungenes Vollbild samt
// festgehaltenem Querformat stoert dann mehr, als es hilft.
export const HANDY_BREITE = 540;

// Laeuft das auf einem Geraet, bei dem sich Vollbild und Drehen lohnen?
//
// Bewusst nicht an der Kennung des Browsers festgemacht - die luegen seit
// jeher. Gefragt wird nach dem, worauf es ankommt: grober Zeiger (Finger
// statt Maus) und ein kleiner Bildschirm.
export function istHandy(umgebung = globalThis) {
  const mm = umgebung.matchMedia;
  const grob = typeof mm === 'function'
    ? (mm.call(umgebung, '(pointer: coarse)').matches === true)
    : (umgebung.navigator && umgebung.navigator.maxTouchPoints > 0);

  const breite = umgebung.screen && umgebung.screen.width
    ? Math.min(umgebung.screen.width, umgebung.screen.height)
    : (umgebung.innerWidth || 0);

  return grob === true && breite > 0 && breite <= HANDY_BREITE;
}

export function imVollbild(dok = globalThis.document) {
  return !!(dok && (dok.fullscreenElement || dok.webkitFullscreenElement));
}

// Vollbild anfordern und, wenn moeglich, aufs Querformat festlegen.
// Gibt zurueck, was tatsaechlich geklappt hat - der Aufrufer kann danach
// einen Hinweis anzeigen, statt so zu tun, als waere alles gut gegangen.
export async function vollbildAn(element) {
  const ergebnis = { vollbild: false, quer: false };
  if (!element) return ergebnis;

  try {
    if (element.requestFullscreen) {
      await element.requestFullscreen({ navigationUI: 'hide' });
      ergebnis.vollbild = true;
    } else if (element.webkitRequestFullscreen) {
      // Aeltere WebKit-Fassungen; liefert kein Versprechen zurueck.
      element.webkitRequestFullscreen();
      ergebnis.vollbild = true;
    }
  } catch (e) {
    // Verweigert oder nicht unterstuetzt - kein Grund, nicht zu singen.
  }

  try {
    const o = globalThis.screen && globalThis.screen.orientation;
    if (o && typeof o.lock === 'function') {
      await o.lock('landscape');
      ergebnis.quer = true;
    }
  } catch (e) {
    // Auf dem iPhone gibt es das nicht, und im Fenster ist es ohnehin
    // nicht erlaubt.
  }

  return ergebnis;
}

// Rueckgaengig machen. Wird auch aufgerufen, wenn gar nichts gesetzt war -
// deshalb muss jeder Schritt einen fehlenden Vorzustand vertragen.
export async function vollbildAus() {
  try {
    const o = globalThis.screen && globalThis.screen.orientation;
    if (o && typeof o.unlock === 'function') o.unlock();
  } catch (e) { /* nichts festgelegt gewesen */ }

  try {
    const dok = globalThis.document;
    if (!imVollbild(dok)) return;
    if (dok.exitFullscreen) await dok.exitFullscreen();
    else if (dok.webkitExitFullscreen) dok.webkitExitFullscreen();
  } catch (e) { /* schon verlassen */ }
}
