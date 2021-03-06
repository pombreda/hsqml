{-# LANGUAGE
    ForeignFunctionInterface
  #-}

module Graphics.QML.Internal.Classes where

import Foreign.C.String
import Foreign.C.Types
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.StablePtr
import Foreign.Storable
import System.IO.Unsafe

import Graphics.QML.Internal.Core

#include "hsqml.h"


foreign import ccall "wrapper"
  marshalFunc :: UniformFunc -> IO (FunPtr UniformFunc)

foreign import ccall "wrapper"
  marshalPlacementFunc :: PlacementFunc -> IO (FunPtr PlacementFunc)

{#pointer *HsQMLClassHandle as ^ foreign newtype #}

foreign import ccall "hsqml.h &hsqml_finalise_class_handle"
  hsqmlFinaliseClassHandlePtr :: FunPtr (Ptr (HsQMLClassHandle) -> IO ())

newClassHandle :: Ptr HsQMLClassHandle -> IO (Maybe HsQMLClassHandle)
newClassHandle p =
  if nullPtr == p
    then return Nothing
    else do
      fp <- newForeignPtr hsqmlFinaliseClassHandlePtr p
      return $ Just $ HsQMLClassHandle fp

{#fun hsqml_create_class as ^
  {id `Ptr CUInt',
   id `Ptr CChar',
   id `Ptr (FunPtr UniformFunc)',
   id `Ptr (FunPtr UniformFunc)'} ->
  `Maybe HsQMLClassHandle' newClassHandle* #}

{#fun hsqml_allocate_in_place as ^
  {id `Ptr ()',
   id `Ptr ()',
   id `Ptr HsQMLClassHandle'} -> `()' #}

{#fun hsqml_register_type as ^
  {id `FunPtr PlacementFunc',
   `String',
   fromIntegral `Int',
   fromIntegral `Int',
   `String',
   id `Ptr HsQMLClassHandle'} -> `()' #}

{#fun hsqml_emit_signal as ^
  {id `Ptr ()',
   fromIntegral `Int',
   id `Ptr (Ptr ())'} -> `()' #}

{#pointer *HsQMLObjectHandle as ^ newtype #}

objToPtr :: a -> (Ptr () -> IO b) -> IO b
objToPtr obj f = do
  sPtr <- newStablePtr obj
  res <- f $ castStablePtrToPtr sPtr
  return res

withHsQMLClassHandle :: HsQMLClassHandle -> (Ptr HsQMLClassHandle -> IO b) -> IO b
{#fun hsqml_create_object as ^
  {objToPtr* `a',
   withHsQMLClassHandle* `HsQMLClassHandle'} ->
  `HsQMLObjectHandle' id #}

ptrToObj :: Ptr () -> IO a
ptrToObj =
  deRefStablePtr . castPtrToStablePtr

{#fun hsqml_get_haskell as ^
  {id `HsQMLObjectHandle'} ->
  `a' ptrToObj* #}

{#fun hsqml_set_haskell as ^
  {id `Ptr ()',
   id `Ptr ()'} -> `()' #}

{#fun hsqml_allocate_context_object as ^
  {id `Ptr HsQMLClassHandle'} -> `Ptr ()' id #}




{#pointer *HsQMLListHandle as ^ newtype #}

foreign import ccall "hsqml.h &hsqml_list_size"
  hsqmlListSizePtr :: Ptr CInt
hsqmlListSize :: Int
hsqmlListSize = fromIntegral $ unsafePerformIO $ peek hsqmlListSizePtr

{#fun unsafe hsqml_init_list as ^
  {id `HsQMLListHandle'} -> `()' #}
{#fun unsafe hsqml_deinit_list as ^
  {id `HsQMLListHandle'} -> `()' #}
{#fun unsafe hsqml_list_append as ^
  {id `HsQMLListHandle', id `Ptr ()'} -> `()' #}

-- hsqmlMarshalList ::
hsqmlMarshalList lst hdl = do
  mapM_ (addElt hdl) lst
  where
    addElt h o = objToPtr o (hsqmlListAppend h)

hsqmlUnmarshalList hdl = undefined

ofDynamicMetaObject :: CUInt
ofDynamicMetaObject = 0x01

mfAccessPrivate, mfAccessProtected, mfAccessPublic, mfAccessMask,
  mfMethodMethod, mfMethodSignal, mfMethodSlot, mfMethodConstructor,
  mfMethodTypeMask, mfMethodCompatibility, mfMethodCloned, mfMethodScriptable
  :: CUInt
mfAccessPrivate   = 0x00
mfAccessProtected = 0x01
mfAccessPublic    = 0x02
mfAccessMask      = 0x03
mfMethodMethod      = 0x00
mfMethodSignal      = 0x04
mfMethodSlot        = 0x08
mfMethodConstructor = 0x0c
mfMethodTypeMask    = 0x0c
mfMethodCompatibility = 0x10
mfMethodCloned        = 0x20
mfMethodScriptable    = 0x40

pfInvalid, pfReadable, pfWritable, pfResettable, pfEnumOrFlag, pfStdCppSet,
  pfConstant, pfFinal, pfDesignable, pfResolveDesignable, pfScriptable,
  pfResolveScriptable, pfStored, pfResolveStored, pfEditable,
  pfResolveEditable, pfUser, pfResolveUser, pfNotify :: CUInt
pfInvalid           = 0x00000000
pfReadable          = 0x00000001
pfWritable          = 0x00000002
pfResettable        = 0x00000004
pfEnumOrFlag        = 0x00000008
pfStdCppSet         = 0x00000100
pfConstant          = 0x00000400
pfFinal             = 0x00000800
pfDesignable        = 0x00001000
pfResolveDesignable = 0x00002000
pfScriptable        = 0x00004000
pfResolveScriptable = 0x00008000
pfStored            = 0x00010000
pfResolveStored     = 0x00020000
pfEditable          = 0x00040000
pfResolveEditable   = 0x00080000
pfUser              = 0x00100000
pfResolveUser       = 0x00200000
pfNotify            = 0x00400000
