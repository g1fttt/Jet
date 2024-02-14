import
  std/strformat,
  std/strutils,
  std/sequtils,
  std/tables,
  std/options,
  std/enumutils,

  jet/token,
  jet/ast,
  jet/literal,
  jet/lexer,
  jet/lexerbase,

  lib/utils,
  lib/stacks,
  lib/lineinfo,

  pkg/questionable

{.push, raises: [].}

type
  Parser* {.byref.} = object
    tokens      : seq[Token]
    isModule    : bool
    curr        : int = 0
    ast         : Option[AstNode] = none(AstNode)
    blockStack  : Stack[BlockContext]
    prefixFuncs : OrderedTable[TokenKind, ParsePrefixFunc]
    infixFuncs  : OrderedTable[TokenKind, ParseInfixFunc]
    suffixFuncs : OrderedTable[TokenKind, ParseSuffixFunc]
    priority    : Option[Priority]

  Priority = enum
    Lowest
    Eq
    Or
    And
    Ord
    Sum
    Product
    Suffix
    Path
    Prefix
    Highest

  ParserError* = object of CatchableError
    rng* : FileRange

  FmtLexer = object of LexerBase

  FmtLexerError* = object of CatchableError

  BlockContext = tuple[line, indent: int]

  ParsePrefixFunc = proc(self: var Parser): AstNode
    {.nimcall, noSideEffect, raises: [LexerError, FmtLexerError, ParserError, ValueError].}
  ParseInfixFunc  = proc(self: var Parser; left: AstNode): AstNode
    {.nimcall, noSideEffect, raises: [LexerError, FmtLexerError, ParserError, ValueError].}
  ParseSuffixFunc = proc(self: var Parser; left: AstNode): AstNode
    {.nimcall, noSideEffect, raises: [LexerError, FmtLexerError, ParserError, ValueError].}

func str(kind: TokenKind): string =
  $kind

func `$`(kind: TokenKind): string =
  kind.symbolName()

const priorities = {
  LeRound    : Highest,
  LeSquare   : Highest,
  LeCurly    : Highest,
  Dot        : Path,
  Asterisk   : Product,
  Slash      : Product,
  Percent    : Product,
  Plus       : Sum,
  Minus      : Sum,
  PlusPlus   : Sum,
  EqOp       : Ord,
  NeOp       : Ord,
  LtOp       : Ord,
  GtOp       : Ord,
  LeOp       : Ord,
  GeOp       : Ord,
  KwAnd      : And,
  KwOr       : Or,
  KwNot      : Prefix,
  Eq         : Eq,
}.toTable()

#
# Parse Functions
#

type
  ParseMode = enum
    Block
    List
    Adaptive

{.pop.} # raises: []
{.push, raises: [LexerError, FmtLexerError, ParserError, ValueError].}

func parseLit(self: var Parser): AstNode
func parseExpr(self: var Parser): AstNode
func parseTypeExpr(self: var Parser): AstNode
func parseId(self: var Parser): AstNode
func parseNot(self: var Parser): AstNode
func parseStruct(self: var Parser): AstNode
func parseType(self: var Parser): AstNode
func parseFunc(self: var Parser): AstNode
func parseIf(self: var Parser): AstNode
func parseWhile(self: var Parser): AstNode
func parseReturn(self: var Parser): AstNode
func parseModule(self: var Parser): AstNode
func parseUsing(self: var Parser): AstNode
func parseVar(self: var Parser): AstNode
func parseVal(self: var Parser): AstNode
func parseValDecl(self: var Parser): AstNode
func parseParamOrField(self: var Parser): AstNode
func parseDo(self: var Parser): AstNode
func parseDoOrBlock(self: var Parser): AstNode
func parseDoOrExpr(self: var Parser): AstNode
func parseExprOrBlock(self: var Parser; fn: ParsePrefixFunc = parseExpr): AstNode
func parsePrefix(self: var Parser): AstNode
func parseInfix(self: var Parser; left: AstNode): AstNode
func parseInfixCurly(self: var Parser; left: AstNode): AstNode
func parseInfixRound(self: var Parser; left: AstNode): AstNode
func parseInfixSquare(self: var Parser; left: AstNode): AstNode
func parseExprDotExpr(self: var Parser; left: AstNode): AstNode
func parseAnnotation(self: var Parser): AstNode
func parseList(self: var Parser; fn: ParsePrefixFunc): AstNode
func parseList(self: var Parser): AstNode = self.parseList(parseExpr)
func parseBlock(
  self: var Parser;
  body: var seq[AstNode];
  mode: ParseMode = Block;
  until: Option[TokenKind] = none(TokenKind);
  fn: ParsePrefixFunc = parseExpr;
): ParseMode {.discardable.}

