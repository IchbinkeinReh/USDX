unit USongFilter;

(*
 * Der Suchmodus der Liedersuche - als eigene Unit.
 *
 * Herausgeloest aus USongs, damit Einheiten, die nur den Modus brauchen
 * (etwa die gespeicherten Suchen), nicht die gesamte Liederverwaltung
 * mitziehen. USongs zieht ueber UImage die SDL-Bindungen nach; ohne diese
 * Trennung liesse sich nichts davon ohne Fenster und Ton pruefen.
 *
 * USongs reicht Typ und Werte unveraendert weiter, bestehender Code
 * braucht also nichts zu aendern.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

type
  TSongFilter = (
    fltAll,
    fltTitle,
    fltArtist,
    fltLanguage,
    fltEdition,
    fltGenre,
    fltYear,
    fltCreator,
    fltTags
  );

implementation

end.
