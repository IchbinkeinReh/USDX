unit UWebApi;

(*
 * Die eigentliche Weboberflaeche: Weg hinein, Antwort hinaus.
 *
 * Bewusst getrennt vom Server-Thread in UWebServer. Der haengt ueber ULog am
 * halben Spiel und laesst sich ohne SDL nicht einmal uebersetzen; hier
 * dagegen gibt es nur Zeichenketten, JSON und die Bruecke - und damit ist
 * jede Route pruefbar, ohne dass ein Fenster aufgeht.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  fpjson,
  USongFilter,
  USearchStore,
  UWebBridge,
  UWebPage;

const
  WEB_MAX_RESULTS = 200;

  // Auslieferbare Dateien der Weboberflaeche, abschliessend aufgezaehlt.
  //
  // Bewusst eine Erlaubnisliste statt "alles unter web/": Damit kann keine
  // noch so verdrehte URL etwas ausliefern, was nicht hier steht, und der
  // uebliche Fehler - ein ../ das durch die Pruefung rutscht - kann gar nicht
  // erst auftreten. Neue Datei im Ordner heisst: hier eintragen.
  WEB_DATEIEN: array[0..8] of UTF8String = (
    'index.html',
    'js/song.js',
    'js/pitch.js',
    'js/score.js',
    'js/render.js',
    'js/game.js',
    'js/vollbild.js',
    'js/pegel.js',
    'js/bewertung.js'
  );

type
  // Wie eine Anfrage zu beantworten ist.
  TWebAntwortArt = (
    waNichts,   // keine Dateianfrage - HandleWebRequest uebernimmt
    waDatei,    // FilePath ausliefern
    waFehlt     // war eine Dateianfrage, aber es gibt sie nicht -> 404
  );

// Klaert, ob Path mit einer Datei zu beantworten ist, und liefert deren Pfad.
// WebRoot ist der Ordner mit index.html und js/.
function ResolveFileRequest(Bridge: TWebBridge; const Path, WebRoot: UTF8String;
                            out FilePath, ContentType: UTF8String): TWebAntwortArt;

// Beantwortet eine Anfrage. Rueckgabe ist der HTTP-Status; ContentType und
// Body werden gesetzt. Query enthaelt die Parameter als Name=Wert.
function HandleWebRequest(Bridge: TWebBridge; const Path: UTF8String;
                          Query: TStrings;
                          out ContentType, Body: UTF8String): integer;

implementation

function MimeTyp(const Datei: UTF8String): UTF8String;
var
  Endung: UTF8String;
begin
  Endung := LowerCase(ExtractFileExt(Datei));
  if      (Endung = '.html') then Result := 'text/html; charset=utf-8'
  else if (Endung = '.js')   then Result := 'text/javascript; charset=utf-8'
  else if (Endung = '.css')  then Result := 'text/css; charset=utf-8'
  else if (Endung = '.txt')  then Result := 'text/plain; charset=utf-8'
  else if (Endung = '.mp3')  then Result := 'audio/mpeg'
  else if (Endung = '.ogg')  then Result := 'audio/ogg'
  else if (Endung = '.opus') then Result := 'audio/ogg'
  else if (Endung = '.m4a')  then Result := 'audio/mp4'
  else if (Endung = '.wav')  then Result := 'audio/wav'
  else if (Endung = '.flac') then Result := 'audio/flac'
  // Bewegtbild. Was der Browser davon tatsaechlich abspielen kann, ist eine
  // andere Frage - .avi und .mpg stehen in vielen aelteren Liedern und
  // spielt kein Browser. Der richtige Typ gehoert trotzdem hin: Nur so kann
  // der Browser sauber abwinken, statt an geratenen Daten zu wuergen.
  else if (Endung = '.mp4')  then Result := 'video/mp4'
  else if (Endung = '.m4v')  then Result := 'video/mp4'
  else if (Endung = '.webm') then Result := 'video/webm'
  else if (Endung = '.ogv')  then Result := 'video/ogg'
  else if (Endung = '.mkv')  then Result := 'video/x-matroska'
  else if (Endung = '.avi')  then Result := 'video/x-msvideo'
  else if (Endung = '.mpg')  then Result := 'video/mpeg'
  else if (Endung = '.mpeg') then Result := 'video/mpeg'
  else if (Endung = '.mov')  then Result := 'video/quicktime'
  else if (Endung = '.divx') then Result := 'video/x-msvideo'
  // Hintergrundbilder.
  else if (Endung = '.jpg')  then Result := 'image/jpeg'
  else if (Endung = '.jpeg') then Result := 'image/jpeg'
  else if (Endung = '.png')  then Result := 'image/png'
  else if (Endung = '.gif')  then Result := 'image/gif'
  else if (Endung = '.webp') then Result := 'image/webp'
  else if (Endung = '.bmp')  then Result := 'image/bmp'
  else Result := 'application/octet-stream';
end;

function ResolveFileRequest(Bridge: TWebBridge; const Path, WebRoot: UTF8String;
                            out FilePath, ContentType: UTF8String): TWebAntwortArt;
var
  I, Index, Schraeg: integer;
  Rest, Name: UTF8String;
  Art: TWebFileKind;
begin
  FilePath := '';
  ContentType := '';
  Result := waNichts;

  // --- Liedateien: /api/song/<index>/txt bzw. /audio ---
  if (Copy(Path, 1, 10) = '/api/song/') then
  begin
    Result := waFehlt;
    Rest := Copy(Path, 11, Length(Path));
    Schraeg := Pos('/', Rest);
    if (Schraeg <= 1) then Exit;

    Name := Copy(Rest, Schraeg + 1, Length(Rest));
    if      (Name = 'txt')        then Art := wfkTxt
    else if (Name = 'audio')      then Art := wfkAudio
    else if (Name = 'video')      then Art := wfkVideo
    else if (Name = 'background') then Art := wfkBackground
    else Exit;

    // -1 als Ausweichwert: StrToIntDef schluckt auch "3x" nicht, und ein
    // negativer Index wird von SongPath ohnehin abgelehnt.
    Index := StrToIntDef(Copy(Rest, 1, Schraeg - 1), -1);
    if not Assigned(Bridge) then Exit;
    if not Bridge.SongPath(Index, Art, FilePath) then
    begin
      FilePath := '';
      Exit;
    end;
    ContentType := MimeTyp(FilePath);
    Result := waDatei;
    Exit;
  end;

  // --- Oberflaeche selbst ---
  if (Path = '') or (Path = '/') then
    Name := 'index.html'
  else
    Name := Copy(Path, 2, Length(Path));

  for I := Low(WEB_DATEIEN) to High(WEB_DATEIEN) do
    if (Name = WEB_DATEIEN[I]) then
    begin
      if (WebRoot = '') then Exit;   // kein Ordner bekannt -> alte Seite
      FilePath := IncludeTrailingPathDelimiter(WebRoot) +
                  StringReplace(Name, '/', PathDelim, [rfReplaceAll]);
      ContentType := MimeTyp(Name);
      if FileExists(FilePath) then
        Result := waDatei
      else
      begin
        FilePath := '';
        Result := waNichts;   // faellt auf die eingebaute Seite zurueck
      end;
      Exit;
    end;
end;

function FilterFromName(const Name: UTF8String): TSongFilter;
begin
  // Dieselben Namen wie bei den gespeicherten Suchen - USearchStore ist die
  // eine Stelle, an der die Zuordnung steht. Eine zweite Liste hier waere
  // beim naechsten neuen Suchmodus sofort veraltet.
  if not NameToFilter(Name, Result) then
    Result := fltAll;
end;

function SongsToJSON(const Treffer: TWebSongArray): UTF8String;
var
  Liste: TJSONArray;
  Eintrag: TJSONObject;
  I: integer;
begin
  Liste := TJSONArray.Create;
  try
    for I := 0 to High(Treffer) do
    begin
      Eintrag := TJSONObject.Create;
      Eintrag.Add('index', Treffer[I].Index);
      Eintrag.Add('artist', Treffer[I].Artist);
      Eintrag.Add('title', Treffer[I].Title);
      Eintrag.Add('genre', Treffer[I].Genre);
      Eintrag.Add('language', Treffer[I].Language);
      Eintrag.Add('year', Treffer[I].Year);
      Eintrag.Add('duet', Treffer[I].Duet);
      Liste.Add(Eintrag);
    end;
    Result := Liste.AsJSON;
  finally
    Liste.Free;
  end;
end;

function HandleWebRequest(Bridge: TWebBridge; const Path: UTF8String;
                          Query: TStrings;
                          out ContentType, Body: UTF8String): integer;
var
  Max, Index: integer;
  Antwort: TJSONObject;
begin
  ContentType := 'text/plain; charset=utf-8';
  Body := '';

  if not Assigned(Bridge) then
  begin
    Body := 'Keine Verbindung zum Spiel';
    Result := 503;
    Exit;
  end;

  if (Path = '') or (Path = '/') or (Path = '/index.html') then
  begin
    ContentType := 'text/html; charset=utf-8';
    Body := WebPageHTML;
    Result := 200;
    Exit;
  end;

  if (Path = '/api/status') then
  begin
    Antwort := TJSONObject.Create;
    try
      Antwort.Add('songs', Bridge.SongCount);
      Antwort.Add('stand', Bridge.Stand);
      Body := Antwort.AsJSON;
    finally
      Antwort.Free;
    end;
    ContentType := 'application/json; charset=utf-8';
    Result := 200;
    Exit;
  end;

  if (Path = '/api/songs') then
  begin
    Max := StrToIntDef(Query.Values['max'], 100);
    // Nach oben begrenzen: Eine Anfrage mit max=1000000 soll nicht das
    // ganze Verzeichnis in eine Antwort giessen.
    if (Max <= 0) or (Max > WEB_MAX_RESULTS) then
      Max := WEB_MAX_RESULTS;
    Body := SongsToJSON(Bridge.FindSongs(Query.Values['q'],
                                         FilterFromName(Query.Values['mode']),
                                         Max));
    ContentType := 'application/json; charset=utf-8';
    Result := 200;
    Exit;
  end;

  if (Path = '/api/select') then
  begin
    Index := StrToIntDef(Query.Values['index'], -1);
    Antwort := TJSONObject.Create;
    try
      if (Index < 0) then
      begin
        Antwort.Add('error', 'index fehlt oder ist ungueltig');
        Result := 400;
      end
      else
      begin
        // Nur einreihen - ausgefuehrt wird im Spielthread.
        Bridge.PostCommand(wckStart, Index);
        Antwort.Add('queued', true);
        Result := 200;
      end;
      Body := Antwort.AsJSON;
    finally
      Antwort.Free;
    end;
    ContentType := 'application/json; charset=utf-8';
    Exit;
  end;

  Body := 'Nicht gefunden';
  Result := 404;
end;

end.