func parseAll*(input: string; posOffset = emptyFilePos; isModule = false): Option[AstNode]
func parseExpr*(input: string; posOffset = emptyFilePos; isModule = false): AstNode

{.pop.} # raises: [LexerError, FmtLexerError, ParserError, ValueError]
{.push, raises: [].}

const # errors
  ErrExpectedId = "expected identifier"

#
# FmtString lexer
#

func escapeString(s: string; startPos: FilePosition): string
  {.raises: [LexerError].} =
  result = ""
  var i = 0

  while i <= s.high:
    let info = startPos.withOffset(i)

    if s[i] == '\\':
      if i == s.high:
        raiseLexerError(
          "invalid character escape; expected character after `\\`, got end of string literal",
          info)

      i += 1
      result.add case s[i]:
        of 'n': "\n"
        of 'r': "\r"
        of 't': "\t"
        of '\\': "\\"
        of '\'': "\'"
        of '\"': "\""
        of 'x', 'u', 'U': todo()
        of Digits:
          if i+2 <= s.high and s[i+1] in Digits and s[i+2] in Digits:
            var num = 0
            num = (num * 10) + (ord(s[i+0]) - ord('0'))
            num = (num * 10) + (ord(s[i+1]) - ord('0'))
            num = (num * 10) + (ord(s[i+2]) - ord('0'))

            if num > 255:
              raiseLexerError(
                "invalid character escape; constant must be in range 0..255",
                info.withLength(4))

            i += 2
            $char(num)
          else:
            if s[1] != '0':
              raiseLexerError(
                "invalid character escape: '" & s[1] & "'",
                info.withLength(2))

            "\0"
        else:
          raiseLexerError("invalid character escape: '\\" & s[i] & "'", info.withOffset(-1).withLength(2))
    elif s[i] in PrintableChars:
      result &= s[i]
    else:
      raiseLexerError("invalid character: " & escape($s[i], "'\\", "'"), info)

    i += 1

const
  fmtSpecifierChars* = Letters + Digits + {'.', '_', '-', '+', '<', '>', '=', '!', '?'}

template raiseFmtLexerError(message: string) =
  raise (ref FmtLexerError)(msg: message)

func newFmtLexer*(node: AstNode): FmtLexer =
  assert(node.kind == Lit)
  assert(node.lit.kind == lkString)

  result = FmtLexer(
    buffer: node.lit.stringVal.toOpenArray(0, node.lit.stringVal.high),
    posOffset: node.rng.a.withOffset(1) - initialFilePos,
  )

