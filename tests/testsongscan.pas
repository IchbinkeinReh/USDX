program testsongscan;

// Prueft das Einlesen der Kopfdaten und das Durchsuchen der Liederordner.
//
// Genau diese beiden Schritte ersetzen im kopflosen Betrieb das, was sonst
// TSongs tut - und TSongs laesst sich hier nicht pruefen, weil es ueber
// USong an URenderer und UMusic haengt.

{$MODE Delphi}{$H+}

uses
  SysUtils, Classes,
  USongHeader, USongScan, UWebBridge;

var
  Bestanden, Fehlgeschlagen: integer;
  Basis: string;

procedure Check(const Was: string; Bedingung: boolean; const Info: string = '');
begin
  if Bedingung then
  begin
    Inc(Bestanden);
    WriteLn('  OK   ', Was);
  end
  else
  begin
    Inc(Fehlgeschlagen);
    WriteLn('  FEHL ', Was, '  ', Info);
  end;
end;

// Legt eine Datei mit genau diesem Inhalt an. Bewusst ueber einen Stream:
// Bei Textdateien haengt FPC Zeilenenden an, und ein BOM-Test braucht die
// Bytes so, wie sie dastehen.
procedure SchreibeDatei(const Pfad, Inhalt: RawByteString);
var
  S: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Pfad));
  S := TFileStream.Create(Pfad, fmCreate);
  try
    if (Length(Inhalt) > 0) then
      S.WriteBuffer(Inhalt[1], Length(Inhalt));
  finally
    S.Free;
  end;
end;

var
  H: TSongHeader;
  Ordner: TStringList;
  Lieder: TWebSongArray;
  I, Gefunden: integer;
  DuoIdx, AbbaIdx: integer;
