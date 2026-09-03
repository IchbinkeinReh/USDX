unit USongScan;

(*
 * Sucht Lieddateien und liest ihre Kopfdaten - ohne SDL, ohne OpenGL.
 *
 * Gegenstueck zu TSongs fuer den kopflosen Betrieb. TSongs selbst ist hier
 * nicht zu gebrauchen: Es haengt ueber USong an URenderer und UMusic, also
 * an der Grafik- und Tonkette, und die gibt es auf einem Rechner ohne
 * Bildschirm nicht.
 *
 * Woher die Liederordner kommen, in dieser Reihenfolge:
 *   1. --songpath auf der Befehlszeile
 *   2. [Directories] SongDir* aus der config.ini des Spiels
 *   3. die ueblichen Stellen neben der ausfuehrbaren Datei
 *
 * Punkt 2 ist der Grund, warum ueberhaupt eine Ini gelesen wird: So sieht
 * der kopflose Server DIESELBE Sammlung wie das Spiel auf demselben Rechner.
 * Ohne das muesste man die Ordner doppelt pflegen.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  IniFiles,
  USongHeader,
  UWebBridge;

// Sammelt die Liederordner. Die Liste kann leer sein.
procedure CollectSongDirs(Dirs: TStrings);

// Sucht rekursiv nach *.txt und liest deren Kopfdaten.
// Meldung wird - wenn gesetzt - je Ordner mit dem Stand aufgerufen.
type
  TScanReport = procedure(const Nachricht: UTF8String) of object;

function ScanSongs(Dirs: TStrings; Bericht: TScanReport = nil): TWebSongArray;

// Sucht die config.ini des Spiels. '' wenn keine gefunden wurde.
function FindConfigIni: UTF8String;

implementation

const
  // Tiefer verschachtelt legt niemand seine Lieder ab, und die Grenze
  // verhindert, dass eine Schleife aus Verweisen den Lauf aufhaengt.
  MAX_TIEFE = 8;

function Verzeichnis(const P: UTF8String): UTF8String;
begin
  Result := IncludeTrailingPathDelimiter(P);
end;

function FindConfigIni: UTF8String;
var
  Kandidaten: array[0..2] of UTF8String;
  Basis, Heim: UTF8String;
  I: integer;
begin
  Result := '';
  Basis := ExtractFilePath(ParamStr(0));
  Heim := GetEnvironmentVariable('HOME');

  Kandidaten[0] := Basis + 'config.ini';
  Kandidaten[1] := Basis + '..' + PathDelim + 'config.ini';
  if (Heim <> '') then
    Kandidaten[2] := Verzeichnis(Heim) + '.ultrastardx' + PathDelim + 'config.ini'
  else
    Kandidaten[2] := '';

  for I := Low(Kandidaten) to High(Kandidaten) do
    if (Kandidaten[I] <> '') and FileExists(Kandidaten[I]) then
    begin
      Result := Kandidaten[I];
      Exit;
    end;
end;

// Liest --songpath von der Befehlszeile. Bewusst selbst gelesen statt ueber
// UCommandLine: Das haengt an ULog und damit wieder am ganzen Spiel.
procedure SongPathsVonBefehlszeile(Dirs: TStrings);
var
  I: integer;
  Arg: UTF8String;
begin
  I := 1;
  while (I <= ParamCount) do
  begin
    Arg := ParamStr(I);
    while (Length(Arg) > 0) and (Arg[1] = '-') do
      Delete(Arg, 1, 1);
    if (LowerCase(Arg) = 'songpath') and (I < ParamCount) then
    begin
      Dirs.Add(ParamStr(I + 1));
      Inc(I);
    end;
    Inc(I);
  end;
end;

procedure SongPathsVonIni(Dirs: TStrings);
var
  Ini: TIniFile;
  Datei: UTF8String;
  Schluessel: TStringList;
  I: integer;
  Wert: UTF8String;
begin
  Datei := FindConfigIni;
  if (Datei = '') then Exit;

  Ini := TIniFile.Create(Datei);
  Schluessel := TStringList.Create;
  try
    Ini.ReadSection('Directories', Schluessel);
    for I := 0 to Schluessel.Count - 1 do
    begin
      // Dieselbe Regel wie TIni.LoadPaths: alles, was mit SONGDIR anfaengt.
      if (Pos('SONGDIR', UpperCase(Schluessel[I])) = 1) then
      begin
        Wert := Trim(Ini.ReadString('Directories', Schluessel[I], ''));
        if (Wert <> '') then
          Dirs.Add(Wert);
      end;
    end;
  finally
    Schluessel.Free;
    Ini.Free;
  end;
end;

procedure CollectSongDirs(Dirs: TStrings);
var
  Basis, Heim: UTF8String;

  procedure NimmWennDa(const P: UTF8String);
  begin
    if (P <> '') and DirectoryExists(P) then
      Dirs.Add(P);
  end;

var
  I: integer;
begin
  SongPathsVonBefehlszeile(Dirs);
  if (Dirs.Count = 0) then
    SongPathsVonIni(Dirs);

  if (Dirs.Count = 0) then
  begin
    Basis := ExtractFilePath(ParamStr(0));
    Heim := GetEnvironmentVariable('HOME');
    NimmWennDa(Basis + 'songs');
    NimmWennDa(Basis + '..' + PathDelim + 'songs');
    if (Heim <> '') then
      NimmWennDa(Verzeichnis(Heim) + '.ultrastardx' + PathDelim + 'songs');
  end;

  // Nicht vorhandene Ordner aus Ini oder Befehlszeile wieder entfernen -
  // sonst laeuft die Suche gegen Pfade, die es nicht mehr gibt.
  for I := Dirs.Count - 1 downto 0 do
    if not DirectoryExists(Dirs[I]) then
      Dirs.Delete(I);
end;

// Sucht in einem Ordner rekursiv nach .txt und haengt die Treffer an.
procedure SucheIn(const Ordner: UTF8String; Tiefe: integer; Dateien: TStrings);
var
  Suche: TSearchRec;
  Voll: UTF8String;
begin
  if (Tiefe > MAX_TIEFE) then Exit;
  if (FindFirst(Verzeichnis(Ordner) + '*', faAnyFile, Suche) <> 0) then Exit;
  try
    repeat
      if (Suche.Name = '.') or (Suche.Name = '..') then Continue;
      Voll := Verzeichnis(Ordner) + Suche.Name;
      if ((Suche.Attr and faDirectory) <> 0) then
        SucheIn(Voll, Tiefe + 1, Dateien)
      else if (LowerCase(ExtractFileExt(Suche.Name)) = '.txt') then
        Dateien.Add(Voll);
    until (FindNext(Suche) <> 0);
  finally
    FindClose(Suche);
  end;
end;

function ScanSongs(Dirs: TStrings; Bericht: TScanReport = nil): TWebSongArray;
var
  Dateien: TStringList;
  Kopf: TSongHeader;
  I, Anzahl: integer;
begin
  SetLength(Result, 0);
  if not Assigned(Dirs) then Exit;

  Dateien := TStringList.Create;
  try
    for I := 0 to Dirs.Count - 1 do
    begin
      if Assigned(Bericht) then
        Bericht('Durchsuche ' + Dirs[I]);
      SucheIn(Dirs[I], 0, Dateien);
    end;

    SetLength(Result, Dateien.Count);
    Anzahl := 0;
    for I := 0 to Dateien.Count - 1 do
    begin
      if not ReadSongHeader(Dateien[I], Kopf) then
        Continue;   // keine Lieddatei - etwa eine Liesmich daneben

      Result[Anzahl].Index     := Anzahl;
      Result[Anzahl].Artist    := Kopf.Artist;
      Result[Anzahl].Title     := Kopf.Title;
      Result[Anzahl].Edition   := Kopf.Edition;
      Result[Anzahl].Genre     := Kopf.Genre;
      Result[Anzahl].Language  := Kopf.Language;
      Result[Anzahl].Year      := Kopf.Year;
      Result[Anzahl].Duet      := Kopf.Duet;
      Result[Anzahl].TxtPath   := Kopf.TxtPath;
      Result[Anzahl].AudioPath := Kopf.AudioPath;
      Inc(Anzahl);
    end;
    SetLength(Result, Anzahl);
  finally
    Dateien.Free;
  end;
end;

end.
