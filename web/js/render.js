// Zeichnet die Singansicht auf ein Canvas.
//
// Das Spiel nutzt OpenGL; im Browser ist Canvas 2D der passende Ersatz - fuer
// Notenbalken und Text braucht es kein WebGL, und 2D laeuft ueberall.
//
// Dargestellt wird je Stimme immer nur die AKTUELLE Zeile. Genau das macht
// das Spiel auch: Mehr passt nicht lesbar auf einen Bildschirm, und beim
// Singen schaut man ohnehin nur auf die naechsten Sekunden.
//
// Im Duett bekommt jede Stimme ihre eigene Bahn, uebereinander. Beide teilen
// sich dieselbe Zeitachse, damit man sieht, wann man dran ist.

const BALKEN_RUND = 6;

// Je Bahn eine Farbe, damit im Duett klar ist, wer wo singt.
const FARBEN = [
  { balken: '#4a5570', treffer: '#6ee7a8', stimme: '#7fd1ff' },
  { balken: '#6b4a70', treffer: '#e79ad8', stimme: '#ffb27f' },
];

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
  }

  // bahnen: [{ line, sungMidi, anteile, name, score }]
  // beat:   aktueller Schlag, gilt fuer alle Bahnen
  draw(bahnen, beat) {
    const { ctx, canvas } = this;
    const w = canvas.width, h = canvas.height;

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#11131a';
    ctx.fillRect(0, 0, w, h);

    if (!bahnen || bahnen.length === 0) return;

    const hoehe = h / bahnen.length;
    bahnen.forEach((bahn, i) => {
      this.zeichneBahn(bahn, beat, i, 0, i * hoehe, w, hoehe,
                       bahnen.length > 1);
      if (i > 0) {
        ctx.strokeStyle = '#252b38';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, i * hoehe);
        ctx.lineTo(w, i * hoehe);
        ctx.stroke();
      }
    });
  }

  zeichneBahn(bahn, beat, index, ox, oy, w, h, mitNamen) {
    const ctx = this.ctx;
    const farbe = FARBEN[index % FARBEN.length];
    const line = bahn.line;

    ctx.save();
    ctx.translate(ox, oy);

    if (mitNamen && bahn.name) {
      ctx.font = '600 15px system-ui, sans-serif';
      ctx.textBaseline = 'top';
      ctx.fillStyle = farbe.stimme;
      ctx.fillText(bahn.name, 12, 8);
      // Kein Wert heisst "ohne Mikrofon". Eine 0 an dieser Stelle liesse es
      // aussehen, als saenge jemand daneben.
      ctx.textAlign = 'right';
      ctx.fillStyle = bahn.score === undefined ? '#5c6478' : '#ffd978';
      ctx.fillText(bahn.score === undefined ? 'nicht gewertet'
                                            : String(bahn.score), w - 12, 8);
      ctx.textAlign = 'left';
    }

    if (!line || line.notes.length === 0) {
      ctx.restore();
      return;
    }

    const letzte = line.notes[line.notes.length - 1];
    const von = line.notes[0].start;
    const bis = letzte.start + letzte.length;
    const spanne = Math.max(1, bis - von);

    // Tonhoehen der Zeile mittig legen, statt fest zu skalieren: Sonst
    // rutschen tiefe Lieder aus dem Bild.
    const toene = line.notes.map((n) => n.pitch);
    const mitte = (Math.min(...toene) + Math.max(...toene)) / 2;
    const umfang = Math.max(8, Math.max(...toene) - Math.min(...toene) + 4);

    // Notenhoehe aus dem Platz ableiten, nicht fest setzen: In der halben
    // Bahn eines Duetts waere ein fester Wert entweder winzig oder zu gross.
    const nutzbar = h * 0.55;
    const tonHoehe = Math.max(5, Math.min(14, nutzbar / umfang));

    const x = (b) => ((b - von) / spanne) * (w - 40) + 20;
    const y = (p) => h * 0.45 - (p - mitte) * tonHoehe;

    ctx.strokeStyle = '#1e2230';
    ctx.lineWidth = 1;
    for (let p = -6; p <= 6; p += 2) {
      ctx.beginPath();
      ctx.moveTo(0, y(mitte + p));
      ctx.lineTo(w, y(mitte + p));
      ctx.stroke();
    }

    for (const note of line.notes) {
      const bx = x(note.start);
      const bw = Math.max(4, x(note.start + note.length) - bx);
      const by = y(note.pitch) - tonHoehe / 2;

      ctx.fillStyle = note.type === 'golden' ? '#e8b23a'
                    : note.type === 'freestyle' ? '#3a4152'
                    : farbe.balken;
      this.balken(bx, by, bw, tonHoehe, Math.min(BALKEN_RUND, tonHoehe / 2));

      const anteil = bahn.anteile ? bahn.anteile.get(note) : 0;
      if (anteil > 0) {
        ctx.fillStyle = note.type === 'golden' ? '#ffd978' : farbe.treffer;
        this.balken(bx, by, bw * Math.min(1, anteil), tonHoehe,
                    Math.min(BALKEN_RUND, tonHoehe / 2));
      }
    }

    if (bahn.sungMidi >= 0) {
      const px = x(beat);
      // Auf die Oktave der Zeile holen, sonst zeichnet man ausserhalb.
      let p = bahn.sungMidi - 60;
      while (p - mitte > 6) p -= 12;
      while (mitte - p > 6) p += 12;
      ctx.strokeStyle = farbe.stimme;
      ctx.lineWidth = 4;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(px - 14, y(p));
      ctx.lineTo(px + 14, y(p));
      ctx.stroke();
    }

    ctx.strokeStyle = '#ffffff44';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x(beat), 0);
    ctx.lineTo(x(beat), h);
    ctx.stroke();

    this.text(line, beat, w, h);
    ctx.restore();
  }

  balken(x, y, w, h, r) {
    const ctx = this.ctx;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
    ctx.fill();
  }

  // Der Liedtext, die gerade faellige Silbe hervorgehoben.
  text(line, beat, w, h) {
    const ctx = this.ctx;
    const groesse = Math.max(15, Math.min(26, h * 0.09));
    ctx.font = `600 ${groesse}px system-ui, sans-serif`;
    ctx.textBaseline = 'alphabetic';

    const breiten = line.notes.map((n) => ctx.measureText(n.text).width);
    const gesamt = breiten.reduce((a, b) => a + b, 0);
    let cx = (w - gesamt) / 2;
    const cy = h - groesse * 0.6;

    line.notes.forEach((note, i) => {
      const aktiv = beat >= note.start && beat < note.start + note.length;
      ctx.fillStyle = aktiv ? '#ffd978'
                    : (beat >= note.start ? '#8b93a4' : '#e8e8ea');
      ctx.fillText(note.text, cx, cy);
      cx += breiten[i];
    });
  }
}
