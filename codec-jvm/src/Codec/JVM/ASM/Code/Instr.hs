{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Codec.JVM.ASM.Code.Instr where

import Control.Monad.Trans.RWS
import Data.ByteString (ByteString)
import Data.Monoid ((<>))
import Data.List(scanl')
import Data.Maybe(fromMaybe)
import Control.Monad(forM_)

import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as IntMap

import Codec.JVM.ASM.Code.CtrlFlow (CtrlFlow, Stack)
import Codec.JVM.ASM.Code.Types (Offset(..), StackMapTable(..), LabelTable(..))
import Codec.JVM.Cond (Cond)
import Codec.JVM.Const (Const)
import Codec.JVM.Internal (packI16, packI32)
import Codec.JVM.Opcode (Opcode, opcode)
import Codec.JVM.ConstPool (ConstPool)
import Codec.JVM.Types (ReturnType, jint, Label(..))

import qualified Codec.JVM.ASM.Code.CtrlFlow as CF
import qualified Codec.JVM.Cond as CD
import qualified Codec.JVM.ConstPool as CP
import qualified Codec.JVM.Opcode as OP


-- TODO: Fix known space leak with Writer
-- http://stackoverflow.com/questions/25280852/space-leak-in-pipes-with-rwst
type InstrRWS a = (RWS ConstPool (ByteString, StackMapTable) (Offset, CtrlFlow, LabelTable) a)

newtype Instr = Instr (InstrRWS ())

instrRWS :: Instr -> InstrRWS ()
instrRWS (Instr irws) = irws

instance Monoid Instr where
  mempty = Instr $ return mempty
  mappend (Instr rws0) (Instr rws1) = Instr $ do
    rws0
    rws1

instance Show Instr where
  show insr = "Instructions"

withOffset :: (Int -> Instr) -> Instr
withOffset f = Instr $ do
  (Offset offset, _, _)<- get
  instrRWS $ f offset

runInstr :: Instr -> ConstPool -> (ByteString, CtrlFlow, StackMapTable)
runInstr instr cp = runInstr' instr cp 0 CF.empty

runInstr' :: Instr -> ConstPool -> Offset -> CtrlFlow -> (ByteString, CtrlFlow, StackMapTable)
runInstr' (Instr instr) cp offset cf = (bs, cf', smfs)
  where (_, (_, cf', _), (bs, smfs)) = runRWS instr cp (offset, cf, mempty)

modifyStack' :: (Stack -> Stack) -> InstrRWS ()
modifyStack' = ctrlFlow' . CF.mapStack

modifyStack :: (Stack -> Stack) -> Instr
modifyStack = ctrlFlow . CF.mapStack

iif :: Cond -> Instr -> Instr -> Instr
iif cond ok ko = Instr $ do
  lengthOp <- writeInstr ifop
  branches lengthOp ok ko
    where
      ifop = op oc <> modifyStack (CF.pop jint) where
        oc = case cond of
          CD.EQ -> OP.ifeq
          CD.NE -> OP.ifne

-- TODO: This function fails for huge methods, must make it safe
--       when goto offset is outside of −32,768 to 32,767
--       which isn't likely to happen.
branches :: Int -> Instr -> Instr -> InstrRWS ()
branches lengthOp ok ko = do
  (_, cf, _) <- get
  (koBytes, koCF, koFrames) <- pad 2 ko -- packI16
  writeBytes . packI16 $ BS.length koBytes + lengthJumpOK + lengthOp + 2 -- packI16
  write koBytes koFrames
  (okBytes, okCF, okFrames) <- pad lengthJumpOK ok
  op' OP.goto
  writeBytes . packI16 $ BS.length okBytes + 3 -- op goto <> packI16 $ length ok
  writeStackMapFrame
  write okBytes okFrames
  putCtrlFlow' $ CF.merge cf [okCF, koCF]
  writeStackMapFrame
    where
      pad padding instr = do
        cp <- ask
        (Offset offset, cf, _) <- get
        return $ runInstr' instr cp (Offset $ offset + padding) cf
      lengthJumpOK = 3 -- op goto <> pack16 $ length ko

bytes :: ByteString -> Instr
bytes = Instr . writeBytes

ix :: Const -> Instr
ix c = Instr $ do
  cp <- ask
  writeBytes . packI16 $ CP.ix $ CP.unsafeIndex c cp

op :: Opcode -> Instr
op = Instr . op'

op' :: Opcode -> InstrRWS ()
op' = writeBytes . BS.singleton . opcode

ctrlFlow' :: (CtrlFlow -> CtrlFlow) -> InstrRWS ()
ctrlFlow' f = state $ \(off, cf, lt) -> (mempty, (off, f cf, lt))

ctrlFlow :: (CtrlFlow -> CtrlFlow) -> Instr
ctrlFlow = Instr . ctrlFlow'

initCtrl :: (CtrlFlow -> CtrlFlow) -> Instr
initCtrl f = Instr $ do
  let Instr instr = ctrlFlow f
  instr
  writeStackMapFrame

putCtrlFlow :: CtrlFlow -> Instr
putCtrlFlow = Instr . putCtrlFlow'

putCtrlFlow' :: CtrlFlow -> InstrRWS ()
putCtrlFlow' cf = do
  (off, _, lt) <- get
  put (off, cf, lt)

incOffset :: Int -> Instr
incOffset = Instr . incOffset'

incOffset' :: Int -> InstrRWS ()
incOffset' i = state s where s (Offset off, cf, lt) = (mempty, (Offset $ off + i, cf, lt))

write :: ByteString -> StackMapTable -> InstrRWS ()
write bs smfs = do
  incOffset' $ BS.length bs
  tell (bs, smfs)

writeBytes :: ByteString -> InstrRWS ()
writeBytes bs = write bs mempty

writeInstr :: Instr -> InstrRWS Int
writeInstr (Instr action) = do
  (Offset off0, _, _) <- get
  action
  (Offset off1, _, _) <- get
  return (off1 - off0)

writeStackMapFrame :: InstrRWS ()
writeStackMapFrame = get >>= f where
  f (Offset offset, cf, _) = tell (mempty, StackMapTable $ IntMap.singleton offset cf)

getOffset :: InstrRWS Int
getOffset = do
  (Offset offset, _, _) <- get
  return offset

type BranchMap = IntMap.IntMap Instr

tableswitch :: Int -> Int -> BranchMap -> Maybe Instr -> Instr
tableswitch low high branchMap deflt = Instr $ do
  cp <- ask
  baseOffset <- getOffset
  writeInstr $ op OP.tableswitch
  modifyStack' $ CF.pop jint
  (Offset offset, cf, _) <- get
  -- Align to 4-byte boundary
  let padding = 4 - (offset `mod` 4)
  writeBytes . BS.pack . replicate padding $ 0
  offset' <- getOffset
  let firstOffset = offset' + 4 * (3 + numBranches)
      (offsets, codeInfos) = unzip . tail $ scanl' (computeOffsets cf cp) (firstOffset, undefined) [low..high]
      defOffset = last offsets
      defInstr = fromMaybe mempty deflt
      (defBytes, defCF, defFrames) = runInstr' defInstr cp (Offset defOffset) cf
      breakOffset = defOffset + BS.length defBytes
      relOffset x = x - baseOffset
  writeBytes . packI32 $ relOffset defOffset
  writeBytes . packI32 $ low
  writeBytes . packI32 $ high
  forM_ codeInfos $ \(offset, _, _, _, _) ->
    writeBytes . packI32 $ relOffset offset
  forM_ codeInfos $ \(offset, len, bytes, cf', frames) -> do
    writeStackMapFrame
    if len == 0 then do
      op' OP.goto
      writeBytes . packI16 $ (defOffset - offset)
    else do
      write bytes frames
      op' OP.goto
      writeBytes . packI16 $ (breakOffset - (offset + len))
  writeStackMapFrame
  write defBytes defFrames
  putCtrlFlow' $ CF.merge cf (defCF : map (\(_, _, _, cf', _) -> cf') codeInfos)
  writeStackMapFrame
  where computeOffsets cf cp (offset, _) i =
          ( offset + bytesLength + lengthJump
          , (offset, bytesLength, bytes, cf', frames) )
          where (bytes, cf', frames) = runInstr' instr cp (Offset offset) cf
                instr = IntMap.findWithDefault mempty i branchMap
                bytesLength = BS.length bytes
        lengthJump = 3 -- op goto <> pack16 $ length ko
        numBranches = high - low + 1

lookupswitch :: BranchMap ->  Maybe Instr -> Instr
lookupswitch branchMap deflt = Instr $ do
  cp <- ask
  baseOffset <- getOffset
  writeInstr $ op OP.lookupswitch
  modifyStack' $ CF.pop jint
  (Offset offset, cf, _) <- get
  -- Align to 4-byte boundary
  let padding = 4 - (offset `mod` 4)
  writeBytes . BS.pack . replicate padding $ 0
  offset' <- getOffset
  let firstOffset = offset' + 4 * (1 + 2 * numBranches)
      (offsets, codeInfos) = unzip . tail $ scanl' (computeOffsets cf cp) (firstOffset, undefined) $ IntMap.toAscList branchMap
      defOffset = last offsets
      defInstr = fromMaybe mempty deflt
      (defBytes, defCF, defFrames) = runInstr' defInstr cp (Offset defOffset) cf
      breakOffset = defOffset + BS.length defBytes
      relOffset x = x - baseOffset
  writeBytes . packI32 $ relOffset defOffset
  forM_ codeInfos $ \(offset, _, val, _, _, _) -> do
    writeBytes . packI32 $ val
    writeBytes . packI32 $ relOffset offset
  forM_ codeInfos $ \(offset, len, _, bytes, cf', frames) -> do
    writeStackMapFrame
    write bytes frames
    op' OP.goto
    writeBytes . packI16 $ (breakOffset - (offset + len))
  writeStackMapFrame
  write defBytes defFrames
  putCtrlFlow' $
    CF.merge cf (defCF : map (\(_, _, _, _, cf', _) -> cf') codeInfos)
  writeStackMapFrame
  where computeOffsets cf cp (offset, _) (val, instr) =
          ( offset + bytesLength + lengthJump
          , (offset, bytesLength, val, bytes, cf', frames) )
          where (bytes, cf', frames) = runInstr' instr cp (Offset offset) cf
                bytesLength = BS.length bytes
        lengthJump = 3 -- op goto <> pack16 $ length ko
        numBranches = IntMap.size branchMap


lookupLabel :: Label -> InstrRWS Offset
lookupLabel (Label id)= do
  (_, _, LabelTable table) <- get
  return $ IntMap.findWithDefault (error "lookupLabel: failed") id table

gotoLabel :: Label -> Instr
gotoLabel label = Instr $ do
  offset <- getOffset
  Offset labelOffset <- lookupLabel label
  op' OP.goto
  writeBytes . packI16 $ labelOffset - offset

putLabel :: Label -> Instr
putLabel (Label id) = Instr $
  state $ \(off, cf, LabelTable table) ->
            (mempty, (off, cf, LabelTable $ IntMap.insert id off table))
