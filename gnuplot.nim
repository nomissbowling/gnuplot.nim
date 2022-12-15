import osproc, os, streams, times, random, strutils
import re, strformat

## Importing this module will start gnuplot. Array contents are written
## to temporary files (in /tmp) and then loaded by gnuplot. The temporary
## files aren't deleted automatically in case they would be useful later.
## To delete temporary file, result = gps.tmpFilePush(temp) and {.discardable.}
## To set col:col or pt ps etc instead of set_style(), append parameter extra.

type
  Style* = enum
    Lines,
    Points,
    Linespoints,
    Impulses,
    Dots,
    Steps,
    Errorbars,
    Boxes,
    Boxerrorbars,
    LabelsBoxed

type
  GPsingleton = object
    gp*: Process
    useTmp*: bool
    removeTmp*: bool
    tmpFiles*: seq[string]

proc tmpFilePush*(gps: var GPsingleton, p: string): string =
  if gps.useTmp and gps.removeTmp: gps.tmpFiles.add(p)
  result = p

proc tmpFileRemove*(gps: var GPsingleton) =
  for fn in gps.tmpFiles: fn.removeFile
  gps.tmpFiles = @[]

proc close(gps: var GPsingleton) =
  if gps.gp != nil:
    gps.gp.terminate
    gps.gp.close
  gps.tmpFileRemove

proc `=destroy`*(gps: var GPsingleton) =
  gps.close

var gps: GPsingleton

proc gp_close*() =
  gps.close

proc gp_start*() =
  try:
    var
      ut = true
      rt = false
    if gps.gp != nil:
      ut = gps.useTmp
      rt = gps.removeTmp
    gps = GPsingleton(gp: startProcess findExe("gnuplot"),
      useTmp: ut, removeTmp: rt)
  except:
    echo "Error: Couldn't start gnuplot, exe is not found"
    quit 1

template gp_restart*() =
  gp_start()

proc set_useTmp*(b: bool) =
  gps.useTmp = b

proc set_removeTmp*(b: bool) =
  gps.removeTmp = b

var
  multiplot: bool = false
  nplots = 0
  style: Style = Lines

proc set_multiplot*(b: bool) =
  multiplot = b

proc set_style*(s: Style) =
  ## set plotting style
  style = s

proc plotCmd(): string =
  if nplots == 0 or multiplot: "plot " else: "replot "

proc tmpTimeStamp(b: bool = false): string =
  result = $epochTime() & "-" & $rand(1000)
  if b: result = "tmp" & result.replace(".", "").replace("-", "")

proc tmpFilename(): string =
  when defined(Windows):
    (getEnv("TEMP") / (tmpTimeStamp() & ".tmp")).replace("\\", "/")
  else:
    getTempDir() & tmpTimeStamp() & ".tmp"

proc tmpFileCleanup*() =
  let
    q = re"(\d+)\.(\d+)-(\d+)\.tmp"
    td = getTempDir()
  for p in (fmt"{td}*.tmp").walkPattern:
    if p.fileExists and p[td.len..<p.len].match(q):
      echo fmt"rm {p}"
      p.removeFile

proc cmd*(cmd: string; noEcho: bool=false) =
  if not noEcho: echo cmd
  ## send a raw command to gnuplot
  try:
    gps.gp.inputStream.write(cmd, "\x0a")
    gps.gp.inputStream.flush
  except:
    echo "Error: Couldn't send command to gnuplot"
    quit 1

proc toString(s: Style): string =
  if s == LabelsBoxed: return "labels boxed"
  toLowerAscii($s)

proc sendPlot(arg: string, title: string, extra: string = "",
  multi: bool = false) =
  let
    title_line =
      if title == "": " notitle"
      else: " title \"" & title & "\""

  var line: string
  if multi:
    if title.len > 0:
      cmd "set title \"" & title & "\""
    line = (plotCmd() & arg & extra)
  else:
    line = (plotCmd() & arg & extra & title_line & " with " & style.toString)

  cmd line
  nplots = nplots + 1

proc quote(s: string): string =
  '"' & s & '"'

proc mkTemp(): tuple[temp: string, msg: string] =
  let temp = if gps.useTmp: tmpFilename() else: tmpTimeStamp(true)
  result = (temp: temp, msg: "Error: Couldn't write to " &
    (if gps.useTmp: "string stream: " else: "temporary file: ") & temp)

template nameStream(temp: string): string =
  if gps.useTmp: quote(temp) else: ("$" & temp)

template openStream(temp: string): Stream =
  if not gps.useTmp:
    let s = newStringStream()
    s.write("$" & temp & " << EOD\x0a")
    s
  else:
    newFileStream(temp, fmWrite)

template closeStream(fs: Stream) =
  if not gps.useTmp:
    fs.write("EOD\x0a")
    fs.flush
    fs.setPosition(0)
    cmd fs.readAll
  fs.close

