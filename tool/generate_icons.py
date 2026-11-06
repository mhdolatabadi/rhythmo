"""Generate rhythmo's "pulse play" app icon and all shipped icon sizes.

The icon is a glossy play button with a heartbeat line cut through it: play
and rhythm in one shape. The mark is real geometry (the pulse is subtracted
from the triangle), so the same paths work in SVG, PNG and Android vectors,
which have no masks or blur.

Install dependencies with `python3 -m pip install -r tool/icon-requirements.txt`,
then run `python3 tool/generate_icons.py`. Technical asset names stay stable.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKGROUND = "#0B0D16"
EMBER = "#FF626A"
VIOLET = "#8D7CFF"
# The mark runs light coral at the top-left through ember to violet.
BODY_STOPS = ((0, "#FF9480"), (0.45, "#FF5470"), (1, VIOLET))
BODY_LINE = ((130, 110), (380, 400))
# The play button's darker underside, drawn a little below it for depth.
EXTRUSION, EXTRUSION_DEPTH = "#7A2346", 12
# A rounded play triangle, nudged left so it sits optically centred.
TRIANGLE = ((144, 112), (144, 400), (394, 256))
CORNER_RADIUS = 46
# The heartbeat: flat, a small dip, a deep beat, a high beat, flat again.
PULSE = ((100, 262), (176, 262), (198, 214), (230, 318), (262, 186),
         (286, 262), (420, 262))
PULSE_WIDTH = 24
# Highlights: a soft sheen over the top-left and one specular ellipse,
# as (centre x, centre y, radius x, radius y, rotation).
SHEEN_CENTRE, SHEEN_RADIUS = (231, 184), 210
SPECULAR = (206, 168, 44, 18, 30)
# Every point of the mark lies within 183 of the centre, inside the PWA
# maskable safe circle (radius 204.8). The adaptive foreground's 108dp
# canvas shows only 72dp and keeps 66dp safe, so it is drawn at 0.8.
ADAPTIVE_SCALE, FAVICON_SCALE = 0.8, 1.15
# "Listening at night": two soft lights behind the mark, ember low-left and
# violet high-right, as (colour, centre x, centre y, radius, opacity).
LIGHTS = ((EMBER, 190, 330, 300, 0.34), (VIOLET, 330, 190, 280, 0.34))


def _rounded_triangle():
    from shapely.geometry import Polygon

    points = []
    for i, corner in enumerate(TRIANGLE):
        before, after = TRIANGLE[i - 1], TRIANGLE[(i + 1) % len(TRIANGLE)]

        def toward(target):
            dx, dy = target[0] - corner[0], target[1] - corner[1]
            length = (dx * dx + dy * dy) ** 0.5
            return (corner[0] + dx / length * CORNER_RADIUS,
                    corner[1] + dy / length * CORNER_RADIUS)

        start, end = toward(before), toward(after)
        for step in range(17):
            t = step / 16
            points.append(tuple(
                (1 - t) ** 2 * s + 2 * (1 - t) * t * c + t ** 2 * e
                for s, c, e in zip(start, corner, end)))
    return Polygon(points)


def _path(geometry) -> str:
    polygons = getattr(geometry, 'geoms', [geometry])
    parts = []
    for polygon in polygons:
        for ring in [polygon.exterior, *polygon.interiors]:
            xy = list(ring.coords)[:-1]
            parts.append('M' + 'L'.join(f'{x:.1f} {y:.1f}' for x, y in xy) + 'Z')
    return ''.join(parts)


def shapes() -> dict[str, str]:
    """SVG path data for the mark, its underside and the specular highlight."""
    from shapely import affinity
    from shapely.geometry import LineString, Point

    pulse = LineString(PULSE).buffer(PULSE_WIDTH / 2, quad_segs=8)
    mark = _rounded_triangle().difference(pulse)
    x, y, rx, ry, angle = SPECULAR
    specular = affinity.rotate(
        affinity.scale(Point(x, y).buffer(1, quad_segs=16), rx, ry), angle)
    return {'mark': _path(mark),
            'extrusion': _path(affinity.translate(mark, 0, EXTRUSION_DEPTH)),
            'specular': _path(specular)}


def scaled(scale: float) -> str:
    return f'translate(256 256) scale({scale}) translate(-256 -256)'


def icon_svg(s: dict[str, str]) -> str:
    (x1, y1), (x2, y2) = BODY_LINE
    lights = ''.join(
        f'    <radialGradient id="light{i}" gradientUnits="userSpaceOnUse"'
        f' cx="{x}" cy="{y}" r="{r}">'
        f'<stop stop-color="{c}" stop-opacity="{a}"/>'
        f'<stop offset="1" stop-color="{c}" stop-opacity="0"/></radialGradient>\n'
        for i, (c, x, y, r, a) in enumerate(LIGHTS))
    body = ''.join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in BODY_STOPS)
    sx, sy = SHEEN_CENTRE
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
        '  <title>rhythmo</title>\n'
        '  <defs>\n' + lights +
        f'    <linearGradient id="body" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}"'
        f' x2="{x2}" y2="{y2}">{body}</linearGradient>\n'
        f'    <radialGradient id="sheen" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{sy}"'
        f' r="{SHEEN_RADIUS}"><stop stop-color="#fff" stop-opacity=".35"/>'
        '<stop offset=".5" stop-color="#fff" stop-opacity="0"/></radialGradient>\n'
        '    <linearGradient id="specular" x2="0" y2="1"><stop stop-color="#fff" stop-opacity=".7"/>'
        '<stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>\n'
        '    <radialGradient id="floor"><stop stop-color="#000" stop-opacity=".6"/>'
        '<stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>\n'
        '  </defs>\n'
        f'  <rect width="512" height="512" fill="{BACKGROUND}"/>\n'
        '  <rect width="512" height="512" fill="url(#light0)"/>\n'
        '  <rect width="512" height="512" fill="url(#light1)"/>\n'
        '  <ellipse cx="250" cy="432" rx="150" ry="24" fill="url(#floor)"/>\n'
        f'  <path fill="{EXTRUSION}" d="{s["extrusion"]}"/>\n'
        f'  <path fill="url(#body)" d="{s["mark"]}"/>\n'
        f'  <path fill="url(#sheen)" d="{s["mark"]}"/>\n'
        f'  <path fill="url(#specular)" d="{s["specular"]}"/>\n'
        '</svg>\n'
    )


def favicon_svg(s: dict[str, str]) -> str:
    """Flat colours, a rounded tile and a bigger mark for tab-sized icons."""
    (x1, y1), (x2, y2) = BODY_LINE
    body = ''.join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in BODY_STOPS)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
        '  <title>rhythmo</title>\n'
        f'  <defs><linearGradient id="body" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}"'
        f' x2="{x2}" y2="{y2}">{body}</linearGradient></defs>\n'
        f'  <rect width="512" height="512" rx="112" fill="{BACKGROUND}"/>\n'
        f'  <path transform="{scaled(FAVICON_SCALE)}" fill="url(#body)" d="{s["mark"]}"/>\n'
        '</svg>\n'
    )


def argb(colour: str, alpha: float = 1.0) -> str:
    return f'#{round(alpha * 255):02X}{colour[1:].upper()}'


def vector(body: str, size: str = '108dp') -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by tool/generate_icons.py: rhythmo pulse play. -->\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    xmlns:aapt="http://schemas.android.com/aapt"\n'
        f'    android:width="{size}" android:height="{size}"\n'
        '    android:viewportWidth="512" android:viewportHeight="512">\n'
        + body +
        '</vector>\n'
    )


def gradient_path(path: str, gradient: str) -> str:
    return (
        f'    <path android:pathData="{path}">\n'
        '      <aapt:attr name="android:fillColor">\n'
        f'        {gradient}\n'
        '      </aapt:attr>\n'
        '    </path>\n'
    )


def adaptive_foreground_xml(s: dict[str, str]) -> str:
    (x1, y1), (x2, y2) = BODY_LINE
    sx, sy = SHEEN_CENTRE
    body = ''.join(f'<item android:offset="{o}" android:color="{argb(c)}"/>'
                   for o, c in BODY_STOPS)
    x, y, _, ry, _ = SPECULAR
    return vector(
        '  <group android:pivotX="256" android:pivotY="256"\n'
        f'      android:scaleX="{ADAPTIVE_SCALE}" android:scaleY="{ADAPTIVE_SCALE}">\n'
        f'    <path android:fillColor="{argb(EXTRUSION)}" android:pathData="{s["extrusion"]}"/>\n'
        + gradient_path(s['mark'],
                        f'<gradient android:type="linear" android:startX="{x1}"'
                        f' android:startY="{y1}" android:endX="{x2}" android:endY="{y2}">'
                        f'{body}</gradient>')
        + gradient_path(s['mark'],
                        f'<gradient android:type="radial" android:centerX="{sx}"'
                        f' android:centerY="{sy}" android:gradientRadius="{SHEEN_RADIUS}">'
                        f'<item android:offset="0" android:color="{argb("#FFFFFF", .35)}"/>'
                        f'<item android:offset="0.5" android:color="{argb("#FFFFFF", 0)}"/>'
                        f'<item android:offset="1" android:color="{argb("#FFFFFF", 0)}"/>'
                        '</gradient>')
        + gradient_path(s['specular'],
                        f'<gradient android:type="linear" android:startX="{x}"'
                        f' android:startY="{y - ry - 10}" android:endX="{x}"'
                        f' android:endY="{y + ry + 10}">'
                        f'<item android:offset="0" android:color="{argb("#FFFFFF", .7)}"/>'
                        f'<item android:offset="1" android:color="{argb("#FFFFFF", 0)}"/>'
                        '</gradient>')
        + '  </group>\n'
    )


def adaptive_background_xml() -> str:
    square = 'M0 0H512V512H0Z'
    lights = ''.join(
        gradient_path(square,
                      f'<gradient android:type="radial" android:centerX="{x}"'
                      f' android:centerY="{y}" android:gradientRadius="{r}">'
                      f'<item android:offset="0" android:color="{argb(c, a)}"/>'
                      f'<item android:offset="1" android:color="{argb(c, 0)}"/>'
                      '</gradient>')
        for c, x, y, r, a in LIGHTS)
    return vector(
        f'  <path android:fillColor="{argb(BACKGROUND)}" android:pathData="{square}"/>\n'
        + lights)


def adaptive_monochrome_xml(s: dict[str, str]) -> str:
    """Android 13+ themed icons tint this layer, so only its alpha matters."""
    return vector(
        '  <group android:pivotX="256" android:pivotY="256"\n'
        f'      android:scaleX="{ADAPTIVE_SCALE}" android:scaleY="{ADAPTIVE_SCALE}">\n'
        f'    <path android:fillColor="#FF000000" android:pathData="{s["mark"]}"/>\n'
        '  </group>\n')


ADAPTIVE_ICON_XML = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- Generated by tool/generate_icons.py: rhythmo pulse play. -->\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '  <background android:drawable="@drawable/ic_launcher_background"/>\n'
    '  <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
    '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
    '</adaptive-icon>\n'
)


def notification_xml(s: dict[str, str]) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by tool/generate_icons.py: rhythmo pulse play. -->\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="24dp" android:height="24dp"\n'
        '    android:viewportWidth="512" android:viewportHeight="512">\n'
        f'  <path android:fillColor="#FFFFFFFF" android:pathData="{s["mark"]}"/>\n'
        '</vector>\n'
    )


def main() -> None:
    import cairosvg

    s = shapes()
    svg = icon_svg(s)
    res = ROOT / 'android/app/src/main/res'
    texts = {
        ROOT / 'web/icons/icon.svg': svg,
        ROOT / 'web/icons/favicon.svg': favicon_svg(s),
        ROOT / 'store/tools/icon.html': (
            '<!doctype html><html><body style="margin:0;background:transparent">'
            + svg.replace('<svg ', '<svg width="512" height="512" ', 1)
            + '</body></html>\n'),
        res / 'drawable/ic_stat_rhythmo.xml': notification_xml(s),
        res / 'drawable/ic_launcher_foreground.xml': adaptive_foreground_xml(s),
        res / 'drawable/ic_launcher_background.xml': adaptive_background_xml(),
        res / 'drawable/ic_launcher_monochrome.xml': adaptive_monochrome_xml(s),
        res / 'mipmap-anydpi-v26/ic_launcher.xml': ADAPTIVE_ICON_XML,
    }
    for path, text in texts.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
    targets = {'assets/icon/rhythmo.png': 288,
               'server/internal/httpapi/public/rhythmo.png': 288,
               'store/listing/icon-512.png': 512,
               'web/icons/icon-192.png': 192, 'web/icons/icon-512.png': 512}
    # Launchers older than Android 8 use these instead of the adaptive icon.
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                          ('xxhdpi', 144), ('xxxhdpi', 192)]:
        targets[f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'] = size
    for path, size in targets.items():
        cairosvg.svg2png(bytestring=svg.encode(), write_to=str(ROOT / path),
                        output_width=size, output_height=size)


if __name__ == '__main__':
    main()
