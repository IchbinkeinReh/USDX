unit UScreenSongSearchLoad;

(*
 * Auswahlfenster fuer gespeicherte Suchen.
 *
 * Liegt als Overlay ueber der Liederauswahl, wie das Sprungfenster und das
 * Liedmenue: sichtbar schalten, Eingaben abfangen, darueber zeichnen.
 *
 * Es benutzt absichtlich den Theme-Block "SongMenu" mit, statt einen
 * eigenen zu verlangen. Ein neuer Block muesste in JEDER vorhandenen
 * Theme-Datei ergaenzt werden; fehlt er dort, zeichnet das Fenster ins
 * Leere. So sieht es in jedem Theme sofort richtig aus - der Block gehoert
 * ohnehin zu einem Fenster derselben Art an derselben Stelle.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  UMenu,
  UMusic,
  USongs,
  USongFilter,
  USearchStore,
  UThemes,
  UPath,
  sdl2,
  SysUtils,
  Classes;

type
  TScreenSongSearchLoad = class(TMenu)
    private
      fVisible: boolean;
      fAuswahl: integer;      // Index in der Liste, an SelectSlide gebunden
      fStore:   TSearchStore;

      procedure SetVisible(Value: boolean);
      procedure FuelleListe;
      function  DateiPfad: IPath;
    public
      constructor Create; override;
      destructor Destroy; override;

      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
      function Draw: boolean; override;

      // Nimmt die gerade aktive Suche auf und schreibt sie weg.
      // Rueckgabe: false, wenn sie leer war oder schon vorhanden.
      function SpeichereAktuelle(const AText: UTF8String; AFilter: TSongFilter): boolean;

      procedure Laden;
      procedure Sichern;

      property Visible: boolean read fVisible write SetVisible;
      property Store: TSearchStore read fStore;
  end;

const
  ID = 'ID_016';   // fuer das Hilfesystem - dieselbe Seite wie die Suche

implementation

uses
  UGraphic,
  URenderer,
  UPlatform,
  UFilesystem,
  ULog,
  UUnicodeUtils,
  ULanguage,
  UIni;

const
  // ACHTUNG beim Umbenennen: Pascal unterscheidet keine Gross- und
  // Kleinschreibung. Diese Konstante hiess erst DATEINAME - genau wie die
  // Methode Dateiname. Damit loeste der Name in der Methode auf die Methode
  // selbst auf, und weil Append sowohl Zeichenkette als auch IPath annimmt,
  // compilierte die Endlosschleife anstandslos. Sichtbar wurde sie erst als
  // Stack Overflow beim ersten Tastendruck.
  SUCHEN_DATEI = 'searches.txt';

constructor TScreenSongSearchLoad.Create;
var
  Leer: array of UTF8String;
begin
  inherited Create;

  fStore := TSearchStore.Create;
  fAuswahl := 0;

  AddText(Theme.SongMenu.TextMenu);
  LoadFromTheme(Theme.SongMenu);

  SetLength(Leer, 1);
  Leer[0] := '-';
  AddSelectSlide(Theme.SongMenu.SelectSlide1, fAuswahl, Leer);

  Interaction := 0;
end;

destructor TScreenSongSearchLoad.Destroy;
begin
  fStore.Free;
  inherited;
end;

function TScreenSongSearchLoad.DateiPfad: IPath;
begin
  // Derselbe Ort, an dem auch die Einstellungen liegen (siehe UIni):
  // beschreibbar und je Benutzer getrennt. UPathUtils.UserPath ist dafuer
  // nicht zu gebrauchen - das ist eine lokale Variable, kein Global.
  Result := Platform.GetGameUserPath.Append(SUCHEN_DATEI);
end;

procedure TScreenSongSearchLoad.Laden;
var
  Lines: TStringList;
  Stream: TBinaryFileStream;
begin
  fStore.Clear;
  if not DateiPfad.IsFile then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Stream := TBinaryFileStream.Create(DateiPfad, fmOpenRead);
      try
        Lines.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      fStore.LoadFromStrings(Lines);
    except
      on E: Exception do
        // Eine unlesbare Datei darf das Spiel nicht aufhalten: Dann gibt es
        // eben keine gespeicherten Suchen.
        Log.LogError('Gespeicherte Suchen nicht lesbar: ' + E.Message,
                     'ScreenSongSearchLoad');
    end;
  finally
    Lines.Free;
  end;
end;

procedure TScreenSongSearchLoad.Sichern;
var
  Lines: TStringList;
  Stream: TBinaryFileStream;
begin
  Lines := TStringList.Create;
  try
    fStore.SaveToStrings(Lines);
    try
      Stream := TBinaryFileStream.Create(DateiPfad, fmCreate);
      try
        Lines.SaveToStream(Stream);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
        Log.LogError('Gespeicherte Suchen nicht schreibbar: ' + E.Message,
                     'ScreenSongSearchLoad');
    end;
  finally
    Lines.Free;
  end;
end;

function TScreenSongSearchLoad.SpeichereAktuelle(const AText: UTF8String;
                                                 AFilter: TSongFilter): boolean;
begin
  Laden;   // frisch einlesen, falls anderswo geaendert
  Result := fStore.Add(AText, AFilter);
  if Result then
    Sichern;
end;

procedure TScreenSongSearchLoad.FuelleListe;
var
  I: integer;
  Eintraege: array of UTF8String;
begin
  if (fStore.Count = 0) then
  begin
    SetLength(Eintraege, 1);
    Eintraege[0] := Language.Translate('SEARCH_NONE_SAVED');
  end
  else
  begin
    SetLength(Eintraege, fStore.Count);
    for I := 0 to fStore.Count - 1 do
      Eintraege[I] := fStore.Caption(I);
  end;

  fAuswahl := 0;
  UpdateSelectSlideOptions(0, Eintraege, fAuswahl);
  SelectsS[0].SetSelectOpt(0);
end;

procedure TScreenSongSearchLoad.SetVisible(Value: boolean);
begin
  if (fVisible = false) and (Value = true) then
    OnShow;
  fVisible := Value;
end;

procedure TScreenSongSearchLoad.OnShow;
begin
  inherited;
  Laden;
  FuelleListe;
  Interaction := 0;
end;

function TScreenSongSearchLoad.ParseInput(PressedKey: cardinal;
                                          CharCode: UCS4Char;
                                          PressedDown: boolean): boolean;
var
  Gewaehlt: TSavedSearch;
begin
  Result := true;
  if not PressedDown then
    Exit;

  case PressedKey of
    SDLK_ESCAPE,
    SDLK_BACKSPACE:
      begin
        // Ohne jede Aenderung schliessen - das ist der Sinn von Esc.
        Visible := false;
        AudioPlayback.PlaySound(SoundLib.Back);
      end;

    SDLK_RETURN:
      begin
        Visible := false;
        if (fStore.Count > 0) and (fAuswahl >= 0) and (fAuswahl < fStore.Count) then
        begin
          Gewaehlt := fStore[fAuswahl];
          AudioPlayback.PlaySound(SoundLib.Start);
          // Das Sprungfenster haelt den Suchzustand; es setzt Modus und
          // Begriff und fuehrt die Suche aus.
          ScreenSongJumpto.ApplySearch(Gewaehlt.Text, Gewaehlt.Filter);
        end
        else
          AudioPlayback.PlaySound(SoundLib.Back);
      end;

    SDLK_DELETE:
      begin
        // Aufraeumen von hier aus, sonst muesste man die Datei von Hand
        // bearbeiten.
        if (fStore.Count > 0) then
        begin
          fStore.Delete(fAuswahl);
          Sichern;
          FuelleListe;
          AudioPlayback.PlaySound(SoundLib.Back);
        end;
      end;

    SDLK_UP, SDLK_LEFT:
      begin
        InteractDec;
        AudioPlayback.PlaySound(SoundLib.Change);
      end;

    SDLK_DOWN, SDLK_RIGHT:
      begin
        InteractInc;
        AudioPlayback.PlaySound(SoundLib.Change);
      end;
  end;
end;

function TScreenSongSearchLoad.Draw: boolean;
begin
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  Result := inherited Draw;
end;

end.
