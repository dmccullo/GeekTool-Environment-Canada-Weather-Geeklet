#!/usr/bin/env bash
set -euo pipefail

# GeekTool usage examples:
#   ./envcan-geektool.sh --coords "45.403,-75.687"
#   ./envcan-geektool.sh --coords "45.403,-75.687" --fahrenheit
#   ./envcan-geektool.sh --url "https://weather.gc.ca/en/location/index.html?coords=45.403,-75.687" --units F
#   ./envcan-geektool.sh --url "https://weather.gc.ca/en/location/index.html?coords=45.403,-75.687"
#
# Tip: GeekTool can pass arguments directly in the shell command field.

URL=""
COORDS=""
UNITS="C"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --coords)
      COORDS="${2:-}"; shift 2;;
    --url)
      URL="${2:-}"; shift 2;;
    --units)
      UNITS="${2:-C}"; shift 2;;
    --fahrenheit|-F)
      UNITS="F"; shift 1;;
    --celsius|-C)
      UNITS="C"; shift 1;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2;;
  esac
done

if [[ -z "${URL}" ]]; then
  if [[ -z "${COORDS}" ]]; then
    # Default to Ottawa if nothing provided.
    COORDS="45.403,-75.687"
  fi
  URL="https://weather.gc.ca/en/location/index.html?coords=${COORDS}"
fi

UNITS="$(printf '%s' "${UNITS}" | tr '[:lower:]' '[:upper:]')"
if [[ "${UNITS}" != "C" && "${UNITS}" != "F" ]]; then
  echo "Invalid --units value: ${UNITS} (use C or F)" >&2
  exit 2
fi

python3 - "$URL" "$UNITS" <<'PY'
import re
import sys
import json
from html import unescape
from urllib.request import Request, urlopen

URL = sys.argv[1]
UNITS = (sys.argv[2] if len(sys.argv) > 2 else "C").strip().upper()
if UNITS not in {"C", "F"}:
    UNITS = "C"


def fetch(url: str) -> str:
    req = Request(url, headers={"User-Agent": "Mozilla/5.0 (GeekTool envcan weather)"})
    with urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")

def strip_tags(s: str) -> str:
    # Replace tags with spaces so adjacent elements don't concatenate.
    s = re.sub(r"<[^>]+>", " ", s)
    s = unescape(s).replace("\xa0", " ")
    s = re.sub(r"\s+", " ", s)
    s = s.replace("° C", "°C").replace(" %", "%")
    return s.strip()

def icon_for(condition: str) -> str:
    c = (condition or "").lower()
    # Prefer single-width symbols for narrow GeekTool windows.
    if any(k in c for k in ["thunder", "t-storm", "tstorm"]):
        return "⚡"
    if "flurr" in c or "snow" in c or "blizzard" in c:
        return "❄"
    if "freezing" in c or "ice" in c or "sleet" in c:
        return "❄"
    if "fog" in c or "mist" in c or "haze" in c or "smoke" in c:
        return "≋"
    if "drizzle" in c:
        return "☂"
    if "shower" in c:
        return "☂"
    if "rain" in c:
        return "☔"
    if "clear" in c:
        return "☾" if "night" in c else "☀"
    if "sun" in c:
        return "☀"
    if "cloud" in c or "overcast" in c:
        return "☁"
    return "•"

def c_to_f(c):
    try:
        v = float(c)
    except Exception:
        return None
    return int(round(v * 9.0 / 5.0 + 32.0))


def format_temp_display(temp_text: str) -> str:
    """temp_text is expected to include a Celsius value, usually like '10.2°C'."""
    if not temp_text:
        return temp_text
    if UNITS == "C":
        return temp_text
    m = re.search(r"(-?\d+(?:\.\d+)?)\s*°\s*C", temp_text)
    if not m:
        return temp_text
    f = c_to_f(m.group(1))
    if f is None:
        return temp_text
    return f"{f}°F"


def format_forecast_temps(high: str, low):
    """high/low are Celsius values as strings (may include negatives)."""
    if UNITS == "C":
        lo_s = f"/{low}" if low is not None else ""
        return f"{high}{lo_s}C"
    hi_f = c_to_f(high)
    if low is None or low == "":
        return f"{hi_f}°F" if hi_f is not None else f"{high}C"
    lo_f = c_to_f(low)
    if hi_f is None or lo_f is None:
        return f"{high}/{low}C"
    return f"{hi_f}°/{lo_f}°F"

