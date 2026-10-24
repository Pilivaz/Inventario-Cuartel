import { unzipSync } from 'fflate';

export type ExistingPerson = { id: string; personnel_no: string | null; full_name: string };
export type ProfileGearRow = {
  firefighter_id: string;
  personnel_no: string;
  source_key: string;
  source_sheet: string;
  source_row: number;
  raw_data: Record<string, string>;
};
export type ProfilePreview = {
  id: string;
  personnel_no: string;
  full_name: string;
  sheet_name: string;
  rows: ProfileGearRow[];
};
export type WorkbookPreview = { profiles: ProfilePreview[]; excludedSheets: { sheet: string; name: string; reason: string }[]; rows: ProfileGearRow[] };

type XmlSheet = { name: string; path: string };
type Grid = string[][];

function xml(bytes: Uint8Array, name: string): XMLDocument {
  const source = new TextDecoder().decode(bytes);
  const doc = new DOMParser().parseFromString(source, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) throw new Error(`El archivo XLSX contiene XML inválido (${name}).`);
  return doc;
}

function elements(doc: XMLDocument, local: string): Element[] {
  return Array.from(doc.getElementsByTagNameNS('*', local));
}

function columnIndex(ref: string): number {
  const letters = ref.match(/^[A-Z]+/i)?.[0]?.toUpperCase() || 'A';
  return [...letters].reduce((n, char) => n * 26 + char.charCodeAt(0) - 64, 0) - 1;
}

function cellText(cell: Element, shared: string[]): string {
  const type = cell.getAttribute('t');
  if (type === 'inlineStr') return elements(cell as unknown as XMLDocument, 't').map(t => t.textContent || '').join('');
  const value = elements(cell as unknown as XMLDocument, 'v')[0]?.textContent ?? '';
  if (type === 's') return shared[Number(value)] ?? '';
  if (type === 'b') return value === '1' ? 'TRUE' : 'FALSE';
  return value;
}

function decodeSheet(bytes: Uint8Array, shared: string[]): Grid {
  const doc = xml(bytes, 'hoja');
  const grid: Grid = [];
  for (const row of elements(doc, 'row')) {
    const rowNo = Number(row.getAttribute('r') || grid.length + 1);
    const cells = elements(row as unknown as XMLDocument, 'c');
    const values: string[] = [];
    for (const cell of cells) values[columnIndex(cell.getAttribute('r') || 'A1')] = cellText(cell, shared);
    grid[rowNo - 1] = values.map(value => value ?? '');
  }
  return grid;
}

