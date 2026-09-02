#!/usr/bin/env python3
"""Sucht Bezeichner, die in derselben Unit als Konstante UND als Routine
vorkommen.

Pascal unterscheidet keine Gross- und Kleinschreibung. Eine Konstante
DATEINAME und eine Methode Dateiname sind derselbe Name - im Rumpf der
Methode loest er dann auf die Methode auf. Wenn die Signaturen zufaellig
zusammenpassen, compiliert die Endlosschleife anstandslos und faellt erst
zur Laufzeit als Stack Overflow auf. Genau das ist am 02.09.2026 passiert.

Geprueft werden nur die Dateien, die zu diesem Vorhaben gehoeren - der
restliche Quellbestand ist gewachsen und wuerde nur Rauschen liefern.
"""
import re
import sys
from pathlib import Path

DATEIEN = [
    "src/base/USearchStore.pas",
    "src/base/USongSearch.pas",
    "src/base/USongFilter.pas",
    "src/screens/UScreenSongSearchLoad.pas",
    "src/screens/UScreenSongJumpto.pas",
    "src/base/USongs.pas",
]

CONST_BLOCK = re.compile(r"^\s*const\s*$", re.I)
ABSCHNITT = re.compile(r"^\s*(type|var|implementation|interface|begin)\s*$", re.I)
CONST_DEF = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?::[^=]+)?=", re.M)
ROUTINE = re.compile(
    r"^\s*(?:function|procedure)\s+(?:T\w+\.)?([A-Za-z_]\w*)", re.I | re.M)


def konstanten(text: str) -> set[str]:
    """Namen aus allen const-Bloecken."""
    namen = set()
    im_block = False
    for zeile in text.splitlines():
        if CONST_BLOCK.match(zeile):
            im_block = True
            continue
        if im_block:
            if ABSCHNITT.match(zeile):
                im_block = False
                continue
            treffer = CONST_DEF.match(zeile)
            if treffer:
                namen.add(treffer.group(1).lower())
    return namen


def main() -> int:
    wurzel = Path(__file__).resolve().parent.parent
    fehler = 0
    for rel in DATEIEN:
        pfad = wurzel / rel
        if not pfad.is_file():
            print(f"  FEHL {rel} fehlt")
            fehler += 1
            continue
        text = pfad.read_text(encoding="utf-8", errors="replace")
        konst = konstanten(text)
        routinen = {m.lower() for m in ROUTINE.findall(text)}
        kollision = konst & routinen
        if kollision:
            print(f"  FEHL {rel}: {', '.join(sorted(kollision))} "
                  "ist Konstante UND Routine")
            fehler += 1
        else:
            print(f"  OK   {rel}")
    if fehler:
        print(f"\n{fehler} Datei(en) mit Namenskollision")
    return 1 if fehler else 0


if __name__ == "__main__":
    sys.exit(main())
