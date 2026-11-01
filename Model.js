.pragma library

// Data and formatting helpers for the Stock Portfolio widget. Kept free of
// QML objects so the same file can be imported by the bar widget and the
// popup panel.

var RANGE_LABELS = ["1D", "5D", "1M", "6M", "1Y"]

var SEARCHABLE_TYPES = ["EQUITY", "ETF", "MUTUALFUND", "INDEX", "CRYPTOCURRENCY", "CURRENCY"]

function isFiniteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

function toNumber(value) {
  if (value === null || value === undefined || value === "") return NaN
  var n = Number(value)
  return isFinite(n) ? n : NaN
}

function sanitizeSymbol(raw) {
  var text = String(raw === null || raw === undefined ? "" : raw)
  text = text.replace(/^\s+|\s+$/g, "").toUpperCase()
  // Letters, digits, and the punctuation Yahoo uses for classes, indices,
  // futures and FX pairs (BRK-B, ^GSPC, EURUSD=X, BTC-USD).
  return text.replace(/[^A-Z0-9.^=\-]/g, "")
}

function cleanSeries(values) {
  var out = []
  if (!Array.isArray(values)) return out
  for (var i = 0; i < values.length; i++) {
    if (values[i] === null || values[i] === undefined) continue
    var n = toNumber(values[i])
    if (isFinite(n)) out.push(n)
  }
  return out
}

function quoteFromResponse(response) {
  if (!response) return null
  var meta = response.meta || {}
  var quoteBlock = response.indicators && response.indicators.quote
    ? response.indicators.quote[0] : null
  var closes = cleanSeries(quoteBlock ? quoteBlock.close : [])

  var price = toNumber(meta.regularMarketPrice)
  var previousClose = toNumber(meta.previousClose)
  if (!isFinite(previousClose)) previousClose = toNumber(meta.chartPreviousClose)
  if (!isFinite(price) && closes.length > 0) price = closes[closes.length - 1]

  var change = NaN
  var changePercent = NaN
  if (isFinite(price) && isFinite(previousClose)) {
    change = price - previousClose
    if (previousClose !== 0) changePercent = (change / previousClose) * 100
  }
  var reportedPercent = toNumber(meta.regularMarketChangePercent)
  if (isFinite(reportedPercent)) changePercent = reportedPercent

  return {
    symbol: String(meta.symbol || ""),
    name: String(meta.longName || meta.shortName || ""),
    exchange: String(meta.fullExchangeName || meta.exchangeName || ""),
    currency: String(meta.currency || ""),
    type: String(meta.instrumentType || ""),
    price: price,
    previousClose: previousClose,
    change: change,
    changePercent: changePercent,
    open: toNumber(meta.regularMarketOpen),
    dayHigh: toNumber(meta.regularMarketDayHigh),
    dayLow: toNumber(meta.regularMarketDayLow),
    week52High: toNumber(meta.fiftyTwoWeekHigh),
    week52Low: toNumber(meta.fiftyTwoWeekLow),
    volume: toNumber(meta.regularMarketVolume),
    time: toNumber(meta.regularMarketTime),
    closes: closes,
    timestamps: Array.isArray(response.timestamp) ? response.timestamp : []
  }
}

function parseQuotes(raw) {
  var out = {}
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return out }
  var results = data && data.spark && Array.isArray(data.spark.result)
    ? data.spark.result : []
  for (var i = 0; i < results.length; i++) {
    var entry = results[i] || {}
    var responses = Array.isArray(entry.response) ? entry.response : []
    var quote = quoteFromResponse(responses[0])
    if (!quote) continue
    if (!quote.symbol) quote.symbol = String(entry.symbol || "")
    if (quote.symbol) out[quote.symbol] = quote
  }
  return out
}

function parseChart(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  var results = data && data.chart && Array.isArray(data.chart.result)
    ? data.chart.result : []
  return quoteFromResponse(results[0])
}

