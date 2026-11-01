import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Stock portfolio popup: a portfolio summary with a weighted "pulse" chart and
// an allocation bar, a clean quote overview for every tracked ticker, a detail
// card with range chart and key stats, and an inline position editor. Quotes
// come from Yahoo Finance through curl; holdings are persisted as JSON.
Panel {
  id: root

  moduleName: "lipi.stocks"
  ipcTarget: "lipi.stocks"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/stocks.json"

  // ------------------------------------------------------------------ state

  property var holdings: []
  property var quotes: ({})
  property string selectedSymbol: ""
  property string editSharesText: ""
  property string editCostText: ""
  property bool confirmingRemove: false

  property string searchQuery: ""
  property var searchResults: []
  property bool searching: false
  property bool searchPending: false
  property string searchActiveQuery: ""

  property bool loadingQuotes: false
  property bool quotesFailed: false
  property bool quoteRefreshPending: false
  property var lastUpdated: null

  property string chartRange: "1D"
  property var chartData: null
  property bool chartLoading: false
  property bool chartPending: false
  property string chartActiveSymbol: ""
  property string chartActiveRange: ""

  property bool editorFieldFocused: false

  property color gainColor: Commons.Color.accent
  property color lossColor: Commons.Color.urgent
  property var themePalette: []

  // --------------------------------------------------------------- derived

  readonly property var summary: Model.portfolio(holdings, quotes)
  readonly property var portfolioSummary: summary
  readonly property var fallbackQuote: Model.fallbackQuote(holdings, quotes)
  readonly property var selectedHolding: holdingFor(selectedSymbol)
  readonly property var selectedQuote: quotes[selectedSymbol] || null
  readonly property bool hasHoldings: holdings.length > 0
  readonly property string baseCurrency: summary.currency
    ? summary.currency
    : (fallbackQuote && fallbackQuote.currency ? fallbackQuote.currency : "USD")

  readonly property int refreshSeconds: {
    var value = parseInt(String(root.setting("refreshSeconds", 60)), 10)
    if (!isFinite(value)) value = 60
    return Math.max(30, Math.min(600, value))
  }

  readonly property bool showSparklines: boolSetting("showSparklines", true)

  readonly property var portfolioPulse: Model.portfolioSeries(holdings, quotes)
  readonly property var allocationRows: Model.allocation(holdings, quotes)
  readonly property var moverInfo: Model.movers(holdings, quotes)

  readonly property color dayColor: summary.hasPositions
    ? (summary.dayPercent >= 0 ? gainColor : lossColor)
    : Commons.Color.muted

  readonly property var selectedPosition: {
    var holding = selectedHolding
    var quote = selectedQuote
    if (!holding || !quote || !(Model.toNumber(holding.shares) > 0)) return null
    var price = Model.toNumber(quote.price)
    if (!isFinite(price)) return null
    var shares = Model.toNumber(holding.shares)
    var cost = Model.toNumber(holding.cost)
    return {
      shares: shares,
      value: shares * price,
      cost: cost > 0 ? shares * cost : NaN,
      profit: cost > 0 ? shares * (price - cost) : NaN,
      profitPercent: cost > 0 ? ((price - cost) / cost) * 100 : NaN
    }
  }

  readonly property bool editorDirty: {
    var holding = selectedHolding
    if (!holding) return false
    var shares = parseNumber(editSharesText)
    var cost = parseNumber(editCostText)
    return Math.abs(shares - Model.toNumber(holding.shares)) > 0.000001
      || Math.abs(cost - Model.toNumber(holding.cost)) > 0.000001
  }

  readonly property string headerUpdated: {
    if (loadingQuotes && !lastUpdated) return "Updating…"
    if (!lastUpdated) return quotesFailed ? "Offline" : ""
    return "Updated " + Qt.formatTime(lastUpdated, "HH:mm")
  }

  readonly property string countText: {
    var n = holdings.length
    if (n === 0) return ""
    return n + (n === 1 ? " stock" : " stocks")
  }

  // The chart is drawn from the 1-day close series that already came with the
  // bar quote, so 1D works without another request; longer ranges fetch their
  // own series.
  readonly property var chartValues: {
    if (chartRange === "1D") return selectedQuote ? selectedQuote.closes : []
    if (chartData && chartActiveSymbol === selectedSymbol
        && chartData.closes && chartData.closes.length > 0) return chartData.closes
    return []
  }

  readonly property var chartTimestamps: {
    if (chartRange === "1D") return selectedQuote ? selectedQuote.timestamps : []
    if (chartData && chartActiveSymbol === selectedSymbol
        && chartData.timestamps) return chartData.timestamps
    return []
  }

  readonly property real chartBaseline: {
    if (chartRange === "1D") return selectedQuote ? selectedQuote.previousClose : NaN
    var values = chartValues
    return values.length > 0 ? values[0] : NaN
  }

  readonly property real chartMovePercent: {
    if (chartRange === "1D") return selectedQuote ? selectedQuote.changePercent : NaN
    var values = chartValues
    if (values.length < 2 || values[0] === 0) return NaN
    return ((values[values.length - 1] - values[0]) / values[0]) * 100
  }

  readonly property color chartColor: isFinite(chartMovePercent)
    ? (chartMovePercent >= 0 ? gainColor : lossColor)
    : Commons.Color.muted

  readonly property var chartBounds: {
    var values = chartValues
    if (!values || values.length === 0) return null
    var min = values[0]
    var max = values[0]
    for (var i = 1; i < values.length; i++) {
      if (!isFinite(values[i])) continue
      if (values[i] < min) min = values[i]
      if (values[i] > max) max = values[i]
    }
    return { min: min, max: max }
  }

  readonly property string chartStart: formatStamp(chartTimestamps.length ? chartTimestamps[0] : NaN)
  readonly property string chartEnd: formatStamp(chartTimestamps.length
    ? chartTimestamps[chartTimestamps.length - 1] : NaN)

  readonly property string pulseStart: portfolioPulse.timestamps.length
    ? Qt.formatTime(new Date(portfolioPulse.timestamps[0] * 1000), "HH:mm") : ""
  readonly property string pulseEnd: portfolioPulse.timestamps.length
    ? Qt.formatTime(new Date(portfolioPulse.timestamps[portfolioPulse.timestamps.length - 1] * 1000), "HH:mm") : ""

  readonly property string updatedText: {
    var stamp = NaN
    if (chartRange === "1D") stamp = selectedQuote ? selectedQuote.time : NaN
    else if (chartTimestamps.length) stamp = chartTimestamps[chartTimestamps.length - 1]
    if (!isFinite(stamp) || stamp <= 0) return ""
    return "as of " + Qt.formatTime(new Date(stamp * 1000), "HH:mm")
  }

  readonly property var detailStats: {
    var quote = selectedQuote
    if (!quote) return []
    var currency = quote.currency
    return [
      ["Prev close", Model.formatPrice(quote.previousClose, currency)],
      ["Open", Model.formatPrice(quote.open, currency)],
      ["Day range", rangeText(quote.dayLow, quote.dayHigh, currency)],
      ["52w range", rangeText(quote.week52Low, quote.week52High, currency)],
      ["Volume", Model.formatVolume(quote.volume)],
      ["Last trade", isFinite(quote.time) && quote.time > 0
        ? Qt.formatDateTime(new Date(quote.time * 1000), "ddd HH:mm") : "—"]
    ]
  }

  // ---------------------------------------------------------------- helpers

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(text) !== -1) return true
    if (["false", "0", "no", "off"].indexOf(text) !== -1) return false
    return fallback
  }

  function parseNumber(text) {
    var value = parseFloat(String(text).replace(",", "."))
    return isFinite(value) && value > 0 ? value : 0
  }

  function rangeText(low, high, currency) {
    if (!isFinite(low) || !isFinite(high)) return "—"
    return Model.formatPrice(low, currency) + " – " + Model.formatPrice(high, currency)
  }

  function formatStamp(stamp) {
    if (!isFinite(stamp)) return ""
    var date = new Date(stamp * 1000)
    if (chartRange === "1D") return Qt.formatTime(date, "HH:mm")
    if (chartRange === "5D") return Qt.formatDateTime(date, "ddd HH:mm")
    return Qt.formatDateTime(date, "d MMM")
  }

  function holdingFor(symbol) {
    var key = Model.sanitizeSymbol(symbol)
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].symbol === key) return holdings[i]
    }
    return null
  }

  function syncEditor() {
    var holding = holdingFor(selectedSymbol)
    editSharesText = holding && Model.toNumber(holding.shares) > 0
      ? Model.trimNumber(holding.shares) : ""
    editCostText = holding && Model.toNumber(holding.cost) > 0
      ? Model.trimNumber(holding.cost) : ""
    confirmingRemove = false
  }

  function allocationColor(index) {
    if (themePalette.length > 0) return themePalette[index % themePalette.length]
    return Commons.Color.accent
  }

  function loadPortfolio(raw) {
    var parsed = Model.parsePortfolio(raw)
    holdings = parsed
    if (selectedSymbol && !holdingFor(selectedSymbol)) {
      selectedSymbol = parsed.length > 0 ? parsed[0].symbol : ""
    }
    if (!selectedSymbol && parsed.length > 0) selectedSymbol = parsed[0].symbol
    syncEditor()
  }

  function persist() {
    portfolioFile.setText(Model.serializePortfolio(holdings))
  }

  // ------------------------------------------------------------ market data

  function refreshQuotes() {
    if (!holdings.length) {
      quotes = ({})
      lastUpdated = null
      return
    }
    if (quotesProc.running) {
      quoteRefreshPending = true
      return
    }

    var symbols = []
    for (var i = 0; i < holdings.length; i++) {
      var symbol = Model.sanitizeSymbol(holdings[i].symbol)
      if (symbol && symbols.indexOf(symbol) === -1) symbols.push(symbol)
    }
    if (symbols.length === 0) return

    quoteRefreshPending = false
    loadingQuotes = true
    quotesProc.command = [
      "curl", "-fsS", "--max-time", "10", "--compressed",
      "-H", "User-Agent: Mozilla/5.0",
      Model.quotesUrl(symbols)
    ]
    quotesProc.running = true
  }

  function applyQuotes(raw) {
    var parsed = Model.parseQuotes(raw)
    if (Object.keys(parsed).length === 0) {
      quotesFailed = true
      return
    }
    quotes = parsed
    quotesFailed = false
    lastUpdated = new Date()

    // Fill in display names for tickers added by hand.
    var renamed = false
    var next = []
    for (var i = 0; i < holdings.length; i++) {
      var holding = holdings[i]
      var quote = parsed[holding.symbol]
      if (quote && !holding.name && quote.name) {
        next.push({
          symbol: holding.symbol,
          name: quote.name,
          shares: holding.shares,
          cost: holding.cost
        })
        renamed = true
      } else {
        next.push(holding)
      }
    }
    if (renamed) holdings = next
  }

  function refreshChart() {
    if (!selectedSymbol) {
      chartData = null
      chartLoading = false
      return
    }
    if (chartProc.running) {
      chartPending = true
      return
    }

    chartPending = false
    chartActiveSymbol = selectedSymbol
    chartActiveRange = chartRange
    chartLoading = true
    chartProc.command = [
      "curl", "-fsS", "--max-time", "10", "--compressed",
      "-H", "User-Agent: Mozilla/5.0",
      Model.chartUrl(selectedSymbol, chartRange)
    ]
    chartProc.running = true
  }

  // ---------------------------------------------------------------- editing

  function selectSymbol(symbol) {
    var next = Model.sanitizeSymbol(symbol)
    if (!next || next === selectedSymbol) return
    selectedSymbol = next
    chartData = null
    refreshChart()
  }

  function saveEdit() {
    var symbol = selectedSymbol
    if (!symbol) return
    var holding = holdingFor(symbol)
    if (!holding) return

    var shares = parseNumber(editSharesText)
    var cost = parseNumber(editCostText)

    var next = []
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].symbol === symbol) {
        next.push({
          symbol: symbol,
          name: holdings[i].name,
          shares: shares,
          cost: cost
        })
      } else {
        next.push(holdings[i])
      }
    }
    holdings = next
    syncEditor()
    persist()
    refreshQuotes()
  }

  function requestRemove() {
    if (!selectedSymbol) return
    if (!confirmingRemove) {
      confirmingRemove = true
      removeConfirmTimer.restart()
      return
    }
    confirmingRemove = false
    removeHolding(selectedSymbol)
  }

  function removeHolding(symbol) {
    var key = Model.sanitizeSymbol(symbol)
    var next = []
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].symbol !== key) next.push(holdings[i])
    }
    holdings = next

    if (selectedSymbol === key) {
      selectedSymbol = next.length > 0 ? next[0].symbol : ""
      chartData = null
      syncEditor()
      refreshChart()
    }
    persist()
    refreshQuotes()
  }

  function addSymbol(symbol, name) {
    var key = Model.sanitizeSymbol(symbol)
    if (!key) return
    if (!holdingFor(key)) {
      holdings = holdings.concat([{
        symbol: key,
        name: String(name || ""),
        shares: 0,
        cost: 0
      }])
      persist()
      refreshQuotes()
    }
    searchQuery = ""
    searchResults = []
    searchField.text = ""
    selectSymbol(key)
    syncEditor()
  }

  // ----------------------------------------------------------------- search

  function scheduleSearch() {
    if (searchQuery.trim() === "") {
      searchDebounce.stop()
      searchResults = []
      searching = false
      return
    }
    searchDebounce.restart()
  }

  function runSearch() {
    var query = searchQuery.trim()
    if (query === "") return
    if (searchProc.running) {
      searchPending = true
      return
    }
    searchPending = false
    searchActiveQuery = query
    searching = true
    searchProc.command = [
      "curl", "-fsS", "--max-time", "10", "--compressed",
      "-H", "User-Agent: Mozilla/5.0",
      Model.searchUrl(query)
    ]
    searchProc.running = true
  }

  function setChartRange(rangeLabel) {
    if (chartRange === rangeLabel) return
    chartRange = rangeLabel
    chartData = null
    refreshChart()
  }

  function focusSearch() {
    Qt.callLater(function() {
      if (!scroll) return
      scroll.contentY = Math.max(0, scroll.contentHeight - scroll.height)
      searchField.forceActiveFocus()
    })
  }

  function focusShares() {
    if (!selectedHolding) return
    sharesField.forceActiveFocus()
    sharesField.selectAll()
  }

  function stepSelection(delta) {
    if (holdings.length === 0) return
    var index = 0
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].symbol === selectedSymbol) {
        index = i
        break
      }
    }
    index = (index + delta + holdings.length) % holdings.length
    selectSymbol(holdings[index].symbol)
  }

  function stepRange(delta) {
    var index = Model.RANGE_LABELS.indexOf(chartRange)
    if (index === -1) index = 0
    index = (index + delta + Model.RANGE_LABELS.length) % Model.RANGE_LABELS.length
    setChartRange(Model.RANGE_LABELS[index])
  }

  // --------------------------------------------------------------- lifetime

  function open() {
    controller.show()
    refreshQuotes()
    refreshChart()
    Qt.callLater(function() {
      if (!root.hasHoldings) root.focusSearch()
    })
  }

  function openFromHotkey() {
    open()
  }

  function close() {
    confirmingRemove = false
    searchQuery = ""
    searchResults = []
    searching = false
    if (searchField) searchField.text = ""
    controller.hide()
  }

  onSelectedSymbolChanged: syncEditor()

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.opened ? root.close() : root.open() }
    function refresh(): void { root.refreshQuotes(); root.refreshChart() }
  }

  // ------------------------------------------------------------ persistence

  FileView {
    id: portfolioFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPortfolio(text())
    onLoadFailed: root.loadPortfolio("")
    onFileChanged: reload()
  }

  FileView {
    id: themeColorsFile
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyThemeColors(text())
    onFileChanged: reload()
  }

  function applyThemeColors(raw) {
    var text = String(raw || "")
    root.gainColor = themeColor(text, ["green", "bright_green", "color2"]) || Commons.Color.accent
    root.lossColor = themeColor(text, ["red", "bright_red", "color1"]) || Commons.Color.urgent

    var keys = ["blue", "magenta", "yellow", "cyan", "orange", "green", "brown"]
    var palette = []
    for (var i = 0; i < keys.length; i++) {
      var value = themeColor(text, [keys[i]])
      if (value) palette.push(value)
    }
    root.themePalette = palette
  }

  function themeColor(raw, keys) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match && keys.indexOf(match[1]) !== -1) return match[2]
    }
    return ""
  }

  // ------------------------------------------------------------------ timers

  Timer {
    id: refreshTimer
    interval: root.refreshSeconds * 1000
    running: root.hasHoldings
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshQuotes()
  }

  Timer {
    id: searchDebounce
    interval: 350
    onTriggered: root.runSearch()
  }

  Timer {
    id: removeConfirmTimer
    interval: 3000
    onTriggered: root.confirmingRemove = false
  }

  // ------------------------------------------------------------------ curl

  Process {
    id: quotesProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingQuotes = false
        var raw = String(text || "").trim()
        if (raw === "") root.quotesFailed = true
        else root.applyQuotes(raw)
        if (root.quoteRefreshPending) {
          root.quoteRefreshPending = false
          root.refreshQuotes()
        }
      }
    }
  }

  Process {
    id: chartProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.chartLoading = false
        var raw = String(text || "").trim()
        if (raw !== "") {
          var parsed = Model.parseChart(raw)
          if (parsed && parsed.symbol === root.chartActiveSymbol) root.chartData = parsed
        }
        if (root.chartPending) {
          root.chartPending = false
          root.refreshChart()
        }
      }
    }
  }

  Process {
    id: searchProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        var query = root.searchActiveQuery
        if (root.searchPending) {
          root.searchPending = false
          root.searching = false
          root.runSearch()
          return
        }
        root.searching = false
        if (query !== root.searchQuery.trim()) return
        root.searchResults = raw === "" ? [] : Model.parseSearch(raw)
      }
    }
  }

  // -------------------------------------------------------------------- UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(720), contentColumn.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || root.editorFieldFocused
      onCloseRequested: root.close()
      onDeleteRequested: root.requestRemove()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.stepSelection(dy)
        else if (dx !== 0) root.stepRange(dx)
      }
      onTextKey: function(text) {
        if (text === "/") root.focusSearch()
        else if (text === "r") root.refreshQuotes()
        else if (text === "e") root.focusShares()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(10)

          // ------------------------------------------------------- header
          Item {
            width: parent.width
            height: Math.max(titleRow.implicitHeight,
              Math.max(headerUpdatedText.implicitHeight, addStockButton.implicitHeight))

            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Portfolio"
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                renderType: Text.NativeRendering
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.countText !== ""
                text: root.countText
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              id: headerUpdatedText
              anchors.right: addStockButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.headerUpdated
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              id: addStockButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: "Add"
              tooltipText: "Add a stock to the watchlist"
              fontSize: Style.font.caption
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              onClicked: root.focusSearch()
            }
          }

          Text {
            visible: root.quotesFailed
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            text: "Market data unavailable — showing the last known prices."
            color: root.lossColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // --------------------------------------------------- empty state
          Rectangle {
            visible: !root.hasHoldings
            width: parent.width
            height: emptyColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
            border.width: 1
            border.color: Style.normalBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)

            Column {
              id: emptyColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.topMargin: Style.space(12)
              spacing: Style.space(6)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\uf201"
                color: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.displayLarge
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Track your portfolio"
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Search a ticker below, then add your shares and average cost to see live profit and loss."
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // ---------------------------------------------------- hero card
          Rectangle {
            visible: root.hasHoldings
            width: parent.width
            height: heroColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
            border.width: 1
            border.color: Style.normalBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)

            Column {
              id: heroColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.topMargin: Style.space(12)
              spacing: Style.space(10)

              // Value and today's move.
              Item {
                width: parent.width
                height: Math.max(valueColumn.implicitHeight, todayColumn.implicitHeight)

                Column {
                  id: valueColumn
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - todayColumn.width - Style.space(12)
                  spacing: Style.space(1)

                  Text {
                    text: root.summary.hasPositions ? "TOTAL VALUE" : "WATCHLIST"
                    color: Commons.Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.summary.hasPositions
                      ? Model.formatMoney(root.summary.totalValue, root.baseCurrency)
                      : (root.holdings.length + (root.holdings.length === 1 ? " stock" : " stocks"))
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                    renderType: Text.NativeRendering
                  }
                }

                Column {
                  id: todayColumn
                  width: Style.space(150)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    text: root.summary.hasPositions
                      ? Model.formatSignedMoney(root.summary.dayAbs, root.baseCurrency) : ""
                    color: root.dayColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    text: root.summary.hasPositions
                      ? Model.formatPercent(root.summary.dayPercent) + " today" : ""
                    color: root.dayColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                  }
                }
              }

              // Weighted portfolio pulse: one line for the whole portfolio.
              Item {
                visible: root.summary.hasPositions && root.portfolioPulse.values.length > 1
                width: parent.width
                height: Style.space(52)

                Sparkline {
                  anchors.fill: parent
                  values: root.portfolioPulse.values
                  baselineValue: 100
                  lineColor: root.dayColor
                  showBaseline: true
                  filled: true
                }
              }

              Item {
                visible: root.summary.hasPositions && root.portfolioPulse.values.length > 1
                width: parent.width
                height: pulseStartText.implicitHeight

                Text {
                  id: pulseStartText
                  anchors.left: parent.left
                  text: root.pulseStart
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  text: root.pulseEnd
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // Allocation: what the portfolio is made of.
              Column {
                visible: root.allocationRows.length > 1
                width: parent.width
                spacing: Style.space(6)

                Row {
                  id: allocationBar
                  width: parent.width
                  height: Style.space(8)
                  spacing: 2

                  Repeater {
                    model: root.allocationRows

                    Rectangle {
                      required property var modelData
                      required property int index
                      width: Math.max(2, (allocationBar.width
                        - Style.space(2) * (root.allocationRows.length - 1)) * modelData.weight)
                      height: allocationBar.height
                      radius: 2
                      color: root.allocationColor(index)
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  Repeater {
                    model: root.allocationRows.slice(0, 4)

                    Row {
                      required property var modelData
                      required property int index
                      spacing: Style.space(3)

                      Text {
                        text: "●"
                        color: root.allocationColor(index)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        text: modelData.symbol + " " + Math.round(modelData.weight * 100) + "%"
                        color: Commons.Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Text {
                    visible: root.allocationRows.length > 4
                    text: "+" + (root.allocationRows.length - 4)
                    color: Commons.Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // Invested, total return, and today's leader.
              Row {
                visible: root.summary.hasPositions
                width: parent.width
                spacing: Style.space(16)

                Item {
                  width: (parent.width - Style.space(32)) / 3
                  height: investedColumn.implicitHeight

                  Column {
                    id: investedColumn
                    width: parent.width
                    spacing: Style.space(1)

                    Text {
                      text: "INVESTED"
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.summary.hasCost
                        ? Model.formatMoney(root.summary.cost, root.baseCurrency) : "—"
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      renderType: Text.NativeRendering
                    }
                  }
                }

                Item {
                  width: (parent.width - Style.space(32)) / 3
                  height: returnColumn.implicitHeight

                  Column {
                    id: returnColumn
                    width: parent.width
                    spacing: Style.space(1)

                    Text {
                      text: "TOTAL RETURN"
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.summary.hasCost
                        ? Model.formatSignedMoney(root.summary.unrealized, root.baseCurrency) : "—"
                      color: root.summary.hasCost
                        ? (root.summary.unrealized >= 0 ? root.gainColor : root.lossColor)
                        : Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      renderType: Text.NativeRendering
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.summary.hasCost
                        ? Model.formatPercent(root.summary.unrealizedPercent) : ""
                      color: root.summary.hasCost
                        ? (root.summary.unrealized >= 0 ? root.gainColor : root.lossColor)
                        : Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      renderType: Text.NativeRendering
                    }
                  }
                }

                Item {
                  width: (parent.width - Style.space(32)) / 3
                  height: leaderColumn.implicitHeight

                  Column {
                    id: leaderColumn
                    width: parent.width
                    spacing: Style.space(1)

                    Text {
                      text: "TODAY'S LEADER"
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.moverInfo.best
                        ? root.moverInfo.best.symbol + " " + Model.formatPercent(root.moverInfo.best.changePercent)
                        : "—"
                      color: root.moverInfo.best
                        ? (root.moverInfo.best.changePercent >= 0 ? root.gainColor : root.lossColor)
                        : Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      renderType: Text.NativeRendering
                    }

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.moverInfo.best ? root.moverInfo.best.name : ""
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      renderType: Text.NativeRendering
                    }
                  }
                }
              }
            }
          }

          // ------------------------------------------------------ overview
          Column {
            visible: root.hasHoldings
            width: parent.width
            spacing: Style.space(3)

            Item {
              width: parent.width
              height: holdingsTitle.implicitHeight + Style.space(2)

              Text {
                id: holdingsTitle
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "OVERVIEW"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "select a row for details"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.holdings.map(function(holding) { return holding.symbol })

              delegate: HoldingRow {
                required property string modelData
                width: parent.width
                holding: root.holdingFor(modelData) || ({})
                quote: root.quotes[modelData] || null
                selected: root.selectedSymbol === modelData
                showSparkline: root.showSparklines
                gainColor: root.gainColor
                lossColor: root.lossColor
                onActivated: root.selectSymbol(modelData)
              }
            }
          }

          // -------------------------------------------------------- detail
          Rectangle {
            visible: root.hasHoldings && root.selectedHolding !== null
            width: parent.width
            height: detailColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
            border.width: 1
            border.color: Style.normalBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)

            Column {
              id: detailColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.topMargin: Style.space(12)
              spacing: Style.space(10)

              // Name, symbol, exchange, price.
              Item {
                width: parent.width
                height: Math.max(detailName.implicitHeight, detailPrice.implicitHeight)

                Column {
                  id: detailName
                  anchors.left: parent.left
                  anchors.right: detailPrice.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.selectedQuote && root.selectedQuote.name
                      ? root.selectedQuote.name
                      : (root.selectedHolding ? root.selectedHolding.name : root.selectedSymbol)
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                      var parts = [root.selectedSymbol]
                      if (root.selectedQuote && root.selectedQuote.exchange)
                        parts.push(root.selectedQuote.exchange)
                      if (root.selectedQuote && root.selectedQuote.currency)
                        parts.push(root.selectedQuote.currency)
                      return parts.join(" · ")
                    }
                    color: Commons.Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                  }
                }

                Column {
                  id: detailPrice
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    anchors.right: parent.right
                    text: root.selectedQuote
                      ? Model.formatPrice(root.selectedQuote.price, root.selectedQuote.currency) : "—"
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Text {
                    anchors.right: parent.right
                    text: root.selectedQuote
                      ? Model.formatPercent(root.chartMovePercent) : ""
                    color: root.chartColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    renderType: Text.NativeRendering
                  }
                }
              }

              // Chart.
              Item {
                width: parent.width
                height: Style.space(96)

                Sparkline {
                  anchors.fill: parent
                  values: root.chartValues
                  baselineValue: root.chartBaseline
                  lineColor: root.chartColor
                  showBaseline: true
                  filled: true
                }

                Text {
                  anchors.top: parent.top
                  anchors.right: parent.right
                  text: root.chartBounds ? Model.formatPrice(root.chartBounds.max,
                    root.selectedQuote ? root.selectedQuote.currency : "") : ""
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.bottom: parent.bottom
                  anchors.right: parent.right
                  text: root.chartBounds ? Model.formatPrice(root.chartBounds.min,
                    root.selectedQuote ? root.selectedQuote.currency : "") : ""
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.centerIn: parent
                  visible: root.chartValues.length === 0
                  text: root.chartLoading ? "Loading chart…" : "No chart data"
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Item {
                width: parent.width
                height: Math.max(chartStartText.implicitHeight, chartEndText.implicitHeight)
                visible: root.chartValues.length >= 2

                Text {
                  id: chartStartText
                  anchors.left: parent.left
                  text: root.chartStart
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: chartEndText
                  anchors.right: parent.right
                  text: root.chartEnd
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // Range chips and freshness.
              Item {
                width: parent.width
                height: Math.max(rangeRow.implicitHeight, chartUpdatedText.implicitHeight)

                Row {
                  id: rangeRow
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Repeater {
                    model: Model.RANGE_LABELS

                    delegate: Button {
                      required property string modelData
                      text: modelData
                      selected: root.chartRange === modelData
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(3)
                      onClicked: root.setChartRange(modelData)
                    }
                  }
                }

                Text {
                  id: chartUpdatedText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.updatedText
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // Key stats, two aligned columns of label/value pairs.
              Grid {
                width: parent.width
                columns: 2
                columnSpacing: Style.space(16)
                rowSpacing: Style.space(5)

                Repeater {
                  model: root.detailStats

                  Item {
                    required property var modelData
                    width: (parent.width - Style.space(16)) / 2
                    height: statValue.implicitHeight

                    Text {
                      id: statLabel
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(68)
                      elide: Text.ElideRight
                      text: modelData[0]
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: statValue
                      anchors.left: statLabel.right
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      text: modelData[1]
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.NativeRendering
                    }
                  }
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: Style.normalBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
              }

              // Position editor.
              Column {
                width: parent.width
                spacing: Style.space(8)

                Item {
                  width: parent.width
                  height: positionTitle.implicitHeight

                  Text {
                    id: positionTitle
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "YOUR POSITION"
                    color: Commons.Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  Text {
                    id: removeText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.confirmingRemove ? "Remove?" : "Remove"
                    color: root.lossColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.underline: removeMouse.containsMouse

                    MouseArea {
                      id: removeMouse
                      anchors.fill: parent
                      anchors.margins: -4
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.requestRemove()
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Math.max(sharesColumn.implicitHeight, costColumn.implicitHeight,
                    saveButton.implicitHeight)

                  Column {
                    id: sharesColumn
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    spacing: Style.space(2)

                    Text {
                      text: "Shares"
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: sharesField
                      width: Style.space(96)
                      placeholderText: "0"
                      verticalPadding: Style.space(4)
                      validator: DoubleValidator {
                        bottom: 0
                        top: 1000000000
                        decimals: 6
                        notation: DoubleValidator.StandardNotation
                        locale: "C"
                      }

                      Component.onCompleted: syncFromRoot()
                      Connections {
                        target: root
                        function onEditSharesTextChanged() { sharesField.syncFromRoot() }
                      }
                      onTextEdited: root.editSharesText = text
                      onActiveFocusChanged: root.editorFieldFocused = activeFocus

                      function syncFromRoot() {
                        if (text !== root.editSharesText) text = root.editSharesText
                      }
                    }
                  }

                  Column {
                    id: costColumn
                    anchors.left: sharesColumn.right
                    anchors.leftMargin: Style.space(12)
                    anchors.bottom: parent.bottom
                    spacing: Style.space(2)

                    Text {
                      text: "Average cost"
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: costField
                      width: Style.space(120)
                      placeholderText: root.baseCurrency ? root.baseCurrency + " per share" : "per share"
                      verticalPadding: Style.space(4)
                      validator: DoubleValidator {
                        bottom: 0
                        top: 1000000000
                        decimals: 6
                        notation: DoubleValidator.StandardNotation
                        locale: "C"
                      }

                      Component.onCompleted: syncFromRoot()
                      Connections {
                        target: root
                        function onEditCostTextChanged() { costField.syncFromRoot() }
                      }
                      onTextEdited: root.editCostText = text
                      onActiveFocusChanged: root.editorFieldFocused = activeFocus

                      function syncFromRoot() {
                        if (text !== root.editCostText) text = root.editCostText
                      }
                    }
                  }

                  Button {
                    id: saveButton
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    text: "Save"
                    selected: root.editorDirty
                    enabled: root.editorDirty
                    opacity: enabled ? 1 : 0.45
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.space(12)
                    verticalPadding: Style.space(4)
                    onClicked: root.saveEdit()
                  }
                }

                Text {
                  visible: root.selectedPosition !== null
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.selectedPosition
                    ? Model.trimNumber(root.selectedPosition.shares) + " shares · "
                      + Model.formatMoney(root.selectedPosition.value, root.baseCurrency) + " market value"
                    : ""
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }

                Text {
                  visible: root.selectedPosition !== null && root.selectedPosition.cost > 0
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.selectedPosition
                    ? Model.formatSignedMoney(root.selectedPosition.profit, root.baseCurrency)
                      + " (" + Model.formatPercent(root.selectedPosition.profitPercent) + ") total return"
                    : ""
                  color: root.selectedPosition && root.selectedPosition.profit >= 0
                    ? root.gainColor : root.lossColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  renderType: Text.NativeRendering
                }

                Text {
                  visible: root.selectedPosition === null
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Watch only — set shares and an average cost to include this ticker in your portfolio."
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // -------------------------------------------------------- search
          Column {
            width: parent.width
            spacing: Style.space(5)

            Item {
              width: parent.width
              height: searchTitle.implicitHeight

              Text {
                id: searchTitle
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "ADD A STOCK"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "Enter adds the raw ticker"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Search stocks, ETFs, crypto…"
              onTextEdited: {
                root.searchQuery = text
                root.scheduleSearch()
              }
              onAccepted: {
                if (root.searchResults.length > 0) {
                  root.addSymbol(root.searchResults[0].symbol, root.searchResults[0].name)
                } else {
                  root.addSymbol(text, "")
                }
              }
            }

            Text {
              visible: root.searching && root.searchResults.length === 0
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              text: "Searching…"
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.searchResults

              delegate: Rectangle {
                id: resultRow
                required property var modelData
                width: parent ? parent.width : 0
                height: Style.space(34)
                radius: Style.cornerRadius
                color: resultHover.hovered
                  ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
                  : "transparent"

                Text {
                  id: resultSymbol
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(64)
                  elide: Text.ElideRight
                  text: resultRow.modelData.symbol
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  id: resultExchange
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: resultRow.modelData.exchange
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.left: resultSymbol.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: resultExchange.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: resultRow.modelData.name
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                HoverHandler { id: resultHover }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addSymbol(resultRow.modelData.symbol, resultRow.modelData.name)
                }
              }
            }

            Text {
              visible: root.searchQuery.trim() !== "" && !root.searching && root.searchResults.length === 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: "No matches. Press Enter to add " + Model.sanitizeSymbol(root.searchQuery) + " directly."
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Yahoo Finance · delayed quotes · refreshes every " + root.refreshSeconds + "s"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
