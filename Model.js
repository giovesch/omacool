// Pure helpers for the omacool panel. No QML types in here, so everything is
// reachable from both Panel.qml and CurveEditor.qml.

function parseStatus(text) {
  var raw = String(text || "").trim()
  if (!raw) return null
  try {
    var parsed = JSON.parse(raw)
    return parsed && parsed.ok ? parsed : null
  } catch (error) {
    return null
  }
}

function clampPercent(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(100, Math.round(n)))
}

function clampTemp(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(120, Math.round(n)))
}

// Sort by temperature, drop duplicates and force the curve upward — the same
// rules the daemon applies, mirrored here so the editor never draws a shape the
// daemon would silently rewrite.
function normalizeCurve(points) {
  var cleaned = []
  for (var i = 0; i < (points || []).length; i++) {
    var point = points[i]
    if (!point || point.length < 2) continue
    var temp = Number(point[0])
    var percent = Number(point[1])
    if (!isFinite(temp) || !isFinite(percent)) continue
    cleaned.push([clampTemp(temp), clampPercent(percent)])
  }
  cleaned.sort(function (a, b) { return a[0] - b[0] })

  var result = []
  for (var j = 0; j < cleaned.length; j++) {
    var t = cleaned[j][0]
    var p = cleaned[j][1]
    if (result.length && Math.abs(result[result.length - 1][0] - t) < 1) {
      result[result.length - 1][1] = Math.max(result[result.length - 1][1], p)
      continue
    }
    if (result.length) p = Math.max(p, result[result.length - 1][1])
    result.push([t, p])
  }
  return result.length >= 2 ? result : [[30, 30], [80, 100]]
}

function curvePercent(curve, temperature) {
  var points = normalizeCurve(curve)
  if (temperature === null || temperature === undefined || !isFinite(temperature))
    return points[points.length - 1][1]
  if (temperature <= points[0][0]) return points[0][1]
  if (temperature >= points[points.length - 1][0]) return points[points.length - 1][1]
  for (var i = 0; i < points.length - 1; i++) {
    var left = points[i]
    var right = points[i + 1]
    if (left[0] <= temperature && temperature <= right[0]) {
      var span = right[0] - left[0]
      if (span <= 0) return right[1]
      return left[1] + ((temperature - left[0]) / span) * (right[1] - left[1])
    }
  }
  return points[points.length - 1][1]
}

function curveToArg(points) {
  var normalized = normalizeCurve(points)
  var parts = []
  for (var i = 0; i < normalized.length; i++)
    parts.push(normalized[i][0] + ":" + normalized[i][1])
  return parts.join(",")
}

function fanLabel(fan) {
  if (!fan) return ""
  var label = String(fan.label || "")
  // Drivers that have no real name fall back to "fan1"/"pwm1", which reads as
  // noise next to the chip name; show the chip instead.
  if (/^(fan|pwm)\d+$/.test(label)) return String(fan.chipName || fan.chip || "") + " " + label
  return label
}

function fanSubtitle(fan) {
  if (!fan) return ""
  var bits = []
  if (fan.rpm !== null && fan.rpm !== undefined) bits.push(fan.rpm + " RPM")
  else bits.push("no tacho")
  if (!fan.writable) bits.push("read-only")
  else if (fan.mode === "auto") bits.push("firmware")
  else if (fan.mode === "manual") bits.push("manual")
  else if (fan.mode === "curve") bits.push("curve")
  return bits.join(" · ")
}

function formatTemp(value) {
  if (value === null || value === undefined || !isFinite(value)) return "--"
  return Math.round(value) + "°"
}

// Banding is deliberately coarse so the hero line changes on a real shift in
// thermal state, not on every degree of normal jitter.
function thermalName(value, critical) {
  if (value === null || value === undefined || !isFinite(value)) return "no sensors"
  var limit = isFinite(critical) && critical > 0 ? critical : 90
  if (value >= limit) return "critical"
  if (value >= limit - 10) return "hot"
  if (value >= limit - 25) return "warm"
  if (value >= limit - 40) return "steady"
  return "cool"
}

function thermalFraction(value, critical) {
  var limit = isFinite(critical) && critical > 0 ? critical : 90
  var low = 30
  if (!isFinite(value)) return 0
  return Math.max(0, Math.min(1, (value - low) / Math.max(1, limit - low)))
}

function findFan(fans, id) {
  for (var i = 0; i < (fans || []).length; i++)
    if (fans[i] && fans[i].id === id) return fans[i]
  return null
}

function findTemp(temps, id) {
  for (var i = 0; i < (temps || []).length; i++)
    if (temps[i] && temps[i].id === id) return temps[i]
  return null
}

function sensorOptions(temps) {
  var options = [{ value: "auto", label: "Hottest sensor" }]
  for (var i = 0; i < (temps || []).length; i++) {
    var temp = temps[i]
    options.push({
      value: temp.id,
      label: temp.label + " · " + temp.chipName
    })
  }
  return options
}

function presetOptions(presets) {
  var options = []
  for (var i = 0; i < (presets || []).length; i++) {
    var preset = presets[i]
    options.push({
      value: preset.id,
      label: preset.label || preset.id,
      tooltip: preset.mode === "auto"
        ? "Hand every fan back to the firmware"
        : (preset.mode === "manual"
           ? "Pin every fan at " + preset.percent + "%"
           : "Follow the " + (preset.label || preset.id) + " curve")
    })
  }
  return options
}