def short_day_label(lab: str) -> str:
    s = (lab or "").strip()
    sl = s.lower()
    if sl.startswith("today"):
        return "Today"
    if sl.startswith("tomorrow"):
        return "Tom"
    m = re.match(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\d{1,2})\b", s)
    if m:
        return f"{m.group(1)}{m.group(2)}"
    return s

def parse_ec_daily_json(html: str):
    """Return list[dict] for Environment Canada's embedded \"daily\": [...] array (excluding trailing false)."""
    start = html.find('"daily":[')
    if start == -1:
        return []
    pos = html.find('false],"dailyIssuedTime"', start)
    if pos == -1:
        return []
    raw = html[start + len('"daily":') : pos + len("false]")]
    try:
        arr = json.loads(raw)
    except Exception:
        return []
    return [x for x in arr if isinstance(x, dict)]

def build_daily_hi_lo_map(items):
    """Map 'Wed, 22 Apr' -> {high, low, pop} using EC's day/night sequencing."""
    out = {}
    for i, it in enumerate(items):
        date = (it.get("date") or "").strip()
        if not date:
            continue
        t = it.get("temperature") or {}
        pop = it.get("precip")

        if "periodHigh" in t:
            hi = str(t.get("periodHigh"))
            lo = None
            p2 = pop
            if i + 1 < len(items):
                t2 = items[i + 1].get("temperature") or {}
                if "periodLow" in t2:
                    lo = str(t2.get("periodLow"))
                    if (p2 is None or p2 == "") and items[i + 1].get("precip") not in (None, ""):
                        p2 = items[i + 1].get("precip")
            if lo is None:
                for j in range(i - 1, -1, -1):
                    t0 = items[j].get("temperature") or {}
                    if "periodLow" in t0:
                        lo = str(t0.get("periodLow"))
                        if (p2 is None or p2 == "") and items[j].get("precip") not in (None, ""):
                            p2 = items[j].get("precip")
                        break
            out[date] = {"high": hi, "low": lo, "pop": p2}
    return out

def html_label_to_json_date(lab: str):
    """Convert 'Thu 16 Apr' -> 'Thu, 16 Apr'. Returns None if not matched."""
    s = (lab or "").strip()
    m = re.match(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\d{1,2})\s+([A-Za-z]{3})$", s)
    if not m:
        return None
    return f"{m.group(1)}, {int(m.group(2))} {m.group(3)}"

def slice_from(marker: str, html: str, length: int) -> str:
    i = html.find(marker)
    if i == -1:
        return ""
    return html[i : i + length]

def dt_dd_value(label: str, html: str):
    # Matches: <dt>Label:</dt><dd> ... </dd>
    m = re.search(rf"<dt[^>]*>\s*{re.escape(label)}:\s*</dt>\s*<dd[^>]*>(.*?)</dd>", html, re.I | re.S)
    if not m:
        return None
    return strip_tags(m.group(1))

html = fetch(URL)

loc_m = re.search(r"<h1[^>]*>\s*([^<]+)\s*</h1>", html, re.I)
if loc_m:
    location = strip_tags(loc_m.group(1))
else:
    # Fallback: page title is usually "<City> - 7 Day Forecast - Environment Canada"
    title_m = re.search(r"<title>\s*([^<]+?)\s*</title>", html, re.I)
    title = strip_tags(title_m.group(1)) if title_m else ""
    location = title.split(" - ")[0].strip() if " - " in title else (title or "Environment Canada")

# The string "Current Conditions" can appear in the page chrome; anchor instead near the observation dl list.
cur = slice_from("Current Conditions", html, 40000) or html[:40000]
if "Temperature:" not in cur and "Observed at:" in html:
    j = html.find("Observed at:")
    cur = html[max(0, j - 8000) : j + 40000]
elif "Temperature:" not in cur and "Temperature:" in html:
    j = html.find("Temperature:")
    cur = html[max(0, j - 8000) : j + 40000]

alts = [strip_tags(a) for a in re.findall(r'<img[^>]+alt="([^"]+)"', cur) if "ATOM" not in a]
condition = alts[0] if alts else None

temp = dt_dd_value("Temperature", cur)
dew = dt_dd_value("Dew point", cur)
hum = dt_dd_value("Humidity", cur)
wind = dt_dd_value("Wind", cur)
vis = dt_dd_value("Visibility", cur)
# If we didn't land on the observation <dl>, re-anchor around the Temperature <dt> and retry.
if temp is None:
    temp_anchor = re.search(r"<dt[^>]*>\s*Temperature:", html, re.I)
    if temp_anchor:
        j = temp_anchor.start()
        cur = html[max(0, j - 12000) : j + 40000]
        alts = [strip_tags(a) for a in re.findall(r'<img[^>]+alt="([^"]+)"', cur) if "ATOM" not in a]
        condition = alts[0] if alts else condition
        temp = dt_dd_value("Temperature", cur)
        dew = dt_dd_value("Dew point", cur)
        hum = dt_dd_value("Humidity", cur)
        wind = dt_dd_value("Wind", cur)
        vis = dt_dd_value("Visibility", cur)
