// Extracts the Spool module from design/design_v3.html and writes golden reference output.
// Run: node Scripts/spool_golden.mjs   (writes Fixtures/spool/*.json; --design-copy opts into copy fixtures)
import fs from 'node:fs';
import crypto from 'node:crypto';
const full = process.argv.includes('--full');
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const html = fs.readFileSync('design/design_v3.html', 'utf8');
const lines = html.split('\n');
const start = lines.findIndex(l => l.startsWith('const Spool=(()=>{'));
const end = lines.findIndex((l, i) => i > start && l.startsWith('})();'));
if (start < 0 || end < 0) throw new Error('Spool module not found');
let src = lines.slice(start, end + 1).join('\n');
// expose internals that the public API hides, without changing any maths
src = src.replace('return{scene,cameo,live,flight};', 'return{scene,cameo,live,flight,art,rig,poses,tapeRibbon,TAPE,character,shade};');
const Spool = new Function(src + '\nreturn Spool;')();
const errLine = lines.find(l => l.startsWith('const ERROR_POSES='));
const ERROR_POSES = new Function(errLine.replace('const ERROR_POSES=', 'return ') )();

const keys = Object.keys(Spool.poses);
const times = [0, 0.1, 0.25, 0.45, 0.55, 0.8, 1.05, 1.4, 1.9, 4.35, 4.4];
const motionAt = (key,t) => ({level:Spool.live.has(key)?1:key==='finishing'?1-Math.max(0,Math.min(1,t/.55))**2*(3-2*Math.max(0,Math.min(1,t/.55))):0, lean:.8, lift:-.3, mouthOpen:.35, mouthSmile:.25,gaze:-1.5,phase:t});
const scenes = [];
for (const key of keys) for (const t of times) for (const angle of [0, -123.4])
  scenes.push({ key, t, width: 560, still: false, angle, motion:motionAt(key,t), svg: Spool.scene(key, t, 'g', 560, false, angle, motionAt(key,t)) });
for (const key of keys) {
  scenes.push({ key, t: 1.4, width: 380, still: false, angle: 0, motion:motionAt(key,1.4), svg: Spool.scene(key, 1.4, 'g', 380, false, 0, motionAt(key,1.4)) });
  scenes.push({ key, t: 0, width: 560, still: true, angle: 0, svg: Spool.scene(key, 0, 'g', 560, true, 0) });
}
const cameos = keys.map(key => ({ key, svg: Spool.cameo(key, 'g') }));
const flightLines = [{x:140,y:420,width:310},{x:140,y:446,width:240},{x:140,y:472,width:110}];
const flights = [0.05, 0.3, 0.65, 0.72, 0.9, 1.0, 1.2, 1.29].map(t => ({ t, from: [480, 111], lines:flightLines, w: 900, h: 600,
  svg: Spool.flight(t, [480, 111], flightLines, 900, 600) }));

const spec = {
  source: 'design/design_v3.html (Spool module, lines ' + (start + 1) + '–' + (end + 1) + ')',
  character: Spool.character,
  tape: Spool.TAPE,
  housingShades: { gradientTop: Spool.shade(Spool.character.color, .38), gradientMid: Spool.character.color,
    gradientBottom: Spool.shade(Spool.character.color, -.2), dark: Spool.shade(Spool.character.color, -.25),
    light: Spool.shade(Spool.character.color, .5), ink: '#34372f', cream: '#fff0d2' },
  statePoses: Spool.poses,
  liveStates: [...Spool.live],
  stillTimes: { default: 1.4, finishing: .55, inserting: .4, cancelled: .8 },
  sceneGeometry: { viewBoxHeight: 160, wide: { scale: .8, cxFromRight: 72, cy: 76 }, narrow: { below: 400, scale: .65, cxFromRight: 61, cy: 76 },
    tapeStart: [20, 98], tapeSamples: 97, tapeWidth: 6.4, cameoViewBox: [-76, -72, 152, 132] },
  reelAngleRules: {
    note: 'Angle is external state, accumulated per frame by the host loop (drawWave), never reset between states.',
    live: 'angle -= 150 * energy * dt (states in liveStates)',
    finishing: 'angle -= 150 * motion.level * dt while motion.level > .02',
    inserting: 'angle += 390 * min(1,t/.12) * dt while t < 1.2',
    otherwise: 'angle unchanged',
    dtClamp: 0.05, reducedMotion: 'no accumulation; still frames only'
  },
  timeRemap: { finishing: 'min(t * 1.5 / 0.55, 1.5)', inserting: 'min(t, 1.2)', editing: '1.5 (fixed)', other: 't' },
  loopStops: 'animate while state is live, editing or notes, inserting before 1.3 s, or within 1.1 s of a state change; stop when hidden or reduced',
  errorPoses: ERROR_POSES,
  menuGlyph: { viewBox: [0, 0, 32, 24], rect: { x: 1, y: 2, w: 30, h: 21, rx: 4, stroke: 1.5 }, eyes: [{ cx: 10, cy: 10, r: 4 }, { cx: 22, cy: 10, r: 4 }], mouth: 'M11 17q5 4 10 0', template: true },
  numberFormat: 'JS Number(x.toFixed(2)) then String(): at most 2 decimals, trailing zeros and "-0" removed'
};
fs.writeFileSync('Fixtures/spool/spool_spec.json', JSON.stringify(spec, null, 2));
// Representative full frames: one per state at t = 1.4 (0.45 for inserting, 0.25 for finishing), wide, angle 0.
const repT = k => k === 'inserting' ? 0.45 : k === 'finishing' ? 0.25 : 1.4;
const withHash = x => ({ ...x, sha256: sha(x.svg), svg: undefined });
const representative = scenes.filter(x => !x.still && x.width === 560 && x.angle === 0 && x.t === repT(x.key));
const golden = {
  representative,
  hashes: scenes.map(withHash),
  cameos: cameos.map(withHash),
  flights: flights.map(withHash),
  flightSample: flights.find(x => x.t === 0.65)
};
fs.writeFileSync('Fixtures/spool/spool_golden.json', JSON.stringify(golden));
if (full) fs.writeFileSync('Fixtures/spool/spool_full.local.json', JSON.stringify({ scenes, cameos, flights }));
console.log('keys', keys.length, 'frames', scenes.length, 'representative', representative.length, full ? '(+ full local dump)' : '');

