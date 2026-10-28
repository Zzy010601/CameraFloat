"""CameraFloat · 摄像头悬浮窗（Windows / 跨平台版本）

与 macOS 原生版功能对齐：
  * 无边框圆角悬浮窗，可任意拖动、缩放（最小 90x90，最大 1600 宽）
  * 画布式取景：拖动画面平移视角，滚轮以光标为锚点缩放 1~6 倍
  * 四种贴合方式：右固定 / 左固定 / 居中裁切 / 自适应（完整显示）
  * 镜像（后视镜）、多摄像头源切换（内置 / USB / 虚拟摄像头）
  * 随时开关摄像头、可切换置顶
  * 状态持久化、托盘常驻、右键菜单

依赖：pip install PySide6
运行：python camera_float.py
"""

from __future__ import annotations

import sys
from enum import Enum

from PySide6.QtCore import (
    QPoint,
    QPointF,
    QRect,
    QRectF,
    QSettings,
    QSize,
    Qt,
    QTimer,
    QVariantAnimation,
)
from PySide6.QtGui import (
    QAction,
    QActionGroup,
    QColor,
    QFont,
    QGuiApplication,
    QIcon,
    QImage,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QTransform,
)
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon, QWidget
from PySide6.QtMultimedia import (
    QCamera,
    QCameraDevice,
    QMediaCaptureSession,
    QMediaDevices,
    QVideoSink,
)

# ---------------------------------------------------------------- 常量

MIN_W, MIN_H = 90, 90
MAX_W = 1600
EDGE = 12               # 边缘缩放热区
RADIUS = 14             # 圆角
DEFAULT_W, DEFAULT_H = 480, 270
MIN_ZOOM, MAX_ZOOM = 1.0, 6.0

BAR_H = 30
BTN_SIZE = 22
BTN_GAP = 4
BAR_PAD = 6
MODE_BTN = 34

FADE_MS = 180
BAR_LINGER_MS = 1600    # 鼠标移出后控制条停留时间
BAR_HOLD_MS = 2600      # 无交互自动淡出时间


class FrameAnchor(Enum):
    """窗口与画面比例不一致时的贴合策略"""

    RIGHT = "right"
    LEFT = "left"
    CENTER = "center"
    CONTAIN = "contain"

    @property
    def title(self) -> str:
        return {
            FrameAnchor.RIGHT: "右固定（裁左边）",
            FrameAnchor.LEFT: "左固定（裁右边）",
            FrameAnchor.CENTER: "居中裁切（两边都裁）",
            FrameAnchor.CONTAIN: "自适应（完整显示）",
        }[self]


class DragMode(Enum):
    """鼠标拖动的作用对象"""

    PAN = "pan"
    WINDOW = "window"

    @property
    def title(self) -> str:
        return {
            DragMode.PAN: "拖动画面视角",
            DragMode.WINDOW: "拖动整个窗口",
        }[self]


def _enum(cls, raw, default):
    """从配置字符串还原枚举，非法值回落到默认值"""
    try:
        return cls(str(raw))
    except (ValueError, TypeError):
        return default


def _font(size: int, bold: bool = False) -> QFont:
    f = QFont()
    f.setFamilies(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "Segoe UI"])
    f.setPixelSize(size)
    f.setBold(bold)
    return f


# ---------------------------------------------------------------- 主窗口


