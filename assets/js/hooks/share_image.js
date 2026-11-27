// Draws the "Rolezinhos" share image onto a <canvas> and shares or downloads it.
//
// The element carrying the hook holds the data in attributes:
//   data-rows — JSON list of rows from `Rolezinho.MultiShare.to_image_rows/1`
//   data-host — the app's host, printed under the title and in the footer
//
// It renders a <canvas> child (preview) and listens for clicks on buttons with
// `data-share-image-action="share" | "download"` anywhere in the document whose
// `data-target` points at the hook element's id.
//
// The image is always in the light theme, whatever the app's current theme:
// a shared post should look the same for everyone. Canvas can't read Tailwind
// classes, and in dark mode the CSS variables resolve to the dark values, so
// the light palette is mirrored below.
// Paired source: the `colors` frontmatter in DESIGN.md (light theme).
const PALETTE = {
  bg: "oklch(93.02% 0.0137 78.26)", // canvas
  card: "oklch(97.56% 0.0085 67.73)", // surface
  ink: "oklch(18.76% 0.0085 84.57)", // ink
  muted: "oklch(51.5% 0.0072 84.57)", // muted
  hairline: "oklch(83.05% 0.0193 75.3)", // hairline
  accent: "oklch(69.81% 0.1771 48.76)", // accent
  accentInk: "oklch(60.1% 0.1558 47.88)", // accent-ink
  accentContent: "oklch(100% 0 0)", // accent-content
  tint: "oklch(95.26% 0.0272 63.96)", // tint
  shadow: "oklch(18.76% 0.0085 84.57 / 0.10)",
  glow: "oklch(69.81% 0.1771 48.76 / 0.22)",
  glowEnd: "oklch(69.81% 0.1771 48.76 / 0)",
}

const WIDTH = 1080
const HEIGHT = 1350
const PAD = 80
const MAX_ROWS = 7
const HEART = "M12 21s-7.5-4.6-10-9.3C.3 8.4 2 4 6.2 4c2.4 0 3.9 1.4 5.8 3.5C13.9 5.4 15.4 4 17.8 4 22 4 23.7 8.4 22 11.7 19.5 16.4 12 21 12 21z"

let logoPath = null

async function loadLogo() {
  if (logoPath) return logoPath
  try {
    const svg = await (await fetch("/images/logo.svg")).text()
    const d = new DOMParser().parseFromString(svg, "image/svg+xml").querySelector("path")?.getAttribute("d")
    if (d) logoPath = new Path2D(d)
  } catch (_) { }
  return logoPath
}

async function loadFonts() {
  await Promise.all(["400", "600", "700", "800"].map(w => document.fonts.load(`${w} 40px Inter`)))
}

const font = (weight, px) => `${weight} ${Math.round(px)}px Inter, ui-sans-serif, system-ui, sans-serif`

function ellipsize(ctx, text, maxWidth) {
  if (ctx.measureText(text).width <= maxWidth) return text
  let cut = text
  while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) cut = cut.slice(0, -1)
  return cut.trimEnd() + "…"
}

function pill(ctx, x, y, w, h) {
  ctx.beginPath()
  ctx.roundRect(x, y, w, h, h / 2)
  ctx.fill()
}

function drawHeader(ctx, host, logo) {
  if (logo) {
    ctx.save()
    ctx.translate(PAD, PAD + 4)
    ctx.scale(1.9, 1.9)
    ctx.fillStyle = PALETTE.accent
    ctx.fill(logo)
    ctx.restore()
  }

  ctx.fillStyle = PALETTE.ink
  ctx.font = font(800, 112)
  ctx.letterSpacing = "-3px"
  ctx.fillText("Rolezinhos", PAD, PAD + 210)
  ctx.letterSpacing = "0px"

  ctx.fillStyle = PALETTE.accentInk
  ctx.font = font(600, 34)
  ctx.fillText(host, PAD + 4, PAD + 262)
}

// Up to three rows get a roomy layout (place and time on their own lines,
// larger type) so a short list doesn't float in empty space; more rows
// share one compact meta line.
function drawRow(ctx, row, { top, height, left, right, scale, roomy }) {
  const mid = top + height / 2
  const full = row.total > 0 && row.count >= row.total

  ctx.font = font(800, 48 * scale)
  const countText = `${row.count}/${row.total}`
  const pillW = ctx.measureText(countText).width + 44 * scale
  const pillH = 76 * scale
  const pillX = right - pillW
  ctx.fillStyle = full ? PALETTE.accent : PALETTE.tint
  pill(ctx, pillX, mid - pillH / 2, pillW, pillH)
  ctx.fillStyle = full ? PALETTE.accentContent : PALETTE.accentInk
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  ctx.fillText(countText, pillX + pillW / 2, mid + 2 * scale)
  ctx.textAlign = "left"
  ctx.textBaseline = "alphabetic"

  const textMax = pillX - left - 28
  const meta = roomy
    ? [row.place, row.when].filter(Boolean)
    : [[row.place, row.when].filter(Boolean).join(" · ")].filter(Boolean)
  const tagH = row.tag ? 32 * scale : 0
  const titleH = 50 * scale
  const lineH = 40 * scale
  let y = mid - (tagH + titleH + meta.length * lineH) / 2

  if (row.tag) {
    ctx.fillStyle = PALETTE.accentInk
    ctx.font = font(700, 22 * scale)
    ctx.letterSpacing = "1.5px"
    ctx.fillText(ellipsize(ctx, row.tag.toUpperCase(), textMax), left, y + 22 * scale)
    ctx.letterSpacing = "0px"
    y += tagH
  }

  ctx.fillStyle = PALETTE.ink
  ctx.font = font(800, 44 * scale)
  ctx.letterSpacing = "-0.5px"
  ctx.fillText(ellipsize(ctx, row.title, textMax), left, y + 40 * scale)
  ctx.letterSpacing = "0px"
  y += titleH

  ctx.fillStyle = PALETTE.muted
  ctx.font = font(400, 30 * scale)
  meta.forEach((line, i) => ctx.fillText(ellipsize(ctx, line, textMax), left, y + 8 * scale + (i + 1) * lineH - 10 * scale))
}