function parseSearch(raw) {
  var out = []
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return out }
  var quotes = data && Array.isArray(data.quotes) ? data.quotes : []
  var seen = {}
  for (var i = 0; i < quotes.length; i++) {
    var entry = quotes[i] || {}
    var type = String(entry.quoteType || "").toUpperCase()
    if (SEARCHABLE_TYPES.indexOf(type) === -1) continue
    var symbol = sanitizeSymbol(entry.symbol)
    if (!symbol || seen[symbol]) continue
    seen[symbol] = true
    out.push({
      symbol: symbol,
      name: String(entry.longname || entry.shortname || symbol),
      exchange: String(entry.exchDisp || entry.exchange || ""),
      type: type
    })
    if (out.length >= 8) break
  }
  return out
}

function quotesUrl(symbols) {
  var list = []
  if (Array.isArray(symbols)) {
    for (var i = 0; i < symbols.length; i++) {
      var symbol = sanitizeSymbol(symbols[i])
      if (symbol) list.push(encodeURIComponent(symbol))
    }
  }
  return "https://query1.finance.yahoo.com/v7/finance/spark"
    + "?symbols=" + list.join(",")
    + "&range=1d&interval=5m&includePrePost=false"
}

function searchUrl(query) {
  return "https://query1.finance.yahoo.com/v1/finance/search"
    + "?q=" + encodeURIComponent(String(query || ""))
    + "&quotesCount=10&newsCount=0&listsCount=0"
}

function rangeSpec(label) {
  var name = String(label || "1D").toUpperCase()
  if (name === "5D") return { label: name, range: "5d", interval: "30m" }
  if (name === "1M") return { label: name, range: "1mo", interval: "1d" }
  if (name === "6M") return { label: name, range: "6mo", interval: "1d" }
  if (name === "1Y") return { label: name, range: "1y", interval: "1wk" }
  return { label: "1D", range: "1d", interval: "5m" }
}

function chartUrl(symbol, rangeLabel) {
  var spec = rangeSpec(rangeLabel)
  return "https://query1.finance.yahoo.com/v8/finance/chart/"
    + encodeURIComponent(sanitizeSymbol(symbol))
    + "?range=" + spec.range
    + "&interval=" + spec.interval
    + "&includePrePost=false"
}

// ------------------------------------------------------------------ numbers

function groupNumber(value, decimals) {
  var n = isFinite(Number(value)) ? Number(value) : 0
  var fixed = Math.abs(n).toFixed(decimals)
  var parts = fixed.split(".")
  var integer = parts[0]
  var grouped = ""
  for (var i = 0; i < integer.length; i++) {
    if (i > 0 && (integer.length - i) % 3 === 0) grouped += ","
    grouped += integer.charAt(i)
  }
  return (n < 0 ? "-" : "") + grouped + (parts.length > 1 ? "." + parts[1] : "")
}

function trimNumber(value) {
  var n = toNumber(value)
  if (!isFinite(n)) return "0"
  if (Math.abs(n - Math.round(n)) < 0.000001) return String(Math.round(n))
  return String(Number(n.toFixed(4)))
}

function currencySymbol(code) {
  var c = String(code || "").toUpperCase()
  if (c === "USD") return "$"
  if (c === "EUR") return "€"
  if (c === "GBP") return "£"
  if (c === "JPY") return "¥"
  if (c === "INR") return "₹"
  if (c === "CAD") return "C$"
  if (c === "AUD") return "A$"
  if (c === "CHF") return "CHF "
  if (c === "CNY") return "CN¥"
  if (c === "HKD") return "HK$"
  return c ? c + " " : ""
}

function formatMoney(value, currency, decimals) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  var d = decimals === undefined ? 2 : decimals
  var sign = n < 0 ? "-" : ""
  return sign + currencySymbol(currency) + groupNumber(Math.abs(n), d)
}

function formatSignedMoney(value, currency, decimals) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  var d = decimals === undefined ? 2 : decimals
  var sign = n > 0 ? "+" : (n < 0 ? "-" : "")
  return sign + currencySymbol(currency) + groupNumber(Math.abs(n), d)
}

function formatCompactMoney(value, currency) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  var abs = Math.abs(n)
  var sign = n < 0 ? "-" : ""
  if (abs >= 1000000) return sign + currencySymbol(currency) + (abs / 1000000).toFixed(2) + "M"
  if (abs >= 10000) return sign + currencySymbol(currency) + (abs / 1000).toFixed(1) + "K"
  return formatMoney(n, currency, 2)
}