begin
  Bestanden := 0; Fehlgeschlagen := 0;
  Basis := IncludeTrailingPathDelimiter(GetTempDir) +
           'usdxscan' + IntToStr(Random(1000000)) + PathDelim;

  // --- Kopfdaten ---
  WriteLn('Kopfdaten');

  SchreibeDatei(Basis + 'a' + PathDelim + 'lied.txt',
    '#TITLE:Dancing Queen'#13#10 +
    '#ARTIST:ABBA'#13#10 +
    '#GENRE:Pop'#13#10 +
    '#LANGUAGE:English'#13#10 +
    '#EDITION:Best of'#13#10 +
    '#YEAR:1976'#13#10 +
    '#MP3:song.mp3'#13#10 +
    '#BPM:100'#13#10 +
    ': 0 4 60 Danc'#13#10 +
    'E'#13#10);
  SchreibeDatei(Basis + 'a' + PathDelim + 'song.mp3', 'TON');

  Check('Lied wird gelesen',
        ReadSongHeader(Basis + 'a' + PathDelim + 'lied.txt', H));
  Check('Titel', H.Title = 'Dancing Queen', H.Title);
  Check('Interpret', H.Artist = 'ABBA', H.Artist);
  Check('Genre', H.Genre = 'Pop', H.Genre);
  Check('Sprache', H.Language = 'English', H.Language);
  Check('Ausgabe', H.Edition = 'Best of', H.Edition);
  Check('Jahr', H.Year = 1976, IntToStr(H.Year));
  Check('kein Duett', not H.Duet);
  Check('Tondatei wird neben der .txt gefunden',
        H.AudioPath = Basis + 'a' + PathDelim + 'song.mp3', H.AudioPath);

  // Windows-Zeilenenden hat die Datei oben schon. Jetzt ohne, mit BOM, und
  // mit Kleinschreibung in den Schluesseln.
  SchreibeDatei(Basis + 'b' + PathDelim + 'lied.txt',
    #$EF#$BB#$BF'#title:Mit BOM'#10 +
    '#artist:Wer'#10 +
    '#year:1994-05-01'#10 +
    ': 0 4 60 x'#10);
  Check('mit BOM wird der Titel trotzdem erkannt',
        ReadSongHeader(Basis + 'b' + PathDelim + 'lied.txt', H) and
        (H.Title = 'Mit BOM'), H.Title);
  Check('Schluessel sind unabhaengig von Gross- und Kleinschreibung',
        H.Artist = 'Wer', H.Artist);
  Check('aus einem Datum wird das Jahr', H.Year = 1994, IntToStr(H.Year));
  Check('fehlende Tondatei bleibt leer', H.AudioPath = '', H.AudioPath);

  // --- Duett ---
  WriteLn('Duett');
  SchreibeDatei(Basis + 'c' + PathDelim + 'lied.txt',
    '#TITLE:Zusammen'#10'#ARTIST:Duo'#10'#BPM:120'#10 +
    'P1'#10': 0 4 60 a'#10'P2'#10': 0 4 67 b'#10'E'#10);
  Check('Duett am P der ersten Notenzeile erkannt',
        ReadSongHeader(Basis + 'c' + PathDelim + 'lied.txt', H) and H.Duet);

  // Ein P WEITER UNTEN macht noch kein Duett - USDX entscheidet das an der
  // ersten Zeile des Notenteils, und diese Regel muss hier gleich sein.
  SchreibeDatei(Basis + 'd' + PathDelim + 'lied.txt',
    '#TITLE:Solo'#10'#ARTIST:Wer'#10'#BPM:120'#10 +
    ': 0 4 60 a'#10'P2'#10': 4 4 60 b'#10'E'#10);
  Check('P weiter unten macht kein Duett',
        ReadSongHeader(Basis + 'd' + PathDelim + 'lied.txt', H) and
        (not H.Duet));

  // --- AUDIO vor MP3 ---
  WriteLn('Tondatei');
  SchreibeDatei(Basis + 'e' + PathDelim + 'lied.txt',
    '#TITLE:Zwei'#10'#ARTIST:Wer'#10'#AUDIO:neu.ogg'#10'#MP3:alt.mp3'#10 +
    ': 0 4 60 a'#10);
  SchreibeDatei(Basis + 'e' + PathDelim + 'neu.ogg', 'A');
  SchreibeDatei(Basis + 'e' + PathDelim + 'alt.mp3', 'B');
  ReadSongHeader(Basis + 'e' + PathDelim + 'lied.txt', H);
  Check('AUDIO hat Vorrang vor MP3',
        ExtractFileName(H.AudioPath) = 'neu.ogg', H.AudioPath);

  // Reihenfolge umgedreht - das Ergebnis muss dasselbe sein.
  SchreibeDatei(Basis + 'f' + PathDelim + 'lied.txt',
    '#TITLE:Zwei'#10'#ARTIST:Wer'#10'#MP3:alt.mp3'#10'#AUDIO:neu.ogg'#10 +
    ': 0 4 60 a'#10);
  SchreibeDatei(Basis + 'f' + PathDelim + 'neu.ogg', 'A');
  SchreibeDatei(Basis + 'f' + PathDelim + 'alt.mp3', 'B');
  ReadSongHeader(Basis + 'f' + PathDelim + 'lied.txt', H);
  Check('auch wenn MP3 zuerst dasteht',
        ExtractFileName(H.AudioPath) = 'neu.ogg', H.AudioPath);

  // --- keine Lieddatei ---
  WriteLn('Was kein Lied ist');
  SchreibeDatei(Basis + 'liesmich.txt', 'Hier steht nur Text.'#10);
  Check('Datei ohne Titel und Interpret wird abgelehnt',
        not ReadSongHeader(Basis + 'liesmich.txt', H));
  Check('nicht vorhandene Datei wird abgelehnt',
        not ReadSongHeader(Basis + 'gibtesnicht.txt', H));

  // --- Durchsuchen ---
  WriteLn('Ordner durchsuchen');
  Ordner := TStringList.Create;
  try
    Ordner.Add(Basis);
    Lieder := ScanSongs(Ordner);

    Gefunden := Length(Lieder);
    Check('alle Lieder gefunden, die Liesmich nicht', Gefunden = 6,
          IntToStr(Gefunden));

    DuoIdx := -1; AbbaIdx := -1;
    for I := 0 to High(Lieder) do
    begin
      if (Lieder[I].Artist = 'Duo') then DuoIdx := I;
      if (Lieder[I].Artist = 'ABBA') then AbbaIdx := I;
    end;
    Check('das Duett ist dabei und ist als solches gekennzeichnet',
          (DuoIdx >= 0) and Lieder[DuoIdx].Duet);
    Check('das Sololied ist dabei und nicht als Duett gekennzeichnet',
          (AbbaIdx >= 0) and (not Lieder[AbbaIdx].Duet));

    // Der Index muss fortlaufend sein: Die Weboberflaeche schlaegt Dateien
    // ueber ihn nach. Eine Luecke lieferte die falsche Datei aus.
    Gefunden := 0;
    for I := 0 to High(Lieder) do
      if (Lieder[I].Index = I) then Inc(Gefunden);
    Check('Index ist fortlaufend und ohne Luecken',
          Gefunden = Length(Lieder), IntToStr(Gefunden));

    Check('Pfad zur .txt ist gesetzt',
          (AbbaIdx >= 0) and FileExists(Lieder[AbbaIdx].TxtPath),
          Lieder[AbbaIdx].TxtPath);

    Ordner.Clear;
    Ordner.Add(Basis + 'gibtesnicht');
    Lieder := ScanSongs(Ordner);
    Check('nicht vorhandener Ordner liefert nichts statt eines Absturzes',
          Length(Lieder) = 0);

    Lieder := ScanSongs(nil);
    Check('ohne Ordnerliste ebenfalls kein Absturz', Length(Lieder) = 0);
  finally
    Ordner.Free;
  end;

  // Aufraeumen: nur, was dieser Test angelegt hat.
  DeleteFile(Basis + 'liesmich.txt');
  DeleteFile(Basis + 'a' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'a' + PathDelim + 'song.mp3');
  DeleteFile(Basis + 'b' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'c' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'd' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'e' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'e' + PathDelim + 'neu.ogg');
  DeleteFile(Basis + 'e' + PathDelim + 'alt.mp3');
  DeleteFile(Basis + 'f' + PathDelim + 'lied.txt');
  DeleteFile(Basis + 'f' + PathDelim + 'neu.ogg');
  DeleteFile(Basis + 'f' + PathDelim + 'alt.mp3');
  RemoveDir(Basis + 'a'); RemoveDir(Basis + 'b'); RemoveDir(Basis + 'c');
  RemoveDir(Basis + 'd'); RemoveDir(Basis + 'e'); RemoveDir(Basis + 'f');
  RemoveDir(Basis);

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then Halt(1);
end.
