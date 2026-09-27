// Impressum, Datenschutz und Lizenzen - das Rendern, ohne Browser pruefbar.
//
// Der Text kommt als reine Textdatei vom Server (/api/impressum, siehe
// FindeImpressum in UWebApi.pas). Wer ihn schreibt, soll kein HTML koennen
// muessen, und was in der Datei steht, darf nie als HTML ausgefuehrt werden.
// Deshalb wird erst ALLES maskiert und danach nur eine kleine, feste Auswahl
// an Auszeichnungen wieder in Elemente verwandelt:
//
//   # Ueberschrift / ## / ###     Ueberschriften (eine Zeile, eigener Absatz)
//   - Punkt  oder  * Punkt       Aufzaehlung (alle Zeilen eines Absatzes)
//   **fett**                     fett
//   [Text](https://...)          Link (nur http, https und mailto)
//   https://... / name@host.de   werden von selbst zu Links
//   Leerzeile                    neuer Absatz; einfacher Umbruch bleibt einer

function maskiere(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Satzzeichen am Ende einer nackten Adresse gehoeren zum Satz, nicht zur
// Adresse: "siehe https://example.org." verlinkt ohne den Punkt.
const ADRESSE = /\bhttps?:\/\/[^\s<]+[^\s<.,;:!?)\]'"]/g;
const EPOST = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g;
const MD_LINK = /\[([^\]\n]+)\]\(((?:https?:\/\/|mailto:)[^\s)]+)\)/g;

function link(href, text) {
  const extern = /^https?:/.test(href);
  return `<a href="${href}"${extern ? ' rel="noopener noreferrer"' : ''}>${text}</a>`;
}

// Zeileninhalt: bekommt schon maskierten Text.
function zeile(s) {
  // Fertige Links beiseitelegen, damit die Adresse darin nicht noch einmal
  // verlinkt wird. \u0000 kommt in maskiertem Text nicht vor.
  const fertig = [];
  const merke = (html) => `\u0000${fertig.push(html) - 1}\u0000`;
  s = s.replace(MD_LINK, (_, text, href) => merke(link(href, text)));
  s = s.replace(ADRESSE, (href) => merke(link(href, href)));
  s = s.replace(EPOST, (adr) => merke(link('mailto:' + adr, adr)));
  s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, n) => fertig[+n]);
}

export function textZuHtml(text) {
  const absaetze = maskiere(String(text || '').replace(/\r\n?/g, '\n'))
    .split(/\n\s*\n/).map((a) => a.replace(/^\n+|\n+$/g, '')).filter((a) => a.trim());
  return absaetze.map((a) => {
    const zeilen = a.split('\n');
    const ueber = /^(#{1,3})\s+(.+)$/.exec(a);
    // Die Seite hat schon eine h1 - "#" in der Datei wird zur h2.
    if (ueber && zeilen.length === 1) {
      const stufe = ueber[1].length + 1;
      return `<h${stufe}>${zeile(ueber[2].trim())}</h${stufe}>`;
    }
    if (zeilen.every((z) => /^\s*[-*]\s+/.test(z))) {
      return '<ul>' + zeilen.map((z) =>
        `<li>${zeile(z.replace(/^\s*[-*]\s+/, ''))}</li>`).join('') + '</ul>';
    }
    return `<p>${zeilen.map(zeile).join('<br>')}</p>`;
  }).join('\n');
}

// Die Lizenzliste (web/lizenzen.json, erzeugt von tools/lizenzen.py): je
// Eintrag Name, Zweck und Lizenz sichtbar, der volle Text zum Aufklappen.
export function lizenzenZuHtml(daten) {
  const liste = (daten && Array.isArray(daten.lizenzen)) ? daten.lizenzen : [];
  return liste.map((l) =>
    `<details class="lizenz"><summary><span class="lname">${maskiere(l.name)}</span>` +
    `<span class="lart">${maskiere(l.lizenz)}</span>` +
    `<span class="lzweck">${maskiere(l.zweck)}</span></summary>` +
    (l.adresse ? `<p class="ladresse">${link(maskiere(l.adresse), maskiere(l.adresse))}</p>` : '') +
    `<pre>${maskiere(l.text)}</pre></details>`).join('\n');
}
