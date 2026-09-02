program testsearchstore;
(*
 * Prueft USearchStore direkt - dieselbe Unit, die das Spiel benutzt.
 *)
{$MODE Delphi}

uses
  SysUtils,
  Classes,
  USongFilter,
  USearchStore;

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

var
  Store, Store2: TSearchStore;
  Lines: TStringList;
  F, Zurueck: TSongFilter;
  Namen: TStringList;
  Alle: boolean;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;
  Store := TSearchStore.Create;
  Lines := TStringList.Create;

  WriteLn('Aufnehmen');
  Check('leer beim Start', Store.Count = 0);
  Check('Suche wird aufgenommen', Store.Add('abba OR queen', fltTitle));
  Check('jetzt eine drin', Store.Count = 1);
  Check('Begriff gemerkt', Store[0].Text = 'abba OR queen', Store[0].Text);
  Check('Modus gemerkt', Store[0].Filter = fltTitle);

  Check('gleiche Suche wird nicht doppelt abgelegt',
        not Store.Add('abba OR queen', fltTitle) and (Store.Count = 1));
  Check('gleicher Begriff, anderer Modus ist eine andere Suche',
        Store.Add('abba OR queen', fltArtist) and (Store.Count = 2));
  Check('Randleerzeichen werden abgeschnitten',
        not Store.Add('  abba OR queen  ', fltTitle) and (Store.Count = 2));
  Check('leere Suche wird abgelehnt',
        not Store.Add('   ', fltAll) and (Store.Count = 2));

  WriteLn('Anzeigetext');
  Check('nennt Modus und Begriff',
        Store.Caption(0) = 'Titel: abba OR queen', Store.Caption(0));
  Check('ausserhalb des Bereichs ergibt leer', Store.Caption(99) = '');

  WriteLn('Loeschen');
  Store.Delete(0);
  Check('Eintrag ist weg', Store.Count = 1);
  Check('der richtige blieb stehen', Store[0].Filter = fltArtist);
  Store.Delete(-1);
  Store.Delete(5);
  Check('ungueltiger Index tut nichts', Store.Count = 1);

  WriteLn('Speichern und Laden');
  Store.Clear;
  Store.Add('abba', fltTitle);
  Store.Add('1990-1999', fltYear);
  Store.Add('queen !live', fltAll);
  Store.SaveToStrings(Lines);

  Store2 := TSearchStore.Create;
  Store2.LoadFromStrings(Lines);
  Check('alle drei wieder da', Store2.Count = 3, IntToStr(Store2.Count));
  Check('Reihenfolge bleibt', (Store2[0].Text = 'abba') and
        (Store2[1].Text = '1990-1999') and (Store2[2].Text = 'queen !live'));
  Check('Modi bleiben', (Store2[0].Filter = fltTitle) and
        (Store2[1].Filter = fltYear) and (Store2[2].Filter = fltAll));

  WriteLn('Robustheit beim Laden');
  Lines.Clear;
  Lines.Add('# Kommentar');
  Lines.Add('');
  Lines.Add('kaputt ohne Tabulator');
  Lines.Add('unbekannterModus' + #9 + 'abba');
  Lines.Add('title' + #9 + 'gut');
  Store2.LoadFromStrings(Lines);
  Check('nur die gueltige Zeile bleibt', Store2.Count = 1, IntToStr(Store2.Count));
  Check('und zwar die richtige',
        (Store2[0].Text = 'gut') and (Store2[0].Filter = fltTitle));

  // Ein unbekannter Modus darf NICHT auf "Alle" zurueckfallen: Die Suche
  // liefe sonst still im falschen Modus und zeigte falsche Treffer.
  Check('unbekannter Modus wird nicht zu "Alle"',
        not ((Store2.Count > 0) and (Store2[0].Text = 'abba')));

  WriteLn('Suchbegriffe mit Sonderzeichen');
  Store2.Clear;
  Store2.Add('AC/DC: Back in Black', fltArtist);
  Store2.Add('(abba OR queen) AND !live', fltAll);
  Lines.Clear;
  Store2.SaveToStrings(Lines);
  Store.Clear;
  Store.LoadFromStrings(Lines);
  Check('Doppelpunkt und Schraegstrich ueberleben',
        (Store.Count = 2) and (Store[0].Text = 'AC/DC: Back in Black'),
        Store[0].Text);
  Check('Klammern und Ausrufezeichen ueberleben',
        Store[1].Text = '(abba OR queen) AND !live', Store[1].Text);

  WriteLn('Modusnamen');
  // Jeder Modus braucht einen eindeutigen Namen, sonst laedt eine
  // gespeicherte Suche spaeter im falschen Modus.
  Namen := TStringList.Create;
  Namen.Sorted := true;
  Namen.Duplicates := dupIgnore;
  Alle := true;
  for F := Low(TSongFilter) to High(TSongFilter) do
  begin
    Namen.Add(FilterToName(F));
    if (FilterToName(F) = '') or (FilterCaption(F) = '') then
      Alle := false;
  end;
  Check('jeder Modus hat einen Namen und eine Beschriftung', Alle);
  Check('alle Namen sind verschieden',
        Namen.Count = Ord(High(TSongFilter)) - Ord(Low(TSongFilter)) + 1,
        IntToStr(Namen.Count));
  Alle := true;
  for F := Low(TSongFilter) to High(TSongFilter) do
    if not NameToFilter(FilterToName(F), Zurueck) or (Zurueck <> F) then
      Alle := false;
  Check('Name laesst sich zurueckuebersetzen', Alle);
  Check('unbekannter Name wird abgelehnt', not NameToFilter('quatsch', Zurueck));
  Check('Grossschreibung egal',
        NameToFilter('TITLE', Zurueck) and (Zurueck = fltTitle));
  Namen.Free;

  Store.Free;
  Store2.Free;
  Lines.Free;

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