// Spool parity regeneration must not rewrite unrelated product-copy fixtures.
if (!process.argv.includes('--design-copy')) process.exit(0);

// ---- Design copy: exact strings from the verified prototype ----
const grab = prefix => { const l = lines.find(x => x.startsWith(prefix)); if (!l) throw new Error('missing ' + prefix);
  return new Function(l.replace(/^const [A-Za-z]+=/, 'return ').replace(/;\s*$/, ''))(); };
const ERRORS = grab('const ERRORS=');
const states = grab('const states=');
const emptyLine = lines.find(x => x.startsWith('const emptyCopy='));
const emptyCopy = new Function('return ' + emptyLine.slice('const emptyCopy='.length, emptyLine.indexOf(';const ') > 0 ? emptyLine.indexOf(';const ') : undefined).replace(/;\s*$/, ''))();
const seLine = lines.find(x => x.startsWith('const screenError='));
const screenError = new Function('return ' + seLine.slice('const screenError='.length).replace(/;.*$/, ''))();
const pill = {};
for (const l of lines) {
  const m = l.match(/^case'([a-z]+)':(?:n\.classList\.add\('([a-z]+)'\);)?out=(.*)$/);
  if (!m) continue;
  const [, key, cls, body] = m;
  if (!body.startsWith('pillHtml(') && !body.startsWith("'")) continue;
  if (body.startsWith("'")) { pill[key] = { text: body.match(/^'([^']*)'/)?.[1] ?? '', layout: cls ?? null }; continue; }
  const strs = [...body.matchAll(/'((?:[^'\\]|\\.)*)'/g)].map(x => x[1]);
  const buttons = [...body.matchAll(/pb\('([^']*)','([^']*)'(,true)?\)/g)].map(x => ({ label: x[1], action: x[2], primary: !!x[3] }));
  const tone = strs[strs.length - 1] === 'warn' ? 'warn' : null;
  pill[key] = { status: strs[0], strings: strs.filter(s => s !== 'warn' && !buttons.some(b => b.label === s || b.action === s)), buttons, notice: cls === 'notice', tone };
}
const screens = {};
for (const l of lines) { const m = l.match(/^case'([a-z]+)':out=title\('([^']*)','([^']*)'/); if (m) screens[m[1]] = { title: m[2], subtitle: m[3] }; }
fs.mkdirSync('Fixtures/design', { recursive: true });
fs.writeFileSync('Fixtures/design/design_copy.json', JSON.stringify({ source: 'design/design_v3.html', pill, screens, emptyCopy, screenError, states, errors: ERRORS.map(e => ({ id: e[0], family: e[1], trigger: e[2], headline: e[3], consequence: e[4], action: e[5], data: e[6], evidence: e[7] })) }, null, 2));
console.log('copy: pill', Object.keys(pill).length, 'screens', Object.keys(screens).length, 'empty', Object.keys(emptyCopy).length, 'errors', ERRORS.length, 'states', states.length);