obs_m = re.search(r"Observed at:\s*</span>\s*<span[^>]*>([^<]+)</span>", cur, re.I)
observed_at = strip_tags(obs_m.group(1)) if obs_m else None

cur_icon = icon_for(condition or "")

json_items = parse_ec_daily_json(html)
json_map = build_daily_hi_lo_map(json_items)

# Forecast block: parse day+night periods from the div-row list and pair highs with the next low.
fb_m = re.search(r'<div class="div-row\s+div-row1\s+div-row-head"', html, re.I)
fb = html[fb_m.start() : fb_m.start() + 180000] if fb_m else slice_from("div-row1", html, 180000)
periods = []
if fb:
    # Find each period head, then parse the immediately following data chunk.
    for hm in re.finditer(r'<div class="div-row\s+div-row\d+\s+div-row-head"[^>]*>(.*?)</div>', fb, re.I | re.S):
        label = strip_tags(hm.group(1))
        start = hm.end()
        chunk = fb[start : start + 3500]
        icon_alt_m = re.search(r'<img[^>]+alt="([^"]+)"', chunk, re.I)
        icon_alt = strip_tags(icon_alt_m.group(1)) if icon_alt_m else ""
        high_m = re.search(r'<span[^>]+title="High"[^>]*>\s*([+-]?\d+)\s*</span>', chunk, re.I)
        low_m = re.search(r'<span[^>]+title="Low"[^>]*>\s*([+-]?\d+)\s*</span>', chunk, re.I)
        pop_m = re.search(r'<small[^>]+title="Chance of Precipitation"[^>]*>\s*([^<]+)\s*</small>', chunk, re.I)
        periods.append({
            "label": label,
            "cond": icon_alt,
            "icon": icon_for(icon_alt),
            "high": high_m.group(1) if high_m else None,
            "low": low_m.group(1) if low_m else None,
            "pop": strip_tags(pop_m.group(1)) if pop_m else None,
        })
# Build 7 days (daytime only): take first 7 items that have a High and are not night-only periods.
days = []
for i, p in enumerate(periods):
    if not p.get("high"):
        continue
    lab = (p.get("label") or "").strip()
    if lab.lower() in {"tonight", "night"}:
        continue
    if lab.lower().startswith("night"):
        continue
    lo = None
    if i + 1 < len(periods) and periods[i + 1].get("low"):
        lo = periods[i + 1]["low"]

    jdate = html_label_to_json_date(lab)
    if jdate and jdate in json_map:
        j = json_map[jdate]
        # Prefer HTML high/POP/icon, but fill missing low (common on last day) from JSON.
        if j.get("high"):
            p["high"] = j["high"]
        if not lo and j.get("low"):
            lo = j["low"]
        if (not p.get("pop")) and (j.get("pop") not in (None, "")):
            p["pop"] = str(j.get("pop")).strip()

    days.append({
        "label": lab,
        "icon": p["icon"],
        "cond": p["cond"],
        "high": p["high"],
        "low": lo,
        "pop": p["pop"],
    })
    if len(days) >= 7:
        break

print("CURRENT")
if condition and temp:
    # Keep each line short: GeekTool "blank rows" are usually wrapped lines in a narrow box.
    print(f"{location}  {format_temp_display(temp)}")
    print(f"{cur_icon} {condition}")
    extras3 = []
    if wind: extras3.append(f"W {wind}")
    if hum: extras3.append(f"H {hum}")
    if vis: extras3.append(f"V {vis}")
    if extras3:
        print("  ".join(extras3))
else:
    print(f"{location}")
    if condition:
        print(f"{cur_icon} {condition}")

print("──────────")
print("FORECAST")

if days:
    for d in days:
        pop_raw = (d.get("pop") or "").strip()
        pop = ""
        if pop_raw:
            pop_clean = pop_raw.replace("%", "").strip()
            pop = f" {pop_clean}%" if pop_clean else ""
        lab = short_day_label(d["label"])
        temps = format_forecast_temps(str(d.get("high")), d.get("low"))
        print(f"{lab:<7} {d['icon']} {temps}{pop}")

PY