function drawList(ctx, rows) {
  const cardX = PAD - 24
  const cardW = WIDTH - 2 * cardX
  const listTop = PAD + 310
  const footerH = 110
  const available = HEIGHT - listTop - footerH

  const shown = rows.slice(0, rows.length > MAX_ROWS ? MAX_ROWS - 1 : MAX_ROWS)
  const extra = rows.length - shown.length
  const slots = shown.length + (extra > 0 ? 1 : 0)
  const roomy = slots <= 3
  const rowH = roomy ? 232 : Math.min(150, (available - 24) / slots)
  const scale = roomy ? 1.15 : rowH / 150
  const cardH = slots * rowH + 24
  const cardY = listTop + Math.max(0, (available - cardH) / 2 - 20)

  ctx.save()
  ctx.shadowColor = PALETTE.shadow
  ctx.shadowBlur = 48
  ctx.shadowOffsetY = 16
  ctx.fillStyle = PALETTE.card
  ctx.beginPath()
  ctx.roundRect(cardX, cardY, cardW, cardH, 44)
  ctx.fill()
  ctx.restore()

  const left = cardX + 44
  const right = cardX + cardW - 44

  shown.forEach((row, i) => {
    const top = cardY + 12 + i * rowH
    if (i > 0) {
      ctx.fillStyle = PALETTE.hairline
      ctx.fillRect(left, top, right - left, 2)
    }
    drawRow(ctx, row, { top, height: rowH, left, right, scale, roomy })
  })

  if (extra > 0) {
    const top = cardY + 12 + shown.length * rowH
    ctx.fillStyle = PALETTE.hairline
    ctx.fillRect(left, top, right - left, 2)
    ctx.fillStyle = PALETTE.muted
    ctx.font = font(700, 34 * scale)
    ctx.textBaseline = "middle"
    ctx.fillText(`+${extra} rolezinhos`, left, top + rowH / 2)
    ctx.textBaseline = "alphabetic"
  }
}

function drawFooter(ctx, host) {
  const size = 28
  const before = "Feito com "
  const after = " em "
  const heartW = 30

  ctx.font = font(600, size)
  const beforeW = ctx.measureText(before).width
  const afterW = ctx.measureText(after).width
  ctx.font = font(700, size)
  const hostW = ctx.measureText(host).width

  let x = (WIDTH - (beforeW + heartW + afterW + hostW)) / 2
  const y = HEIGHT - 60

  ctx.fillStyle = PALETTE.muted
  ctx.font = font(600, size)
  ctx.fillText(before, x, y)
  x += beforeW

  ctx.save()
  ctx.translate(x + 2, y - 24)
  ctx.scale(size / 24, size / 24)
  ctx.fillStyle = PALETTE.accent
  ctx.fill(new Path2D(HEART))
  ctx.restore()
  x += heartW

  ctx.fillStyle = PALETTE.muted
  ctx.fillText(after, x, y)
  x += afterW

  ctx.fillStyle = PALETTE.ink
  ctx.font = font(700, size)
  ctx.fillText(host, x, y)
}

export async function drawShareImage(canvas, rows, host) {
  const [logo] = await Promise.all([loadLogo(), loadFonts()])
  canvas.width = WIDTH
  canvas.height = HEIGHT
  const ctx = canvas.getContext("2d")

  ctx.fillStyle = PALETTE.bg
  ctx.fillRect(0, 0, WIDTH, HEIGHT)
  const glow = ctx.createRadialGradient(WIDTH - 60, 40, 0, WIDTH - 60, 40, 520)
  glow.addColorStop(0, PALETTE.glow)
  glow.addColorStop(1, PALETTE.glowEnd)
  ctx.fillStyle = glow
  ctx.fillRect(0, 0, WIDTH, HEIGHT)

  drawHeader(ctx, host, logo)
  drawList(ctx, rows)
  drawFooter(ctx, host)
}

const FILENAME = "rolezinhos.png"

function toFile(canvas) {
  return new Promise((resolve, reject) =>
    canvas.toBlob(blob => blob ? resolve(new File([blob], FILENAME, { type: "image/png" })) : reject(), "image/png"))
}

// The link is attached inside `container` (the hook element, within the
// sheet): a click on an element outside the bottom sheet counts as a
// click-away and closes it.
function download(file, container) {
  const url = URL.createObjectURL(file)
  const link = document.createElement("a")
  link.href = url
  link.download = FILENAME
  link.hidden = true
  container.appendChild(link)
  link.click()
  link.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export const ShareImage = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.onClick = event => {
      const button = event.target.closest("[data-share-image-action]")
      if (button && button.dataset.target === this.el.id) this.act(button.dataset.shareImageAction)
    }
    document.addEventListener("click", this.onClick)
    this.render()
  },

  updated() {
    this.render()
  },

  destroyed() {
    document.removeEventListener("click", this.onClick)
  },

  render() {
    const rows = JSON.parse(this.el.dataset.rows || "[]")
    this.drawing = drawShareImage(this.canvas, rows, this.el.dataset.host || "")
  },

  async act(action) {
    await this.drawing
    const file = await toFile(this.canvas)
    if (action === "share" && navigator.canShare?.({ files: [file] })) {
      try { await navigator.share({ files: [file] }) } catch (_) { }
    } else {
      download(file, this.el)
    }
  },
}
