program testsongsearch;
(*
 * Prueft USongSearch direkt - dieselbe Unit, die das Spiel benutzt.
 *
 * Bauen und laufen lassen:
 *   fpc -Mdelphi -Fu../src/base -Fu../src/lib/anyascii -Fi../src \
 *       -FUbuild tests/testsongsearch.pas && ./tests/testsongsearch
 *)
{$MODE Delphi}

uses
  SysUtils,
  USongSearch;

var
  Bestanden, Fehlgeschlagen: integer;

procedure Check(const Was: string; Bedingung: boolean; const Detail: string = '');
begin
  if Bedingung then
  begin
    Inc(Bestanden);
    WriteLn('  OK   ', Was);
  end
  else
  begin
    Inc(Fehlgeschlagen);
    WriteLn('  FEHL ', Was, '   ', Detail);
  end;
end;

// Sucht Ausdruck gegen einen Text, ohne Jahresmodus.
function Trifft(const Ausdruck, Text: UTF8String): boolean;
var
  Baum: PSearchNode;
begin
  Baum := BuildSearchTree(Ausdruck);
  try
    Result := EvalSearchNode(Baum, Text, 0, false);
  finally
    FreeSearchNode(Baum);
  end;
end;

// Sucht Ausdruck gegen ein Jahr, mit Bereichsunterstuetzung.
function TrifftJahr(const Ausdruck: UTF8String; Jahr: integer): boolean;
var
  Baum: PSearchNode;
begin
  Baum := BuildSearchTree(Ausdruck);
  try
    Result := EvalSearchNode(Baum, IntToStr(Jahr), Jahr, true);
  finally
    FreeSearchNode(Baum);
  end;
end;

var
  A, B: integer;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;

  WriteLn('Bisheriges Verhalten bleibt');
  Check('einzelnes Wort trifft', Trifft('abba', 'abba dancing queen'));
  Check('einzelnes Wort trifft nicht', not Trifft('queen', 'abba waterloo'));
  Check('zwei Woerter werden weiterhin verundet',
        Trifft('abba dancing', 'abba dancing queen'));
  Check('und zwar wirklich verundet',
        not Trifft('abba waterloo', 'abba dancing queen'));
  Check('Grossschreibung im Suchwort egal', Trifft('ABBA', 'abba dancing queen'));

  WriteLn('OR');
  Check('OR trifft links', Trifft('abba OR queen', 'abba waterloo'));
  Check('OR trifft rechts', Trifft('abba OR queen', 'queen bohemian'));
  Check('OR trifft keines', not Trifft('abba OR queen', 'nirvana smells'));
  Check('mehrfaches OR', Trifft('a OR b OR nirvana', 'nirvana smells'));

  WriteLn('AND');
  Check('AND ausgeschrieben', Trifft('abba AND dancing', 'abba dancing queen'));
  Check('AND schlaegt fehl', not Trifft('abba AND waterloo', 'abba dancing queen'));

  WriteLn('Vorrang: AND bindet staerker als OR');
  // abba OR (queen AND 1980) - "abba" allein muss reichen
  Check('abba OR queen AND 1980  ->  abba reicht',
        Trifft('abba OR queen AND 1980', 'abba dancing'));
  Check('queen ohne 1980 reicht NICHT',
        not Trifft('abba OR queen AND 1980', 'queen bohemian'));
  Check('queen mit 1980 reicht',
        Trifft('abba OR queen AND 1980', 'queen bohemian 1980'));

  WriteLn('Klammern kehren den Vorrang um');
  // (abba OR queen) AND 1980
  Check('abba ohne 1980 reicht nicht mehr',
        not Trifft('(abba OR queen) AND 1980', 'abba dancing'));
  Check('abba mit 1980 trifft',
        Trifft('(abba OR queen) AND 1980', 'abba dancing 1980'));
  Check('queen mit 1980 trifft',
        Trifft('(abba OR queen) AND 1980', 'queen bohemian 1980'));
  Check('verschachtelte Klammern',
        Trifft('((abba OR queen) AND (1980 OR 1981))', 'queen x 1981'));

  WriteLn('Unvollstaendige Eingaben (waehrend des Tippens)');
  Check('offene Klammer stuerzt nicht ab', Trifft('(abba', 'abba dancing'));
  Check('haengendes AND wird ignoriert', Trifft('abba AND', 'abba dancing'));
  Check('haengendes OR wird ignoriert', Trifft('abba OR', 'abba dancing'));
  Check('nur Klammern trifft alles', Trifft('()', 'irgendwas'));
  Check('nur ein Operator trifft alles', Trifft('AND', 'irgendwas'));
  Check('fuehrendes OR wird uebergangen', Trifft('OR abba', 'abba dancing'));
  Check('fuehrendes AND wird uebergangen', Trifft('AND abba', 'abba dancing'));
  Check('und filtert danach trotzdem',
        not Trifft('OR abba', 'queen bohemian'));

  WriteLn('Kleingeschriebenes and/or bleibt Suchwort');
  // Sonst waere nach der Band "AND ONE" oder einem Titel mit "or" nicht
  // mehr zu suchen.
  Check('"and" als Wort trifft', Trifft('and one', 'and one technoman'));
  Check('"and" als Wort trifft nicht wo es fehlt',
        not Trifft('and one', 'abba dancing'));

  WriteLn('Jahresbereiche');
  Check('Bereich wird erkannt', ParseYearRange('1990-1999', A, B) and (A = 1990) and (B = 1999));
  Check('verdrehter Bereich wird gedreht',
        ParseYearRange('1999-1990', A, B) and (A = 1990) and (B = 1999));
  Check('kein Bereich ohne Ziffern', not ParseYearRange('abba-queen', A, B));
  Check('kein Bereich bei fuehrendem Strich', not ParseYearRange('-1999', A, B));
  Check('kein Bereich bei haengendem Strich', not ParseYearRange('1990-', A, B));

  Check('Jahr in der Mitte trifft', TrifftJahr('1990-1999', 1995));
  Check('untere Grenze trifft', TrifftJahr('1990-1999', 1990));
  Check('obere Grenze trifft', TrifftJahr('1990-1999', 1999));
  Check('darunter trifft nicht', not TrifftJahr('1990-1999', 1989));
  Check('darueber trifft nicht', not TrifftJahr('1990-1999', 2000));
  Check('einzelnes Jahr weiterhin als Text',
        TrifftJahr('1995', 1995) and not TrifftJahr('1995', 1996));
  Check('Bereich mit OR verknuepfbar',
        TrifftJahr('1990-1992 OR 1998-1999', 1999));
  Check('und trifft dazwischen nicht',
        not TrifftJahr('1990-1992 OR 1998-1999', 1995));

  // Ohne Jahresmodus ist "1990-1999" ein gewoehnlicher Suchbegriff.
  Check('Bereich gilt NUR bei der Jahressuche',
        not Trifft('1990-1999', '1995'));

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
