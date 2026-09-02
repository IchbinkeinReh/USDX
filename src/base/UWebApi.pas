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

// Beantwortet eine Anfrage. Rueckgabe ist der HTTP-Status; ContentType und
// Body werden gesetzt. Query enthaelt die Parameter als Name=Wert.
function HandleWebRequest(Bridge: TWebBridge; const Path: UTF8String;
                          Query: TStrings;
                          out ContentType, Body: UTF8String): integer;

implementation

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
