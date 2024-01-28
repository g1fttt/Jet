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

  lib/utils,
  lib/stacks,
  lib/lineinfo,

  pkg/questionable

{.push, raises: [].}

type
  Parser* {.byref.} = object
    tokens      : seq[Token]
    curr        : int = 0
    ast         : Option[AstNode] = none(AstNode)
    blockStack  : Stack[BlockContext]
    prefixFuncs : OrderedTable[TokenKind, ParsePrefixFunc]
    infixFuncs  : OrderedTable[TokenKind, ParseInfixFunc]
    suffixFuncs : OrderedTable[TokenKind, ParseSuffixFunc]
    precedence  : Option[Precedence]

  Precedence = enum
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

  BlockContext = tuple[line, indent: int]

  ParsePrefixFunc = proc(self: var Parser): AstNode {.nimcall, noSideEffect, raises: [ParserError, ValueError].}
  ParseInfixFunc  = proc(self: var Parser; left: AstNode): AstNode {.nimcall, noSideEffect, raises: [ParserError, ValueError].}
  ParseSuffixFunc = proc(self: var Parser; left: AstNode): AstNode {.nimcall, noSideEffect, raises: [ParserError, ValueError].}

func str(kind: TokenKind): string =
  $kind

func `$`(kind: TokenKind): string =
  kind.symbolName()

