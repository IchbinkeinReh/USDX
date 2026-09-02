{* UltraStar Deluxe - Karaoke Game
 *
 * UltraStar Deluxe is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING. If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 * $URL: svn://basisbit@svn.code.sf.net/p/ultrastardx/svn/trunk/src/screens/UScreenSongJumpto.pas $
 * $Id: UScreenSongJumpto.pas 2199 2010-03-14 20:56:20Z brunzelchen $
 *}

unit UScreenSongJumpto;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UDisplay,
  UFiles,
  UMenu,
  UMusic,
  USongs,
  UThemes,
  USongSearch,
  Classes,
  sdl2,
  SysUtils;

type
  TScreenSongJumpto = class(TMenu)
    private
      //For ChangeMusic
      fLastPlayed: integer;
      fVisible: boolean;
      fSelectType: TSongFilter;
      fVisSongs: integer;

      // Die verschiedenen Werte des aktuellen Feldes, alphabetisch - fuer
      // das Durchblaettern mit Hoch/Runter. Wird bei Bedarf gefuellt und
      // beim Moduswechsel verworfen, weil sie dann nicht mehr passt.
      fWerte: TStringList;
      fWertIndex: integer;
      // Wofuer die Liste gesammelt wurde. Daran wird erkannt, ob sie noch
      // passt - verlaesslicher, als an jeder Stelle ans Verwerfen zu denken,
      // die den Modus aendert (Pfeiltasten, geladene Suche, neu eingelesene
      // Lieder).
      fWerteModus: TSongFilter;
      fWerteAnzahl: integer;

      function  BlaetternMoeglich: boolean;
      procedure WerteSammeln;
      procedure WerteVerwerfen;
      procedure WertWaehlen(Schritt: integer);

      procedure SetTextFound(Count: Cardinal);

      //Visible //Whether the Menu should be Drawn
      //Whether the Menu should be Drawn
      procedure SetVisible(Value: boolean);
    public
      constructor Create; override;
      destructor Destroy; override;

      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
      function Draw: boolean; override;

      // Der gerade aktive Suchzustand - fuer das Speichern und Laden von
      // Suchen. Der Begriff steht im Textfeld des Knopfes, der Modus im
      // Auswahlfeld; beides zusammen ist die Suche.
      function GetSearchText: UTF8String;
      function GetSearchFilter: TSongFilter;

      // Setzt beides und fuehrt die Suche aus. Wird vom Ladefenster benutzt.
      procedure ApplySearch(const AText: UTF8String; AFilter: TSongFilter);

      property Visible: boolean read fVisible write SetVisible;
  end;

const
  ID='ID_016';   //for help system

implementation

uses
  UGraphic,
  UHelp,
  UIni,
  ULanguage,
  ULog,
  UMain,
  UParty,
  URenderer,
  UScreenSong,
  UUnicodeUtils;

function TScreenSongJumpto.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
begin
  Result := true;
  if (PressedDown) then
  begin // Key Down
    // check normal keys
    if (IsAlphaNumericChar(CharCode) or
        IsPunctuationChar(CharCode)) then
    begin
      if (Interaction = 0) then
      begin
        Button[0].Text[0].ColR := Theme.SongJumpto.ButtonSearchText.ColR;
        Button[0].Text[0].ColG := Theme.SongJumpto.ButtonSearchText.ColG;
        Button[0].Text[0].ColB := Theme.SongJumpto.ButtonSearchText.ColB;

        Button[0].Text[0].Text := Button[0].Text[0].Text + UCS4ToUTF8String(CharCode);
        SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
        ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
      end;
    end;

    // check special keys
    case PressedKey of
      SDLK_BACKSPACE:
        begin
          if (Interaction = 0) and (Length(Button[0].Text[0].Text) > 0) then
          begin
            Button[0].Text[0].DeleteLastLetter();
            SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
        end;

      SDLK_TAB:
        begin
          ScreenPopupHelp.ShowPopup();
        end;

      SDLK_RETURN,
      SDLK_ESCAPE:
        begin
          Visible := false;
          AudioPlayback.PlaySound(SoundLib.Back);
          if (fVisSongs = 0) and (Length(Button[0].Text[0].Text) > 0) then
          begin
            //ScreenSong.UnLoadDetailedCover;
            Button[0].Text[0].Text := '';
            CatSongs.SetFilter('', fltAll);
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
            SetTextFound(0);
          end;
        end;

      SDLK_DOWN:
        begin
          if BlaetternMoeglich then
            WertWaehlen(1);
        end;

      SDLK_UP:
        begin
          if BlaetternMoeglich then
            WertWaehlen(-1);
        end;

      SDLK_RIGHT:
        begin
          Interaction := 1;
          InteractInc;
          WerteVerwerfen;
          if (Length(Button[0].Text[0].Text) > 0) then
          begin
            SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
          Interaction := 0;
        end;
      SDLK_LEFT:
        begin
          Interaction := 1;
          InteractDec;
          WerteVerwerfen;
          if (Length(Button[0].Text[0].Text) > 0) then
          begin
            SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
          Interaction := 0;
        end;
    end;
  end;