function workbookSheets(files: Record<string, Uint8Array>): XmlSheet[] {
  const book = files['xl/workbook.xml'];
  const relsBytes = files['xl/_rels/workbook.xml.rels'];
  if (!book || !relsBytes) throw new Error('No pude encontrar la estructura de hojas del libro.');
  const relDoc = xml(relsBytes, 'relaciones');
  const targets = new Map(elements(relDoc, 'Relationship').map(node => [node.getAttribute('Id') || '', node.getAttribute('Target') || '']));
  const bookDoc = xml(book, 'libro');
  return elements(bookDoc, 'sheet').map(node => {
    const relId = node.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id') || node.getAttribute('r:id') || '';
    let target = targets.get(relId);
    if (!target) throw new Error(`Falta la referencia de la hoja ${node.getAttribute('name') || ''}.`);
    target = target.replace(/^\//, '');
    if (!target.startsWith('xl/')) target = `xl/${target}`;
    const normalized = target.split('/').reduce<string[]>((parts, piece) => {
      if (piece === '..') parts.pop(); else if (piece !== '.' && piece) parts.push(piece);
      return parts;
    }, []).join('/');
    return { name: node.getAttribute('name') || '', path: normalized };
  });
}

function normalizeName(value: string): string {
  return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().match(/[a-z0-9]+/g)?.sort().join(' ') || '';
}

function findHeader(grid: Grid): number {
  return grid.findIndex(row => (row?.[0] || '').replace(/^\uFEFF/, '').trim().toLowerCase() === 'numero' && (row?.[1] || '').trim().toLowerCase() === 'nombre y apellido');
}

function rosterFrom(grid: Grid): Map<string, string> {
  const head = findHeader(grid);
  if (head < 0) throw new Error('No encontré las columnas Numero y Nombre y Apellido en el resumen operativo.');
  const roster = new Map<string, string>();
  for (const row of grid.slice(head + 1)) {
    const no = (row?.[0] || '').trim();
    const name = (row?.[1] || '').trim();
    if (!no || !name || name.toUpperCase().includes('REFERENCIAS')) continue;
    const canonicalNo = /^\d+(?:\.0+)?$/.test(no) ? String(Number(no)) : no;
    if (roster.has(canonicalNo)) throw new Error(`Legajo repetido en el resumen operativo: ${canonicalNo}.`);
    roster.set(canonicalNo, name);
  }
  if (roster.size !== 22) throw new Error(`El resumen operativo contiene ${roster.size} personas; se esperaban 22.`);
  return roster;
}

function recordsForSheet(grid: Grid, profile: Omit<ProfilePreview, 'rows'>): ProfileGearRow[] {
  const sectionHeaders = new Map<string, string>([['Traje de Gala', 'Traje de gala'], ['Traje de Fajina', 'Traje de fajina'], ['HANDY', 'Handy']]);
  let section = 'Equipamiento operativo';
  const baseHeaders = grid[1] || [];
  const output: ProfileGearRow[] = [];
  for (let index = 3; index < grid.length; index++) {
    const row = grid[index] || [];
    const first = (row[0] || '').trim();
    if (sectionHeaders.has(first)) { section = sectionHeaders.get(first)!; continue; }
    if (!row.some(value => String(value || '').trim())) continue;
    if (first.toLowerCase() === 'recambio por...') continue;
    const headers = section === 'Handy' ? (row[0] === 'HANDY' ? row : (grid[index - 1] || [])) : baseHeaders;
    const raw: Record<string, string> = { _section: section, _workbook_sheet: profile.sheet_name, _excel_row: String(index + 1) };
    if (!first) raw._review_reason = 'Renglón con datos sin nombre de elemento.';
    row.forEach((value, col) => {
      if (value === '' || value == null) return;
      const label = (headers[col] || `Columna ${col + 1}`).trim() || `Columna ${col + 1}`;
      const key = label in raw ? `${label}_${col + 1}` : label;
      raw[key] = value;
    });
    if (section === 'Handy' && Object.keys(raw).some(key => /^Columna \d+$/.test(key))) {
      raw._review_reason = 'La ficha no etiqueta todos los campos del Handy; los valores se conservan y requieren revisión.';
    }
    const originalFlags = [...new Set(row.map(value => String(value || '').trim()).filter(value => /^(OK|NO|PROPIA|ROJA|TRANSPARENTE)$/i.test(value)))];
    if (originalFlags.length) {
      const note = `Valores originales ${originalFlags.join(', ')} conservados literalmente; significado pendiente de revisión contextual.`;
      raw._review_reason = raw._review_reason ? `${raw._review_reason} ${note}` : note;
    }
    output.push({ firefighter_id: profile.id, personnel_no: profile.personnel_no, source_key: `profile:${profile.personnel_no}:row-${index + 1}`, source_sheet: `Ficha individual · ${section}`, source_row: index + 1, raw_data: raw });
  }
  return output;
}

export async function parseLegacyWorkbook(file: File, people: ExistingPerson[]): Promise<WorkbookPreview> {
  if (!file.name.toLowerCase().endsWith('.xlsx')) throw new Error('Seleccioná el libro original en formato .xlsx.');
  if (file.size > 10 * 1024 * 1024) throw new Error('El libro supera el límite de 10 MB.');
  const files = unzipSync(new Uint8Array(await file.arrayBuffer()));
  const sharedStrings = files['xl/sharedStrings.xml'] ? elements(xml(files['xl/sharedStrings.xml'], 'cadenas'), 'si').map(si => elements(si as unknown as XMLDocument, 't').map(t => t.textContent || '').join('')) : [];
  const sheets = workbookSheets(files);
  const grids = new Map(sheets.map(sheet => {
    const bytes = files[sheet.path];
    if (!bytes) throw new Error(`No se encontró el contenido de la hoja ${sheet.name}.`);
    return [sheet.name, decodeSheet(bytes, sharedStrings)];
  }));
  const summary = grids.get('Hoja1');
  const summaryUniforms = grids.get('Hoja2');
  if (!summary || !summaryUniforms) throw new Error('El libro debe contener las hojas Hoja1 y Hoja2.');
  const roster = rosterFrom(summary);
  const secondRoster = rosterFrom(summaryUniforms);
  if ([...roster].some(([no, name]) => secondRoster.get(no) !== name)) throw new Error('Los padrones de Hoja1 y Hoja2 no coinciden por legajo y nombre.');

  const byNo = new Map<string, ExistingPerson>();
  for (const person of people.filter(person => person.personnel_no)) {
    const no = String(person.personnel_no).trim();
    if (byNo.has(no)) throw new Error(`El legajo ${no} aparece más de una vez en el padrón actual.`);
    byNo.set(no, person);
  }
  for (const [no, name] of roster) {
    const current = byNo.get(no);
    if (!current || normalizeName(current.full_name) !== normalizeName(name)) throw new Error(`El legajo ${no} (${name}) no coincide con el padrón actual de la aplicación.`);
  }
  const matched = new Map<string, { sheet: XmlSheet; name: string; person: ExistingPerson }>();
  const excludedSheets: WorkbookPreview['excludedSheets'] = [];
  const retired = new Map([
    'Evelyn Servin', 'Pamela Gomez', 'Carlos Cordera', 'Cesar Aguilera', 'Lucas Seimandi',
  ].map(name => [normalizeName(name), name]));
  const unmatched: { sheet: string; name: string }[] = [];
  const rosterEntries = [...roster];
  for (const sheet of sheets.filter(item => item.name !== 'Hoja1' && item.name !== 'Hoja2')) {
    const grid = grids.get(sheet.name)!;
    const name = (grid[0]?.[0] || '').trim();
    const candidates = rosterEntries.filter(([, rosterName]) => normalizeName(rosterName) === normalizeName(name));
    if (candidates.length > 1) throw new Error(`El nombre de la ficha “${name}” coincide con más de un legajo; requiere revisión manual.`);
    const rosterMatch = candidates[0];
    if (!rosterMatch) { unmatched.push({ sheet: sheet.name, name }); continue; }
    const [no] = rosterMatch;
    if (matched.has(no)) throw new Error(`Hay más de una ficha individual para el legajo ${no} (${name}).`);
    matched.set(no, { sheet, name, person: byNo.get(no)! });
  }
  if (matched.size !== 22) throw new Error(`Pude vincular ${matched.size} fichas con el padrón. Se requieren 22; revisá nombres y legajos antes de importar.`);
  const excludedByName = new Map(unmatched.map(entry => [normalizeName(entry.name), entry]));
  const unexpected = unmatched.filter(entry => !retired.has(normalizeName(entry.name)));
  const missingRetirees = [...retired].filter(([normalized]) => !excludedByName.has(normalized)).map(([, name]) => name);
  if (unexpected.length || missingRetirees.length || unmatched.length !== retired.size) {
    const details = [
      unexpected.length ? `fichas no reconocidas: ${unexpected.map(entry => `${entry.name || '(sin nombre)'} [${entry.sheet}]`).join(', ')}` : '',
      missingRetirees.length ? `no se encontraron las fichas jubiladas esperadas: ${missingRetirees.join(', ')}` : '',
    ].filter(Boolean).join('; ');
    throw new Error(`La lista de fichas excluidas no coincide con las cinco jubiladas indicadas. ${details}`);
  }
  for (const entry of unmatched) excludedSheets.push({ ...entry, reason: 'Persona jubilada; excluida por indicación del cuartel.' });
  const profiles = [...roster].map(([no, name]) => {
    const match = matched.get(no)!;
    const profile = { id: match.person.id, personnel_no: no, full_name: name, sheet_name: match.sheet.name };
    return { ...profile, rows: recordsForSheet(grids.get(match.sheet.name)!, profile) };
  });
  const rows = profiles.flatMap(profile => profile.rows);
  const keys = new Set(rows.map(row => row.source_key));
  if (keys.size !== rows.length) throw new Error('El libro produce claves repetidas para las filas de origen; no se puede importar de forma segura.');
  return { profiles, excludedSheets, rows };
}