func parseFmtString*(self: var FmtLexer): AstNode
  {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
  var exprs = newSeq[AstNode]()
  var buf = ""
  var bufStartPos = emptyFilePos

  # TODO: lineinfo is broken in multiline literals

  func genFmtCall(result: var seq[AstNode]; expr, spec: string; exprPosOffset: FilePosition; specRange: FileRange)
    {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
    # We procude code like this:
    # | $formatValue(`expr`, `spec`)
    let exprNode = parseExpr(expr, exprPosOffset)
    let specLit = initAstNodeLit(newLit(spec), specRange)
    let fmtFunc = initAstNodeBranch(Prefix, @[
      initAstNodeOperator(OpDollar),
      initAstNodeId("formatValue"),
    ])
    let fmtFuncArgs = initAstNodeBranch(List, @[exprNode, specLit])
    let formatValueCall = initAstNodeBranch(ExprRound, @[fmtFunc, fmtFuncArgs])
    result &= formatValueCall

  func genBuf(result: var seq[AstNode]; buf: string; rng: FileRange) =
    let expr = initAstNodeLit(newLit(buf))
    result &= expr

  while true:
    if self.popChar('$'):
      var expr = ""
      var spec = ""
      var exprPosOffset = emptyFilePos
      var specRange = emptyFileRange

      case self.peek()
      of '{':
        self.pop()
        exprPosOffset = self.peekPos() - initialFilePos
        expr = self.parseWhile(it notin {'}', ':'})

        if self.popChar(':'):
          let specStartPos = self.peekPos()
          spec = self.parseUntil(it == '}')
          specRange = specStartPos .. self.peekPos()

          if spec.len() == 0:
            raiseFmtLexerError("empty format specifier are not alloved")

          for c in spec:
            if c notin fmtSpecifierChars:
              raiseFmtLexerError(&"invalid character in format specifier: '{c}'")

        if not self.popChar('}'):
          raiseFmtLexerError("missing closing }")
      of IdStartChars:
        exprPosOffset = self.peekPos() - initialFilePos
        expr = self.parseWhile(it in IdChars)
      of '$':
        discard
      of '\0':
        raiseFmtLexerError("expected format specifier after '$', got end of string literal")
      else:
        raiseFmtLexerError(&"unexpected character after '$': '{self.peek()}'; for single '$' symbol write it twice")

      if expr.len() > 0:
        if buf.len() > 0:
          genBuf(exprs, move(buf), bufStartPos .. self.peekPos())
          buf = ""
          bufStartPos = emptyFilePos
        let posOffset = exprPosOffset
        genFmtCall(exprs, expr, spec, posOffset, specRange)

    if self.isEmpty():
      break

    if self.peek() in Newlines:
      self.handleNewLine()

    buf &= self.pop()

    if bufStartPos == emptyFilePos:
      bufStartPos = self.peekPos()

  if buf.len() > 0:
    genBuf(exprs, move(buf), bufStartPos .. self.peekPos())

  # TODO: prealloc string
  result = initAstNodeLit(newLit(""))

  for i, expr in exprs:
    result =
      if i == 0: expr
      else: initAstNodeBranch(Infix, @[
        initAstNodeOperator(OpAdd),
        result,
        expr,
      ])

func parseFmtString*(node: AstNode): AstNode
  {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
  var lexer = newFmtLexer(node)
  result = lexer.parseFmtString()

#
# Util Functions
#

template raiseParserError*(message: string; node: AstNode) =
  raise (ref ParserError)(msg: message, rng: node.rng)

template raiseParserError*(message: string; fileRange: FileRange) =
  raise (ref ParserError)(msg: message, rng: fileRange)

template raiseParserError*(message: string; filePos: FilePosition) =
  raise (ref ParserError)(msg: message, rng: filePos.withLength(0))

func peekToken(self: Parser): Token
  {.raises: [ParserError].} =
  if self.curr > self.tokens.high:
    raiseParserError("no token to peek", self.tokens[^1].rng)

  result = self.tokens[self.curr]

func peekToken(self: Parser; kinds: set[TokenKind]): Token
  {.raises: [ParserError, ValueError].} =
  result = self.peekToken()

  if result.kind notin kinds:
    let kindsStr = kinds.toSeq().join(" or ")
    raiseParserError(&"expected token of kind {kindsStr}, got {result.kind}", result.rng)

func peekToken(self: Parser; kind: TokenKind): Token
  {.raises: [ParserError, ValueError].} =
  result = self.peekToken({kind})

func prevToken*(self: Parser): Token
  {.raises: [ParserError].} =
  let idx = self.curr - 1

  if idx < 0 or idx >= self.tokens.high:
    raiseParserError("no previous token to peek", self.tokens[0].rng)

  result = self.tokens[idx]

func popToken(self: var Parser): Token
  {.raises: [ParserError].} =
  result = self.peekToken()
  self.curr += 1

func popToken(self: var Parser; kinds: set[TokenKind]): Token
  {.raises: [ParserError, ValueError].} =
  result = self.peekToken(kinds)
  self.curr += 1

func popToken(self: var Parser; kind: TokenKind): Token
  {.raises: [ParserError, ValueError].} =
  result = self.popToken({kind})

func skipToken(self: var Parser; kinds: set[TokenKind])
  {.raises: [ParserError, ValueError].} =
  let token = self.peekToken()

  if token.kind notin kinds:
    let kindsStr = kinds.toSeq().join(" or ")
    raiseParserError(&"expected token of kind {kindsStr}, got {token.kind}", token.rng)

  self.curr += 1

func skipToken(self: var Parser; kind: TokenKind)
  {.raises: [ParserError, ValueError].} =
  self.skipToken({kind})

func skipTokenMaybe(self: var Parser; kinds: set[TokenKind]): bool
  {.discardable, raises: [ParserError, ValueError].} =
  let token = self.peekToken()

  if token.kind in kinds:
    self.skipToken(kinds)
    result = true
  else:
    result = false

func skipTokenMaybe(self: var Parser; kind: TokenKind): bool
  {.discardable, raises: [ParserError, ValueError].} =
  self.skipTokenMaybe({kind})

func isNewBlockContext(self: Parser; context: BlockContext): bool =
  self.blockStack.isEmpty() or context.indent > self.blockStack.peek().indent

#
# Parse Functions AUX
#

func parseIfBranch(self: var Parser): AstNode
  {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
  debug("parseIfBranch")
  debug(&"parseIfBranch: {self.peekToken().kind}")

  let token = self.popToken({KwIf, KwElif})
  let cond = self.parseExpr()
  let body = self.parseDoOrBlock()

  result = initAstNodeBranch(IfBranch, @[cond, body], token.rng)

func parseElseBranch(self: var Parser): AstNode
  {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
  debug("parseElseBranch")

  let token = self.popToken(KwElse)
  let body = self.parseExprOrBlock()

  result = initAstNodeBranch(ElseBranch, @[body], token.rng)

#
# Parse Functions Implementation
#

func parseLit(self: var Parser): AstNode =
  debug("parseLit")

  let token = self.popToken()

  result = case token.kind:
    of KwNil:
      initAstNodeLit(newLit(nil), token.rng)
    of KwTrue:
      initAstNodeLit(newLit(true), token.rng)
    of KwFalse:
      initAstNodeLit(newLit(false), token.rng)
    of StringLit, RawStringLit:
      var lit = initAstNodeLit(newLit(token.data), token.rng)
      lit = parseFmtString(lit)
      if token.kind != RawStringLit:
        lit.lit.stringVal = escapeString(lit.lit.stringVal, token.rng.a)
      lit
    of CharLit:
      if token.data.len() != 1:
        raise (ref ValueError)(msg: &"invalid character: '{token.data}'")
      initAstNodeLit(newLit(token.data[0]), token.rng)
    of IntLit:
      let number =
        if token.data.len() > 2 and token.data[0] == '0' and token.data[1] in {'x', 'b', 'o'}:
          case token.data[1]
          of 'x': token.data.parseHexInt()
          of 'b': token.data.parseBinInt()
          of 'o': token.data.parseOctInt()
          else: unreachable()
        else:
          token.data.parseBiggestInt()
      initAstNodeLit(newLit(number), token.rng)
    of FloatLit:
      initAstNodeLit(newLit(token.data.parseFloat()), token.rng)
    else:
      raiseParserError(&"expected literal, got {token.kind}", token.rng)

func parseExpr(self: var Parser): AstNode =
  debug("parseExpr")

  var token     = self.peekToken()
  let fn        = self.prefixFuncs.getOrDefault(token.kind)
  let priority  = self.priority.get(Lowest)
  self.priority = none(Priority)

  if fn == nil:
    raiseParserError(&"expression is expected, got {token.kind}", token.rng)

  result = fn(self)

  if self.peekToken().kind == Eof:
    return

  while true:
    token = self.peekToken()

    debug(&"parseExpr: priority = {priority}")

    if priority >= priorities.getOrDefault(token.kind, Lowest):
      break

    debug("parseExpr: infix")
    debug(&"parseExpr: token {token.human()}")

    let fn = self.infixFuncs.getOrDefault(token.kind)
    if fn == nil: break
    result = fn(self, result)

func parseTypeExpr(self: var Parser): AstNode =
  result = self.parseExpr()

  let isType = case result.kind:
    of Id:
      true
    of Branch:
      case result.branchKind
      of Prefix:
        case result.children[0].kind:
        of Operator:
          case result.children[0].op:
          of OpRef, OpRefVar:
            true
          else:
            false
        else:
          false

        # case result.children[1].kind:
        # of Id:
        #   true
        # else:
        #   false
      else:
        false
    else:
      false

  if not isType:
    raiseParserError("expected type here", result.rng)

func parseId(self: var Parser): AstNode =
  debug("parseId")

  let token = self.popToken(Id)

  result = initAstNodeId(token.data, token.rng)

func parseNot(self: var Parser): AstNode =
  debug("parseNot")

  self.priority = some(Priority.Prefix)

  let token = self.popToken(KwNot)
  let expr  = self.parseExpr()
  let notOp = initAstNodeOperator(OpNot, token.rng)

  result = initAstNodeBranch(Prefix, @[notOp, expr], token.rng)

func parseStruct(self: var Parser): AstNode =
  debug("parseStruct")

  let token = self.popToken(KwStruct)
  let body  = self.parseExprOrBlock(fn = parseParamOrField)

  result = initAstNodeBranch(Struct, @[body], token.rng)

func parseType(self: var Parser): AstNode =
  debug("parseType")

  let token    = self.popToken(KwType)
  let id       = self.parseId()
  let typeExpr = self.parseExpr()

  result = initAstNodeBranch(Type, @[id, typeExpr], token.rng)

func parseFunc(self: var Parser): AstNode =
  debug("parseFunc")

  let token  = self.popToken(KwFunc)
  let id     = self.parseId()
  let params = self.parseList(fn = parseParamOrField)
  let returnType =
    if self.prevToken().spaces.trailing != spacesLast and
       self.peekToken().kind != KwDo: self.parseExpr()
    else: initAstNodeEmpty()
  let body = self.parseDoOrBlock()

  result = initAstNodeBranch(Func, @[id, params, returnType, body], token.rng)

func parseIf(self: var Parser): AstNode =
  debug("parseIf")

  var branches = newSeq[AstNode]()

  while true:
    branches &= self.parseIfBranch()
    if self.peekToken().kind != KwElif: break

  let elseBranch =
    if self.peekToken().kind == KwElse: self.parseElseBranch()
    else: initAstNodeEmpty()

  result = initAstNodeBranch(If, branches)

  if elseBranch.kind != Empty:
    result.children &= elseBranch

func parseWhile(self: var Parser): AstNode =
  debug("parseWhile")

  let token = self.popToken(KwWhile)
  let cond  = self.parseExpr()
  let body  = self.parseDoOrBlock()

  result = initAstNodeBranch(While, @[cond, body], token.rng)

func parseReturn(self: var Parser): AstNode =
  debug("parseReturn")

  let token = self.popToken(KwReturn)
  let expr  = self.parseExpr()

  result = initAstNodeBranch(Return, @[expr], token.rng)

func parseModule(self: var Parser): AstNode =
  self.skipToken(KwModule)

  let path = self.parseExpr()

  case path.kind
  of Id: discard
  of Branch:
    case path.branchKind
    of ExprDotExpr: discard
    else: raiseParserError(&"expected Id or ExprDotExpr, got {path.branchKind}", path.rng)
  else: raiseParserError(&"expected Id or ExprDotExpr, got {path.kind}", path.rng)

  result = initAstNodeBranch(Module, @[path])

func parseUsing(self: var Parser): AstNode =
  self.skipToken(KwUsing)

  let path = self.parseExpr()

  case path.kind
  of Id: discard
  of Branch:
    case path.branchKind
    of ExprDotExpr: discard
    else: raiseParserError(&"expected Id or ExprDotExpr, got {path.branchKind}", path.rng)
  else: raiseParserError(&"expected Id or ExprDotExpr, got {path.kind}", path.rng)

  result = initAstNodeBranch(Using, @[path])

func parseVar(self: var Parser): AstNode =
  debug("parseVar")

  let token = self.popToken(KwVar)

  result = self.parseValDecl()
  result = initAstNodeBranch(VarDecl, result.children, token.rng)

func parseVal(self: var Parser): AstNode =
  debug("parseVal")

  let token = self.popToken(KwVal)

  result = self.parseValDecl()
  result.rng = token.rng

func parseValDecl(self: var Parser): AstNode =
  debug("parseValDecl")

  let id = self.parseId()

  if self.prevToken().spaces.trailing == spacesLast:
    raiseParserError("expected type or initializer after identifier", id.rng)

  let typeExpr =
    if self.peekToken().kind == Eq: initAstNodeEmpty()
    else: self.parseTypeExpr()
  let body =
    if self.skipTokenMaybe(Eq): self.parseDoOrExpr()
    else: initAstNodeEmpty()

  if typeExpr.kind == Empty and body.kind == Empty:
    raiseParserError("variable declaration must have type or initializer", id.rng)

  result = initAstNodeBranch(ValDecl, @[id, typeExpr, body], id.rng)

func parseParamOrField(self: var Parser): AstNode =
  debug("parseParamOrField")

  result = case self.peekToken().kind:
    of KwVar: self.parseVar()
    of KwVal: self.parseVal()
    else: self.parseValDecl()

func parseDo(self: var Parser): AstNode =
  debug("parseDo")

  let token = self.popToken(KwDo)
  let expr = self.parseExprOrBlock()

  result =
    if expr.kind == Branch and expr.branchKind == Block: expr
    else: initAstNodeBranch(Block, @[expr], token.rng)

func parseDoOrBlock(self: var Parser): AstNode =
  debug("parseDoOrBlock")

  if self.peekToken().kind == KwDo:
    result = self.parseDo()
  else:
    result = initAstNodeBranch(Block, @[])
    self.parseBlock(result.children)

func parseDoOrExpr(self: var Parser): AstNode =
  debug("parseDoOrExpr")

  result =
    if self.peekToken().kind == KwDo: self.parseDo()
    else: self.parseExpr()

func parseExprOrBlock(self: var Parser; fn: ParsePrefixFunc): AstNode =
  debug("parseExprOrBlock")

  if self.peekToken().spaces.wasEndl:
    result = initAstNodeBranch(Block, @[])
    self.parseBlock(result.children, fn = fn)
  else:
    result = fn(self)

func parsePrefix(self: var Parser): AstNode =
  let token = self.popToken({Ampersand, Dollar})

  # TODO: priority

  result = case token.kind:
    of Ampersand:
      let opKind =
        if self.skipTokenMaybe(KwVar): OpRefVar
        else: OpRef
      let refOp = initAstNodeOperator(opKind, token.rng)
      let expr = self.parseExpr()
      initAstNodeBranch(Prefix, @[refOp, expr], token.rng.a .. expr.rng.b)
    of Dollar:
      let dollarOp = initAstNodeOperator(OpDollar, token.rng)
      let id = self.parseId()
      let args = self.parseList()
      let prefix = initAstNodeBranch(Prefix, @[dollarOp, id], token.rng.a .. id.rng.b)
      initAstNodeBranch(ExprRound, @[prefix, args], prefix.rng.a .. args.rng.b)
    of Id:
      initAstNodeId(token.data, token.rng)
    else:
      unreachable()

func parseInfix(self: var Parser; left: AstNode): AstNode =
  debug("parseInfix")

  let token = self.popToken()

  if token.kind notin OperatorKinds + WordLikeOperatorKinds:
    raiseParserError(&"expected operator, got '{token.kind}'", token.rng)

  let op = token.kind.str()
  let opKind = op.toOperatorKind()

  if opKind.isNone():
    raiseParserError(&"operator '{op}' not yet supported", token.rng)

  if OperatorNotation.Infix notin opKind.get().notation():
    raiseParserError(&"operator '{op}' is not infix", token.rng)

  self.priority = some do:
    try:
      priorities[token.kind]
    except KeyError:
      unreachable()

  let opNode = initAstNodeOperator(opKind.get(), token.rng)
  let right = self.parseExpr()

  result = initAstNodeBranch(Infix, @[opNode, left, right], opNode.rng)

func parseInfixCurly(self: var Parser; left: AstNode): AstNode =
  let args = self.parseList()

  case left.kind:
  of Id:
    discard
  of Branch:
    if left.branchKind != Prefix:
      raiseParserError("expected identifier or prefix expression", left.rng)
  else:
    todo($left.kind)

  # FIXME: line rng is not correct
  result = initAstNodeBranch(ExprCurly, @[left, args], left.rng.a .. args.rng.b)

func parseInfixRound(self: var Parser; left: AstNode): AstNode =
  let args = self.parseList()

  result = case left.kind:
    of Id:
      initAstNodeBranch(ExprRound, @[left, args], left.rng.a .. args.rng.b)
    else:
      raiseParserError(&"expected Id node, got {left.kind}", self.peekToken().rng)

func parseInfixSquare(self: var Parser; left: AstNode): AstNode =
  raiseParserError("todo", self.peekToken().rng)

func parseExprDotExpr(self: var Parser; left: AstNode): AstNode =
  self.skipToken(Dot)

  let right = self.parseExpr()

  result = initAstNodeBranch(ExprDotExpr, @[left, right])

func parseAnnotation(self: var Parser): AstNode =
  let atToken = self.popToken(At)

  if atToken.spaces.trailing != 0:
    raiseParserError(ErrExpectedId, atToken.rng)

  let annotPrefix = initAstNodeOperator(OpAnnot, atToken.rng)
  let id = self.parseId()
  let annot = initAstNodeBranch(Prefix, @[annotPrefix, id], annotPrefix.rng.a .. id.rng.b)
  let args = block:
    let token = self.peekToken()
    if token.kind == LeRound and token.spaces.leading == 0 and not token.spaces.wasEndl:
      self.parseList()
    else:
      initAstNodeEmpty()

  result = initAstNodeBranch(ExprRound, @[annot, args])

func parseList(self: var Parser; fn: ParsePrefixFunc): AstNode =
  debug("parseList")

  let token = self.peekToken({LeRound, LeCurly, LeSquare})
  let openBracketInfo = token.rng
  let until = case token.kind:
    of LeRound: RiRound
    of LeCurly: RiCurly
    of LeSquare: RiSquare
    else: unreachable()

  self.skipToken(token.kind)
  var elems        = newSeq[AstNode]()
  let prevPriority = self.priority

  self.priority = none(Priority)
  let mode      = self.parseBlock(elems, mode = Adaptive, until = some(until), fn = fn)
  self.priority = prevPriority
  # TODO: check indentation

  let closeBracketInfo = self.popToken(until).rng
  let rng = openBracketInfo.a .. closeBracketInfo.b

  result = case mode
    of Block:
      if elems.len() == 1: elems[0]
      else: initAstNodeBranch(Block, elems, rng)
    of List: initAstNodeBranch(List, elems, rng)
    else: unreachable()

func parseBlock(
  self: var Parser;
  body: var seq[AstNode];
  mode: ParseMode = Block;
  until: Option[TokenKind];
  fn: ParsePrefixFunc;
): ParseMode =
  debug("parseBlock")

  var contextPushed = false
  var wasSemicolon  = false
  var mode          = mode

  let untilKinds =
    if untilKind =? until: {Eof, untilKind}
    else: {Eof}

  if self.blockStack.isEmpty():
    self.blockStack.push((1, 0))
    contextPushed = true

  while true:
    var token = self.peekToken()

    if token.kind in untilKinds:
      break

    debug(&"parseBlock: mode {mode}, token {self.peekToken().human()}")

    if token.spaces.wasEndl:
      let token = self.peekToken()
      let indent = token.spaces.leading

      if mode == Block and wasSemicolon:
        raiseParserError("expected expression after semicolon", token.rng)

      if contextPushed:
        # check indentation of token
        if indent > self.blockStack.peek().indent:
          raiseParserError(
            &"invalid indentation, expected {self.blockStack.peek().indent}, got {indent}",
            token.rng)
        elif indent < self.blockStack.peek().indent:
          # end of block
          break
      else:
        # create a new context
        let newContext = (line: token.rng.a.line.int, indent: indent)

        # validate new context
        if not self.isNewBlockContext(newContext):
          raiseParserError(
            &"a new block context expected, but got {newContext}, " &
            &"which is the same or lower with previous context {self.blockStack.peek()}",
            token.rng)

        # push a new context
        self.blockStack.push(newContext)
        contextPushed = true
    else:
      # FIXME: a lot of bugs here
      let token = self.peekToken()
      if mode == Block and not wasSemicolon:
        raiseParserError(
          &"expected semicolon or newline after expression, got {token.kind}",
          token.rng)
      wasSemicolon = false

    let tree = fn(self)
    token = self.peekToken()

    if tree.kind != Empty:
      body &= tree

    if mode == Adaptive:
      mode = case token.kind:
        of Comma:
          List
        of Semicolon:
          Block
        elif token.kind in untilKinds:
          List
        elif token.spaces.wasEndl:
          Block
        else:
          raiseParserError(
            &"expected comma, semicolon or newline after expression, got {token.kind}",
            token.rng)
      hint(&"determine mode of block parsing: {mode}, token is {token.kind} {token.human()}")

    case mode
    of Block:
      if self.skipTokenMaybe(Semicolon):
        wasSemicolon = true
    of List:
      if not self.skipTokenMaybe(Comma):
        let token = self.peekToken()

        if token.kind notin untilKinds:
          raiseParserError(&"expected comma after expression", self.prevToken().rng)

        break
    else:
      unreachable()

  if mode == Adaptive:
    # something like `()` or `[]`
    mode = List

  if mode == Block and wasSemicolon:
    raiseParserError("expected expression after semicolon", self.prevToken().rng)

  if contextPushed:
    self.blockStack.drop()

  result = mode

#
# API
#

func newParser*(tokens: openArray[Token]; isModule = true): Parser =
  ## The `isModule` parameter specifies that `tokens` should
  ## contain a top-level declaration of the module name
  result = Parser(tokens: @tokens, isModule: isModule)
  result.prefixFuncs[Id]       = parseId
  result.prefixFuncs[LeRound]  = parseList
  result.prefixFuncs[LeCurly]  = parseList
  result.prefixFuncs[LeSquare] = parseList
  result.prefixFuncs[At]       = parseAnnotation
  result.prefixFuncs[KwNot]    = parseNot
  result.prefixFuncs[KwDo]     = parseDo
  result.prefixFuncs[KwStruct] = parseStruct
  result.prefixFuncs[KwType]   = parseType
  result.prefixFuncs[KwFunc]   = parseFunc
  result.prefixFuncs[KwVal]    = parseVal
  result.prefixFuncs[KwVar]    = parseVar
  result.prefixFuncs[KwIf]     = parseIf
  result.prefixFuncs[KwWhile]  = parseWhile
  result.prefixFuncs[KwReturn] = parseReturn
  result.prefixFuncs[KwModule] = parseModule
  result.prefixFuncs[KwUsing]  = parseUsing

  result.prefixFuncs[Dollar]    = parsePrefix
  result.prefixFuncs[Ampersand] = parsePrefix
  result.prefixFuncs[KwNil]     = parseLit
  result.prefixFuncs[KwTrue]    = parseLit
  result.prefixFuncs[KwFalse]   = parseLit
  result.prefixFuncs[IntLit]    = parseLit
  result.prefixFuncs[FloatLit]  = parseLit
  result.prefixFuncs[StringLit] = parseLit
  result.prefixFuncs[CharLit]   = parseLit

  result.infixFuncs[KwAnd]    = parseInfix
  result.infixFuncs[KwOr]     = parseInfix
  result.infixFuncs[EqOp]     = parseInfix
  result.infixFuncs[NeOp]     = parseInfix
  result.infixFuncs[LtOp]     = parseInfix
  result.infixFuncs[GtOp]     = parseInfix
  result.infixFuncs[LeOp]     = parseInfix
  result.infixFuncs[GeOp]     = parseInfix
  result.infixFuncs[Plus]     = parseInfix
  result.infixFuncs[Minus]    = parseInfix
  result.infixFuncs[Asterisk] = parseInfix
  result.infixFuncs[Slash]    = parseInfix
  result.infixFuncs[Percent]  = parseInfix
  result.infixFuncs[Shl]      = parseInfix
  result.infixFuncs[Shr]      = parseInfix

  result.infixFuncs[LeCurly]  = parseInfixCurly
  result.infixFuncs[LeRound]  = parseInfixRound
  result.infixFuncs[LeSquare] = parseInfixSquare
  result.infixFuncs[Dot]      = parseExprDotExpr

func getAst*(self: Parser): Option[AstNode] =
  self.ast

func parseAll*(self: var Parser)
  {.raises: [LexerError, FmtLexerError, ParserError, ValueError].} =
  debug("parseAll")

  if self.tokens.len() == 0:
    if self.isModule:
      raiseParserError("this file should have the module name declaration at the beginning", emptyFilePos)
    else:
      self.ast = some(initAstNodeEmpty())
      return

  var ast = initAstNodeBranch(Block, @[])

  if self.isModule:
    if self.tokens[0].kind != KwModule:
      raiseParserError(
        "this file should have the module name declaration at the beginning; " &
        &"got {self.tokens[0].kind} instead", self.tokens[0].rng)

  self.parseBlock(ast.children, until = some(Eof))
  self.ast = some(ast)

func parseAll(input: string; posOffset: FilePosition; isModule: bool): Option[AstNode] =
  let tokens = input.getAllTokens(posOffset).normalizeTokens()
  var parser = newParser(tokens, isModule)
  parser.parseAll()
  result = parser.getAst()

func parseExpr(input: string; posOffset: FilePosition; isModule: bool): AstNode =
  let tokens = input.getAllTokens(posOffset).normalizeTokens()
  var parser = newParser(tokens, isModule)
  result = parser.parseExpr()

{.pop.} # raises: []
