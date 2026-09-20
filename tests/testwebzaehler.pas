program testwebzaehler;
(*
 * Prueft UWebZaehler - wann welches Lied gesungen wurde.
 *
 * Die drei Regeln, auf die es ankommt:
 *   - Drei Leute singen dasselbe Lied  -> drei Eintraege.
 *   - Einer laedt mitten im Lied neu   -> KEIN zweiter Eintrag.
 *   - Danach noch einmal dasselbe Lied -> wieder ein Eintrag.
 *
 * Unterschieden wird das allein am Durchgang: Der Browser wuerfelt ihn beim
 * Beginn des Singens und legt ihn in den sessionStorage, wo er ein Neuladen
 * ueberlebt. Ein zweites Singen bekommt einen neuen.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  SysUtils,
  Classes,
  UWebZaehler;

var
  Bestanden, Fehlgeschlagen: integer;
  Ordner: UTF8String;

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

function Zeilen(const Datei: UTF8String): integer;
var
  L: TStringList;
begin
  Result := 0;
  if not FileExists(Ordner + Datei) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Ordner + Datei);
    Result := L.Count;
  finally
    L.Free;
  end;
end;

function Inhalt(const Datei: UTF8String): UTF8String;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Ordner + Datei) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Ordner + Datei);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure PruefeFelder;
begin
  WriteLn('Felder saeubern');
  // Ein Tabulator im Titel zerlegte die Datei in zusaetzliche Spalten, ein
  // Zeilenumbruch machte aus einer Auffuehrung zwei.
  Check('Tabulator wird ersetzt',
        Saeubere('Mit' + #9 + 'Tab') = 'Mit Tab', Saeubere('Mit' + #9 + 'Tab'));
  Check('Zeilenumbruch wird ersetzt',
        Saeubere('Zwei' + #10 + 'Zeilen') = 'Zwei Zeilen');
  Check('Wagenruecklauf ebenso',
        Saeubere('A' + #13 + 'B') = 'A B');
  Check('aussen wird getrimmt', Saeubere('  Rand  ') = 'Rand');

  Check('Protokollzeile hat drei Spalten',
        ProtokollZeile('2026-01-01T12:00:00', 'ABBA', 'Waterloo') =
        '2026-01-01T12:00:00'#9'ABBA'#9'Waterloo');
  Check('auch mit Tabulator im Titel bleiben es drei',
        ProtokollZeile('Z', 'A', 'B'#9'C') = 'Z'#9'A'#9'B C');
end;

procedure PruefeRegeln;
var
  Z: TWebZaehler;
begin
  WriteLn;
  WriteLn('Die drei Regeln');
  Z := TWebZaehler.Create(Ordner);
  try
    Check('erstes Singen zaehlt',
          Z.Zaehle('lauf-a', 0, 'ABBA', 'Waterloo'));
    Check('und steht im Protokoll', Zeilen(PROTOKOLL_NAME) = 1,
          IntToStr(Zeilen(PROTOKOLL_NAME)));

    // Der Browser holt den Ton in vielen Stuecken - jedes davon kommt hier
    // an. Zaehlen darf nur das erste.
    Z.Zaehle('lauf-a', 0, 'ABBA', 'Waterloo');
    Z.Zaehle('lauf-a', 0, 'ABBA', 'Waterloo');
    Check('weitere Stuecke desselben Durchgangs zaehlen nicht',
          Zeilen(PROTOKOLL_NAME) = 1, IntToStr(Zeilen(PROTOKOLL_NAME)));

    // Neu geladen: Der Durchgang steht im sessionStorage und kommt
    // unveraendert wieder.
    Check('Neuladen zaehlt nicht noch einmal',
          not Z.Zaehle('lauf-a', 0, 'ABBA', 'Waterloo'));
    Check('Protokoll bleibt bei einer Zeile', Zeilen(PROTOKOLL_NAME) = 1);

    // Zweiter Saenger, eigener Browser, eigener Durchgang.
    Check('zweiter Saenger zaehlt', Z.Zaehle('lauf-b', 0, 'ABBA', 'Waterloo'));
    Check('dritter Saenger zaehlt', Z.Zaehle('lauf-c', 0, 'ABBA', 'Waterloo'));
    Check('drei Saenger, drei Zeilen', Zeilen(PROTOKOLL_NAME) = 3,
          IntToStr(Zeilen(PROTOKOLL_NAME)));
    Check('und der Zaehler steht auf drei',
          Z.Anzahl('ABBA', 'Waterloo') = 3,
          IntToStr(Z.Anzahl('ABBA', 'Waterloo')));

    // Nochmal singen: neuer Durchgang.
    Check('nochmal singen zaehlt wieder',
          Z.Zaehle('lauf-d', 0, 'ABBA', 'Waterloo'));
    Check('jetzt vier', Z.Anzahl('ABBA', 'Waterloo') = 4);

    // Ein anderes Lied im selben Durchgang ist eine eigene Auffuehrung -
    // der Schluessel enthaelt beides.
    Check('anderes Lied, gleicher Durchgang zaehlt',
          Z.Zaehle('lauf-d', 1, 'Queen', 'Bohemian'));
    Check('und wird getrennt gezaehlt',
          (Z.Anzahl('Queen', 'Bohemian') = 1) and
          (Z.Anzahl('ABBA', 'Waterloo') = 4));

    // Ohne Kennung wird nicht gezaehlt: Sonst zaehlte jeder Abruf mit.
    Check('ohne Durchgang wird nicht gezaehlt',
          not Z.Zaehle('', 2, 'Nirvana', 'Smells'));
    Check('und nichts geschrieben', Z.Anzahl('Nirvana', 'Smells') = 0);

    Check('unbekanntes Lied hat Anzahl 0', Z.Anzahl('Gibt', 'Es Nicht') = 0);
  finally
    Z.Free;
  end;
end;

procedure PruefeDauerhaft;
var
  Z: TWebZaehler;
begin
  WriteLn;
  WriteLn('Ueber einen Neustart hinweg');
  // "Dauerhaft" heisst: Ein neuer Zaehler liest die Zahlen wieder.
  Z := TWebZaehler.Create(Ordner);
  try
    Check('Zaehlerstand ueberlebt den Neustart',
          Z.Anzahl('ABBA', 'Waterloo') = 4,
          IntToStr(Z.Anzahl('ABBA', 'Waterloo')));
    // Derselbe Durchgang nach einem Neustart des Servers: Der Merkspeicher
    // ist leer, also zaehlt es wieder. Das ist gewollt - nach einem
    // Serverneustart laeuft ohnehin kein Lied mehr.
    Check('nach dem Neustart zaehlt auch ein alter Durchgang',
          Z.Zaehle('lauf-a', 0, 'ABBA', 'Waterloo'));
    Check('jetzt fuenf', Z.Anzahl('ABBA', 'Waterloo') = 5);
  finally
    Z.Free;
  end;
end;

procedure PruefeOrdnerwahl;
var
  Nur: UTF8String;
begin
  WriteLn;
  WriteLn('Wohin geschrieben wird');
  // Ein nicht beschreibbarer Ordner darf NICHT gewaehlt werden: Sonst meldet
  // der Start "Zaehlung: ..." und es wird nie etwas mitgeschrieben.
  Check('beschreibbarer Ordner wird genommen',
        ZaehlerOrdner(Ordner + 'config.ini') = Ordner,
        ZaehlerOrdner(Ordner + 'config.ini'));

  Nur := Ordner + 'nurlesbar' + PathDelim;
  ForceDirectories(Nur);
  {$IFDEF UNIX}
  // 0500: betreten und lesen, nicht schreiben.
  FpChmod(PChar(ExcludeTrailingPathDelimiter(Nur)), &500);
  Check('schreibgeschuetzter Ordner wird uebergangen',
        ZaehlerOrdner(Nur + 'config.ini') <> Nur,
        ZaehlerOrdner(Nur + 'config.ini'));
  FpChmod(PChar(ExcludeTrailingPathDelimiter(Nur)), &700);
  {$ENDIF}
  RemoveDir(ExcludeTrailingPathDelimiter(Nur));
end;

procedure PruefeOhneOrdner;
var
  Z: TWebZaehler;
begin
  WriteLn;
  WriteLn('Ohne beschreibbaren Ordner');
  // Steht kein Ordner zur Verfuegung, darf das Singen trotzdem laufen.
  Z := TWebZaehler.Create('');
  try
    Check('zaehlt ohne Ordner ohne Absturz',
          Z.Zaehle('lauf-x', 0, 'A', 'B'));
    Check('meldet aber keine Anzahl', Z.Anzahl('A', 'B') = 0);
  finally
    Z.Free;
  end;
end;

procedure PruefeProtokollInhalt;
var
  Text: UTF8String;
  Z: TWebZaehler;
begin
  WriteLn;
  WriteLn('Was im Protokoll steht');
  Text := Inhalt(PROTOKOLL_NAME);
  Check('Interpret steht drin', Pos('ABBA', Text) > 0);
  Check('Titel steht drin', Pos('Waterloo', Text) > 0);
  // "wann" ist der halbe Auftrag - ohne Zeitstempel waere es nur ein Zaehler.
  Check('Zeitstempel steht drin', Pos('T', Text) > 0);
  Check('Zeitstempel sieht nach ISO aus',
        (Length(Text) > 19) and (Text[5] = '-') and (Text[8] = '-'),
        Copy(Text, 1, 20));

  Text := Inhalt(ZAEHLER_NAME);
  Check('Zaehlerdatei nennt das Lied', Pos('Waterloo', Text) > 0);

  // Die Zahl in der Datei muss dieselbe sein, die Anzahl() meldet, und sie
  // muss zur Zahl der Protokollzeilen passen. Gegen die beiden anderen
  // Werte geprueft statt gegen eine hingeschriebene Zahl - sonst haengt der
  // Test daran, in welcher Reihenfolge die Pruefungen darueber liefen.
  Z := TWebZaehler.Create(Ordner);
  try
    Check('Zahl in der Datei stimmt mit Anzahl() ueberein',
          Pos(#9 + IntToStr(Z.Anzahl('ABBA', 'Waterloo')) + LineEnding,
              Text + LineEnding) > 0,
          Text + ' / Anzahl=' + IntToStr(Z.Anzahl('ABBA', 'Waterloo')));
    // Jede Auffuehrung von Waterloo steht als eigene Zeile im Protokoll.
    Check('Zaehler passt zur Zahl der Protokollzeilen',
          Z.Anzahl('ABBA', 'Waterloo') + Z.Anzahl('Queen', 'Bohemian') =
          Zeilen(PROTOKOLL_NAME),
          IntToStr(Z.Anzahl('ABBA', 'Waterloo')) + '+' +
          IntToStr(Z.Anzahl('Queen', 'Bohemian')) + ' vs ' +
          IntToStr(Zeilen(PROTOKOLL_NAME)));
  finally
    Z.Free;
  end;
end;

var
  Basis: UTF8String;
begin
  Bestanden := 0;
  Fehlgeschlagen := 0;

  Basis := GetTempDir + 'usdxzaehler' + IntToStr(Random(100000));
  ForceDirectories(Basis);
  Ordner := IncludeTrailingPathDelimiter(Basis);

  PruefeFelder;
  PruefeRegeln;
  PruefeProtokollInhalt;
  PruefeDauerhaft;
  PruefeOrdnerwahl;
  PruefeOhneOrdner;

  DeleteFile(Ordner + PROTOKOLL_NAME);
  DeleteFile(Ordner + ZAEHLER_NAME);
  RemoveDir(Basis);

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