proc plot*(equation: string, extra: string = "") =
  ## Plot an equation as understood by gnuplot. e.g.:
  ##
  ## .. code-block:: nim
  ##   plot "sin(x)/x"
  sendPlot equation, equation, extra

proc plot*(xs: openarray[float64],
          title = "", extra = ""): string {.discardable.} =
  ## plot an array or seq of float64 values. e.g.:
  ##
  ## .. code-block:: nim
  ##   import math, sequtils
  ##
  ##   let xs = newSeqWith(20, random(1.0))
  ##
  ##   plot xs, "random values"
  let (temp, errMsg) = mkTemp()
  try:
    let fs: Stream = temp.openStream
    for x in xs:
      fs.write(x, "\x0a")
    fs.closeStream
  except:
    echo errMsg
    quit 1
  sendPlot(temp.nameStream, title, extra)
  result = gps.tmpFilePush(temp)

proc plot*[X, Y](xs: openarray[X],
                ys: openarray[Y],
                title = "", extra = " using 1:2"): string {.discardable.} =
  ## plot points taking x and y values from corresponding pairs in
  ## the given arrays.
  ##
  ## With a bit of effort, this can be used to
  ## make date plots. e.g.:
  ##
  ## .. code-block:: nim
  ##   let
  ##       X = ["2014-01-29",
  ##            "2014-02-05",
  ##            "2014-03-15",
  ##            "2014-04-12",
  ##            "2014-05-24",
  ##            "2014-06-02",
  ##            "2014-07-07",
  ##            "2014-08-19",
  ##            "2014-09-04",
  ##            "2014-10-26",
  ##            "2014-11-21",
  ##            "2014-12-07"]
  ##       Y = newSeqWith(len(X), random(10.0))
  ##
  ##   cmd "set timefmt \"%Y-%m-%d\""
  ##   cmd "set xdata time"
  ##
  ##   plot X, Y, "buttcoin value over time"
  ##
  ## or other drawings. e.g.:
  ##
  ## .. code-block:: nim
  ##   var
  ##       X = newSeq[float64](100)
  ##       Y = newSeq[float64](100)
  ##
  ##   for i in 0.. <100:
  ##       let f = float64(i)
  ##       X[i] = f * sin(f)
  ##       Y[i] = f * cos(f)
  ##
  ##   plot X, Y, "spiral"
  if xs.len != ys.len:
    raise newException(ValueError, "xs and ys must have same length")
  let (temp, errMsg) = mkTemp()
  try:
    let fs: Stream = temp.openStream
    for i in xs.low..xs.high:
      fs.write(xs[i], " ", ys[i], "\x0a")
    fs.closeStream
  except:
    echo errMsg
    quit 1
  sendPlot(temp.nameStream, title, extra)
  result = gps.tmpFilePush(temp)

proc plot*[X, Y](xs: openarray[X],
                ys: openarray[Y],
                labels: seq[string],
                title = "", extra = ""): string {.discardable.} =
  if xs.len != ys.len or xs.len != labels.len:
    raise newException(ValueError, "xs, ys and labels must have same length")
  let (temp, errMsg) = mkTemp()
  try:
    let fs: Stream = temp.openStream
    for i in xs.low..xs.high:
      fs.write(xs[i], " ", ys[i], " ", labels[i], "\x0a")
    fs.closeStream
  except:
    echo errMsg
    quit 1
  block:
    let style_bk = style
    defer: set_style(style_bk)
    set_style(LabelsBoxed)
    sendPlot(temp.nameStream, title, extra)
  result = gps.tmpFilePush(temp)

proc plot*[X, Y](xs: openarray[X],
                ys: seq[seq[Y]],
                keys: seq[string] = @[""],
                styles: seq[Style] = @[]): string {.discardable.} =
  ## plot multiple lines ys[k] versus xs
  let
    ncurves = ys.len
    xslen = xs.len
    stlen = styles.len

  for i in 0..<ncurves:
    if xs.len != ys[i].len:
      raise newException(ValueError, "xs and ys[i] must have same length")
  let (temp, errMsg) = mkTemp()
  try:
    let fs: Stream = temp.openStream
    for i in xs.low..xs.high:
      fs.write(xs[i], " ")
      for nc in ys.low..<ys.high:
        fs.write(ys[nc][i], " ")
      fs.write(ys[ys.high][i], "\x0a")
    fs.closeStream
  except:
    echo errMsg
    quit 1

  let
    ys_len = ys[0].len
    keyslen = keys.len
  var usingline = ""
  for nc in 1..ncurves:
    usingline &= (if nc > 1: ", \"\" " else: "") & " using 1:" & $(nc+1) &
      (if nc < keyslen: " title " & quote(keys[nc]) else: "") &
      " with " & (if nc <= stlen: styles[nc-1] else: style).toString

  sendPlot(temp.nameStream, keys[0], usingline, true)
  result = gps.tmpFilePush(temp)

gp_start()