const precedences = {
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

func parseLit(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseExpr(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseId(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseNot(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseStruct(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseType(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseFunc(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseIf(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseWhile(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseReturn(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseVar(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseVal(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseValDecl(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseParamOrField(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseDo(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseDoOrBlock(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseDoOrExpr(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseExprOrBlock(self: var Parser; fn: ParsePrefixFunc = parseExpr): AstNode {.raises: [ParserError, ValueError].}
func parsePrefix(self: var Parser): AstNode {.raises: [ParserError, ValueError].}
func parseInfix(self: var Parser; left: AstNode): AstNode {.raises: [ParserError, ValueError].}
func parseInfixCurly(self: var Parser; left: AstNode): AstNode {.raises: [ParserError, ValueError].}
func parseInfixRound(self: var Parser; left: AstNode): AstNode {.raises: [ParserError, ValueError].}
func parseInfixSquare(self: var Parser; left: AstNode): AstNode {.raises: [ParserError, ValueError].}
func parseList(self: var Parser; fn: ParsePrefixFunc): AstNode {.raises: [ParserError, ValueError].}
func parseList(self: var Parser): AstNode {.raises: [ParserError, ValueError].} = self.parseList(parseExpr)
func parseBlock(
  self: var Parser;
  body: var seq[AstNode];
  mode: ParseMode = Block;
  until: Option[TokenKind] = none(TokenKind);
  fn: ParsePrefixFunc = parseExpr;
): ParseMode {.discardable, raises: [ParserError, ValueError].}

#
# Util Functions
#

template raiseParserError(message: string; node: AstNode) =
  raise (ref ParserError)(msg: message, rng: node.rng)

template raiseParserError(message: string; fileRange: FileRange) =
  raise (ref ParserError)(msg: message, rng: fileRange)

template raiseParserError(message: string; filePos: FilePosition) =
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
  {.raises: [ParserError, ValueError].} =
  debug("parseIfBranch")
  debug(&"parseIfBranch: {self.peekToken().kind}")

  let token = self.popToken({KwIf, KwElif})
  let cond = self.parseExpr()
  let body = self.parseDoOrBlock()

  result = initAstNodeBranch(IfBranch, @[cond, body], token.rng)

func parseElseBranch(self: var Parser): AstNode
  {.raises: [ParserError, ValueError].} =
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
    of StringLit:
      initAstNodeLit(newLit(token.data), token.rng)
    of CharLit:
      if token.data.len() != 1:
        raise (ref ValueError)(msg: &"invalid character: '{token.data}'")
      initAstNodeLit(newLit(token.data[0]), token.rng)
    of IntLit:
      initAstNodeLit(newLit(token.data.parseBiggestInt()), token.rng)
    of FloatLit:
      initAstNodeLit(newLit(token.data.parseFloat()), token.rng)
    else:
      raiseParserError(&"expected literal, got {token.kind}", token.rng)

func parseExpr(self: var Parser): AstNode =
  debug("parseExpr")

  var token      = self.peekToken()
  let precedence = self.precedence.get(Lowest)
  let fn         = self.prefixFuncs.getOrDefault(token.kind)

  if fn == nil:
    raiseParserError(&"expression is expected, got {token.kind}", token.rng)

  result = fn(self)

  if self.peekToken().kind == Eof:
    return

  while true:
    token = self.peekToken()

    debug(&"parseExpr: precedence = {precedence}")

    if precedence >= precedences.getOrDefault(token.kind, Lowest):
      break

    debug("parseExpr: infix")
    debug(&"parseExpr: token {token.human()}")

    let fn = self.infixFuncs.getOrDefault(token.kind)
    if fn == nil: break
    result = fn(self, result)

  self.precedence = none(Precedence)

func parseId(self: var Parser): AstNode =
  debug("parseId")

  let token = self.popToken(Id)

  result = initAstNodeId(token.data, token.rng)

func parseNot(self: var Parser): AstNode =
  debug("parseNot")

  self.precedence = some(Precedence.Prefix)

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

  let isRec  = self.skipTokenMaybe(KwRec)
  let token  = self.popToken(KwFunc)
  let id     = self.parseId()
  let params = self.parseList(fn = parseParamOrField)
  let returnType =
    if self.prevToken().spaces.trailing != spacingLast and
       self.peekToken().kind != KwDo: self.parseExpr()
    else: initAstNodeEmpty()
  let body = self.parseDoOrBlock()
  let nodeKind =
    if isRec: RecFunc
    else: Func

  result = initAstNodeBranch(nodeKind, @[id, params, returnType, body], token.rng)

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
  let typeExpr =
    if self.peekToken().kind == Eq: initAstNodeEmpty()
    else: self.parseExpr()
  let body =
    if self.skipTokenMaybe(Eq): self.parseDoOrExpr()
    else: initAstNodeEmpty()

  if typeExpr.kind == Empty and body.kind == Empty:
    raiseParserError("variable declaration must have type or expression", id.rng)

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

  if self.peekToken().spaces.wasLF:
    result = initAstNodeBranch(Block, @[])
    self.parseBlock(result.children, fn = fn)
  else:
    result = fn(self)

func parsePrefix(self: var Parser): AstNode =
  let token = self.popToken({Ampersand, Dollar})

  # TODO: precedence

  result = case token.kind:
    of Ampersand:
      let refOp = initAstNodeOperator(OpRef, token.rng)
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

  self.precedence = some do:
    try:
      precedences[token.kind]
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
  var elems = newSeq[AstNode]()
  let prevPrecedence = self.precedence
  self.precedence = none(Precedence)
  let mode = self.parseBlock(elems, mode = Adaptive, until = some(until), fn = fn)
  self.precedence = prevPrecedence
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

    if token.spaces.wasLF:
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
        elif token.spaces.wasLF:
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

func parseAll*(self: var Parser)
  {.raises: [ParserError, ValueError].} =
  debug("parseAll()")
  if self.tokens.len() == 0:
    self.ast = some(initAstNodeEmpty())
    return

  var ast = initAstNodeBranch(Block, @[])
  self.parseBlock(ast.children, until = some(Eof))
  self.ast = some(ast)

func getAst*(self: Parser): Option[AstNode] =
  self.ast

func newParser*(tokens: openArray[Token]): Parser =
  result = Parser(tokens: @tokens)
  result.prefixFuncs[Id]       = parseId
  result.prefixFuncs[LeRound]  = parseList
  result.prefixFuncs[LeCurly]  = parseList
  result.prefixFuncs[LeSquare] = parseList
  result.prefixFuncs[KwNot]    = parseNot
  result.prefixFuncs[KwDo]     = parseDo
  result.prefixFuncs[KwStruct] = parseStruct
  result.prefixFuncs[KwType]   = parseType
  result.prefixFuncs[KwRec]    = parseFunc
  result.prefixFuncs[KwFunc]   = parseFunc
  result.prefixFuncs[KwVal]    = parseVal
  result.prefixFuncs[KwVar]    = parseVar
  result.prefixFuncs[KwIf]     = parseIf
  result.prefixFuncs[KwWhile]  = parseWhile
  result.prefixFuncs[KwReturn] = parseReturn

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

{.pop.} # raises: []