function formatPercent(value, decimals) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  var d = decimals === undefined ? 2 : decimals
  var sign = n > 0 ? "+" : (n < 0 ? "-" : "")
  return sign + Math.abs(n).toFixed(d) + "%"
}

function formatPrice(value, currency) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  return formatMoney(n, currency, Math.abs(n) > 0 && Math.abs(n) < 1 ? 4 : 2)
}

function formatVolume(value) {
  var n = toNumber(value)
  if (!isFinite(n)) return "—"
  var abs = Math.abs(n)
  var sign = n < 0 ? "-" : ""
  if (abs >= 1e12) return sign + (abs / 1e12).toFixed(2) + "T"
  if (abs >= 1e9) return sign + (abs / 1e9).toFixed(2) + "B"
  if (abs >= 1e6) return sign + (abs / 1e6).toFixed(2) + "M"
  if (abs >= 1e3) return sign + (abs / 1e3).toFixed(1) + "K"
  return sign + String(Math.round(abs))
}

// ---------------------------------------------------------------- portfolio

function normalizeHolding(item) {
  if (!item) return null
  var symbol = sanitizeSymbol(item.symbol)
  if (!symbol) return null
  var shares = toNumber(item.shares)
  var cost = toNumber(item.cost)
  return {
    symbol: symbol,
    name: String(item.name || ""),
    shares: isFinite(shares) && shares > 0 ? shares : 0,
    cost: isFinite(cost) && cost > 0 ? cost : 0
  }
}

function parsePortfolio(raw) {
  var out = []
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return out }
  var list = Array.isArray(data) ? data
    : (data && Array.isArray(data.holdings) ? data.holdings : [])
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var holding = normalizeHolding(list[i])
    if (!holding || seen[holding.symbol]) continue
    seen[holding.symbol] = true
    out.push(holding)
  }
  return out
}

function serializePortfolio(holdings) {
  var clean = []
  if (Array.isArray(holdings)) {
    for (var i = 0; i < holdings.length; i++) {
      var holding = normalizeHolding(holdings[i])
      if (holding) clean.push(holding)
    }
  }
  return JSON.stringify({ version: 1, holdings: clean }, null, 2) + "\n"
}

function portfolio(holdings, quotes) {
  var result = {
    count: Array.isArray(holdings) ? holdings.length : 0,
    tracked: 0,
    totalValue: 0,
    previousValue: 0,
    dayAbs: 0,
    dayPercent: NaN,
    cost: NaN,
    costedValue: 0,
    unrealized: NaN,
    unrealizedPercent: NaN,
    shares: 0,
    hasPositions: false,
    hasCost: false,
    currency: ""
  }
  if (!Array.isArray(holdings) || !quotes) return result

  for (var i = 0; i < holdings.length; i++) {
    var holding = holdings[i]
    var quote = quotes[holding.symbol]
    if (!quote || !isFiniteNumber(quote.price)) continue
    result.tracked++
    if (!result.currency && quote.currency) result.currency = quote.currency

    var shares = toNumber(holding.shares)
    if (!(shares > 0)) continue

    result.hasPositions = true
    result.shares += shares
    result.totalValue += shares * quote.price
    if (isFiniteNumber(quote.previousClose)) {
      result.previousValue += shares * quote.previousClose
    }

    var cost = toNumber(holding.cost)
    if (cost > 0) {
      if (!result.hasCost) {
        result.hasCost = true
        result.cost = 0
      }
      result.cost += shares * cost
      result.costedValue += shares * quote.price
    }
  }

  if (result.hasPositions && result.previousValue > 0) {
    result.dayAbs = result.totalValue - result.previousValue
    result.dayPercent = (result.dayAbs / result.previousValue) * 100
  }
  if (result.hasCost && result.cost > 0) {
    result.unrealized = result.costedValue - result.cost
    result.unrealizedPercent = (result.unrealized / result.cost) * 100
  }
  return result
}