end;

constructor TScreenSongJumpto.Create;
var
  ButtonID: integer;
begin
  inherited Create;

  AddText(Theme.SongJumpto.TextFound);

  LoadFromTheme(Theme.SongJumpto);

  ButtonID := AddButton(Theme.SongJumpto.ButtonSearchText);

  if (Length(Button[0].Text) = 0) then
    AddButtonText(14, 20, '');

  Button[ButtonID].Text[0].Writable := true;

  fSelectType := fltAll;
  AddSelectSlide(Theme.SongJumpto.SelectSlideType, PInteger(@fSelectType)^, Theme.SongJumpto.IType);

  Interaction := 0;
  fLastPlayed  := 0;
end;

procedure TScreenSongJumpto.SetVisible(Value: boolean);
begin
//If change from invisible to Visible then OnShow
  if (fVisible = false) and (Value = true) then
    OnShow;

  SetTextInput(Value);
  fVisible := Value;
end;

procedure TScreenSongJumpto.OnShow;
begin
  inherited;

  if not Help.SetHelpID(ID) then
    Log.LogWarn('No Entry for Help-ID ' + ID, 'ScreenSongJumpTo');

  //Reset Screen if no Old Search is Displayed
  if (CatSongs.CatNumShow <> -2) then
  begin
    SelectsS[0].SetSelectOpt(0);

    Button[0].Text[0].Text := '';
    Text[0].Text := Theme.SongJumpto.NoSongsFound;
  end;

  //Select Input
  Interaction := 0;
  Button[0].Text[0].Selected := true;

  fLastPlayed := ScreenSong.Interaction;
end;

function TScreenSongJumpto.Draw: boolean;
begin
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  Result := inherited Draw;
end;

procedure TScreenSongJumpto.SetTextFound(Count: cardinal);
begin
  if (Count = 0) then
  begin
    Text[0].Text := Theme.SongJumpto.NoSongsFound;
    if (Length(Button[0].Text[0].Text) = 0) then
      ScreenSong.HideCatTL
    else
      ScreenSong.ShowCatTLCustom(Format(Theme.SongJumpto.CatText, [Button[0].Text[0].Text]));
  end
  else
  begin
    Text[0].Text := Format(Theme.SongJumpto.SongsFound, [Count]);

    //Set CatTopLeftText
    ScreenSong.ShowCatTLCustom(Format(Theme.SongJumpto.CatText, [Button[0].Text[0].Text]));
  end;

  //Set visSongs
  fVisSongs := Count;

  //Fix SongSelection
  if (TSongMenuMode(Ini.SongMenu) = smRoulette) then
  begin
    ScreenSong.Interaction := high(CatSongs.Song);
  end;

  if (TSongMenuMode(Ini.SongMenu) in [smChessboard, smList]) then
  begin
    ScreenSong.Interaction := 0;
    ScreenSong.ChessboardMinLine := 0;
    ScreenSong.ListMinLine := 0;
  end;

  ScreenSong.SelectNext;
  ScreenSong.FixSelected;

  ScreenSong.SetScrollRefresh;

  //Play Correct Music
  if (ScreenSong.Interaction <> fLastPlayed) or (CatSongs.VisibleSongs = 0) then
  begin
    if (CatSongs.VisibleSongs > 0) then
      fLastPlayed := ScreenSong.Interaction
    else
      fLastPlayed := -1;

    ScreenSong.ChangeMusic;
  end;
