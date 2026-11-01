import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One row in the quotes overview: symbol and name on the left, sparkline in
// the middle, price and today's move on the right. Everything is aligned to a
// shared two-column rhythm so the numbers line up down the list.
Item {
  id: root

  property var holding: ({})
  property var quote: null
  property bool selected: false
  property bool showSparkline: true
  property color gainColor: Commons.Color.accent
  property color lossColor: Commons.Color.urgent

  signal activated()

  readonly property string symbol: holding && holding.symbol ? String(holding.symbol) : ""
  readonly property string name: {
    if (holding && holding.name) return String(holding.name)
    if (quote && quote.name) return String(quote.name)
    return ""
  }
  readonly property real shares: holding ? Model.toNumber(holding.shares) : 0
  readonly property real price: quote ? Model.toNumber(quote.price) : NaN
  readonly property real changePercent: quote ? Model.toNumber(quote.changePercent) : NaN
  readonly property string currency: quote && quote.currency ? String(quote.currency) : ""
  readonly property color changeColor: isFinite(changePercent)
    ? (changePercent >= 0 ? gainColor : lossColor) : Commons.Color.muted
  readonly property string fontFamily: Style.font.family

  readonly property string metaText: {
    var parts = []
    if (name) parts.push(name)
    if (shares > 0) parts.push(Model.trimNumber(shares) + " sh")
    else if (quote) parts.push("watch only")
    return parts.join(" · ")
  }

  implicitHeight: Style.space(44)

  Rectangle {
    id: surface
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.selected
      ? Style.selectedFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
      : (rowHover.hovered
        ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
        : "transparent")

    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      visible: root.selected
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(2, Style.space(2))
      height: parent.height * 0.5
      radius: width / 2
      color: Commons.Color.accent
    }

    Item {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(6)
      anchors.bottomMargin: Style.space(6)

      Column {
        id: rightColumn
        width: Style.space(88)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          text: isFinite(root.price) ? Model.formatPrice(root.price, root.currency) : "—"
          color: Commons.Color.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          renderType: Text.NativeRendering
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: isFinite(root.changePercent) ? Model.formatPercent(root.changePercent) : ""
          color: root.changeColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
        }
      }

      Sparkline {
        id: spark
        visible: root.showSparkline
        width: Style.space(64)
        height: Style.space(24)
        anchors.right: rightColumn.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        values: root.quote ? root.quote.closes : []
        baselineValue: root.quote ? root.quote.previousClose : NaN
        lineColor: root.changeColor
        showBaseline: false
        filled: true
      }

      Column {
        id: leftColumn
        anchors.left: parent.left
        anchors.right: spark.visible ? spark.left : rightColumn.left
        anchors.rightMargin: spark.visible ? Style.space(12) : Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.symbol
          color: Commons.Color.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          renderType: Text.NativeRendering
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.metaText
          color: Commons.Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
        }
      }
    }

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activated()
    }
  }
}
