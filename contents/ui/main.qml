import QtQuick
import org.kde.kwin
import org.kde.kirigami as Kirigami

SceneEffect {
    id: effect

    // A pie menu gets difficult to use with too many sectors. Ten also maps
    // naturally to the 1..9 and 0 keys.
    readonly property int maximumItems: 10
    readonly property real deadZoneRadius: 42
    readonly property int autoDismissInterval: 30000

    property point invocationPos: Qt.point(0, 0)
    property var invocationWindow: null
    property var invocationScreen: null
    property var candidates: []
    property var mruWindows: []
    property int selectedIndex: -1

    property var pendingPointerWindow: null

    Timer {
        id: autoDismissTimer

        interval: effect.autoDismissInterval
        repeat: false

        onTriggered: {
            console.log("Radial switcher timed out")
            effect.cancel()
        }
    }

    DBusCall {
        id: moveMouseToFocus

        service: "org.kde.kglobalaccel"
        path: "/component/kwin"
        dbusInterface: "org.kde.kglobalaccel.Component"
        method: "invokeShortcut"
        arguments: ["MoveMouseToFocus"]

        onFailed: console.warn("Failed to move cursor to focused window")
    }

    function trackable(window) {
        return window
            && window.managed
            && !window.deleted
            && !window.specialWindow
            && !window.skipSwitcher
            && window.wantsInput;
    }

    function moveToMruFront(window) {
        if (!trackable(window)) {
            return;
        }

        const next = [window];
        for (let i = 0; i < mruWindows.length; ++i) {
            const previous = mruWindows[i];
            if (previous && previous !== window) {
                next.push(previous);
            }
        }
        mruWindows = next;
    }

    function removeFromMru(window) {
        const next = [];
        for (let i = 0; i < mruWindows.length; ++i) {
            const previous = mruWindows[i];
            if (previous && previous !== window) {
                next.push(previous);
            }
        }
        mruWindows = next;
    }

    function seedMru() {
        const initial = [];
        const active = Workspace.activeWindow;

        // Put the currently active window first. The remaining initial order is
        // only a fallback until real activation events establish true recency.
        if (trackable(active)) {
            initial.push(active);
        }

        const stack = Workspace.stackingOrder;
        for (let i = stack.length - 1; i >= 0; --i) {
            const window = stack[i];
            if (trackable(window) && initial.indexOf(window) < 0) {
                initial.push(window);
            }
        }

        mruWindows = initial;
    }

    function reconcileMru() {
        // Retain the genuine MRU ordering for windows we already know about,
        // discard stale/ineligible references, then append any newly discovered
        // windows in topmost-first stacking order as a fallback.
        const next = [];

        for (let i = 0; i < mruWindows.length; ++i) {
            const window = mruWindows[i];
            if (trackable(window) && next.indexOf(window) < 0) {
                next.push(window);
            }
        }

        const stack = Workspace.stackingOrder;
        for (let i = stack.length - 1; i >= 0; --i) {
            const window = stack[i];
            if (trackable(window) && next.indexOf(window) < 0) {
                next.push(window);
            }
        }

        mruWindows = next;
    }

    function shortcutLabel(index) {
        if (index < 0 || index >= candidates.length) {
            return "";
        }

        if (candidates[index] === invocationWindow) {
            return "0";
        }

        return String(index + 1);
    }    

    function onCurrentDesktop(window) {
        if (window.onAllDesktops) {
            return true;
        }

        for (let i = 0; i < window.desktops.length; ++i) {
            if (window.desktops[i] === Workspace.currentDesktop) {
                return true;
            }
        }
        return false;
    }

    function onCurrentActivity(window) {
        if (window.activities.length === 0) {
            return true;
        }

        for (let i = 0; i < window.activities.length; ++i) {
            if (window.activities[i] === Workspace.currentActivity) {
                return true;
            }
        }
        return false;
    }

    function snapshotWindows() {
        reconcileMru();

        const result = [];
        const active = invocationWindow;
        const includeActive = trackable(active);

        const mruLimit = includeActive ? maximumItems - 1 : maximumItems;
        
        for (let i = 0; i < mruWindows.length; ++i) {
            const window = mruWindows[i];
            if (!trackable(window) || window === active) {
                continue;
            }

            result.push(window);
            if (result.length >= mruLimit) {
                break;
            }
        }

        if (includeActive) {
            result.push(active);
        }

        candidates = result;
    }

    function openSwitcher() {
        invocationPos = Workspace.cursorPos;
        invocationScreen = Workspace.screenAt(invocationPos);
        invocationWindow = Workspace.activeWindow;
        selectedIndex = -1;
        snapshotWindows();

        if (candidates.length > 0) {
            visible = true;
            autoDismissTimer.restart();
        }
    }

    function cancel() {
        selectedIndex = -1;
        visible = false;
        autoDismissTimer.stop();
    }

    function matchesActivation(window, target) {
        while (window) {
            if (window === target) {
                return true;
            }
            window = window.modal ? window.transientFor : null;
        }
        return false;
    }

    function activateIndex(index) {
        if (index < 0 || index >= candidates.length) {
            return;
        }

        const window = candidates[index];

        autoDismissTimer.stop();
        visible = false;

        // activeWindow is writable in KWin's scripting workspace API; setting
        // it performs the same sort of activation as a task switcher.
        pendingPointerWindow = matchesActivation(Workspace.activeWindow, window) ? null : window;
        Workspace.activeWindow = window;
    }

    function cycle(delta) {
        if (candidates.length === 0) {
            return;
        }

        if (selectedIndex < 0) {
            selectedIndex = delta > 0 ? 0 : candidates.length - 1;
        } else {
            selectedIndex = (selectedIndex + delta + candidates.length)
                          % candidates.length;
        }
    }

    function angularDistance(a, b) {
        let d = Math.abs(a - b) % (Math.PI * 2);
        return d > Math.PI ? Math.PI * 2 - d : d;
    }

    Component.onCompleted: seedMru()

    Connections {
        target: Workspace

        function onWindowActivated(window) {
            effect.moveToMruFront(window);

            if (!window) {
                return;
            }
            const target = effect.pendingPointerWindow;
            effect.pendingPointerWindow = null;
            if (target && effect.matchesActivation(window, target)
                    && effect.configuration.TeleportCursor) {
                moveMouseToFocus.call();
            }
        }

        function onWindowAdded(window) {
            // Most newly opened normal windows will immediately be activated and
            // therefore move to the front. If one is created in the background,
            // append it so it is still available to the switcher.
            if (!effect.trackable(window) || effect.mruWindows.indexOf(window) >= 0) {
                return;
            }
            const next = effect.mruWindows.slice();
            next.push(window);
            effect.mruWindows = next;
        }

        function onWindowRemoved(window) {
            effect.removeFromMru(window);
        }
    }

    ShortcutHandler {
        name: "Radial Window Switcher"
        text: "Show Radial Window Switcher"
        sequence: "Meta+Alt+W"
        onActivated: effect.openSwitcher()
    }

    delegate: Item {
        id: scene

        readonly property var screen: SceneView.screen
        readonly property rect screenGeometry: screen.geometry
        readonly property bool invocationView: effect.invocationScreen === screen
        readonly property real originX: effect.invocationPos.x - screenGeometry.x
        readonly property real originY: effect.invocationPos.y - screenGeometry.y

        // Keep cards compact enough for ten sectors on a typical desktop.
        readonly property real cardWidth: 118
        readonly property real cardHeight: 94
        readonly property real layoutMargin: 8
        // Keep small menus tight, but give 9- and 10-item menus enough
        // circumference that neighbouring cards do not become cramped.
        readonly property real compactRingRadius: Math.min(180,
                                                            Math.max(120,
                                                                     Math.min(width, height) * 0.19))
        readonly property real crowdingRadiusBonus:
            Math.max(0, effect.candidates.length - 8) * 18
        readonly property real ringRadius:
            Math.min(215, compactRingRadius + crowdingRadiusBonus)

        // A full circle is used while it fits around the invocation point.
        // Near an edge we replace it with an inward-facing fan. At a corner
        // the fan narrows further. This keeps every item on a unique ray from
        // the real pointer position instead of independently clamping cards.
        readonly property bool constrainedLeft:
            originX - ringRadius - cardWidth / 2 < layoutMargin
        readonly property bool constrainedRight:
            originX + ringRadius + cardWidth / 2 > width - layoutMargin
        readonly property bool constrainedTop:
            originY - ringRadius - cardHeight / 2 < layoutMargin
        readonly property bool constrainedBottom:
            originY + ringRadius + cardHeight / 2 > height - layoutMargin
        readonly property bool constrainedHorizontal: constrainedLeft || constrainedRight
        readonly property bool constrainedVertical: constrainedTop || constrainedBottom
        readonly property bool edgeConstrained: constrainedHorizontal || constrainedVertical
        readonly property bool cornerConstrained: constrainedHorizontal && constrainedVertical

        readonly property real inwardX: (constrainedLeft ? 1 : 0)
                                        + (constrainedRight ? -1 : 0)
        readonly property real inwardY: (constrainedTop ? 1 : 0)
                                        + (constrainedBottom ? -1 : 0)
        readonly property real fanCenterAngle: edgeConstrained
                                               ? Math.atan2(inwardY, inwardX)
                                               : -Math.PI / 2
        readonly property real fanSpan: cornerConstrained
                                        ? Math.PI * 0.46       // ~83 degrees
                                        : Math.PI * 0.89       // ~160 degrees

        function itemAngle(index) {
            const count = effect.candidates.length;

            if (count <= 0) {
                return -Math.PI / 2;
            }

            if (!edgeConstrained) {
                // Full circle: #1 at 12 o'clock, then clockwise.
                return -Math.PI / 2 + Math.PI * 2 * index / count;
            }

            if (count === 1) {
                return fanCenterAngle;
            }

            const step = fanSpan / (count - 1);

            // Constrained fan: always number sequentially clockwise
            // from one edge of the usable fan to the other.
            return fanCenterAngle - fanSpan / 2 + index * step;
        }

        function radiusBoundsForAngle(angle) {
            // Intersect the ray from the pointer with the rectangle in which
            // a card centre may live while keeping the whole card on-screen.
            const minX = layoutMargin + cardWidth / 2;
            const maxX = width - layoutMargin - cardWidth / 2;
            const minY = layoutMargin + cardHeight / 2;
            const maxY = height - layoutMargin - cardHeight / 2;
            const dx = Math.cos(angle);
            const dy = Math.sin(angle);
            const epsilon = 0.000001;
            let tMin = 0;
            let tMax = Number.POSITIVE_INFINITY;

            function intersectAxis(origin, direction, low, high) {
                if (Math.abs(direction) < epsilon) {
                    if (origin < low || origin > high) {
                        return null;
                    }
                    return { low: Number.NEGATIVE_INFINITY,
                             high: Number.POSITIVE_INFINITY };
                }

                let a = (low - origin) / direction;
                let b = (high - origin) / direction;
                if (a > b) {
                    const tmp = a;
                    a = b;
                    b = tmp;
                }
                return { low: a, high: b };
            }

            const xRange = intersectAxis(originX, dx, minX, maxX);
            const yRange = intersectAxis(originY, dy, minY, maxY);
            if (xRange === null || yRange === null) {
                return { valid: false, min: 0, max: 0 };
            }

            tMin = Math.max(tMin, xRange.low, yRange.low);
            tMax = Math.min(tMax, xRange.high, yRange.high);

            if (tMax < tMin || tMax < 0) {
                return { valid: false, min: 0, max: 0 };
            }

            return { valid: true,
                     min: Math.max(0, tMin),
                     max: tMax };
        }

        function itemRadius(index) {
            const desired = crowdingAdjustedRadius();
            const angle = itemAngle(index);
            const bounds = radiusBoundsForAngle(angle);

            if (!bounds.valid) {
                return ringRadius;
            }

            // Keep every card on its own ray, but otherwise preserve
            // a common radius so the entries form a clean arc.
            return Math.max(bounds.min, Math.min(bounds.max, desired));
        }

        function crowdingAdjustedRadius() {
            const count = effect.candidates.length;

            if (!edgeConstrained || count < 2) {
                return ringRadius;
            }

            // Calculate the actual angles, then sort them geometrically.
            const angles = [];
            for (let i = 0; i < count; ++i) {
                angles.push(itemAngle(i));
            }

            angles.sort((a, b) => a - b);

            const gap = 12;
            const requiredWidth = cardWidth + gap;
            const requiredHeight = cardHeight + gap;
            const epsilon = 0.000001;

            let requiredRadius = ringRadius;

            for (let i = 0; i < angles.length - 1; ++i) {
                const a = angles[i];
                const b = angles[i + 1];

                // At radius r, these are the horizontal/vertical distances
                // between the two card centres divided by r.
                const dx = Math.abs(Math.cos(a) - Math.cos(b));
                const dy = Math.abs(Math.sin(a) - Math.sin(b));

                // Two axis-aligned cards cease overlapping as soon as either
                // their horizontal OR vertical separation is sufficient.
                const radiusForX = dx > epsilon
                    ? requiredWidth / dx
                    : Number.POSITIVE_INFINITY;

                const radiusForY = dy > epsilon
                    ? requiredHeight / dy
                    : Number.POSITIVE_INFINITY;

                const pairRadius = Math.min(radiusForX, radiusForY);

                requiredRadius = Math.max(requiredRadius, pairRadius);
            }

            return requiredRadius;
        }

        function indexFromPointer(localX, localY) {
            const dx = localX - originX;
            const dy = localY - originY;
            const distance = Math.sqrt(dx * dx + dy * dy);

            if (distance < effect.deadZoneRadius || effect.candidates.length === 0) {
                return -1;
            }

            const pointerAngle = Math.atan2(dy, dx);
            let bestIndex = -1;
            let bestDistance = Number.POSITIVE_INFINITY;

            for (let i = 0; i < effect.candidates.length; ++i) {
                const d = effect.angularDistance(pointerAngle, itemAngle(i));
                if (d < bestDistance) {
                    bestDistance = d;
                    bestIndex = i;
                }
            }

            // In fan mode, do not make an item selectable from the inaccessible
            // side of the pointer. Give the two end sectors half a step of slack.
            if (edgeConstrained) {
                const step = effect.candidates.length > 1
                           ? fanSpan / (effect.candidates.length - 1)
                           : fanSpan;
                if (effect.angularDistance(pointerAngle, fanCenterAngle)
                        > fanSpan / 2 + step / 2) {
                    return -1;
                }
            }

            return bestIndex;
        }



        focus: invocationView

        Component.onCompleted: {
            if (invocationView) {
                forceActiveFocus();
            }
        }

        // Reconstruct a simple snapshot of the workspace. SceneEffect replaces
        // KWin's normal scene, so without this the radial UI would be displayed
        // over an empty scene rather than the current desktop.
        DesktopBackground {
            anchors.fill: parent
            output: scene.screen
            desktop: Workspace.currentDesktop
            activity: Workspace.currentActivity
        }

        Repeater {
            model: Workspace.stackingOrder

            delegate: WindowThumbnail {
                required property var modelData

                client: modelData
                x: client.x - scene.screenGeometry.x
                y: client.y - scene.screenGeometry.y
                width: client.width
                height: client.height

                // Only reconstruct ordinary visible windows which intersect
                // this output. The wallpaper is supplied separately above.
                visible: !client.deleted
                         && !client.specialWindow
                         && !client.minimized
                         && !client.hidden
                         && effect.onCurrentDesktop(client)
                         && effect.onCurrentActivity(client)
                         && x < scene.width
                         && y < scene.height
                         && x + width > 0
                         && y + height > 0
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#72000000"
        }

        // Only the output containing the cursor gets the radial controls.
        Item {
            anchors.fill: parent
            visible: scene.invocationView

            MouseArea {
                id: pointerArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onPositionChanged: mouse => {
                    effect.selectedIndex = scene.indexFromPointer(mouse.x, mouse.y);
                }

                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        effect.cancel();
                    } else if (effect.selectedIndex >= 0) {
                        effect.activateIndex(effect.selectedIndex);
                    }
                }
            }

            // Centre/dead-zone marker.
            Rectangle {
                x: scene.originX - width / 2
                y: scene.originY - height / 2
                width: effect.deadZoneRadius * 2
                height: width
                radius: width / 2
                color: "#d8323438"
                border.width: 2
                border.color: "#aaffffff"

                Text {
                    anchors.centerIn: parent
                    text: effect.selectedIndex < 0
                          ? "•"
                          : effect.shortcutLabel(effect.selectedIndex)
                    color: "white"
                    font.pixelSize: 22
                    font.bold: true
                }
            }

            Repeater {
                model: effect.candidates

                delegate: Rectangle {
                    id: card
                    required property int index
                    required property var modelData

                    readonly property real angle: scene.itemAngle(index)
                    readonly property real radiusFromOrigin: scene.itemRadius(index)
                    readonly property bool selected: effect.selectedIndex === index

                    // Position directly on the same ray that mouse hit-testing
                    // uses. Edge handling may change the radius, never the angle.
                    x: scene.originX + Math.cos(angle) * radiusFromOrigin - width / 2
                    y: scene.originY + Math.sin(angle) * radiusFromOrigin - height / 2
                    width: scene.cardWidth
                    height: scene.cardHeight
                    radius: 10
                    color: selected ? "#f02f6fbd" : "#e625272a"
                    border.width: selected ? 3 : 1
                    border.color: selected ? "white" : "#70ffffff"
                    scale: selected ? 1.08 : 1.0
                    z: selected ? 2 : 1

                    Behavior on scale {
                        NumberAnimation { duration: 70 }
                    }

                    // KWin exposes each managed window's QIcon directly to QML.
                    // Kirigami.Icon can render the QIcon without resolving the
                    // application's .desktop file ourselves.
                    Kirigami.Icon {
                        anchors {
                            horizontalCenter: parent.horizontalCenter
                            top: parent.top
                            topMargin: 9
                        }
                        width: 48
                        height: 48
                        source: card.modelData.icon
                        fallback: "application-x-executable"
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            bottom: parent.bottom
                            margins: 6
                        }
                        width: 23
                        height: 23
                        radius: 5
                        color: "#bb000000"

                        Text {
                            anchors.centerIn: parent
                            text: effect.shortcutLabel(card.index)
                            color: "white"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 35
                            right: parent.right
                            rightMargin: 7
                            bottom: parent.bottom
                            bottomMargin: 8
                        }
                        text: card.modelData.caption
                        color: "white"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }
        }

        Keys.onPressed: event => {
            if (!scene.invocationView) {
                return;
            }

            let handled = true;

            if (event.key === Qt.Key_Escape) {
                effect.cancel();
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                effect.activateIndex(effect.selectedIndex);
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
                effect.cycle(1);
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
                effect.cycle(-1);
            } else {
                // Number keys are positional shortcuts for the currently
                // displayed radial entries: 1..9 select items 1..9 and 0
                // selects the window that was active when the switcher
                // was invoked.
                const blockedModifiers = Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier;
                const hasBlockedModifier = (event.modifiers & blockedModifiers) !== 0;
                let shortcutIndex = -1;

                if (!hasBlockedModifier) {
                    switch (event.key) {
                    case Qt.Key_1: shortcutIndex = 0; break;
                    case Qt.Key_2: shortcutIndex = 1; break;
                    case Qt.Key_3: shortcutIndex = 2; break;
                    case Qt.Key_4: shortcutIndex = 3; break;
                    case Qt.Key_5: shortcutIndex = 4; break;
                    case Qt.Key_6: shortcutIndex = 5; break;
                    case Qt.Key_7: shortcutIndex = 6; break;
                    case Qt.Key_8: shortcutIndex = 7; break;
                    case Qt.Key_9: shortcutIndex = 8; break;
                    case Qt.Key_0:
                        shortcutIndex = effect.candidates.indexOf(effect.invocationWindow);
                        break;
                    }
                }

                if (shortcutIndex >= 0  && shortcutIndex < effect.candidates.length
                    && effect.candidates[shortcutIndex] === effect.invocationWindow
                    && event.key !== Qt.Key_0) {
                        shortcutIndex = -1;
                }

                if (shortcutIndex >= 0) {
                    effect.activateIndex(shortcutIndex);
                } else {
                    handled = false;
                }
                
            }

            if (handled) {
                event.accepted = true;
            }
        }
    }
}
