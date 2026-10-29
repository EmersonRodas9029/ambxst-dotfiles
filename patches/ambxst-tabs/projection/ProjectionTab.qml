pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.modules.theme
import qs.modules.components
import qs.config

// Proyeccion estilo Windows+P: Duplicar / Extender / Solo externa / Solo portatil.
// Mismo patron que MonitorsTab (hyprctl -> aplicar en vivo con revert de 12s -> guardar
// en ~/.config/hypr/monitors.conf). Solo soporta el caso de exactamente 2 monitores.
Rectangle {
    id: root
    color: "transparent"
    implicitWidth: 400
    implicitHeight: 300

    property var monitors: []
    property var laptop: null
    property var external: null

    property var pendingRules: []   // [reglaLaptop, reglaExterna] del ultimo modo aplicado
    property string lastMode: ""
    property int revertIn: 0        // > 0 => countdown de seguridad corriendo
    property string status: ""

    // Reglas guardadas en monitors.conf, por nombre: {"eDP-1": {mode,x,y,scale,transform}, ...}
    // Es la fuente de verdad real de "el acomodo que ya tengo configurado" (lo que
    // guarda el tab Monitores). Una foto en vivo de hyprctl no sirve: Hyprland puede
    // reacomodar un monitor solo durante disable/mirror, asi que "Extender" tiene que
    // volver siempre a lo guardado en el archivo, no a lo ultimo que vio en vivo.
    // Se guarda la regla COMPLETA, no solo x/y: si solo restaurabamos posicion, el
    // modo/escala se seguian tomando del objeto en vivo, que Duplicar puede haber
    // dejado con la resolucion/escala compartida del mirror.
    property var savedPositions: ({})

    // Parsea lineas "monitor = NAME,MODE,XxY,escala,transform,T" (el formato que
    // escriben tanto MonitorsTab como el save() de abajo). Las lineas "NAME,disable"
    // no matchean y se ignoran, que es justo lo que queremos para "Extender".
    function parseSavedPositions(confText) {
        const positions = {};
        const lines = confText.split("\n");
        const re = /^\s*monitor\s*=\s*([^,]+),([^,]+),(-?\d+)x(-?\d+),([^,]+),transform,(\d+)/;
        for (const line of lines) {
            const m = line.match(re);
            if (m)
                positions[m[1]] = { mode: m[2], x: parseInt(m[3]), y: parseInt(m[4]), scale: parseFloat(m[5]), transform: parseInt(m[6]) };
        }
        return positions;
    }

    // Un color de acento distinto por modo, igual que MetricsTab distingue
    // CPU/RAM/GPU/Disco: rompe la monotonia gris y ayuda a reconocer cada boton.
    readonly property var modes: [
        { id: "duplicate", label: "Duplicar", accent: Colors.cyan },
        { id: "extend", label: "Extender", accent: Colors.green },
        { id: "external-only", label: "Solo externa", accent: Colors.blue },
        { id: "laptop-only", label: "Solo portatil", accent: Colors.magenta }
    ]

    function reload() {
        monitorsProc.running = true;
        monitorsConfProc.running = true;
    }

    // Lee el modo real desde hyprctl (disabled/mirrorOf) en vez de confiar solo en
    // el ultimo click: asi el boton activo es correcto aunque se reabra el tab,
    // se reinicie ambxst, o el usuario cambie el layout por fuera de este panel.
    function detectMode(a, b) {
        if (!a || !b)
            return "";
        const aOff = !!a.disabled, bOff = !!b.disabled;
        if (aOff && bOff)
            return "";
        if (aOff)
            return "external-only";
        if (bOff)
            return "laptop-only";
        const mirrored = (a.mirrorOf && a.mirrorOf !== "none") || (b.mirrorOf && b.mirrorOf !== "none");
        return mirrored ? "duplicate" : "extend";
    }

    // Ancho logico de un monitor (pixeles / escala; 90/270 intercambia ancho y alto).
    function logicalWidth(m) {
        const tr = m.transform || 0;
        const w = m.width || 0, h = m.height || 0;
        const sc = m.scale || 1;
        const lw = (tr === 1 || tr === 3) ? h : w;
        return Math.round(lw / sc);
    }

    // ponytail: una sola funcion arma la linea, igual que MonitorsTab.ruleFor.
    function baseRule(m, opts) {
        if (opts.enabled === false)
            return `${m.name},disable`;
        const mode = opts.mode !== undefined ? opts.mode : `${m.width}x${m.height}@${(m.refreshRate || 60).toFixed(2)}`;
        const scale = opts.scale !== undefined ? opts.scale : (m.scale || 1);
        const x = opts.x !== undefined ? opts.x : (m.x || 0);
        const y = opts.y !== undefined ? opts.y : (m.y || 0);
        const transform = opts.transform !== undefined ? opts.transform : (m.transform || 0);
        let rule = `${m.name},${mode},${x}x${y},${scale.toFixed(2)},transform,${transform}`;
        if (opts.mirror)
            rule += `,mirror,${opts.mirror}`;
        return rule;
    }

    // Hyprland soporta mirror nativo (monitor=name,modo,pos,escala,mirror,otronombre):
    // probado a mano con hyprctl, el que no lleva "mirror" manda su propia resolucion/escala.
    function computeRules(modeId) {
        const a = root.laptop, b = root.external;
        if (!a || !b)
            return null;
        switch (modeId) {
        case "duplicate": {
            // el de menor resolucion nativa manda (el otro se mirrorea sobre el)
            const ref = (a.width * a.height <= b.width * b.height) ? a : b;
            const other = ref === a ? b : a;
            return [baseRule(ref, { x: 0, y: 0 }), baseRule(other, { x: 0, y: 0, mirror: ref.name })];
        }
        case "extend": {
            // Regla completa guardada (modo+escala+transform+posicion), no solo x/y:
            // si solo restauraramos posicion, el modo/escala quedarian tomados del
            // objeto en vivo, que Duplicar puede haber dejado con la resolucion
            // compartida del mirror.
            const ap = root.savedPositions[a.name], bp = root.savedPositions[b.name];
            if (ap && bp)
                return [baseRule(a, ap), baseRule(b, bp)];
            return [baseRule(a, { x: 0, y: 0 }), baseRule(b, { x: root.logicalWidth(a), y: 0 })];
        }
        case "external-only":
            return [baseRule(a, { enabled: false }), baseRule(b, { x: 0, y: 0 })];
        case "laptop-only":
            return [baseRule(b, { enabled: false }), baseRule(a, { x: 0, y: 0 })];
        default:
            return null;
        }
    }

    // La lectura de monitors.conf (monitorsConfProc) es async: si el usuario clickea
    // modos rapido, "Extender" podia dispararse antes de que esa lectura terminara,
    // con savedPositions todavia vacio -> caia al layout fijo (portatil-izq/externo-der).
    // apply("extend") ahora siempre relee el archivo primero y aplica cuando termina.
    property bool pendingExtendApply: false

    function apply(modeId) {
        if (modeId === "extend") {
            pendingExtendApply = true;
            monitorsConfProc.running = true;
            return;
        }
        doApply(modeId);
    }

    function doApply(modeId) {
        const rules = computeRules(modeId);
        if (!rules)
            return;
        pendingRules = rules;
        lastMode = modeId;
        applyProc.command = ["sh", "-c", 'hyprctl keyword monitor "$1" && hyprctl keyword monitor "$2"', "_", rules[0], rules[1]];
        applyProc.running = true;
        revertIn = 12;
        status = "";
    }

    function keep() {
        revertIn = 0;
        status = "Aplicado (sin guardar)";
    }

    function revert() {
        revertIn = 0;
        pendingRules = [];
        lastMode = "";
        Quickshell.execDetached(["hyprctl", "reload"]);
        status = "Revertido";
        Qt.callLater(root.reload);
    }

    // ponytail: mismo merge atomico que MonitorsTab, pero con 2 lineas en vez de 1.
    readonly property string saveScript: `f="$HOME/.config/hypr/monitors.conf"
{ echo "# Generado por el tab Proyeccion del notch (ambxst). Se reescribe al guardar."
  echo "# Lo hace source hyprland.conf al final, asi que estas reglas ganan."
  grep -E "^monitor = " "$f" 2>/dev/null | grep -v "^monitor = $1," | grep -v "^monitor = $2,"
  echo "monitor = $3"
  echo "monitor = $4"; } > "$f.tmp" && mv "$f.tmp" "$f" && hyprctl reload`

    function save() {
        if (pendingRules.length !== 2 || !root.laptop || !root.external)
            return;
        saveProc.command = ["sh", "-c", saveScript, "_", root.laptop.name, root.external.name, pendingRules[0], pendingRules[1]];
        saveProc.running = true;
        status = "Guardado en monitors.conf";
    }

    onVisibleChanged: if (visible)
        reload()
    Component.onCompleted: reload()

    Process {
        id: saveProc
    }

    Process {
        id: monitorsConfProc
        command: ["cat", Quickshell.env("HOME") + "/.config/hypr/monitors.conf"]
        stdout: StdioCollector {
            id: monitorsConfOut
            onStreamFinished: {
                root.savedPositions = root.parseSavedPositions(monitorsConfOut.text);
                if (root.pendingExtendApply) {
                    root.pendingExtendApply = false;
                    root.doApply("extend");
                }
            }
        }
    }

    Process {
        id: monitorsProc
        command: ["hyprctl", "monitors", "all", "-j"]
        stdout: StdioCollector {
            id: monitorsOut
        }
        onExited: {
            try {
                const list = JSON.parse(monitorsOut.text);
                root.monitors = list;
                if (list.length === 2) {
                    const edp = list.find(m => /^eDP/i.test(m.name));
                    root.laptop = edp || list[0];
                    root.external = list.find(m => m !== root.laptop) || list[1];
                } else {
                    root.laptop = null;
                    root.external = null;
                }
                root.lastMode = root.detectMode(root.laptop, root.external);
            } catch (e) {
                root.status = "No pude leer hyprctl";
            }
        }
    }

    Process {
        id: applyProc
    }

    Timer {
        running: root.revertIn > 0
        interval: 1000
        repeat: true
        onTriggered: {
            root.revertIn -= 1;
            if (root.revertIn <= 0)
                root.revert();
        }
    }

    // ---- geometria para los diagramas ----
    // Alto logico (gemelo de logicalWidth): lo necesitan las miniaturas para dibujar
    // cada pantalla con su proporcion real en vez de dos cuadrados iguales.
    function logicalHeight(m) {
        const tr = m.transform || 0;
        const w = m.width || 0, h = m.height || 0;
        const sc = m.scale || 1;
        const lh = (tr === 1 || tr === 3) ? w : h;
        return Math.round(lh / sc);
    }

    // Tamaño del escritorio que deja cada modo. Es el dato que uno quiere antes de
    // clickear ("¿cuanto espacio gano extendiendo?"), y cada tarjeta lo muestra.
    function desktopSize(modeId) {
        const a = root.laptop, b = root.external;
        if (!a || !b)
            return null;
        const aw = logicalWidth(a), ah = logicalHeight(a);
        const bw = logicalWidth(b), bh = logicalHeight(b);
        switch (modeId) {
        case "duplicate": {
            const ref = (a.width * a.height <= b.width * b.height) ? a : b;
            return { w: logicalWidth(ref), h: logicalHeight(ref) };
        }
        case "extend": {
            // Si hay acomodo guardado, el escritorio es su bounding box real; si no,
            // el default de computeRules es pegarlas lado a lado.
            const ap = root.savedPositions[a.name], bp = root.savedPositions[b.name];
            if (ap && bp) {
                const x1 = Math.min(ap.x, bp.x), y1 = Math.min(ap.y, bp.y);
                const x2 = Math.max(ap.x + aw, bp.x + bw), y2 = Math.max(ap.y + ah, bp.y + bh);
                return { w: x2 - x1, h: y2 - y1 };
            }
            return { w: aw + bw, h: Math.max(ah, bh) };
        }
        case "external-only":
            return { w: bw, h: bh };
        case "laptop-only":
            return { w: aw, h: ah };
        }
        return null;
    }

    // ---- tokens tipograficos ----
    // Mismos dos roles que MonitorsTab: Roboto Condensed en micro-versalitas para
    // etiquetar, Iosevka mono para los datos. La paleta puede ser gris entera (con un
    // wallpaper B/N matugen devuelve todos los acentos en #ffffff), asi que el estado
    // activo se dice invirtiendo la tarjeta, no tiñendola.
    component Eyebrow: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-4)
        font.weight: Font.DemiBold
        font.letterSpacing: 1.4
        font.capitalization: Font.AllUppercase
        color: Colors.overSurfaceVariant
        opacity: 0.55
    }

    component Chip: Rectangle {
        id: chip
        property string label: ""
        property string icon: ""
        property bool active: false
        property int hPad: 12
        signal clicked

        implicitWidth: Math.max(30, inner.implicitWidth + hPad * 2)
        implicitHeight: 28
        radius: Styling.radius(-4)
        color: chip.active ? Colors.primary : (ma.containsMouse ? Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.12) : "transparent")
        border.width: 1
        border.color: chip.active ? Colors.primary : Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, ma.containsMouse ? 0.5 : 0.28)

        Behavior on color {
            enabled: Config.animDuration > 0
            ColorAnimation {
                duration: Config.animDuration / 3
            }
        }

        RowLayout {
            id: inner
            anchors.centerIn: parent
            spacing: 6
            Text {
                visible: chip.icon !== ""
                text: chip.icon
                font.family: Icons.font
                font.pixelSize: Styling.fontSize(-1)
                color: chip.active ? Colors.overPrimary : Colors.overBackground
            }
            Text {
                visible: chip.label !== ""
                text: chip.label
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-2)
                font.weight: Font.Medium
                color: chip.active ? Colors.overPrimary : Colors.overBackground
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    // Pantalla del diagrama: apagada = contorno hairline sin relleno, presente pero
    // sin señal. Vive aqui y no dentro de ModeDiagram porque QML no admite
    // componentes inline anidados.
    component ScreenGlyph: Rectangle {
        property bool off: false
        property color ink: Colors.overBackground
        radius: 2
        color: off ? "transparent" : ink
        border.width: off ? 1 : 0
        border.color: ink
    }

    // Signature del tab: cada modo dibuja a TUS dos pantallas con su proporcion real
    // (1920x1080 y 1366x768 no son el mismo rectangulo) en la posicion que van a
    // quedar. Antes eran dos cuadrados iguales repetidos en las cuatro tarjetas, que
    // es justo lo que hacia que se vieran todas igual.
    component ModeDiagram: Item {
        id: diagram
        property string mode: ""
        property color ink: Colors.overBackground

        implicitWidth: 76
        implicitHeight: 34

        readonly property bool dupe: mode === "duplicate"
        readonly property bool extOnly: mode === "external-only"
        readonly property bool lapOnly: mode === "laptop-only"

        // Proporciones reales (logicas), encuadradas por el caso mas ancho.
        readonly property real aw: root.laptop ? root.logicalWidth(root.laptop) : 16
        readonly property real ah: root.laptop ? root.logicalHeight(root.laptop) : 9
        readonly property real bw: root.external ? root.logicalWidth(root.external) : 16
        readonly property real bh: root.external ? root.logicalHeight(root.external) : 9
        readonly property real gap: 4
        readonly property real k: Math.min((width - gap) / Math.max(aw + bw, 1), height / Math.max(ah, bh))

        // Portatil. En Duplicar queda atras y a medio tono: el mirror lo manda la otra.
        ScreenGlyph {
            ink: diagram.ink
            off: diagram.extOnly
            width: Math.max(8, diagram.aw * diagram.k * (diagram.lapOnly ? 1.3 : 1))
            height: Math.max(6, diagram.ah * diagram.k * (diagram.lapOnly ? 1.3 : 1))
            x: diagram.dupe ? (diagram.width - width) / 2 - 5 : ((diagram.lapOnly || diagram.extOnly) ? (diagram.width - width) / 2 - diagram.width * 0.17 : 0)
            y: diagram.height - height
            opacity: diagram.extOnly ? 0.35 : (diagram.dupe ? 0.45 : 1)
        }

        // Externa.
        ScreenGlyph {
            ink: diagram.ink
            off: diagram.lapOnly
            width: Math.max(8, diagram.bw * diagram.k * (diagram.extOnly ? 1.3 : 1))
            height: Math.max(6, diagram.bh * diagram.k * (diagram.extOnly ? 1.3 : 1))
            x: diagram.dupe ? (diagram.width - width) / 2 + 5 : ((diagram.lapOnly || diagram.extOnly) ? (diagram.width - width) / 2 + diagram.width * 0.17 : diagram.width - width)
            y: diagram.height - height
            opacity: diagram.lapOnly ? 0.35 : 1
        }
    }

    // Tarjeta de modo. La activa invierte: fondo solido, tinta oscura. En escala de
    // grises es la unica señal de estado que no se confunde con un hover.
    component ModeCard: Rectangle {
        id: card
        property string label: ""
        property string modeId: ""
        property bool active: false
        signal clicked

        readonly property color ink: card.active ? Colors.overPrimary : Colors.overBackground
        readonly property var size: root.desktopSize(card.modeId)

        Layout.fillWidth: true
        Layout.fillHeight: true
        implicitHeight: 96
        radius: Styling.radius(-2)
        color: card.active ? Colors.primary : (ma.containsMouse ? Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.08) : "transparent")
        border.width: 1
        border.color: card.active ? Colors.primary : Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, ma.containsMouse ? 0.5 : 0.25)

        Behavior on color {
            enabled: Config.animDuration > 0
            ColorAnimation {
                duration: Config.animDuration / 3
            }
        }

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 8

            ModeDiagram {
                Layout.alignment: Qt.AlignHCenter
                mode: card.modeId
                ink: card.ink
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: card.label
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-1)
                font.weight: Font.DemiBold
                color: card.ink
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                visible: !!card.size
                text: card.size ? `${card.size.w}×${card.size.h}` : ""
                font.family: Config.theme.monoFont
                font.pixelSize: Styling.monoFontSize(-5)
                color: card.ink
                opacity: 0.55
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.clicked()
        }
    }

    // Lienzo del tab: el panel del dashboard es transparente, el negro lo pone cada
    // tab con su propio pane (igual que MetricsTab). Sin esto el contenido flota
    // sobre el blur gris del notch y todo el contraste se cae.
    StyledRect {
        anchors.fill: parent
        variant: "pane"
        radius: Styling.radius(4)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        // ---- cabecera ----
        // Una sola linea con las dos pantallas unidas por un hairline, en vez de dos
        // tarjetas grandes: dice lo mismo y deja el alto para los modos, que es lo
        // que uno viene a tocar.
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            ColumnLayout {
                spacing: 1
                Eyebrow {
                    text: "Proyeccion"
                }
                RowLayout {
                    spacing: 8
                    Text {
                        text: Icons.laptop
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(0)
                        color: Colors.overSurfaceVariant
                    }
                    Text {
                        text: root.laptop ? root.laptop.name : "—"
                        font.family: Config.theme.monoFont
                        font.pixelSize: Styling.monoFontSize(0)
                        font.weight: Font.Medium
                        color: Colors.overBackground
                    }
                    Rectangle {
                        Layout.preferredWidth: 22
                        implicitHeight: 1
                        color: Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.4)
                    }
                    Text {
                        text: Icons.monitor
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(0)
                        color: Colors.overSurfaceVariant
                    }
                    Text {
                        text: root.external ? root.external.name : "—"
                        font.family: Config.theme.monoFont
                        font.pixelSize: Styling.monoFontSize(0)
                        font.weight: Font.Medium
                        color: Colors.overBackground
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Chip {
                icon: Icons.sync
                hPad: 8
                onClicked: root.reload()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.monitors.length !== 2
            wrapMode: Text.WordWrap
            text: root.monitors.length < 2 ? `Solo hay ${root.monitors.length} monitor(es). El modo estandar necesita exactamente 2 (portatil + externo).` : `Hay ${root.monitors.length} monitores conectados. El modo estandar solo cubre el caso de 2 (portatil + externo).`
            font.family: Config.theme.font
            font.pixelSize: Config.theme.fontSize
            color: Colors.overSurfaceVariant
        }

        // ---- los cuatro modos ----
        GridLayout {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.monitors.length === 2
            columns: 2
            rowSpacing: 10
            columnSpacing: 10

            Repeater {
                model: root.modes
                ModeCard {
                    required property var modelData
                    label: modelData.label
                    modeId: modelData.id
                    active: root.lastMode === modelData.id
                    onClicked: root.apply(modelData.id)
                }
            }
        }

        // Red de seguridad: si la pantalla se queda sin imagen, nadie puede apretar
        // "Mantener" y el timer revierte solo. La barra que se vacia dice cuanto
        // queda sin tener que leer el numero.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.revertIn > 0

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 2
                radius: 1
                color: Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.2)
                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * (root.revertIn / 12)
                    color: Colors.primary
                    Behavior on width {
                        enabled: Config.animDuration > 0
                        NumberAnimation {
                            duration: 950
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: `¿Se ve bien? Revierto en ${root.revertIn}s`
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    color: Colors.overBackground
                }
                Chip {
                    label: "Mantener"
                    icon: Icons.accept
                    active: true
                    onClicked: root.keep()
                }
                Chip {
                    label: "Revertir"
                    onClicked: root.revert()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.revertIn === 0 && root.monitors.length === 2

            Text {
                Layout.fillWidth: true
                text: root.status
                elide: Text.ElideRight
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-3)
                font.letterSpacing: 1.2
                font.capitalization: Font.AllUppercase
                color: Colors.overSurfaceVariant
                opacity: 0.5
            }

            Chip {
                label: "Guardar"
                icon: Icons.accept
                visible: root.pendingRules.length === 2
                active: true
                onClicked: root.save()
            }
        }
    }
}
