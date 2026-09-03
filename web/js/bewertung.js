// Die Bewertung am Ende eines Liedes.
//
// Stufen und Schwellen sind aus ShowRating in src/screens/UScreenScore.pas
// uebernommen, die Bezeichnungen aus game/languages/German.ini. Erfunden ist
// hier nichts - wer das Spiel kennt, soll dieselben Worte lesen.
//
// Die Grenzen sind bewusst krumm (2010, 4010, 7510 ...); so stehen sie im
// Original, und ein glattes Nachbauen haette die Stufen verschoben.

export const STUFEN = [
  { ab: 0,    bis: 2009,  name: 'Nichtskönner' },
  { ab: 2010, bis: 4009,  name: 'Amateur' },
  { ab: 4010, bis: 5009,  name: 'Möchtegern' },
  { ab: 5010, bis: 6009,  name: 'Fortgeschritten' },
  { ab: 6010, bis: 7509,  name: 'Sternchen' },
  { ab: 7510, bis: 8509,  name: 'Hit-Künstler' },
  { ab: 8510, bis: 9009,  name: 'Superstar' },
  { ab: 9010, bis: 10000, name: 'UltraStar' },
];

// Liefert { stufe, name } zu einer Punktzahl. stufe ist 0..7 wie im Spiel.
export function bewertung(punkte) {
  const p = Number.isFinite(punkte) ? Math.round(punkte) : 0;
  for (let i = 0; i < STUFEN.length; i++) {
    if (p >= STUFEN[i].ab && p <= STUFEN[i].bis)
      return { stufe: i, name: STUFEN[i].name };
  }
  // Ausserhalb des Bereichs. Im Spiel steht an dieser Stelle "Cheata :P" und
  // es gibt die unterste Stufe; negative Punkte sind ohnehin unmoeglich.
  return p > 10000
    ? { stufe: STUFEN.length - 1, name: STUFEN[STUFEN.length - 1].name }
    : { stufe: 0, name: STUFEN[0].name };
}

// Wie viele Sterne die Stufe wert ist - im Spiel wird das als Bildreihe
// gezeigt. Stufe 0 bekommt keinen.
export function sterne(stufe) {
  return Math.max(0, Math.min(STUFEN.length - 1, stufe | 0));
}
