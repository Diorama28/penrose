-- | The "Style" module contains the compiler for the Style language,
-- and functions to traverse the Style AST, which are used by "Runtime"
{-# OPTIONS_HADDOCK prune #-}
module Style where
-- module Main (main) where -- for debugging purposes

import Shapes
import Utils
import Control.Monad (void)
import Data.Either (partitionEithers)
import Data.Either.Extra (fromLeft)
import Data.Maybe (fromMaybe)
import Text.Megaparsec
import Text.Megaparsec.Expr
import Text.Megaparsec.String -- input stream is of the type ‘String’
import System.Environment
import qualified Substance as C
import Functions (objFuncDict, constrFuncDict, ObjFnOn, Weight, ConstrFnOn)
import qualified Data.Map.Strict as M
import qualified Text.Megaparsec.Lexer as L

--------------------------------------------------------------------------------
-- Style AST

-- | All geometric object types supported by Style so far.
data StyObj = Ellip | Circle | Box | Dot | Arrow | NoShape | Color | Text | Auto
    deriving (Show)

-- | A type frequently used in the module. A style object such as a 'Circle' has parameters like its radius attached to it. This is a tuple associating the object with its parameters.
type StyObjInfo
    = (StyObj, M.Map String Expr)

-- | Style specification for a particular object declared in Substance
-- (TODO: maybe this is not the best model, since we are seeing more cases where the relationship is one-to-many or vice versa)
data StySpec = StySpec {
    spType :: C.SubType, -- | The Substance type of the object
    spId :: String, -- | The ID of the object
    spArgs :: [String], -- | the "arguments" that the Substance object has. Maybe not the best term here. The idea is to capture @A@ and @B@ in the case of @Map f A B@
    spShape :: StyObjInfo, -- | primary geometry associated with the Substance object, specified by @shape = Circle { }@
    spShpMap :: M.Map String StyObjInfo
} deriving (Show)

-- | A Style program is a collection blocks
type StyProg = [Block]

-- | A Style block contains a list of selectors and statements
type Block = ([Selector], [Stmt])

-- | A selector is some pattern annotated by a __Substance type__.
data Selector = Selector
              { selTyp :: C.SubType -- type of Substance object
              , selPatterns :: [Pattern] -- a list of patterns: ids or wildcards
          } deriving (Show)

-- | So far we have two kinds of patters:
--
-- * Raw IDs: 'Set `A`', referring to actual IDs from Substance
-- * WildCard: `Set A`, which can be anything with the corresponding type
--
-- They can also be mixed, yielding to partial selectors like 'Subset `A` B', referring to all supersets of 'A'.
data Pattern
    = RawID String
    | WildCard String
    deriving (Show)

-- | A Style statement
data Stmt
    = Assign String Expr -- binding to geometric primitives: 'shape =  Circle {}'
    | ObjFn String [Expr] -- adding an objective function
    | ConstrFn String [Expr] -- adding a constraint function
    | Avoid String [Expr] -- to be implemented, stating an objective that we would like to avoid
    deriving (Show)

-- | A Style expression, typically appears on the righthand side of assignment statements
data Expr
    = IntLit Integer
    | FloatLit Float
    | Id String
    | BinOp BinaryOp Expr Expr
    | Cons StyObj [Stmt] -- | Constructors for objects
    deriving (Show)

-- TODO: this feature is NOT fully implemented. As if now, we do not support chained dot-access to arbitrary elements in the environment.
-- Difficulty: the return type of each access might be different. What is a good way to resolve this?
data BinaryOp = Access deriving (Show)

data Color = RndColor | Colo
          { r :: Float
          , g :: Float
          , b :: Float
          , a :: Float }
          deriving (Show)

--------------------------------------------------------------------------------
-- Style Parser

-- | 'styleParser' is the top-level function that parses a Style proram
styleParser :: Parser [Block]
styleParser = between sc eof styProg

-- | `styProg` parses a Style program, consisting of a collection of blocks
styProg :: Parser [Block]
styProg = some block

-- | Style blocks
block :: Parser Block
block = do
    sel <- selector `sepBy1` comma
    void (symbol "{")
    try newline'
    sc
    stmts <- try stmtSeq
    void (symbol "}")
    newline'
    return (sel, stmts)

-- | a selector can be either a global selector or constructor selector
selector :: Parser Selector
selector = constructorSelect <|> globalSelect

-- | a global selector matches on all types of objects. Normally used as the only selector in a "global block", where all Substance identifiers are visible
globalSelect :: Parser Selector
globalSelect = do
    -- i <- WildCard <$> identifier
    rword "global"
    return $ Selector C.AllT []

-- | a constructor selector selects Substance objects in a similar syntax as they were declared in Substance
-- TODO: with the exception of some new grammars that we developed, such as 'f: A -> B'. You still have to do 'Map A B' to select this object.
constructorSelect :: Parser Selector
constructorSelect = do
    typ <- C.subtype
    pat <- patterns
    return $ Selector typ pat

-- | a pattern can be a list of the mixture of wildcard bindings and concrete IDs
patterns :: Parser [Pattern]
patterns = many pattern
    where pattern = (WildCard <$> identifier <|> RawID <$> backticks identifier)

-- | parses the type of Style object
styObj :: Parser StyObj
styObj =
       (rword "Color"   >> return Color)   <|>
       (rword "None"    >> return NoShape) <|>
       (rword "Arrow"   >> return Arrow)   <|>
       (rword "Text"    >> return Text)    <|>
       (rword "Circle"  >> return Circle)  <|>
       (rword "Ellipse" >> return Ellip)   <|>
       (rword "Box"     >> return Box)     <|>
       (rword "Dot"     >> return Dot)

-- | a sequence of Style statements
stmtSeq :: Parser [Stmt]
stmtSeq = endBy stmt newline'

-- | a Style statement can be objective/constraint function calls or assignment statements
stmt :: Parser Stmt
stmt =
    try objFn
    <|> try assignStmt
    <|> try avoidObjFn
    <|> try constrFn
    <|> try constrFnInfix
    <|> try objFnInfix

assignStmt :: Parser Stmt
assignStmt = do
    var  <- attribute
    sc
    void (symbol "=")
    e    <- expr
    return (Assign var e)

-- | objective function call
objFn :: Parser Stmt
objFn = do
    rword "objective"
    fname  <- identifier
    void (symbol "(")
    params <- expr `sepBy` comma
    void (symbol ")")
    return (ObjFn fname params)

-- | objective function call - infix version
objFnInfix :: Parser Stmt
objFnInfix = do
    rword "objective"
    arg1  <- expr
    fname <- identifier
    arg2  <- expr
    return (ObjFn fname [arg1, arg2])

-- | (TODO: to be implemented) "avoid" objective function call
avoidObjFn :: Parser Stmt
avoidObjFn = do
    rword "avoid"
    fname  <- identifier
    lbrac
    params <- expr `sepBy` comma
    rbrac
    return (Avoid fname params)

-- | constraint function call
constrFn :: Parser Stmt
constrFn = do
    rword "constraint"
    fname  <- identifier
    void (symbol "(")
    params <- expr `sepBy` comma
    void (symbol ")")
    return (ConstrFn fname params)

-- | constraint function call -- infix version
constrFnInfix :: Parser Stmt
constrFnInfix = do
    rword "constraint"
    arg1  <- expr
    fname <- identifier
    arg2  <- expr
    return (ConstrFn fname [arg1, arg2])

expr :: Parser Expr
expr =  try objConstructor
    <|> makeExprParser term operators
    <|> none
    <|> auto
    <|> number

term :: Parser Expr
term = Id <$> identifier

operators :: [[Operator Parser Expr]]
operators = [ [ InfixL (BinOp Access <$ symbol ".")] ]

-- | Special keyword @None@, normally written as @shape = None@, making the system not render the Substance object
none :: Parser Expr
none = do
    rword "None"
    return $ Cons NoShape []

-- | Special keyword @Auto@, currently used on labels. When specified, the system automatically generates a label using the object's Substance ID.
auto :: Parser Expr
auto = do
    rword "Auto"
    return $ Cons Auto []

objConstructor :: Parser Expr
objConstructor = do
    typ <- styObj
    lbrac >> newline'
    stmts <- stmtSeq
    rbrac  -- NOTE: not consuming the space because stmt already does
    return $ Cons typ stmts

number :: Parser Expr
number =  FloatLit <$> try float <|> IntLit <$> integer

attribute :: Parser String
attribute = many alphaNumChar

-- TODO: use the PrettyPrint library
-- styPrettyPrint :: Block -> String
-- styPrettyPrint b = ""

--------------------------------------------------------------------------------
-- Functions used by "Runtime"

----- Parser for Style design

-- | Type aliases for readability in this section
type StyDict = M.Map Name StySpec
-- | A VarMap matches lambda ids in the selector to the actual selected id
type VarMap  = M.Map Name Name

initSpec :: StySpec
initSpec = StySpec { spType = C.PointT, spId = "", spShape = (NoShape, M.empty),  spArgs = [], spShpMap = M.empty}

-- | 'getDictAndFns' is the top-level function used by "Runtime", which returns a dictionary of Style configuration and all objective and constraint fucntions generated by Style
-- TODO: maybe generate objects directly?
getDictAndFns :: (Floating a, Real a, Show a, Ord a) =>
    ([C.SubDecl], [C.SubConstr]) -> StyProg
    -> (StyDict, [(ObjFnOn a, Weight a, [Name], [a])], [(ConstrFnOn a, Weight a, [Name], [a])])
getDictAndFns (decls, constrs) blocks = foldl procBlock (initDict, [], []) blocks
    where
        res = getSubTuples decls ++ getConstrTuples constrs
        ids = map (\(x, y, z) -> (x, y)) res
        initDict = foldl (\m (t, n, a) ->
                        M.insert n (initSpec { spId = n, spType = t, spArgs = a }) m) M.empty res

-- |  'procBlock' is called by 'getDictAndFns'. 'getDictAndFns' would fold this function on a list of blocks, a.k.a. a Style program, and accumulate objective/constraint functions, and a dictionary of geometries to be rendered.
procBlock :: (Floating a, Real a, Show a, Ord a) =>
    (StyDict, [(ObjFnOn a, Weight a, [Name], [a])], [(ConstrFnOn a, Weight a, [Name], [a])])
    -> Block
    -> (StyDict, [(ObjFnOn a, Weight a, [Name], [a])], [(ConstrFnOn a, Weight a, [Name], [a])])
procBlock (dict, objFns, constrFns) (selectors, stmts) = (newDict, objFns ++ newObjFns, constrFns ++ newConstrFns)
    where
        select s = M.elems $ M.filter (matchSel s) dict
        -- selectedSpecs :: [[(VarMap, StySpec)]]
        selectedSpecs = map
            (\s -> let xs = select s
                       vs = map (getVarMap s) xs in zip vs xs) selectors
        allVars = M.fromList $ zip k k where k = M.keys dict
        -- Combination of all selected (spec. varmap)
        allCombs = filter (\x -> length x == length selectedSpecs) $ cartesianProduct (map (map fst) selectedSpecs)
        -- $ trStr (concatMap (\x -> show x ++ "\n") $ map (map fst) selectedSpecs)
        mergedMaps = if length selectors == 1 && (selTyp . head) selectors == C.AllT then [allVars] else map M.unions (filter noDup allCombs)
        noDup ms = validMap $ concatMap M.toAscList ms
        validMap ts = and . tr "result" . fst $ foldl
            (\(l, m) (x, y) -> case M.lookup x m of
                Nothing -> (True:l, M.insert x y m)
                Just y' -> ((tr ("compare: " ++ y ++ " " ++ y' ++ ": ") $ y == y') : l, m))
            ([], M.empty) (tr "ts" ts)
        -- Only process assignment statements on matched specs, not the cartesion product of them
        updateSpec d (vm, sp) =
            let newSpec = foldl (procAssign vm) sp stmts in
            M.insert (spId newSpec) newSpec d
        newDict = foldl updateSpec dict $ concat selectedSpecs
        genFns f vm = foldl (f vm) [] stmts
        newObjFns    = concatMap (genFns procObjFn) $ tr "mergedMaps: " mergedMaps
        newConstrFns = concatMap (genFns procConstrFn) mergedMaps

-- removeDups :: [[(VarMap, StySpec)]]
-- TODO: reaaly a helper function. consider moving to "Utils"
cartesianProduct = foldr f [[]] where f l a = [ x:xs | x <- l, xs <- a ]

-- | A helper function that returns a map from placeholder ids to actual matched ids.
getVarMap :: Selector -> StySpec -> VarMap
getVarMap sel spec = foldl add M.empty patternNamePairs
    where
        patternNamePairs = zip (selPatterns sel) (spArgs spec)
        add d (p, n) = case p of
            RawID _    -> d
            WildCard i -> M.insert i n d

-- | Returns true of an object matches the selector. A match is made when
--
-- * The types match
-- * The number of arguments match
-- * Identifier and arguments match. A wildcard matches with anything
matchSel :: Selector -> StySpec -> Bool
matchSel sel spec = all test (zip args patterns) &&
                selTyp sel == spType spec &&
                length args == length patterns
    where
        patterns = selPatterns sel
        args = spArgs spec
        -- dummies = selIds sel
        test (a, p) = case p of
            RawID i -> a == i
            WildCard _ -> True

-- | Called repeated by 'procBlock', 'procConstrFn' would lookup and generate constraint functions if the input is a constraint function call. It ignores all other inputs
procConstrFn :: (Floating a, Real a, Show a, Ord a) =>
    VarMap -> [(ConstrFnOn a, Weight a, [Name], [a])] -> Stmt
    -> [(ConstrFnOn a, Weight a, [Name], [a])]
procConstrFn varMap fns (ConstrFn fname es) =
    trStr ("New Constraint function: " ++ fname ++ " " ++ (show names)) $
    fns ++ [(func, defaultWeight, names, nums)]
    where
        func = case M.lookup fname constrFuncDict of
            Just f -> f
            Nothing -> error "procConstrFn: constraint function not known"
        (names, nums) = partitionEithers $ map (procExpr varMap) es
procConstrFn varMap fns _ = fns -- TODO: avoid functions

-- | Similar to `procConstrFn` but for objective functions
procObjFn :: (Floating a, Real a, Show a, Ord a) =>
    VarMap -> [(ObjFnOn a, Weight a, [Name], [a])] -> Stmt
    -> [(ObjFnOn a, Weight a, [Name], [a])]
procObjFn varMap fns (ObjFn fname es) =
    trStr ("New Objective function: " ++ fname ++ " " ++ (show names)) $
    fns ++ [(func, defaultWeight, names, nums)]
    where
        func = case M.lookup fname objFuncDict of
            Just f -> f
            Nothing -> error "procObjFn: objective function not known"
        (names, nums) = partitionEithers $ map (procExpr varMap) es
procObjFn varMap fns (Avoid fname es) = fns -- TODO: avoid functions
procObjFn varMap fns _ = fns -- TODO: avoid functions

-- TODO: Have a more principled expr look up routine
lookupVarMap s varMap= case M.lookup s varMap of
    Just s -> s
    Nothing  -> (error $ "lookupVarMap: incorrect variable mapping from " ++ s)

-- | Resolve a Style expression, which could be operations among expressions such as a chained dot-access for an attribute through a couple of layers of indirection (TODO: hackiest part of the compiler, rewrite this)
procExpr :: (Floating a, Real a, Show a, Ord a) =>
    VarMap -> Expr -> Either String a
procExpr d (Id s)  = Left $ lookupVarMap s d
-- FIXME: properly resolve access by doing lookups
procExpr d (BinOp Access (Id i) (Id "label"))  = Left $ labelName $ lookupVarMap i d
procExpr d (BinOp Access (Id i) (Id "shape"))  = Left $ lookupVarMap i d
procExpr _ (IntLit i) = Right $ r2f i
procExpr _ (FloatLit i) = Right $ r2f i
procExpr _ _  = error "expr: argument unsupported!"

procAssign :: VarMap -> StySpec -> Stmt -> StySpec
procAssign varMap spec (Assign n (Cons typ stmts)) =
    if n == "shape" then spec { spShape = (typ, configs) } -- primary shape
        else spec { spShpMap = M.insert n (typ, configs) $ spShpMap spec } -- secondary shapes
    where
        configs = foldl addSpec M.empty stmts
        -- FIXME: this is incorrect, we should resolve the variables earlier
        addSpec dict (Assign s e@(Cons NoShape _)) = M.insert s (Id "None") dict
        addSpec dict (Assign s e@(Cons Auto _)) = M.insert s (Id "Auto") dict
        -- FIXME: wrap fromleft inside a function!
        addSpec dict (Assign s e) = M.insert s (Id (fromLeft (error "Unexpected ID")$ procExpr varMap e)) dict
        addSpec _ _ = error "procAssign: only support assignments in constructors!"
procAssign _ spec  _  = spec -- TODO: ignoring assignment for all others

-- | Generate a unique id for a Substance constraint
-- FIXME: make sure these names are unique and make sure users cannot start ids
-- with underscores
getConstrTuples :: [C.SubConstr] -> [(C.SubType, String, [String])]
getConstrTuples = map getType
    where getType c = case c of
            C.Intersect a b -> (C.IntersectT, "_Intersect" ++ a ++ b, [a, b])
            C.NoIntersect a b -> (C.NoIntersectT, "_NoIntersect" ++ a ++ b, [a, b])
            C.Subset a b -> (C.SubsetT, "_Subset" ++ a ++ b, [a, b])
            C.NoSubset a b -> (C.NoSubsetT, "_NoSubset" ++ a ++ b, [a, b])
            C.PointIn a b -> (C.PointInT, "_In" ++ a ++ b, [a, b])
            C.PointNotIn a b -> (C.PointNotInT, "_PointNotIn" ++ a ++ b, [a, b])

getSubTuples :: [C.SubDecl] -> [(C.SubType, String, [String])]
getSubTuples = map getType
    where getType d = case d of
            C.Set n -> (C.SetT, n, [n])
            C.Point n -> (C.PointT, n, [n])
            C.Map n a b -> (C.MapT, n, [n, a, b])
            C.Value n a b -> (C.ValueT, "_Value" ++ n ++ a ++ b, [n, a, b])

getAllIds :: ([C.SubDecl], [C.SubConstr]) -> [String]
getAllIds (decls, constrs) = map (\(_, x, _) -> x) $ getSubTuples decls ++ getConstrTuples constrs


--------------------------------------------------------------------------------
-- DEBUG: takes an input file and prints the parsed AST

parseFromFile p file = runParser p file <$> readFile file

main :: IO ()
main = do
    args <- getArgs
    let styFile = head args
    styIn <- readFile styFile
    -- putStrLn styIn
    -- parseTest styleParser styIn
    case runParser styleParser styFile styIn of
         Left err -> putStr (parseErrorPretty err)
         Right xs -> mapM_ print xs
    return ()