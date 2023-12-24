type Color* = enum
    NoChange
    Reset
    Black
    Red
    Green
    Yellow
    Blue
    Magenta
    Cyan
    White
    BrightBlack
    BrightRed
    BrightGreen
    BrightYellow
    BrightBlue
    BrightMagenta
    BrightCyan
    BrightWhite

type TextStyle* = object
    italic     *: bool = false
    bold       *: bool = false
    underlined *: bool = false
    foreground *: Color = NoChange
    background *: Color = NoChange

func fgID(color: Color): string 
    {.raises: [].} =
    return case color:
        of Black           : "30"
        of Red             : "31"
        of Green           : "32"
        of Yellow          : "33"
        of Blue            : "34"
        of Magenta         : "35"
        of Cyan            : "36"
        of White           : "37"
        of BrightBlack     : "90"
        of BrightRed       : "91"
        of BrightGreen     : "92"
        of BrightYellow    : "93"
        of BrightBlue      : "94"
        of BrightMagenta   : "95"
        of BrightCyan      : "96"
        of BrightWhite     : "97"
        of Reset, NoChange : "0"

func bgID(color: Color): string 
    {.raises: [].} =
    return case color:
        of Black           : "40"
        of Red             : "41"
        of Green           : "42"
        of Yellow          : "43"
        of Blue            : "44"
        of Magenta         : "45"
        of Cyan            : "46"
        of White           : "47"
        of BrightBlack     : "100"
        of BrightRed       : "101"
        of BrightGreen     : "102"
        of BrightYellow    : "103"
        of BrightBlue      : "104"
        of BrightMagenta   : "105"
        of BrightCyan      : "106"
        of BrightWhite     : "107"
        of Reset, NoChange : "0"

func getEsc(style: TextStyle): string 
    {.raises: [].} =
    const allStyleStrCap = 16

    result = newStringOfCap(allStyleStrCap)
    result &= "\x1B["

    if style.foreground != NoChange:
        result &= style.foreground.fgID()

        if style.background != NoChange:
            result &= ";"

    if style.background != NoChange:
        result &= style.background.bgID()
  
    if style.italic:
        result &= ";3"
  
    if style.bold:
        result &= ";1"
  
    if style.underlined:
        result &= ";4"

    result &= "m"

func styleBegin*(style: TextStyle): string
    {.raises: [].} =
    return style.getEsc()

func styleEnd*(): string 
    {.raises: [].} =
    const resetEsc = TextStyle(foreground: Reset, background: Reset).getEsc()
    return resetEsc

func stylizeText*(text: string; style: TextStyle): string 
    {.raises: [].} =
    return styleBegin(style) & text & styleEnd()

template `@`*(text: string; style: TextStyle): string =
    stylizeText(text, style)
