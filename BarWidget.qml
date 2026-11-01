import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar entry point for the stock portfolio. The button shows the portfolio's
// day move (or a single figure, configurable) and left click opens the detail
// popup. The popup does the fetching and owns all state, so the bar stays
// correct even while the popup is closed.
BarWidget {
  id: root

  moduleName: "lipi.stocks"

  property var panelItem: null

  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem
    ? panelItem.popoutSwitchClosing === true : false

  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function togglePanel() { if (panelItem) panelItem.toggle() }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    panelItem = target
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  readonly property var summary: panelItem ? panelItem.portfolioSummary : null
  readonly property var fallback: panelItem ? panelItem.fallbackQuote : null
  readonly property string displayMode: String(setting("barDisplay", "percent")).toLowerCase()
  readonly property bool showIcon: boolSetting("showIcon", true)

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(text) !== -1) return true
    if (["false", "0", "no", "off"].indexOf(text) !== -1) return false
    return fallback
  }

  readonly property real movePercent: {
    if (summary && summary.hasPositions && isFinite(summary.dayPercent)) return summary.dayPercent
    if (fallback && isFinite(fallback.changePercent)) return fallback.changePercent
    return NaN
  }

  readonly property real moveValue: {
    if (summary && summary.hasPositions && isFinite(summary.dayAbs)) return summary.dayAbs
    if (fallback && isFinite(fallback.change)) return fallback.change
    return NaN
  }

  readonly property string currency: panelItem && panelItem.baseCurrency
    ? panelItem.baseCurrency
    : (fallback && fallback.currency ? fallback.currency : "USD")

  readonly property string barText: {
    if (displayMode === "icon") return ""
    if (!panelItem) return ""
    if (summary && summary.hasPositions) {
      if (displayMode === "value") return Model.formatCompactMoney(summary.totalValue, currency)
      if (displayMode === "change") return Model.formatSignedMoney(summary.dayAbs, currency)
      return Model.formatPercent(summary.dayPercent)
    }
    if (fallback) {
      if (displayMode === "value") return Model.formatMoney(fallback.price, fallback.currency)
      if (displayMode === "change") return Model.formatSignedMoney(fallback.change, fallback.currency)
      return Model.formatPercent(fallback.changePercent)
    }
    return ""
  }

  readonly property color gainColor: panelItem ? panelItem.gainColor : Commons.Color.accent
  readonly property color lossColor: panelItem ? panelItem.lossColor : Commons.Color.urgent

  readonly property color barTextColor: {
    if (displayMode === "value")
      return root.bar ? root.bar.barForeground : Commons.Color.foreground
    if (displayMode === "icon" || !isFinite(movePercent))
      return root.bar ? root.bar.barForeground : Commons.Color.foreground
    return movePercent >= 0 ? gainColor : lossColor
  }

  readonly property color barGlyphColor: root.bar
    ? root.bar.barForeground : Commons.Color.foreground

  readonly property string tooltipText: {
    if (!panelItem) return "Stocks"
    if (!panelItem.hasHoldings) return "Stocks · click to add your holdings"
    if (summary && summary.hasPositions) {
      const parts = [
        "Portfolio " + Model.formatMoney(summary.totalValue, currency),
        "today " + Model.formatSignedMoney(summary.dayAbs, currency)
          + " (" + Model.formatPercent(summary.dayPercent) + ")"
      ]
      if (summary.hasCost) {
        parts.push("P/L " + Model.formatSignedMoney(summary.unrealized, currency)
          + " (" + Model.formatPercent(summary.unrealizedPercent) + ")")
      }
      return parts.join(" · ")
    }
    return fallback
      ? fallback.symbol + " " + Model.formatMoney(fallback.price, fallback.currency)
        + " · " + Model.formatPercent(fallback.changePercent)
      : "Stocks"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 6
    tooltipText: root.tooltipText
    fixedWidth: root.vertical
      ? -1
      : Math.ceil(contentRow.implicitWidth + button.scaledHorizontalMargin * 2)

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) {
        if (root.panelItem) root.panelItem.refreshQuotes()
      } else if (pressedButton === Qt.MiddleButton) {
        root.openInSearch()
      } else {
        root.togglePanel()
      }
    }

    Text {
      anchors.centerIn: parent
      visible: root.vertical
      text: root.showIcon ? "\uf201" : root.barText
      color: root.showIcon ? root.barGlyphColor : root.barTextColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.bar.iconFont
      renderType: Text.NativeRendering
    }

    Row {
      id: contentRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        visible: root.showIcon
        text: "\uf201"
        color: root.barGlyphColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }

      Text {
        visible: text !== ""
        text: root.barText
        color: root.barTextColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        renderType: Text.NativeRendering

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }
  }

  function openInSearch() {
    if (!panelItem) return
    panelItem.open()
    Qt.callLater(function() { if (panelItem) panelItem.focusSearch() })
  }
}