class CameraFloat(QWidget):
    def __init__(self) -> None:
        super().__init__(None)
        self._settings = QSettings("CameraFloat", "CameraFloat")

        # ---- 状态 ----
        self._image: QImage | None = None
        self._aspect = 16 / 9
        self._zoom = min(MAX_ZOOM, max(MIN_ZOOM, float(self._settings.value("framing/zoom", 1.0))))
        self._pan = QPointF(
            float(self._settings.value("framing/panX", 0.0)),
            float(self._settings.value("framing/panY", 0.0)),
        )
        self._mirror = bool(self._settings.value("view/mirror", True, type=bool))
        self._on_top = bool(self._settings.value("view/onTop", False, type=bool))
        self._anchor = _enum(FrameAnchor, self._settings.value("view/anchor", "right"), FrameAnchor.RIGHT)
        self._drag_mode = _enum(DragMode, self._settings.value("view/dragMode", "pan"), DragMode.PAN)

        # ---- 交互中间态 ----
        self._drag_kind: str | None = None       # "move" / "pan" / "resize"
        self._edges: set[str] = set()
        self._press_global = QPoint()
        self._press_geom = QRect()
        self._press_pan = QPointF()
        self._hover_button: str | None = None
        self._controls_alpha = 0.0
        self._fade: QVariantAnimation | None = None
        self._hide_timer = QTimer(self)
        self._hide_timer.setSingleShot(True)
        self._hide_timer.timeout.connect(lambda: self._fade_controls(0.0))
        self._status_text = ""

        # ---- 窗口 ----
        self.setWindowTitle("摄像头悬浮窗")
        self.setWindowIcon(self._make_icon())
        self._apply_window_flags()
        self.setAttribute(Qt.WA_TranslucentBackground, True)
        self.setMinimumSize(MIN_W, MIN_H)
        self.setMouseTracking(True)
        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self._show_menu)

        geo = self._restored_geometry()
        self.setGeometry(geo)

        # ---- 摄像头 ----
        self._sink = QVideoSink()
        self._session = QMediaCaptureSession()
        self._camera: QCamera | None = None
        self._current_device: QCameraDevice | None = None
        self._camera_on = False
        self._device_error = ""
        self._sink.videoFrameChanged.connect(self._on_frame)
        self._session.setVideoSink(self._sink)
        self._use_default_camera()

        # ---- 托盘 ----
        self._tray = QSystemTrayIcon(self._make_icon(), self)
        self._tray.setToolTip("摄像头悬浮窗")
        self._tray.activated.connect(self._on_tray_activated)
        self._rebuild_menu()
        self._tray.show()

        self._reveal_controls()

    # ------------------------------------------------------------ 窗口基础

    def _apply_window_flags(self) -> None:
        flags = Qt.Window | Qt.FramelessWindowHint
        if self._on_top:
            flags |= Qt.WindowStaysOnTopHint
        self.setWindowFlags(flags)

    def _make_icon(self) -> QIcon:
        """程序内绘制图标，避免依赖外部资源文件"""
        pm = QPixmap(128, 128)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing, True)

        grad = QColor(52, 92, 190)
        path = QPainterPath()
        path.addRoundedRect(QRectF(6, 6, 116, 116), 26, 26)
        p.fillPath(path, grad)

        p.setPen(Qt.NoPen)
        p.setBrush(QColor(240, 246, 255))
        p.drawRoundedRect(QRectF(26, 44, 76, 46), 10, 10)
        p.drawRoundedRect(QRectF(44, 34, 24, 12), 5, 5)
        p.setBrush(QColor(52, 92, 190))
        p.drawEllipse(QPointF(64, 67), 13, 13)
        p.setBrush(QColor(240, 246, 255))
        p.drawEllipse(QPointF(64, 67), 6, 6)
        p.end()
        return QIcon(pm)

    def _restored_geometry(self) -> QRect:
        saved = self._settings.value("window/geometry")
        if isinstance(saved, QRect) and saved.width() >= MIN_W and saved.height() >= MIN_H:
            for screen in QGuiApplication.screens():
                inter = screen.availableGeometry().intersected(saved)
                if inter.width() >= 80 and inter.height() >= 60:
                    return saved
        screen = QGuiApplication.primaryScreen().availableGeometry()
        return QRect(
            screen.right() - DEFAULT_W - 40,
            screen.top() + 40,
            DEFAULT_W,
            DEFAULT_H,
        )

    def _persist_geometry(self) -> None:
        self._settings.setValue("window/geometry", self.geometry())

    def _persist_framing(self) -> None:
        self._settings.setValue("framing/zoom", self._zoom)
        self._settings.setValue("framing/panX", self._pan.x())
        self._settings.setValue("framing/panY", self._pan.y())

    # ------------------------------------------------------------ 摄像头

    def _use_default_camera(self) -> None:
        device = QMediaDevices.defaultVideoInput()
        if device.isNull():
            devices = QMediaDevices.videoInputs()
            device = devices[0] if devices else QCameraDevice()
        self._set_device(device)

    def _set_device(self, device: QCameraDevice) -> None:
        if self._camera is not None:
            self._camera.stop()
            self._session.setCamera(None)
            self._camera.deleteLater()
            self._camera = None
        if device.isNull():
            self._current_device = None
            self._device_error = "未检测到摄像头"
            self._camera_on = False
            self.update()
            return
        self._device_error = ""
        self._current_device = device
        camera = QCamera(device)
        camera.errorOccurred.connect(self._on_camera_error)
        self._session.setCamera(camera)
        self._camera = camera
        if self._camera_on:
            camera.start()

    def _on_camera_error(self, _error, message: str) -> None:
        self._device_error = message or "摄像头不可用"
        self._camera_on = False
        self.update()

    def toggle_camera(self) -> None:
        self.set_camera_on(not self._camera_on)

    def set_camera_on(self, on: bool) -> None:
        self._camera_on = on
        if self._camera is None:
            self._use_default_camera()
        if self._camera is not None:
            if on:
                self._camera.start()
            else:
                self._camera.stop()
                self._image = None
        self._rebuild_menu()
        self._reveal_controls()
        self.update()

    def _on_frame(self, frame) -> None:
        if not frame.isValid():
            return
        image = frame.toImage()
        if image.isNull():
            return
        self._image = image
        if image.height() > 0:
            self._aspect = image.width() / image.height()
        self.update()

    def _switch_device(self, device: QCameraDevice) -> None:
        self._set_device(device)
        if self._camera_on and self._camera is not None:
            self._camera.start()
        self._rebuild_menu()
        self.update()

    # ------------------------------------------------------------ 布局计算

    def _video_rect(self, pan: QPointF | None = None, zoom: float | None = None) -> QRectF:
        """画面在窗口内的绘制矩形：基准尺寸 × 缩放 + 偏移，并夹紧不露黑边"""
        pan = self._pan if pan is None else pan
        zoom = self._zoom if zoom is None else zoom
        w, h = float(self.width()), float(self.height())
        a = max(0.2, self._aspect)

        if self._anchor is FrameAnchor.CONTAIN:
            if w / h >= a:
                vw, vh = h * a, h
            else:
                vw, vh = w, w / a
        else:
            if h * a >= w:
                vw, vh = h * a, h
            else:
                vw, vh = w, w / a

        vw *= zoom
        vh *= zoom

        if vw <= w + 0.5:
            x = (w - vw) / 2
        else:
            if self._anchor is FrameAnchor.LEFT:
                dx = 0.0
            elif self._anchor is FrameAnchor.CENTER:
                dx = (w - vw) / 2
            else:
                dx = w - vw
            x = min(0.0, max(w - vw, dx + pan.x()))

        if vh <= h + 0.5:
            y = (h - vh) / 2
        else:
            dy = (h - vh) / 2
            y = min(0.0, max(h - vh, dy + pan.y()))

        return QRectF(x, y, vw, vh)

    def _clamp_pan(self) -> None:
        """把平移量收敛到合法范围，避免越界后积攒无效位移"""
        rect = self._video_rect()
        w, h = float(self.width()), float(self.height())
        if rect.width() <= w + 0.5:
            self._pan.setX(0.0)
        if rect.height() <= h + 0.5:
            self._pan.setY(0.0)
        if rect.width() > w + 0.5:
            if self._anchor is FrameAnchor.LEFT:
                dx = 0.0
            elif self._anchor is FrameAnchor.CENTER:
                dx = (w - rect.width()) / 2
            else:
                dx = w - rect.width()
            self._pan.setX(rect.x() - dx)
        if rect.height() > h + 0.5:
            self._pan.setY(rect.y() - (h - rect.height()) / 2)

    def _bar_rect(self) -> QRectF:
        width = BAR_PAD * 2 + BTN_SIZE * 3 + BTN_GAP * 2
        width = min(width, max(64.0, self.width() - 16.0))
        return QRectF((self.width() - width) / 2, self.height() - BAR_H - 14, width, BAR_H)

    def _bar_buttons(self) -> list[tuple[str, QRectF]]:
        bar = self._bar_rect()
        scale = bar.width() / (BAR_PAD * 2 + BTN_SIZE * 3 + BTN_GAP * 2)
        bw = BTN_SIZE * scale
        bh = BTN_SIZE * scale
        x = bar.x() + BAR_PAD * scale
        y = bar.center().y() - bh / 2
        out = []
        for name in ("camera", "pin", "close"):
            out.append((name, QRectF(x, y, bw, bh)))
            x += bw + BTN_GAP * scale
        return out

    def _mode_rect(self) -> QRectF:
        size = min(MODE_BTN, max(22.0, min(self.width(), self.height()) * 0.42))
        return QRectF(
            (self.width() - size) / 2,
            (self.height() - size) / 2,
            size,
            size,
        )

    # ------------------------------------------------------------ 绘制

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        p.setRenderHint(QPainter.SmoothPixmapTransform, True)
        p.setRenderHint(QPainter.TextAntialiasing, True)

        frame = QRectF(self.rect())
        clip = QPainterPath()
        clip.addRoundedRect(frame, RADIUS, RADIUS)
        p.setClipPath(clip)
        p.fillPath(clip, QColor(14, 17, 22))

        rect = self._video_rect()
        if self._image is not None and self._camera_on:
            p.save()
            if self._mirror:
                t = QTransform()
                t.translate(2 * rect.center().x(), 0)
                t.scale(-1, 1)
                p.setTransform(t, True)
            p.drawImage(rect, self._image, QRectF(self._image.rect()))
            p.restore()
        else:
            self._draw_placeholder(p, frame)

        p.setClipping(False)
        self._draw_border(p, frame)

        if self._controls_alpha > 0.01:
            p.setOpacity(self._controls_alpha)
            self._draw_controls(p)

    def _draw_border(self, p: QPainter, frame: QRectF) -> None:
        pen = QPen(QColor(255, 255, 255, 40), 1)
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(frame.adjusted(0.5, 0.5, -0.5, -0.5), RADIUS, RADIUS)

    def _draw_placeholder(self, p: QPainter, frame: QRectF) -> None:
        cx, cy = frame.center().x(), frame.center().y()
        # 上下让开画面中央的拖动模式按钮，避免叠在一起
        offset = max(26.0, min(52.0, frame.height() * 0.18))

        # 相机轮廓
        p.save()
        p.translate(cx, cy - offset)
        p.setBrush(Qt.NoBrush)
        p.setPen(QPen(QColor(230, 238, 250, 130), 2))
        p.drawRoundedRect(QRectF(-15, -8, 30, 20), 5, 5)
        p.drawRoundedRect(QRectF(-5, -14, 10, 6), 3, 3)
        p.drawEllipse(QPointF(0, 2), 5, 5)
        p.restore()

        text = self._device_error or ("摄像头已关闭" if not self._camera_on else "正在启动摄像头…")
        p.setPen(QColor(200, 212, 228, 170))
        p.setFont(_font(max(10, int(min(frame.height() * 0.05, 13)))))
        p.drawText(
            QRectF(0, cy + offset - 10, self.width(), 22),
            Qt.AlignHCenter | Qt.AlignTop,
            text,
        )

    def _draw_controls(self, p: QPainter) -> None:
        bar = self._bar_rect()
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(0, 0, 0, 185))
        p.drawRoundedRect(bar, 11, 11)
        p.setBrush(Qt.NoBrush)
        p.setPen(QPen(QColor(255, 255, 255, 60), 1))
        p.drawRoundedRect(bar, 11, 11)
        p.setPen(Qt.NoPen)

        for name, rect in self._bar_buttons():
            if self._hover_button == name:
                p.setBrush(QColor(255, 255, 255, 40))
                p.drawRoundedRect(rect, 6, 6)
            p.setBrush(Qt.NoBrush)
            if name == "camera":
                self._icon_camera(p, rect, self._camera_on)
            elif name == "pin":
                self._icon_pin(p, rect, self._on_top)
            else:
                self._icon_close(p, rect)

        mode = self._mode_rect()
        active = self._drag_mode is DragMode.WINDOW
        p.setBrush(QColor(46, 108, 226) if active else QColor(8, 12, 18, 205))
        p.setPen(Qt.NoPen)
        p.drawEllipse(mode)
        p.setBrush(Qt.NoBrush)
        p.setPen(QPen(QColor(255, 255, 255, 150 if active else 110), 1))
        p.drawEllipse(mode)
        p.setPen(Qt.NoPen)
        if active:
            self._icon_window(p, mode, QColor(255, 255, 255))
        else:
            self._icon_move(p, mode, QColor(240, 246, 255))

    # ---- 图标绘制 ----

    def _icon_camera(self, p: QPainter, r: QRectF, on: bool) -> None:
        color = QColor(255, 255, 255) if on else QColor(255, 255, 255, 120)
        p.save()
        p.translate(r.center())
        s = min(r.width(), r.height()) / 22
        p.scale(s, s)
        p.setPen(QPen(color, 1.6))
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(QRectF(-8, -5, 16, 11), 3, 3)
        p.drawRoundedRect(QRectF(-2.5, -8.5, 6, 4), 2, 2)
        if on:
            p.setBrush(color)
            p.drawEllipse(QPointF(0, 0.5), 3, 3)
            p.setBrush(Qt.NoBrush)
        else:
            p.drawLine(QPointF(-7, 6), QPointF(7, -7))
        p.restore()

    def _icon_pin(self, p: QPainter, r: QRectF, on: bool) -> None:
        """置顶图标：一条顶边 + 向上的箭头（钉到最上层）"""
        color = QColor(255, 255, 255) if on else QColor(255, 255, 255, 120)
        p.save()
        p.translate(r.center())
        s = min(r.width(), r.height()) / 22
        p.scale(s, s)
        p.setPen(QPen(color, 1.6))
        p.drawLine(QPointF(-7, -8), QPointF(7, -8))
        if on:
            p.setBrush(color)
            p.setPen(Qt.NoPen)
            path = QPainterPath()
            path.moveTo(0, -5)
            path.lineTo(5, 1)
            path.lineTo(2, 1)
            path.lineTo(2, 8)
            path.lineTo(-2, 8)
            path.lineTo(-2, 1)
            path.lineTo(-5, 1)
            path.closeSubpath()
            p.drawPath(path)
        else:
            p.setBrush(Qt.NoBrush)
            p.drawLine(QPointF(0, -4), QPointF(0, 8))
            p.drawLine(QPointF(0, -5), QPointF(-4, -1))
            p.drawLine(QPointF(0, -5), QPointF(4, -1))
        p.restore()

    def _icon_close(self, p: QPainter, r: QRectF) -> None:
        p.save()
        p.translate(r.center())
        s = min(r.width(), r.height()) / 22
        p.scale(s, s)
        p.setPen(QPen(QColor(255, 255, 255, 170), 1.7))
        p.drawLine(QPointF(-5, -5), QPointF(5, 5))
        p.drawLine(QPointF(5, -5), QPointF(-5, 5))
        p.restore()

    def _icon_move(self, p: QPainter, r: QRectF, color: QColor) -> None:
        p.save()
        p.translate(r.center())
        s = min(r.width(), r.height()) / 22
        p.scale(s, s)
        p.setPen(QPen(color, 1.6))
        p.drawLine(QPointF(-7, 0), QPointF(7, 0))
        p.drawLine(QPointF(0, -7), QPointF(0, 7))
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            tip = QPointF(7 * dx, 7 * dy)
            back = QPointF(4 * dx, 4 * dy)
            if dx:
                p.drawLine(tip, QPointF(back.x(), -3))
                p.drawLine(tip, QPointF(back.x(), 3))
            else:
                p.drawLine(tip, QPointF(-3, back.y()))
                p.drawLine(tip, QPointF(3, back.y()))
        p.restore()

    def _icon_window(self, p: QPainter, r: QRectF, color: QColor) -> None:
        p.save()
        p.translate(r.center())
        s = min(r.width(), r.height()) / 22
        p.scale(s, s)
        p.setPen(QPen(color, 1.6))
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(QRectF(-8, -7, 16, 14), 3, 3)
        p.drawLine(QPointF(-8, -2.5), QPointF(8, -2.5))
        p.restore()

    # ------------------------------------------------------------ 控制条淡入淡出

    def _fade_controls(self, target: float) -> None:
        if self._fade is not None:
            self._fade.stop()
        anim = QVariantAnimation(self)
        anim.setStartValue(self._controls_alpha)
        anim.setEndValue(target)
        anim.setDuration(FADE_MS)

        def on_value(value):
            self._controls_alpha = float(value)
            self.update()

        anim.valueChanged.connect(on_value)
        anim.start()
        self._fade = anim

    def _reveal_controls(self) -> None:
        self._fade_controls(1.0)
        self._hide_timer.start(BAR_HOLD_MS)

    def enterEvent(self, event) -> None:
        self._fade_controls(1.0)
        self._hide_timer.start(BAR_HOLD_MS)
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self._hide_timer.start(BAR_LINGER_MS)
        self._hover_button = None
        self.update()
        super().leaveEvent(event)

    # ------------------------------------------------------------ 鼠标

    def _hit_button(self, pos: QPointF) -> str | None:
        if self._controls_alpha < 0.5:
            return None
        if self._mode_rect().contains(pos):
            return "mode"
        if self._bar_rect().contains(pos):
            for name, rect in self._bar_buttons():
                if rect.adjusted(-2, -2, 2, 2).contains(pos):
                    return name
        return None

    def _edges_at(self, pos: QPointF) -> set[str]:
        edges: set[str] = set()
        if pos.x() <= EDGE:
            edges.add("left")
        if pos.x() >= self.width() - EDGE:
            edges.add("right")
        if pos.y() <= EDGE:
            edges.add("top")
        if pos.y() >= self.height() - EDGE:
            edges.add("bottom")
        return edges

    def _update_cursor(self, pos: QPointF) -> None:
        button = self._hit_button(pos)
        if button is not None:
            self.setCursor(Qt.PointingHandCursor)
            return
        edges = self._edges_at(pos)
        cursors = {
            frozenset({"left"}): Qt.SizeHorCursor,
            frozenset({"right"}): Qt.SizeHorCursor,
            frozenset({"top"}): Qt.SizeVerCursor,
            frozenset({"bottom"}): Qt.SizeVerCursor,
            frozenset({"left", "top"}): Qt.SizeFDiagCursor,
            frozenset({"right", "bottom"}): Qt.SizeFDiagCursor,
            frozenset({"right", "top"}): Qt.SizeBDiagCursor,
            frozenset({"left", "bottom"}): Qt.SizeBDiagCursor,
        }
        if edges:
            self.setCursor(cursors.get(frozenset(edges), Qt.SizeAllCursor))
        else:
            self.setCursor(Qt.OpenHandCursor if self._drag_mode is DragMode.PAN else Qt.SizeAllCursor)

    def mousePressEvent(self, event) -> None:
        pos = event.position()
        if event.button() != Qt.LeftButton:
            return super().mousePressEvent(event)

        button = self._hit_button(pos)
        if button is not None:
            self._drag_kind = None
            return

        self._press_global = event.globalPosition().toPoint()
        self._press_geom = self.geometry()
        self._press_pan = QPointF(self._pan)
        edges = self._edges_at(pos)
        if edges:
            self._drag_kind = "resize"
            self._edges = edges
        elif event.modifiers() & (Qt.ControlModifier | Qt.AltModifier):
            # Ctrl / Alt + 拖动：任何模式下都临时移动窗口
            self._drag_kind = "move"
        elif self._drag_mode is DragMode.PAN:
            self._drag_kind = "pan"
        else:
            self._drag_kind = "move"

    def mouseMoveEvent(self, event) -> None:
        pos = event.position()
        if self._drag_kind is None:
            previous = self._hover_button
            self._hover_button = self._hit_button(pos)
            self._update_cursor(pos)
            if previous != self._hover_button:
                self.update()
            return

        delta = event.globalPosition().toPoint() - self._press_global
        if self._drag_kind == "move":
            self.move(self._press_geom.topLeft() + delta)
        elif self._drag_kind == "pan":
            self._pan = self._press_pan + QPointF(delta)
            self._clamp_pan()
            self.update()
            self._persist_framing()
        elif self._drag_kind == "resize":
            self._resize_by(delta)

    def mouseReleaseEvent(self, event) -> None:
        if event.button() != Qt.LeftButton:
            return super().mouseReleaseEvent(event)
        if self._drag_kind is None:
            button = self._hit_button(event.position())
            if button == "camera":
                self.toggle_camera()
            elif button == "pin":
                self.toggle_on_top()
            elif button == "close":
                self.hide_window()
            elif button == "mode":
                self.set_drag_mode(
                    DragMode.WINDOW if self._drag_mode is DragMode.PAN else DragMode.PAN
                )
        self._drag_kind = None
        self._edges = set()
        self._persist_geometry()

    def _resize_by(self, delta: QPoint) -> None:
        g = QRect(self._press_geom)
        if "left" in self._edges:
            g.setLeft(min(g.left() + delta.x(), g.right() - MIN_W))
        if "right" in self._edges:
            g.setRight(max(g.right() + delta.x(), g.left() + MIN_W))
        if "top" in self._edges:
            g.setTop(min(g.top() + delta.y(), g.bottom() - MIN_H))
        if "bottom" in self._edges:
            g.setBottom(max(g.bottom() + delta.y(), g.top() + MIN_H))
        if g.width() > MAX_W:
            if "left" in self._edges:
                g.setLeft(g.right() - MAX_W)
            else:
                g.setRight(g.left() + MAX_W)
        self.setGeometry(g)
        self._clamp_pan()
        self.update()

    def mouseDoubleClickEvent(self, event) -> None:
        if self._hit_button(event.position()) is None:
            self.reset_framing()
        super().mouseDoubleClickEvent(event)

    def wheelEvent(self, event) -> None:
        steps = event.angleDelta().y() / 120.0
        if steps == 0:
            return
        if event.modifiers() & Qt.ControlModifier:
            self._zoom_window(1.0 + steps * 0.08)
            return
        self._zoom_at(1.0 + steps * 0.08, event.position())
        event.accept()

    def _zoom_window(self, factor: float) -> None:
        g = self.geometry()
        ratio = g.height() / max(1, g.width())
        width = min(MAX_W, max(MIN_W, g.width() * factor))
        height = max(MIN_H, width * ratio)
        right, center_y = g.right(), g.center().y()
        g.setWidth(width)
        g.setHeight(height)
        g.moveLeft(right - width + 1)
        g.moveTop(center_y - height // 2)
        self.setGeometry(g)
        self._clamp_pan()
        self.update()
        self._persist_geometry()

    def _zoom_at(self, factor: float, pos: QPointF) -> None:
        target = min(MAX_ZOOM, max(MIN_ZOOM, self._zoom * factor))
        if abs(target - self._zoom) < 1e-4:
            return
        before = self._video_rect(pan=QPointF(0, 0))
        if before.width() <= 0 or before.height() <= 0:
            return
        u = min(1.0, max(0.0, (pos.x() - before.x()) / before.width()))
        v = min(1.0, max(0.0, (pos.y() - before.y()) / before.height()))

        self._zoom = target
        after = self._video_rect(pan=QPointF(0, 0))
        self._pan = QPointF(
            pos.x() - u * after.width() - after.x(),
            pos.y() - v * after.height() - after.y(),
        )
        self._clamp_pan()
        self.update()
        self._persist_framing()

    # ------------------------------------------------------------ 键盘

    def keyPressEvent(self, event) -> None:
        key = event.key()
        if key == Qt.Key_Space:
            self.toggle_camera()
            return
        if key == Qt.Key_Escape:
            self.hide_window()
            return
        if event.modifiers() & Qt.ControlModifier:
            if key == Qt.Key_0:
                self.reset_framing()
                return
            if key == Qt.Key_W:
                self.hide_window()
                return
            if key == Qt.Key_Q:
                self.quit_app()
                return
        super().keyPressEvent(event)

    # ------------------------------------------------------------ 配置动作

    def set_drag_mode(self, mode: DragMode) -> None:
        self._drag_mode = mode
        self._settings.setValue("view/dragMode", mode.value)
        self._rebuild_menu()
        self._reveal_controls()
        local = self.mapFromGlobal(self.cursor().pos())
        if self.rect().contains(local):
            self._update_cursor(QPointF(local))
        else:
            self.setCursor(Qt.OpenHandCursor if mode is DragMode.PAN else Qt.SizeAllCursor)
        self.update()

    def set_anchor(self, anchor: FrameAnchor) -> None:
        self._anchor = anchor
        self._settings.setValue("view/anchor", anchor.value)
        self._pan = QPointF(0, 0)
        self._clamp_pan()
        self._persist_framing()
        self._rebuild_menu()
        self.update()

    def set_mirror(self, on: bool) -> None:
        self._mirror = on
        self._settings.setValue("view/mirror", on)
        self._rebuild_menu()
        self.update()

    def toggle_mirror(self) -> None:
        self.set_mirror(not self._mirror)

    def toggle_on_top(self) -> None:
        geo = self.geometry()
        self._on_top = not self._on_top
        self._settings.setValue("view/onTop", self._on_top)
        self._apply_window_flags()
        self.setGeometry(geo)
        self.show()
        self.raise_()
        self.activateWindow()
        self._rebuild_menu()
        self.update()

    def reset_framing(self) -> None:
        self._zoom = 1.0
        self._pan = QPointF(0, 0)
        self._persist_framing()
        self.update()

    def reset_size(self) -> None:
        g = self.geometry()
        center = g.center()
        g.setWidth(DEFAULT_W)
        g.setHeight(DEFAULT_H)
        g.moveCenter(center)
        self.setGeometry(g)
        self._clamp_pan()
        self._persist_geometry()
        self.update()

    def hide_window(self) -> None:
        self._persist_geometry()
        self.hide()

    def show_window(self) -> None:
        self.show()
        self.raise_()
        self.activateWindow()
        self._reveal_controls()

    def quit_app(self) -> None:
        self._persist_geometry()
        self._persist_framing()
        self._tray.hide()
        QApplication.quit()

    # ------------------------------------------------------------ 菜单

    def _rebuild_menu(self) -> None:
        self._tray.setContextMenu(self._build_menu())

    def _build_menu(self) -> QMenu:
        menu = QMenu(self)

        show = menu.addAction("显示悬浮窗")
        show.triggered.connect(self.show_window)
        menu.addSeparator()

        cam = menu.addAction("关闭摄像头" if self._camera_on else "开启摄像头")
        cam.triggered.connect(self.toggle_camera)

        sources = menu.addMenu("摄像头源")
        devices = QMediaDevices.videoInputs()
        current = self._current_device
        if not devices:
            empty = sources.addAction("未检测到摄像头")
            empty.setEnabled(False)
        group = QActionGroup(sources)
        group.setExclusive(True)
        for device in devices:
            action = sources.addAction(device.description())
            action.setCheckable(True)
            action.setChecked(current is not None and device.id() == current.id())
            action.triggered.connect(lambda _=False, d=device: self._switch_device(d))
            group.addAction(action)

        mirror = menu.addAction("镜像画面（后视镜）")
        mirror.setCheckable(True)
        mirror.setChecked(self._mirror)
        mirror.triggered.connect(self.toggle_mirror)
        menu.addSeparator()

        anchors = menu.addMenu("缩放贴合方式")
        anchor_group = QActionGroup(anchors)
        for anchor in FrameAnchor:
            action = anchors.addAction(anchor.title)
            action.setCheckable(True)
            action.setChecked(anchor is self._anchor)
            action.triggered.connect(lambda _=False, a=anchor: self.set_anchor(a))
            anchor_group.addAction(action)

        drag = menu.addMenu("拖动模式")
        drag_group = QActionGroup(drag)
        for mode in DragMode:
            action = drag.addAction(mode.title)
            action.setCheckable(True)
            action.setChecked(mode is self._drag_mode)
            action.triggered.connect(lambda _=False, m=mode: self.set_drag_mode(m))
            drag_group.addAction(action)

        reset = menu.addAction("重置取景（缩放/位置）")
        reset.setShortcut("Ctrl+0")
        reset.triggered.connect(self.reset_framing)

        top = menu.addAction("置顶：开" if self._on_top else "置顶：关")
        top.triggered.connect(self.toggle_on_top)

        size = menu.addAction("重置窗口大小")
        size.triggered.connect(self.reset_size)
        menu.addSeparator()

        hint = menu.addAction("拖动＝当前拖动模式　Ctrl+拖动画面＝移动窗口　滚轮＝缩放")
        hint.setEnabled(False)
        menu.addSeparator()

        quit_action = menu.addAction("退出")
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.quit_app)
        return menu

    def _show_menu(self, pos: QPoint) -> None:
        self._build_menu().exec(self.mapToGlobal(pos))

    def _on_tray_activated(self, reason) -> None:
        if reason == QSystemTrayIcon.Trigger:
            if self.isVisible():
                self.hide_window()
            else:
                self.show_window()

    # ------------------------------------------------------------ 收尾

    def closeEvent(self, event) -> None:
        self._persist_geometry()
        self._persist_framing()
        if self._camera is not None:
            self._camera.stop()
        event.accept()
        QApplication.quit()


def main() -> int:
    QApplication.setApplicationName("CameraFloat")
    QApplication.setOrganizationName("CameraFloat")
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    window = CameraFloat()
    window.show()
    window.set_camera_on(True)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