end;


function TScreenSongJumpto.GetSearchText: UTF8String;
begin
  Result := Button[0].Text[0].Text;
end;

function TScreenSongJumpto.GetSearchFilter: TSongFilter;
begin
  Result := fSelectType;
end;

procedure TScreenSongJumpto.ApplySearch(const AText: UTF8String; AFilter: TSongFilter);
begin
  fSelectType := AFilter;
  // Der Blaetterzeiger gehoert zum alten Modus und passt jetzt nicht mehr.
  fWertIndex := -1;
  // Das Auswahlfeld zeigt den Modus an; ohne diesen Schritt stuenden
  // Anzeige und tatsaechlicher Modus auseinander.
  SelectsS[0].SetSelectOpt(Ord(AFilter));

  Button[0].Text[0].Text := AText;
  SetTextFound(CatSongs.SetFilter(AText, fSelectType));
  ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
end;


(*
 * Durchblaettern der vorhandenen Werte mit Hoch/Runter.
 *
 * Sinnvoll nur bei Feldern mit einem ueberschaubaren, wiederkehrenden
 * Wertevorrat: Sprache, Genre und Schlagworte. Bei Titel oder Interpret
 * waere die Liste so lang wie die Liedersammlung selbst und damit nutzlos.
 *)
function TScreenSongJumpto.BlaetternMoeglich: boolean;
begin
  Result := fSelectType in [fltLanguage, fltGenre, fltTags];
end;

procedure TScreenSongJumpto.WerteVerwerfen;
begin
  if Assigned(fWerte) then
    fWerte.Clear;
  fWertIndex := -1;
end;

procedure TScreenSongJumpto.WerteSammeln;
var
  I: integer;
  Roh: TStringList;
begin
  if not Assigned(fWerte) then
    fWerte := TStringList.Create;

  // Passt die vorhandene Liste noch? Sie gilt nur fuer denselben Modus und
  // denselben Liederbestand.
  if (fWerte.Count > 0) and (fWerteModus = fSelectType) and
     (fWerteAnzahl = Length(CatSongs.Song)) then
    Exit;

  Roh := TStringList.Create;
  try
    for I := 0 to High(CatSongs.Song) do
    begin
      if CatSongs.Song[I].Main then
        Continue;   // Kategorieueberschrift, kein Lied
      case fSelectType of
        fltLanguage: Roh.Add(CatSongs.Song[I].Language);
        fltGenre:    Roh.Add(CatSongs.Song[I].Genre);
        fltTags:     Roh.Add(CatSongs.Song[I].Tags);
      end;
    end;
    // Zerlegen, entdoppeln und sortieren erledigt USongSearch - dort ist es
    // ohne Fenster und Ton pruefbar.
    CollectDistinctValues(Roh, fWerte);
  finally
    Roh.Free;
  end;
  fWerteModus := fSelectType;
  fWerteAnzahl := Length(CatSongs.Song);
  fWertIndex := -1;
end;

procedure TScreenSongJumpto.WertWaehlen(Schritt: integer);
begin
  WerteSammeln;
  if (fWerte.Count = 0) then
    Exit;

  // Vom noch unbenutzten Zustand aus soll Runter beim ersten und Hoch beim
  // letzten Wert beginnen - sonst uebersprAenge man einen davon.
  if (fWertIndex < 0) then
  begin
    if (Schritt > 0) then
      fWertIndex := 0
    else
      fWertIndex := fWerte.Count - 1;
  end
  else
    fWertIndex := (fWertIndex + Schritt + fWerte.Count) mod fWerte.Count;

  Button[0].Text[0].Text := fWerte[fWertIndex];
  SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
  ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
end;

destructor TScreenSongJumpto.Destroy;
begin
  fWerte.Free;
  inherited;
end;

end.
