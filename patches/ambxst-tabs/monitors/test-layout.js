// Check de la geometria del mapa: saca las funciones del QML y las corre con dos
// monitores falsos. Verifica logicalSize con rotacion/escala y el pegado de bordes.
const fs = require('fs');
const qml = fs.readFileSync(__dirname + '/MonitorsTab.qml', 'utf8');
const a = qml.indexOf('    function logicalSize(');
const b = qml.indexOf('    // ponytail: una sola funcion arma la linea');
if (a < 0 || b < 0 || b < a) { console.log('FALLA: no encontre las funciones en el QML'); process.exit(1); }
const src = qml.slice(a, b);

function env(st) {
    let { dMode, dScale, dTransform, dX, dY, dEnabled, monitors, sel } = st;
    eval(src);
    return { logicalSize, rects, snapPos };
}

let fails = 0;
const eq = (got, want, what) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g !== w) { console.log(`FALLA ${what}: ${g} != ${w}`); fails++; }
};

// laptop 1920x1080 @1.5 => 1280x720 logico
const laptop = { name: 'eDP-1', width: 1920, height: 1080, scale: 1.5, transform: 0, x: 0, y: 0 };
// AOC 1360x768 @1 vertical => 768x1360 logico
const aoc = { name: 'HDMI-A-1', width: 1360, height: 768, scale: 1, transform: 1, x: 5000, y: 5000 };

let e = env({ dMode: '1360x768@60.02', dScale: 1, dTransform: 1, dX: 5000, dY: 5000, dEnabled: true, monitors: [laptop, aoc], sel: 1 });
eq(e.logicalSize(laptop, false), { w: 1280, h: 720 }, 'laptop logico');
eq(e.logicalSize(aoc, true), { w: 768, h: 1360 }, 'aoc vertical logico');

// arrastrado cerca del borde derecho del laptop -> se pega exacto a 1280
eq(e.snapPos(1302, 14, 768, 1360), { x: 1280, y: 0 }, 'pega a la derecha');
// cerca del izquierdo -> queda en -768 (el ancho logico rotado), que es lo que uno escribe mal a mano
eq(e.snapPos(-740, -12, 768, 1360), { x: -768, y: 0 }, 'pega a la izquierda');
// lejos de todo -> no toca nada, solo redondea
eq(e.snapPos(2500.4, 900.6, 768, 1360), { x: 2500, y: 901 }, 'lejos no pega');

// las guias que dibuja el mapa salen del mismo snap: al pegarse a la derecha del
// laptop hay guia vertical en 1280, y lejos de todo no hay ninguna.
e.snapPos(1302, 14, 768, 1360);
eq(global.guideX, [1280], 'guia vertical al pegarse');
e.snapPos(2500.4, 900.6, 768, 1360);
eq(global.guideX, [], 'sin guia lejos de todo');

// con el monitor apagado no debe aparecer en el mapa
e = env({ dMode: 'preferred', dScale: 1, dTransform: 0, dX: 0, dY: 0, dEnabled: false, monitors: [laptop, aoc], sel: 1 });
eq(e.rects().map(r => r.name), ['eDP-1'], 'apagado fuera del mapa');

console.log(fails ? `${fails} fallas` : 'ok');
process.exit(fails ? 1 : 0);
