import osproc, os, streams, times, random, strutils
import re, strformat

## Importing this module will start gnuplot. Array contents are written
## to temporary files (in /tmp) and then loaded by gnuplot. The temporary
## files aren't deleted automatically in case they would be useful later.
## To delete temporary file, append result = fname and {.discardable.}
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
    Boxerrorbars

var
  gp: Process
  nplots = 0
  style: Style = Lines

try:
  gp = startProcess findExe("gnuplot")
except:
  echo "Error: Couldn't start gnuplot, exe is not found"
  quit 1

proc plotCmd(): string =
  if nplots == 0: "plot " else: "replot "

proc tmpFilename(): string =
  when defined(Windows):
    (getEnv("TEMP") / ($epochTime() & "-" & $rand(1000) & ".tmp")).replace("\\", "/")
  else:
    getTempDir() & $epochTime() & "-" & $rand(1000) & ".tmp"

proc tmpFileCleanup*() =
  let
    q = re"(\d+)\.(\d+)-(\d+)\.tmp"
    td = getTempDir()
  for p in (fmt"{td}*.tmp").walkPattern:
    if p.fileExists and p[td.len..<p.len].match(q):
      echo fmt"rm {p}"
      p.removeFile

proc cmd*(cmd: string) =
  echo cmd
  ## send a raw command to gnuplot
  try:
    gp.inputStream.writeLine cmd
    gp.inputStream.flush
  except:
    echo "Error: Couldn't send command to gnuplot"
    quit 1

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
    line = (plotCmd() & arg & extra & title_line &
            " with " & toLowerAscii($style))

  cmd line
  nplots = nplots + 1

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
  let fname = tmpFilename()
  try:
    let f = open(fname, fmWrite)
    for x in xs:
      writeLine f, x
    f.close
  except:
    echo "Error: Couldn't write to temporary file: " & fname
    quit 1
  sendPlot("\"" & fname & "\"", title, extra)
  result = fname

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
  let fname = tmpFilename()
  try:
    let f = open(fname, fmWrite)
    for i in xs.low..xs.high:
      writeLine f, xs[i], " ", ys[i]
    f.close
  except:
    echo "Error: Couldn't write to temporary file: " & fname
    quit 1
  sendPlot("\"" & fname & "\"", title, extra)
  result = fname

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
  let fname = tmpFilename()
  try:
    let f = open(fname, fmWrite)
    for i in xs.low..xs.high:
      write f, xs[i]
      for nc in ys.low..<ys.high:
        write f, " ", ys[nc][i]
      writeLine f, " ", ys[ys.high][i]
    f.close
  except:
    echo "Error: Couldn't write to temporary file: " & fname
    quit 1

  func quote(s: string): string =
    '"' & s & '"'

  let
    ys_len = ys[0].len
    keyslen = keys.len
  var
    usingline = ""
    defStyle = toLowerAscii($style)

  for nc in 1..ncurves:
    usingline &= (if nc > 1: ", \"\" " else: "") & " using 1:" & $(nc+1) &
      (if nc < keyslen: " title " & quote(keys[nc]) else: "") & " w " &
      (if nc <= stlen: toLowerAscii($styles[nc-1]) else: defStyle)

  sendplot(quote(fname), keys[0], usingline, true)
  result = fname

proc set_style*(s: Style) =
  ## set plotting style
  style = s
