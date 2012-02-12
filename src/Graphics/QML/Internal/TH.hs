-- | This module contains the TemplateHaskell helper to define
-- QObjects, along with supporting data types and helpers used in the
-- TH expansion.
module Graphics.QML.Internal.TH (
  -- * Types
  ClassDefinition(..),
  QPointer,

  -- * Functions
  defClass,
  emitSignal,

  -- * Internal (used in TH expansions)
  Property(..),
  Method(..),
  Signal(..),
  InternalClassDefinition(..),
  hsqmlAllocaBytes,
  hsqmlAlloca,
  hsqmlCastPtr,
  hsqmlPokeElemOff,
  hsqmlPeekElemOff,
  hsqmlStorableSizeOf
  ) where

import Data.Bits
import Data.List ( foldl' )
import Foreign.C.Types
import Foreign.Marshal.Alloc ( allocaBytes, alloca )
import Foreign.Ptr ( Ptr, castPtr )
import Foreign.Storable ( Storable, peekElemOff, pokeElemOff, sizeOf )
import Language.Haskell.TH

import Graphics.QML.Internal.Primitive
import Graphics.QML.Internal.Core

type QPointer = Ptr ()

data Property =
  Property { propertyName :: String
           , propertyType :: TypeName
           , propertyReadFunc :: UniformFunc
           , propertyWriteFunc :: Maybe UniformFunc
           , propertyFlags :: CUInt
           }

data Method =
  Method { methodName  :: String -- ^ The name of the 'Method'
         , methodTypes :: [TypeName] -- ^ Gets the 'TypeName's which
                                    -- comprise the signature of a
                                    -- 'Method'.  The head of the list
                                    -- is the return type and the tail
                                    -- the arguments.
         , methodFunc  :: UniformFunc
         }

data Signal =
  Signal { signalName :: String
         , signalArgTypes :: [TypeName]
         }

data ClassDefinition = ClassDef {
  className :: Name,
  classVersion :: (Int, Int),
  classURI :: String,
  classProperties :: [ProtoClassProperty],
  classMethods :: [ProtoClassMethod],
  classSignals :: [Name], -- [ProtoSignal],
  classConstructor :: Name,
  classSelfAccessor :: Name
  }

data InternalClassDefinition tt = InternalClassDef {
  _classVersion :: (Int, Int),
  _classURI :: String,
  _classProperties :: [Property],
  _classMethods :: [Method],
  _classSignals :: [Signal],
  _classConstructor :: QPointer -> IO tt,
  _classSelfAccessor :: tt -> QPointer
  }

-- | This function takes a declarative class description (via the
-- 'ClassDefinition' type) and converts it into an instance
-- declaration and definitions of all of the requested signals.
defClass :: ClassDefinition -> Q [Dec]
defClass cd = do
  let clsName = className cd
  -- This is the instance declaration of the form:
  --
  -- > instance MetaObject <Type> where
  -- >   classDefinition = cd
  --
  -- Since we want to use the argument in the generated code, we have
  -- to lift it into an Exp in the Q monad.
  --
  -- The Marhsal instance for the type will handle actually using this
  -- definition to create and register the type inside of Qt.
  tdef <- translateDef cd
  let clsDef = ValD (VarP (mkName "classDefinition")) (NormalB tdef) []
      itype = AppT (ConT (mkName "MetaObject")) (ConT clsName)
      instanceDec = InstanceD [] itype [clsDef]

  -- The only other thing we need to do is define functions for each
  -- signal.
  --
  -- > signalName :: tt -> t1 -> t2 -> .. -> IO ()
  sigDefs <- mapM (buildSignal clsName) (zip [0..] (classSignals cd))

  return $! instanceDec : concat sigDefs

translateDef :: ClassDefinition -> Q Exp
translateDef pcd = do
  tms <- trMethods (classMethods pcd)
  tprops <- trProperties (classProperties pcd)
  let (majV, minV) = classVersion pcd
      cdName = mkName "InternalClassDef"
      uriField = (mkName "_classURI", LitE (StringL (classURI pcd)))
      verField = (mkName "_classVersion", TupE [mkIntLit majV, mkIntLit minV])
      sigField = (mkName "_classSignals", trSigs (classSignals pcd))
      methField = (mkName "_classMethods", tms)
      propField = (mkName "_classProperties", tprops)
      consField = (mkName "_classConstructor", VarE (classConstructor pcd))
      accField = (mkName "_classSelfAccessor", VarE (classSelfAccessor pcd))

      flds = [ uriField
             , verField
             , sigField
             , methField
             , propField
             , consField
             , accField
             ]

  return $! RecConE cdName flds
  where
    mkIntLit :: Int -> Exp
    mkIntLit = LitE . IntegerL . fromIntegral

trProperties :: [ProtoClassProperty] -> Q Exp
trProperties ps = mapM trProp ps >>= (return . ListE)
  where
    trProp (PProperty n g s fs) = do
      -- Look at the type of the getter (since it must exist) to infer
      -- the type of the property.
      VarI _ gt _ _ <- reify g
      let (_, propTypeIO) = splitTypes gt
          propType = removeIOWrapper propTypeIO
          flag = foldr (.|.) 0 fs
          c1 = AppE (ConE (mkName "Property")) (LitE (StringL n))
          c2 = AppE c1 (typeToTypeNameExp propType)
      c3 <- (mkUniformFunc g) >>= (return . AppE c2)
      c4 <- (maybeMkUniformFunc s) >>= (return . AppE c3)
      let flagEx = AppE (VarE (mkName "fromIntegral")) (LitE (IntegerL (fromIntegral flag)))
          c5 = AppE c4 flagEx
      return c5
    mkUniformFunc n = do
      let mfuncName = mkName "marshalFunc0"
      let mfunc = VarE mfuncName
      dec <- defMarshalFunc 0
      return $! LetE [dec] (AppE mfunc (VarE n))
    maybeMkUniformFunc Nothing = return $! ConE (mkName "Nothing")
    maybeMkUniformFunc (Just n) = do
      let mfunc = VarE (mkName "hsqmlMarshalMutator")
      return $! AppE (ConE (mkName "Just")) (AppE mfunc (VarE n))

-- | Translate a ProtoMethod to an Exp representing its equivalent
-- Method.
--
-- >
-- > Method { methodName = n, methodFunc = defMethodN mref
-- >        , methodTypes = [ mTypeOf (undefined :: t1), ..] }
trMethods :: [ProtoClassMethod] -> Q Exp
trMethods ms = mapM trMeth ms >>= return . ListE
  where
    trMeth (PMethod qname mref) = do
      -- Figure out the type of the function that the user gave us.
      VarI _ t _ _ <- reify mref
      let (argTypes, rTypeIO) = splitTypes t
          rType = removeIOWrapper rTypeIO
      let c1 = AppE (ConE (mkName "Method")) (LitE (StringL qname))
          -- Use tail on argTypes so that we can drop the this pointer
          -- (which isn't counted in qt method descriptions).
          mtypes = ListE $! map typeToTypeNameExp (rType : tail argTypes)
          c2 = AppE c1 mtypes
      mfunc <- mkUniformFunc mref (tail argTypes)
      return $! AppE c2 mfunc
    mkUniformFunc fname ts = do
      let mfuncName = mkName ("marshalFunc" ++ show (length ts))
      let mfunc = VarE mfuncName
      dec <- defMarshalFunc (length ts)
      return $! LetE [dec] (AppE mfunc (VarE fname))

typeToTypeNameExp :: Type -> Exp
typeToTypeNameExp t =
  let uv = SigE (VarE (mkName "undefined")) t
  in AppE (VarE (mkName "mTypeOf")) uv

-- | Given the Type of a function, split it into the list of argument
-- types and the return type.  The list of argument types is built up
-- in reverse, so reverse it before returning.
--
-- This attempts to give useful errors when encountering a type it
-- can't handle.  Notably, type variables (which are introduced by a
-- forall at this level) are not supported.
splitTypes :: Type -> ([Type], Type)
splitTypes ty =
  let (rt : rest) = split' [] ty
  in (reverse rest, rt)
  where
    split' _ (ForallT _ _ _) =
      error ("Type variables are not supported in methods signatures: "
             ++ pprint ty ++ ".  Fix these types with a type signature.")
    split' acc (AppT (AppT ArrowT t) rest) = split' (t : acc) rest
    split' acc t = t : acc

removeIOWrapper :: Type -> Type
removeIOWrapper (AppT _ inner) = inner
removeIOWrapper t = error ("Illegal type (not wrapped in IO): " ++ pprint t)

-- | Convert a ProtoSignal to an Exp representing a Signal to be
-- spliced into the ClassDefinition
trSigs :: [ProtoSignal] -> Exp
trSigs = ListE . map trSig
  where
    -- | Convert a ProtoSignal descriptor to a Signal descriptor; this
    -- mostly involves translating the named types to TypeNames.
    trSig (PSignal name ts) =
      let c1 = AppE (ConE (mkName "Signal")) (LitE (StringL name))
          tns = ListE (map trType ts)
      in AppE c1 tns
    -- | Take a type name and make an expression of type TypeName:
    --
    -- > mkTypeOf (undefined :: tt)
    --
    -- where @tt@ is the name of the type passed in.
    trType :: Name -> Exp
    trType name =
      let uv = SigE (VarE (mkName "undefined")) (ConT name)
      in AppE (VarE (mkName "mTypeOf")) uv

mkFunType :: [Name] -> Type
mkFunType = foldr addT iot -- (AppT ArrowT iot)
  where
    addT t acc = AppT (AppT ArrowT (ConT t)) acc
    -- addT t acc = AppT ArrowT $ AppT (ConT t) acc
    iot = AppT (ConT (mkName "IO")) (TupleT 0)

-- | Builds a function to emit a signal.  It is of the form:
--
-- > signalName :: tt -> t1 -> t2 -> .. -> IO ()
-- > signalName self v0 v1 v2 ... =
-- >   allocaBytes sz marshalAndCall
-- >   where
-- >     sz = (length vs) * sizeof(nullPtr)
-- >     marshalAndCall p0 = do
-- >       alloca $ \x0 -> do
-- >         marshal x0 v0
-- >         pokeElemOff p0 0 x0
-- >         alloca $ \x1 -> do
-- >           marshal x1 v1
-- >           pokeElemOff p0 1 x1
-- >           ..
-- >           hsqmlEmitSignal (_classSelfAccessor self) signum p0
--
-- The extra accessor is to get the pointer to the underlying QObject
-- instead of the Haskell-side user data.  This pointer is required
-- for the signal dispatch.
buildSignal :: Name -> (Int, ProtoSignal) -> Q [Dec]
buildSignal clsName (signo, (PSignal name ts)) = do
  let sigTy = appT (appT arrowT (conT clsName)) (return (mkFunType ts))

      -- Make a list of variables self v0..vn where self will be the
      -- this ptr
      ixs :: [Int]
      ixs = [0..]
      argVars = take (length ts) $ map (\i -> mkName ("v" ++ show i)) ixs
      cpatt = varP (mkName "self") : map varP argVars

  -- The body of the signal needs to eventually call hsqmlEmitSignal;
  -- however, we want to safely use a stack allocated array so we call
  -- through allocaBytes
  szName <- newName "sz"
  marshalAndCallName <- newName "marshalAndCall"
  let szRef = varE szName
      marshalAndCall = varE marshalAndCallName
      body0 = appE (varE (mkName "hsqmlAllocaBytes")) szRef
      body1 = appE body0 marshalAndCall

      -- | The size is the sum of all of the sizes of the arguments
      -- (we need this to compute the size of the buffer to allocate).
      --
      -- > nArgs * qmlStorableSizeOf (undefined :: QPointer)
      sizeOfFunc = varE (mkName "hsqmlStorableSizeOf")
      undefVal = varE (mkName "undefined")
      ptrType = conT (mkName "QPointer")
      ptrSize = appE sizeOfFunc (sigE undefVal ptrType)
      mulOp = varE (mkName "*")
      nSlots = litE (integerL (fromIntegral (length ts)))
      szBody = infixApp ptrSize mulOp nSlots
      szDef = valD (varP szName) (normalB szBody) []

      argsWithTypes = zip argVars ts
      mshDef = mkMarshalAndCall signo marshalAndCallName (varE (mkName "self")) argsWithTypes

  sig <- sigD (mkName name) sigTy
  fdef <- funD (mkName name) [clause cpatt (normalB body1) [szDef, mshDef]]
  return [sig, fdef]
  where
    mSizeOfRef = varE (mkName "mSizeOf")
    mkSizeOf v = appE mSizeOfRef (varE v)

-- | Make a function that takes a pointer to an allocated array of
-- pointers.  Fills the array with pointers to allocad memory and then
-- passes the filled array to hsqmlEmitSignal
mkMarshalAndCall :: Int -> Name -> ExpQ -> [(Name, Name)] -> DecQ
mkMarshalAndCall signo mname self vs = do
  p0Name <- newName "vec"
  let body = doE [foldr (wrapInArgMarshal p0Name) (mkEmit p0Name) (zip [0..] vs)]
      defClause = clause [varP p0Name] (normalB body) []
  funD mname [defClause]
  {-
--  pNames@(p0Name:_) <- mapM (\ix -> newName ("p" ++ show ix)) [0..length vs]

  -- Note that the ptr offset bindings (the pN variables) start at p1
  -- since p0 is the parameter to the function.  The last pN and vN
  -- are not needed to make these bindings.
  let ps = map mkPtrOffsetBinding (zip3 (tail pNames) pNames vs)
      ms = map mkMshl (zip pNames vs)
      body = normalB $ doE (concat [ ps, ms, [mkEmit p0Name] ])
      defClause = clause [varP p0Name] body []
  funD mname [defClause]
-}
  where
    mshlFunc = varE (mkName "marshal")
    szFunc = varE (mkName "mSizeOf")
    ptrAddFunc = varE (mkName "hsqmlPlusPtr")
    allocaFunc = varE (mkName "hsqmlAlloca")
    pokeFunc = varE (mkName "hsqmlPokeElemOff")
    castFunc = varE (mkName "hsqmlCastPtr")
    -- >     marshalAndCall p0 = do
-- >       alloca $ \x0 -> do
-- >         marshal x0 v0
-- >         pokeElemOff p0 0 x0
-- >         alloca $ \x1 -> do
-- >           marshal x1 v1
-- >           pokeElemOff p0 1 x1
-- >           ..
-- >           hsqmlEmitSignal (_classSelfAccessor self) signum p0

    wrapInArgMarshal p0 (argno, (argName, argTyName)) innerExp = do
      xN <- newName ("x" ++ show argno)
      xNt <- newName ("x" ++ show argno ++ "t")
      let ptrTy = appT (conT (mkName "Ptr")) (conT argTyName)
          argSig = sigD xNt ptrTy
          argBind = valD (varP xNt) (normalB (varE xN)) []
          letBind = letS [argSig, argBind]
          mar = mkMshl xNt argName
          poke = mkPoke p0 argno xNt
          doBlock = doE [ letBind, mar, poke, innerExp ]
      noBindS $ appE allocaFunc (lam1E (varP xN) doBlock)

    -- | > marshal p v
    mkMshl p v =
      let castedPtr = appE castFunc (varE p)
      in noBindS $ appE (appE mshlFunc castedPtr) (varE v)
    mkPoke p0 argno xN =
      let ix = litE (integerL (fromIntegral argno))
          castedPtr = appE castFunc (varE xN)
      in noBindS $ appE (appE (appE pokeFunc (varE p0)) ix) castedPtr
    -- | Make a monadic let binding of the form
    --
    -- > let res = plusPtr (mSizeOf v) p
    mkPtrOffsetBinding (res, p, v) =
      letS [valD (varP res) (normalB ptrAdd) []]
      where
        sz = appE szFunc (varE v)
        ptrAdd = appE (appE ptrAddFunc (varE p)) sz
    -- | > hsqmlEmitSignal self signo p0
    mkEmit p0Name =
      let emit = varE (mkName "hsqmlEmitSignal")
          sigEx = litE (integerL (fromIntegral signo))
          accFunc = appE (varE (mkName "_classSelfAccessor")) (varE (mkName "classDefinition"))
          selfToPtr = appE accFunc self
      in noBindS $ appE (appE (appE emit selfToPtr) sigEx) (varE p0Name)

-- | Builds a marshaller from Haskell function with the given arity to
-- a UniformFunc (which can be called by Qt).
defMarshalFunc :: Int -> Q Dec
defMarshalFunc i = do
  r <- newName "r"
  pv <- newName "pv"
  f <- newName "f"
  p0 <- newName "p0"
  pr <- newName "pr"
  v0 <- newName "v0"
  let vNs = map (\ix -> VarE (mkName ("v" ++ show ix))) [1..i]
  let name = mkName ("marshalFunc" ++ show i)
      fpatt = [VarP f, VarP p0, VarP pv]
      peekPr = BindS (VarP pr) (AppE (AppE peekOff (VarE pv)) (LitE (IntegerL 0)))
      unmarThis = BindS (VarP v0) (AppE unmar (VarE p0))
      peeks = map (mkPeek pv) [1..i]
      unmars = map mkUnm [1..i]
      -- The call with all of the unmarshaled params
      call = BindS (VarP r) $ foldl' AppE (AppE (VarE f) (VarE v0)) vNs
      ret = NoBindS $ (AppE (AppE marRet (VarE pr)) (VarE r))

      body = DoE $! concat [[peekPr, unmarThis], peeks, unmars, [call, ret]]
      cls = Clause fpatt (NormalB body) []

  return $! FunD name [cls]
  where
    marRet = VarE (mkName "hsqmlMarshalRet")
    peekOff = VarE (mkName "hsqmlPeekElemOff")
    unmar = VarE (mkName "unmarshal")
    mkPeek pv ix =
      let p = mkName ("p" ++ show ix)
      in BindS (VarP p) (AppE (AppE peekOff (VarE pv)) (LitE (IntegerL (fromIntegral i))))
    mkUnm ix =
      let v = mkName ("v" ++ show ix)
          p = mkName ("p" ++ show ix)
      in BindS (VarP v) (AppE unmar (VarE p))

-- | Define a signal
--
-- > defSignal ''ClassName "signalName" [''Int, ''Int, ''String]
--
-- defines a signal for ClassName that takes three arguments.
defSignal :: Name -> String -> [Name] -> Q Dec
defSignal = undefined

-- Functions referenced in TH expansions.  We export them with
-- prefixed names to hopefully avoid collisions with user code.

hsqmlCastPtr :: Ptr a -> Ptr b
hsqmlCastPtr = castPtr

hsqmlPokeElemOff :: (Storable a) => Ptr a -> Int -> a -> IO ()
hsqmlPokeElemOff = pokeElemOff

hsqmlAlloca :: (Storable a) => (Ptr a -> IO b) -> IO b
hsqmlAlloca = alloca

hsqmlAllocaBytes :: Int -> (Ptr a -> IO b) -> IO b
hsqmlAllocaBytes = allocaBytes

hsqmlPeekElemOff :: (Storable a) => Ptr a -> Int -> IO a
hsqmlPeekElemOff = peekElemOff

hsqmlStorableSizeOf :: (Storable a) => a -> Int
hsqmlStorableSizeOf = sizeOf
