pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.modules.theme
import qs.modules.components
import qs.config

// Editor de monitores. Lee hyprctl, aplica en vivo con reversion por timeout y
// guarda en ~/.config/hypr/monitors.conf (que hyprland.conf hace source al final).
//
// Lenguaje visual (2026-10-26): panel de instrumento, no formulario. La paleta del
// tema puede quedar en escala de grises completa (si el wallpaper es B/N, matugen
// devuelve primary = #ffffff y todos los acentos iguales), asi que la jerarquia se
// construye con VALOR, PESO y TIPOGRAFIA, no con tono: etiquetas en micro-versalitas
// Roboto Condensed, todo numero en Iosevka mono, y el blanco solido reservado para
// un unico estado activo por grupo.
Rectangle {
    id: root
    color: "transparent"
    implicitWidth: 460
    implicitHeight: 430

    readonly property var transforms: [
        { t: 0, label: "0°" },
        { t: 1, label: "90°" },
        { t: 2, label: "180°" },
        { t: 3, label: "270°" }
    ]

    property var monitors: []
    property int sel: 0
    readonly property var cur: sel >= 0 && sel < monitors.length ? monitors[sel] : null

    // Borrador: lo que el usuario edito pero todavia no aplico
    property string dMode: "preferred"
    property real dScale: 1
    property int dX: 0
    property int dY: 0
    property int dTransform: 0
    property bool dEnabled: true
    property bool dirty: false

    // Guias de alineacion: coordenadas logicas donde el borde arrastrado quedo pegado
    // a un borde vecino. El mapa las dibuja como hairlines mientras arrastras; sin
    // ellas el snap ocurre pero no se ve, y se siente como que la caja se traba sola.
    property var guideX: []
    property var guideY: []

    property int revertIn: 0   // > 0 => countdown de seguridad corriendo
    readonly property int revertTotal: 12
    property string status: ""

    function reload() {
        monitorsProc.running = true;
    }

    function loadDraft() {
        if (!cur)
            return;
        dMode = cur.disabled ? "preferred" : `${cur.width}x${cur.height}@${(cur.refreshRate || 60).toFixed(2)}`;
        dScale = cur.scale || 1;
        dX = cur.x || 0;
        dY = cur.y || 0;
        dTransform = cur.transform || 0;
        dEnabled = !cur.disabled;
        dirty = false;
    }

    // --- geometria logica para el mapa ---
    // Hyprland posiciona en coordenadas logicas: pixeles / escala, y rotado 90/270 intercambia ancho y alto.
    function logicalSize(m, draft) {
        let w = m.width || 0;
        let h = m.height || 0;
        if (draft) {
            const mm = dMode.match(/^(\d+)x(\d+)/);
            if (mm) {
                w = parseInt(mm[1]);
                h = parseInt(mm[2]);
            }
        }
        const sc = (draft ? dScale : (m.scale || 1)) || 1;
        const tr = draft ? dTransform : (m.transform || 0);
        w = Math.round(w / sc);
        h = Math.round(h / sc);
        return (tr === 1 || tr === 3) ? { w: h, h: w } : { w: w, h: h };
    }

    // Rect de cada monitor: el seleccionado usa el borrador, el resto lo que reporta hyprctl.
    // null = apagado, no va al mapa.
    function rectFor(i) {
        const m = monitors[i];
        if (!m)
            return null;
        const isSel = i === sel;
        if (isSel ? !dEnabled : m.disabled)
            return null;
        const sz = logicalSize(m, isSel);
        return {
            i: i,
            name: m.name,
            x: isSel ? dX : (m.x || 0),
            y: isSel ? dY : (m.y || 0),
            w: sz.w,
            h: sz.h,
            sel: isSel
        };
    }

    function rects() {
        const out = [];
        for (let i = 0; i < monitors.length; i++) {
            const r = rectFor(i);
            if (r)
                out.push(r);
        }
        return out;
    }

    // Caja que abarca todo, inflada en `extra` px logicos por lado.
    function bbox(extra) {
        const rs = rects();
        if (!rs.length)
            return { x: 0, y: 0, w: 1, h: 1 };
        const e = extra || 0;
        const x1 = Math.min(...rs.map(r => r.x));
        const y1 = Math.min(...rs.map(r => r.y));
        const x2 = Math.max(...rs.map(r => r.x + r.w));
        const y2 = Math.max(...rs.map(r => r.y + r.h));
        return { x: x1 - e, y: y1 - e, w: (x2 - x1) + 2 * e, h: (y2 - y1) + 2 * e };
    }

    // Pega el borde arrastrado al de otra pantalla si queda cerca (en px logicos).
    function snapTo(v, cands, thr) {
        for (const c of cands)
            if (Math.abs(v - c) < thr)
                return Math.round(c);
        return Math.round(v);
    }

    function snapPos(nx, ny, myW, myH) {
        const thr = 40;
        let xs = [];
        let ys = [];
        let ex = [];
        let ey = [];
        for (const r of rects()) {
            if (r.sel)
                continue;
            xs.push(r.x, r.x + r.w, r.x - myW, r.x + r.w - myW);
            ys.push(r.y, r.y + r.h, r.y - myH, r.y + r.h - myH);
            ex.push(r.x, r.x + r.w);
            ey.push(r.y, r.y + r.h);
        }
        const rx = snapTo(nx, xs, thr);
        const ry = snapTo(ny, ys, thr);
        const gx = [];
        const gy = [];
        for (const e of ex)
            if (Math.abs(rx - e) < 0.5 || Math.abs(rx + myW - e) < 0.5)
                gx.push(e);
        for (const e of ey)
            if (Math.abs(ry - e) < 0.5 || Math.abs(ry + myH - e) < 0.5)
                gy.push(e);
        guideX = gx;
        guideY = gy;
        return { x: rx, y: ry };
    }

    // ponytail: una sola funcion arma la linea; la usan igual el apply en vivo y el guardado.
    function ruleFor(name) {
        if (!dEnabled)
            return `${name},disable`;
        const mode = dMode.replace("Hz", "");
        return `${name},${mode},${dX}x${dY},${dScale.toFixed(2)},transform,${dTransform}`;
    }

    function apply() {
        if (!cur)
            return;
        applyProc.command = ["hyprctl", "keyword", "monitor", ruleFor(cur.name)];
        applyProc.running = true;
        revertIn = revertTotal;
        status = "";
    }

    function keep() {
        revertIn = 0;
        dirty = false;
        status = "Aplicado, sin guardar";
        reload();
    }

    function revert() {
        revertIn = 0;
        Quickshell.execDetached(["hyprctl", "reload"]);
        status = "Revertido";
        Qt.callLater(root.reload);
    }

    // ponytail: el merge lo hace sh de un tiron (leer + reescribir + mv atomico);
    // asi no depende de cuando termine de cargar un FileView.
    readonly property string saveScript: `f="$HOME/.config/hypr/monitors.conf"
{ echo "# Generado por el tab Monitores del notch (ambxst). Se reescribe al guardar."
  echo "# Lo hace source hyprland.conf al final, asi que estas reglas ganan."
  grep -E "^monitor = " "$f" 2>/dev/null | grep -v "^monitor = $1,"
  echo "monitor = $2"; } > "$f.tmp" && mv "$f.tmp" "$f" && hyprctl reload`

    function save() {
        if (!cur)
            return;
        saveProc.command = ["sh", "-c", saveScript, "_", cur.name, ruleFor(cur.name)];
        saveProc.running = true;
        dirty = false;
        status = "Guardado en monitors.conf";
    }

    onCurChanged: loadDraft()
    onVisibleChanged: if (visible)
        reload()
    Component.onCompleted: reload()

    Process {
        id: saveProc
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
                if (root.sel >= list.length)
                    root.sel = 0;
                root.loadDraft();
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

    // ---- tokens tipograficos ----
    // Dos roles, ya definidos por el tema y hasta ahora desaprovechados: Roboto
    // Condensed en micro-versalitas para etiquetar, Iosevka mono para los datos.
    component Eyebrow: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-4)
        font.weight: Font.DemiBold
        font.letterSpacing: 1.4
        font.capitalization: Font.AllUppercase
        color: Colors.overSurfaceVariant
        opacity: 0.55
    }

    component Val: Text {
        font.family: Config.theme.monoFont
        font.pixelSize: Styling.monoFontSize(-1)
        color: Colors.overBackground
    }

    component Hairline: Rectangle {
        implicitHeight: 1
        Layout.fillWidth: true
        color: Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.16)
    }

    // ---- controles ----
    // Un solo boton para todo el panel, con tres pesos: ghost (default), hover y
    // solid (el unico activo del grupo). En monocromo el relleno blanco es la unica
    // señal de estado que no se confunde con nada.
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property string icon: ""
        property bool active: false
        property bool mono: false
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
                font.family: chip.mono ? Config.theme.monoFont : Config.theme.font
                font.pixelSize: chip.mono ? Styling.monoFontSize(-2) : Styling.fontSize(-2)
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

    component NumBox: Rectangle {
        id: box
        property int value: 0
        signal edited(int v)
        implicitWidth: 66
        implicitHeight: 28
        radius: Styling.radius(-4)
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, input.activeFocus ? 0.6 : 0.28)

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            text: box.value
            font.family: Config.theme.monoFont
            font.pixelSize: Styling.monoFontSize(-2)
            color: Colors.overBackground
            selectByMouse: true
            validator: IntValidator {
                bottom: -20000
                top: 20000
            }
            onEditingFinished: box.edited(parseInt(text) || 0)
        }
    }

    // Celda de la ficha tecnica: etiqueta arriba, control abajo. Reemplaza las filas
    // "etiqueta ...... control" que dejaban media pantalla vacia a la derecha.
    component Cell: ColumnLayout {
        id: cell
        property string label: ""
        // Las tres columnas se reparten el ancho por igual: en el panel ancho (900px)
        // la ficha ocupaba solo el tercio izquierdo y el resto quedaba vacio.
        Layout.fillWidth: true
        spacing: 5
        Eyebrow {
            text: cell.label
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
        spacing: 10

        // ---- cabecera: que pantalla estoy editando ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ColumnLayout {
                spacing: 1
                Eyebrow {
                    text: "Disposicion"
                }
                Text {
                    text: root.cur ? root.cur.name : "sin monitores"
                    font.family: Config.theme.monoFont
                    font.pixelSize: Styling.monoFontSize(2)
                    font.weight: Font.Medium
                    color: Colors.overBackground
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Repeater {
                model: root.monitors
                Chip {
                    required property var modelData
                    required property int index
                    mono: true
                    label: modelData.name
                    icon: modelData.disabled ? Icons.power : ""
                    active: root.sel === index
                    onClicked: root.sel = index
                }
            }

            Chip {
                icon: Icons.sync
                hPad: 8
                onClicked: root.reload()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !!root.cur && text !== ""
            text: root.cur ? (root.cur.description || "") : ""
            elide: Text.ElideRight
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-3)
            color: Colors.overSurfaceVariant
            opacity: 0.5
        }

        Text {
            Layout.fillWidth: true
            visible: root.monitors.length === 0
            text: "No hay monitores que reportar.\n¿El externo esta conectado?"
            font.family: Config.theme.font
            font.pixelSize: Config.theme.fontSize
            color: Colors.overSurfaceVariant
        }

        // ---- el mapa es el heroe de este tab ----
        // Arrastra una pantalla para colocarla donde esta fisicamente; se pega sola
        // al borde de la otra y la guia blanca te dice contra que borde se pego.
        StyledRect {
            id: mapCard
            variant: "internalbg"
            radius: Styling.radius(-2)
            Layout.fillWidth: true
            // ponytail: crece con lo que sobre; antes el alto fijo dejaba un hueco
            // muerto arriba de Aplicar/Guardar en cualquier pantalla alta.
            Layout.fillHeight: true
            Layout.minimumHeight: 150
            Layout.preferredHeight: 168
            visible: root.monitors.length > 0

            // Durante el arrastre se congela la TRANSFORMACION completa (escala +
            // origen), no la caja contenedora. Antes se congelaba un bbox inflado por
            // el tamaño del monitor, lo que bajaba la escala y encogia todo de golpe
            // al presionar. Congelando k/offX/offY tal cual estaban, nada se mueve ni
            // se achica mientras arrastras; al soltar, el mapa reencuadra solo.
            property var frozen: null
            readonly property var liveBb: root.bbox(0)
            readonly property real pad: 18
            readonly property real liveK: Math.min((width - pad * 2) / Math.max(liveBb.w, 1), (height - pad * 2) / Math.max(liveBb.h, 1))

            readonly property real bbX: frozen ? frozen.bbX : liveBb.x
            readonly property real bbY: frozen ? frozen.bbY : liveBb.y
            readonly property real k: frozen ? frozen.k : liveK
            readonly property real offX: frozen ? frozen.offX : (width - liveBb.w * liveK) / 2
            readonly property real offY: frozen ? frozen.offY : (height - liveBb.h * liveK) / 2

            function freezeView() {
                frozen = {
                    bbX: bbX,
                    bbY: bbY,
                    k: k,
                    offX: offX,
                    offY: offY
                };
            }

            // Cuadricula de referencia: sin esto el mapa era un vacio negro y las
            // cajas parecian flotar sin contexto espacial, como un editor sin regla.
            // Puntos en vez de lineas: marcan la reticula sin competir con los bordes
            // de las pantallas, que es lo unico que uno mira aqui.
            Canvas {
                id: mapGrid
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.fillStyle = Qt.rgba(1, 1, 1, 0.16);
                    const step = 16;
                    for (let gx = step; gx < width; gx += step)
                        for (let gy = step; gy < height; gy += step)
                            ctx.fillRect(gx, gy, 1, 1);
                }
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }

            // Guias de snap: hairlines que cruzan el mapa entero por el borde donde
            // la pantalla acaba de engancharse. Solo existen mientras arrastras.
            Repeater {
                model: mapCard.frozen ? root.guideX : []
                Rectangle {
                    required property var modelData
                    width: 1
                    height: mapCard.height
                    y: 0
                    x: mapCard.offX + (modelData - mapCard.bbX) * mapCard.k
                    color: Colors.primary
                    opacity: 0.5
                }
            }

            Repeater {
                model: mapCard.frozen ? root.guideY : []
                Rectangle {
                    required property var modelData
                    height: 1
                    width: mapCard.width
                    x: 0
                    y: mapCard.offY + (modelData - mapCard.bbY) * mapCard.k
                    color: Colors.primary
                    opacity: 0.5
                }
            }

            Repeater {
                // modelo estable: si dependiera de rects() se recrearian los delegates
                // en cada mousemove y el arrastre se cortaria.
                model: root.monitors

                Item {
                    id: box
                    required property int index
                    readonly property var r: root.rectFor(index)
                    readonly property bool isSel: !!r && r.sel

                    visible: !!r
                    x: r ? mapCard.offX + (r.x - mapCard.bbX) * mapCard.k : 0
                    y: r ? mapCard.offY + (r.y - mapCard.bbY) * mapCard.k : 0
                    width: r ? Math.max(16, r.w * mapCard.k) : 0
                    height: r ? Math.max(16, r.h * mapCard.k) : 0

                    // Una pantalla real = marco + area util. La seleccionada se dibuja
                    // encendida (marco blanco, pantalla con luz); las demas quedan en
                    // hairline, presentes pero apagadas. En escala de grises eso es lo
                    // unico que distingue "esta es la que estoy moviendo".
                    Rectangle {
                        id: bezel
                        anchors.fill: parent
                        radius: Styling.radius(-6)
                        color: Colors.background
                        border.width: box.isSel ? 2 : 1
                        border.color: box.isSel ? Colors.primary : Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.45)

                        Behavior on border.color {
                            enabled: Config.animDuration > 0
                            ColorAnimation {
                                duration: Config.animDuration / 2
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 3
                            radius: Math.max(0, bezel.radius - 2)
                            color: box.isSel ? Qt.rgba(Colors.primary.r, Colors.primary.g, Colors.primary.b, 0.10) : "transparent"
                            border.width: 1
                            border.color: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, box.isSel ? 0.22 : 0.07)
                        }
                    }

                    // Ficha dentro de la pantalla: nombre + resolucion logica, en mono.
                    // Antes era un sticker con el nombre y nada mas; la resolucion es
                    // justo el dato que uno necesita para entender el acomodo.
                    ColumnLayout {
                        anchors.centerIn: parent
                        width: box.width - 10
                        spacing: 0
                        visible: box.width > 46

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: box.width - 10
                            elide: Text.ElideRight
                            text: box.r ? box.r.name : ""
                            font.family: Config.theme.monoFont
                            font.pixelSize: Styling.monoFontSize(-3)
                            font.weight: Font.Medium
                            font.letterSpacing: 0.5
                            color: box.isSel ? Colors.overBackground : Colors.overSurfaceVariant
                        }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: box.height > 42
                            text: box.r ? `${box.r.w}×${box.r.h}` : ""
                            font.family: Config.theme.monoFont
                            font.pixelSize: Styling.monoFontSize(-5)
                            color: Colors.overSurfaceVariant
                            opacity: box.isSel ? 0.75 : 0.4
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property real sx: 0
                        property real sy: 0
                        property int ox: 0
                        property int oy: 0

                        // mouse.x/y son relativos a ESTA caja, y la caja se mueve
                        // mientras arrastras: cada paso se medía desde la posición
                        // nueva, no desde donde empezaste, así que el delta se
                        // reiniciaba solo y la caja se despegaba del cursor.
                        // mapToItem(mapCard) da coordenadas del mapa, que no se
                        // mueven durante el arrastre (el encuadre está congelado).
                        onPressed: mouse => {
                            if (root.sel !== box.index) {
                                root.sel = box.index;   // arrastrar tambien selecciona
                                root.loadDraft();       // sin esto ox/oy serían del monitor anterior
                            }
                            const p = box.mapToItem(mapCard, mouse.x, mouse.y);
                            sx = p.x;
                            sy = p.y;
                            ox = root.dX;
                            oy = root.dY;
                            mapCard.freezeView();
                        }

                        onReleased: {
                            mapCard.frozen = null;
                            root.guideX = [];
                            root.guideY = [];
                        }

                        onPositionChanged: mouse => {
                            if (!pressed || root.sel !== box.index || !box.r)
                                return;
                            const k = mapCard.k || 1;
                            const m = box.mapToItem(mapCard, mouse.x, mouse.y);
                            const p = root.snapPos(ox + (m.x - sx) / k, oy + (m.y - sy) / k, box.r.w, box.r.h);
                            if (p.x !== root.dX || p.y !== root.dY) {
                                root.dX = p.x;
                                root.dY = p.y;
                                root.dirty = true;
                            }
                        }
                    }
                }
            }
        }

        // ---- ficha tecnica ----
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10
            visible: !!root.cur

            GridLayout {
                Layout.fillWidth: true
                columns: 3
                rowSpacing: 12
                columnSpacing: 18

                Cell {
                    label: "Modo"
                    Chip {
                        id: modeChip
                        mono: true
                        label: root.dMode
                        icon: Icons.caretDown
                        onClicked: {
                            const items = [
                                {
                                    text: "preferred",
                                    onTriggered: () => {
                                        root.dMode = "preferred";
                                        root.dirty = true;
                                    }
                                }
                            ];
                            const modes = (root.cur && root.cur.availableModes) || [];
                            for (const m of modes)
                                items.push({
                                    text: m,
                                    onTriggered: () => {
                                        root.dMode = m;
                                        root.dirty = true;
                                    }
                                });
                            modeMenu.items = items;
                            modeMenu.popup(modeChip);
                        }
                    }
                }

                Cell {
                    label: "Escala"
                    RowLayout {
                        spacing: 8
                        Chip {
                            icon: Icons.minus
                            hPad: 8
                            onClicked: {
                                root.dScale = Math.max(0.5, root.dScale - 0.25);
                                root.dirty = true;
                            }
                        }
                        Val {
                            text: root.dScale.toFixed(2) + "×"
                            font.pixelSize: Styling.monoFontSize(1)
                            horizontalAlignment: Text.AlignHCenter
                            Layout.preferredWidth: 54
                        }
                        Chip {
                            icon: Icons.plus
                            hPad: 8
                            onClicked: {
                                root.dScale = Math.min(3, root.dScale + 0.25);
                                root.dirty = true;
                            }
                        }
                    }
                }

                // 3a celda vacia de la primera fila; se queda con el sobrante
                // para que las dos columnas de la izquierda no se estiren.
                Item {
                    Layout.fillWidth: true
                }


                Hairline {
                    Layout.columnSpan: 3
                }





                Cell {
                    label: "Posicion"
                    RowLayout {
                        spacing: 6
                        NumBox {
                            value: root.dX
                            onEdited: v => {
                                root.dX = v;
                                root.dirty = true;
                            }
                        }
                        Text {
                            text: "×"
                            font.family: Config.theme.monoFont
                            font.pixelSize: Styling.monoFontSize(-2)
                            color: Colors.overSurfaceVariant
                            opacity: 0.5
                        }
                        NumBox {
                            value: root.dY
                            onEdited: v => {
                                root.dY = v;
                                root.dirty = true;
                            }
                        }
                    }
                }

                Cell {
                    label: "Rotacion"
                    RowLayout {
                        spacing: 6
                        Repeater {
                            model: root.transforms
                            Chip {
                                required property var modelData
                                mono: true
                                hPad: 8
                                label: modelData.label
                                active: root.dTransform === modelData.t
                                onClicked: {
                                    root.dTransform = modelData.t;
                                    root.dirty = true;
                                }
                            }
                        }
                    }
                }

                Cell {
                    label: "Encendido"
                    Chip {
                        icon: root.dEnabled ? Icons.accept : Icons.cancel
                        label: root.dEnabled ? "Si" : "No"
                        active: root.dEnabled
                        onClicked: {
                            root.dEnabled = !root.dEnabled;
                            root.dirty = true;
                        }
                    }
                }




            }

            // Red de seguridad: si la pantalla se queda sin imagen, nadie puede
            // apretar "Mantener" y el timer revierte solo. La barra que se vacia dice
            // cuanto queda sin que haya que leer el numero.
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
                        width: parent.width * (root.revertIn / root.revertTotal)
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
                visible: root.revertIn === 0

                Text {
                    Layout.fillWidth: true
                    text: root.dirty ? "Cambios sin aplicar" : root.status
                    elide: Text.ElideRight
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-3)
                    font.letterSpacing: 1.2
                    font.capitalization: Font.AllUppercase
                    color: Colors.overSurfaceVariant
                    opacity: root.dirty ? 0.9 : 0.5
                }

                Chip {
                    label: "Aplicar"
                    icon: Icons.lightning
                    active: root.dirty
                    onClicked: root.apply()
                }

                Chip {
                    label: "Guardar"
                    icon: Icons.accept
                    onClicked: root.save()
                }
            }
        }
    }

    OptionsMenu {
        id: modeMenu
    }
}
