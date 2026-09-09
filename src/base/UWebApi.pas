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
  UWebLobby,
  UWebPage;

const
  WEB_MAX_RESULTS = 200;

  // Auslieferbare Dateien der Weboberflaeche, abschliessend aufgezaehlt.
  //
  // Bewusst eine Erlaubnisliste statt "alles unter web/": Damit kann keine
  // noch so verdrehte URL etwas ausliefern, was nicht hier steht, und der
  // uebliche Fehler - ein ../ das durch die Pruefung rutscht - kann gar nicht
  // erst auftreten. Neue Datei im Ordner heisst: hier eintragen.
  WEB_DATEIEN: array[0..10] of UTF8String = (
    'index.html',
    'favicon.png',
    'js/song.js',
    'js/pitch.js',
    'js/score.js',
    'js/render.js',
    'js/game.js',
    'js/vollbild.js',
    'js/pegel.js',
    'js/bewertung.js',
    'js/lobby.js'
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
function HandleWebRequest(Bridge: TWebBridge; Lobby: TLobbyRegistry;
                          const Path: UTF8String; Query: TStrings;
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
    else if (Name = 'cover')      then Art := wfkCover
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

// Das Array gehoert danach dem Aufrufer - genau wie TJSONObject.Add es mit
// jedem TJSONData haelt, das man ihm uebergibt.
function SongsToJSON(const Treffer: TWebSongArray): TJSONArray;
var
  Eintrag: TJSONObject;
  I: integer;
begin
  Result := TJSONArray.Create;
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
    // Ob es ein Titelbild gibt. Ohne diese Angabe muesste die Liste es bei
    // jedem Lied auf gut Glueck anfordern - bei neuntausend Eintraegen
    // waeren das tausende Fehlanfragen.
    Eintrag.Add('cover', Treffer[I].CoverPath <> '');
    Result.Add(Eintrag);
  end;
end;

function PhaseName(Phase: TLobbyPhase): UTF8String;
begin
  case Phase of
    lphSingt: Result := 'singt';
  else
    Result := 'wartet';
  end;
end;

function ZielName(Ziel: TLobbyZiel): UTF8String;
begin
  case Ziel of
    lzBuehne:   Result := 'buehne';
    lzErgebnis: Result := 'ergebnis';
  else
    Result := 'auswahl';
  end;
end;

function ZielVonName(const Name: UTF8String; out Ziel: TLobbyZiel): boolean;
begin
  Result := True;
  if      (Name = 'auswahl')  then Ziel := lzAuswahl
  else if (Name = 'buehne')   then Ziel := lzBuehne
  else if (Name = 'ergebnis') then Ziel := lzErgebnis
  else
  begin
    Ziel := lzAuswahl;
    Result := False;
  end;
end;

function ReaktionsArtName(Art: TReaktionsArt): UTF8String;
begin
  case Art of
    rkRunter: Result := 'runter';
  else
    Result := 'hoch';
  end;
end;

function ReaktionsArtVonName(const Name: UTF8String): TReaktionsArt;
begin
  if (Name = 'runter') then Result := rkRunter else Result := rkHoch;
end;

// Baut die Zustands-Antwort. NIE die eigentlichen Tokens hinein - nur
// serverseitig aus MeinToken berechnete isHost/isYou. So sieht kein Gast
// je den Host-Token oder den eines anderen Gasts.
//
// Since filtert die Reaktionsliste: nur Eintraege mit Seq > Since kommen
// mit - der Aufrufer hat die davor schon gesehen (siehe /state-Route).
function LobbyToJSON(const Z: TLobbyZustand; const MeinToken: UTF8String;
                     Since: int64): TJSONObject;
var
  SpielerListe, ReaktionsListe: TJSONArray;
  SpielerEintrag, ReaktionsEintrag: TJSONObject;
  I: integer;
begin
  Result := TJSONObject.Create;
  Result.Add('code', Z.Code);
  Result.Add('isHost', Z.HostToken = MeinToken);
  Result.Add('phase', PhaseName(Z.Phase));
  Result.Add('ziel', ZielName(Z.Ziel));
  Result.Add('zielNr', Z.ZielNr);
  Result.Add('songIndex', Z.SongIndex);
  Result.Add('revision', Z.Revision);
  Result.Add('serverNowMs', Z.ServerNowMs);
  Result.Add('serverStartMs', Z.ServerStartMs);
  Result.Add('pausiert', Z.Pausiert);
  Result.Add('pausePosMs', Z.PausePosMs);
  Result.Add('vorschauStartMs', Z.VorschauStartMs);

  SpielerListe := TJSONArray.Create;
  for I := 0 to High(Z.Spieler) do
  begin
    SpielerEintrag := TJSONObject.Create;
    SpielerEintrag.Add('name', Z.Spieler[I].Name);
    SpielerEintrag.Add('isHost', Z.Spieler[I].Token = Z.HostToken);
    SpielerEintrag.Add('isYou', Z.Spieler[I].Token = MeinToken);
    SpielerEintrag.Add('bereit', Z.Spieler[I].Bereit);
    SpielerEintrag.Add('singt', Z.Spieler[I].Singt);
    if (Z.Spieler[I].Score >= 0) then
      SpielerEintrag.Add('score', Z.Spieler[I].Score)
    else
      SpielerEintrag.Add('score', TJSONNull.Create);
    SpielerListe.Add(SpielerEintrag);
  end;
  Result.Add('spieler', SpielerListe);

  ReaktionsListe := TJSONArray.Create;
  for I := 0 to High(Z.Reaktionen) do
    if (Z.Reaktionen[I].Seq > Since) then
    begin
      ReaktionsEintrag := TJSONObject.Create;
      ReaktionsEintrag.Add('seq', Z.Reaktionen[I].Seq);
      ReaktionsEintrag.Add('art', ReaktionsArtName(Z.Reaktionen[I].Art));
      ReaktionsEintrag.Add('name', Z.Reaktionen[I].Name);
      ReaktionsListe.Add(ReaktionsEintrag);
    end;
  Result.Add('reaktionen', ReaktionsListe);
end;

function HandleWebRequest(Bridge: TWebBridge; Lobby: TLobbyRegistry;
                          const Path: UTF8String; Query: TStrings;
                          out ContentType, Body: UTF8String): integer;
var
  Max, Index, Sel, Gesamt: integer;
  Antwort: TJSONObject;
  Treffer: TWebSongArray;
  LobbyRest, LobbyCode, LobbyAktion, Token, ReaktionsText: UTF8String;
  LobbySchraeg: integer;
  Since, ServerStartMs, Seq: int64;
  Punkte, MeldeBereit, MeldeSingt: integer;
  FalscherToken, KeinLied, PauseAn: boolean;
  ReaktionsArt: TReaktionsArt;
  LobbyZiel: TLobbyZiel;
  Zustand: TLobbyZustand;
begin
  ContentType := 'text/plain; charset=utf-8';
  Body := '';

  if not Assigned(Bridge) or not Assigned(Lobby) then
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
    Treffer := Bridge.FindSongs(Query.Values['q'],
                                FilterFromName(Query.Values['mode']),
                                Max,
                                StrToIntDef(Query.Values['offset'], 0),
                                Gesamt);
    // Gesamtzahl mit ausliefern, nicht nur die Seite: Die Oberflaeche zeigt
    // "N gefunden" an und wuerfelt beim Zufallslied ueber alle Treffer, nicht
    // nur ueber die schon geladene Seite.
    Antwort := TJSONObject.Create;
    try
      Antwort.Add('total', Gesamt);
      Antwort.Add('songs', SongsToJSON(Treffer));
      Body := Antwort.AsJSON;
    finally
      Antwort.Free;
    end;
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
      else if not Bridge.SelectIndexOf(Index, Sel) then
      begin
        Antwort.Add('error', 'unbekanntes Lied');
        Result := 404;
      end
      else
      begin
        // Nur einreihen - ausgefuehrt wird im Spielthread. Uebergeben wird
        // die Kennung, die das Spiel kennt, nicht der Listenplatz: Die
        // Liste ist alphabetisch sortiert und stimmt mit der Reihenfolge im
        // Spiel nicht ueberein.
        Bridge.PostCommand(wckStart, Sel);
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

  // --- Mehrspieler-Lobbys: /api/lobby/create, /api/lobby/<code>/<aktion> ---
  if (Copy(Path, 1, 11) = '/api/lobby/') then
  begin
    ContentType := 'application/json; charset=utf-8';
    Token := Query.Values['token'];
    LobbyRest := Copy(Path, 12, Length(Path));
    Antwort := TJSONObject.Create;
    try
      Result := 404;

      if (LobbyRest = 'create') then
      begin
        LobbyCode := Lobby.CreateLobby(Token, Query.Values['name']);
        Lobby.GetState(LobbyCode, Token, -1, -1, -1, Zustand);
        Antwort.Free;
        Antwort := LobbyToJSON(Zustand, Token, 0);
        Result := 200;
      end
      else
      begin
        LobbySchraeg := Pos('/', LobbyRest);
        if (LobbySchraeg <= 1) then
        begin
          Antwort.Add('error', 'unbekannter Weg');
          Result := 404;
        end
        else
        begin
          LobbyCode := Copy(LobbyRest, 1, LobbySchraeg - 1);
          LobbyAktion := Copy(LobbyRest, LobbySchraeg + 1, Length(LobbyRest));

          if (LobbyAktion = 'join') then
          begin
            if Lobby.JoinLobby(LobbyCode, Token, Query.Values['name']) then
            begin
              Lobby.GetState(LobbyCode, Token, -1, -1, -1, Zustand);
              Antwort.Free;
              Antwort := LobbyToJSON(Zustand, Token, 0);
              Result := 200;
            end
            else
              // Entweder gibt es den Code nicht, oder die Lobby ist voll -
              // fuer den Beitretenden macht das keinen praktischen
              // Unterschied.
              Antwort.Add('error', 'unbekannte oder volle Lobby');
          end

          else if (LobbyAktion = 'leave') then
          begin
            Lobby.LeaveLobby(LobbyCode, Token);
            Antwort.Add('left', true);
            Result := 200;
          end

          else if (LobbyAktion = 'state') then
          begin
            Since := StrToInt64Def(Query.Values['since'], 0);
            // Jeweils -1, wenn der Parameter fehlt: dann bleibt der
            // bisherige Wert stehen.
            Punkte := StrToIntDef(Query.Values['score'], -1);
            MeldeBereit := StrToIntDef(Query.Values['bereit'], -1);
            MeldeSingt := StrToIntDef(Query.Values['singt'], -1);
            if Lobby.GetState(LobbyCode, Token, Punkte, MeldeBereit, MeldeSingt,
                              Zustand) then
            begin
              Antwort.Free;
              Antwort := LobbyToJSON(Zustand, Token, Since);
              Result := 200;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'select') then
          begin
            // -1 ist eine ausdrueckliche Abwahl ("Anderes Lied"), kein
            // Fehler - deshalb -2 als Rueckfall fuer einen fehlenden oder
            // kaputten Parameter, sonst waere beides nicht zu unterscheiden.
            Index := StrToIntDef(Query.Values['index'], -2);
            if (Index <> -1) and ((Index < 0) or (Index >= Bridge.SongCount)) then
            begin
              Antwort.Add('error', 'unbekanntes Lied');
              Result := 404;
            end
            else if Lobby.SelectSong(LobbyCode, Token, Index, FalscherToken) then
            begin
              Antwort.Add('selected', true);
              Result := 200;
            end
            else if FalscherToken then
            begin
              Antwort.Add('error', 'nur der Ersteller darf auswaehlen');
              Result := 403;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'start') then
          begin
            ServerStartMs := StrToInt64Def(Query.Values['serverStartMs'], 0);
            if Lobby.StartSinging(LobbyCode, Token, ServerStartMs,
                                  FalscherToken, KeinLied) then
            begin
              Antwort.Add('phase', 'singt');
              Antwort.Add('serverStartMs', ServerStartMs);
              Result := 200;
            end
            else if FalscherToken then
            begin
              Antwort.Add('error', 'nur der Ersteller darf starten');
              Result := 403;
            end
            else if KeinLied then
            begin
              Antwort.Add('error', 'kein Lied ausgewaehlt');
              Result := 409;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'ziel') then
          begin
            if not ZielVonName(Query.Values['ziel'], LobbyZiel) then
            begin
              Antwort.Add('error', 'unbekanntes Ziel');
              Result := 400;
            end
            else if Lobby.SetZiel(LobbyCode, Token, LobbyZiel, FalscherToken) then
            begin
              Antwort.Add('ziel', Query.Values['ziel']);
              Result := 200;
            end
            else if FalscherToken then
            begin
              Antwort.Add('error', 'nur der Ersteller bestimmt, wie es weitergeht');
              Result := 403;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'pause') then
          begin
            PauseAn := Query.Values['an'] = '1';
            if Lobby.SetPause(LobbyCode, Token, PauseAn,
                              StrToInt64Def(Query.Values['pos'], 0),
                              FalscherToken) then
            begin
              Antwort.Add('pausiert', PauseAn);
              Result := 200;
            end
            else if FalscherToken then
            begin
              Antwort.Add('error', 'nur der Ersteller darf pausieren');
              Result := 403;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'vorschau') then
          begin
            if Lobby.SetVorschau(LobbyCode, Token,
                                 StrToInt64Def(Query.Values['startMs'], 0),
                                 FalscherToken) then
            begin
              Antwort.Add('vorschau', true);
              Result := 200;
            end
            else if FalscherToken then
            begin
              Antwort.Add('error', 'nur der Ersteller gibt die Vorschau vor');
              Result := 403;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else if (LobbyAktion = 'react') then
          begin
            ReaktionsText := Query.Values['art'];
            ReaktionsArt := ReaktionsArtVonName(ReaktionsText);
            if Lobby.React(LobbyCode, Token, ReaktionsArt, Seq) then
            begin
              Antwort.Add('seq', Seq);
              Result := 200;
            end
            else
              Antwort.Add('error', 'unbekannte Lobby');
          end

          else
            Antwort.Add('error', 'unbekannter Weg');
        end;
      end;

      Body := Antwort.AsJSON;
    finally
      Antwort.Free;
    end;
    Exit;
  end;

  Body := 'Nicht gefunden';
  Result := 404;
end;

end.