function fallbackQuote(holdings, quotes) {
  if (!Array.isArray(holdings) || !quotes) return null
  for (var i = 0; i < holdings.length; i++) {
    var quote = quotes[holdings[i].symbol]
    if (quote && isFiniteNumber(quote.price)) return quote
  }
  return null
}

// A weighted intraday index for the portfolio: each position contributes its
// percentage move since the previous close, weighted by market value, and the
// result is rebased to 100. This lets the panel draw one "portfolio pulse"
// line even when the holdings trade at wildly different prices.
function portfolioSeries(holdings, quotes) {
  var result = { values: [], timestamps: [] }
  if (!Array.isArray(holdings) || !quotes) return result

  var legs = []
  var total = 0
  for (var i = 0; i < holdings.length; i++) {
    var holding = holdings[i]
    var shares = toNumber(holding.shares)
    if (!(shares > 0)) continue
    var quote = quotes[holding.symbol]
    if (!quote || !isFiniteNumber(quote.price) || !isFiniteNumber(quote.previousClose)
        || quote.previousClose === 0) continue
    var closes = Array.isArray(quote.closes) ? quote.closes : []
    if (closes.length === 0) continue
    var value = shares * quote.price
    total += value
    legs.push({
      closes: closes,
      previous: quote.previousClose,
      weight: value,
      timestamps: Array.isArray(quote.timestamps) ? quote.timestamps : []
    })
  }
  if (legs.length === 0 || total <= 0) return result

  var count = 0
  var stamps = []
  for (var l = 0; l < legs.length; l++) {
    if (legs[l].closes.length > count) count = legs[l].closes.length
    if (stamps.length === 0 && legs[l].timestamps.length > 0) stamps = legs[l].timestamps
  }
  if (count === 0) return result

  for (var step = 0; step < count; step++) {
    var move = 0
    for (var g = 0; g < legs.length; g++) {
      var leg = legs[g]
      var at = Math.min(step, leg.closes.length - 1)
      var close = toNumber(leg.closes[at])
      if (!isFiniteNumber(close)) continue
      move += (leg.weight / total) * (close / leg.previous - 1)
    }
    result.values.push(100 * (1 + move))
  }
  if (stamps.length >= count) result.timestamps = stamps.slice(0, count)
  return result
}

// Positions with a value, largest first, with their share of the portfolio.
function allocation(holdings, quotes) {
  var rows = []
  if (!Array.isArray(holdings) || !quotes) return rows
  var total = 0
  for (var i = 0; i < holdings.length; i++) {
    var holding = holdings[i]
    var quote = quotes[holding.symbol]
    var shares = toNumber(holding.shares)
    if (!(shares > 0) || !quote || !isFiniteNumber(quote.price)) continue
    var value = shares * quote.price
    total += value
    rows.push({
      symbol: holding.symbol,
      name: holding.name || quote.name || holding.symbol,
      value: value,
      weight: 0
    })
  }
  rows.sort(function(a, b) { return b.value - a.value })
  if (total > 0) {
    for (var r = 0; r < rows.length; r++) rows[r].weight = rows[r].value / total
  }
  return rows
}

// Best and worst day moves. Positions win over watch-only tickers so the
// summary talks about money the user actually owns.
function movers(holdings, quotes) {
  var result = { best: null, worst: null }
  if (!Array.isArray(holdings) || !quotes) return result

  var positions = []
  var watched = []
  for (var i = 0; i < holdings.length; i++) {
    var quote = quotes[holdings[i].symbol]
    if (!quote || !isFiniteNumber(quote.changePercent)) continue
    var entry = {
      symbol: holdings[i].symbol,
      name: holdings[i].name || quote.name || holdings[i].symbol,
      changePercent: quote.changePercent
    }
    if (toNumber(holdings[i].shares) > 0) positions.push(entry)
    else watched.push(entry)
  }
  var pool = positions.length > 0 ? positions : watched
  if (pool.length === 0) return result

  result.best = pool[0]
  result.worst = pool[0]
  for (var p = 1; p < pool.length; p++) {
    if (pool[p].changePercent > result.best.changePercent) result.best = pool[p]
    if (pool[p].changePercent < result.worst.changePercent) result.worst = pool[p]
  }
  return result
}
