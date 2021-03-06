-- Effectual interface to the raw binary data library.
module Network.Packet
import Network.PacketLang
import Effects
import Debug.Trace
%access public

%include C "bindata.h"
%link C "bindata.o"
-- Pointer to the raw packet
data RawPacket = RawPckt Ptr

-- Type synonyms for different arguments to foreign functions
BytePos : Type
BytePos = Int

Position : Type
Position = Int

ByteData : Type
ByteData = Int

Length : Type
Length = Int

data ActivePacket : Type where
  ActivePacketRes : RawPacket -> BytePos -> Length -> ActivePacket

data FailedPacket : Type where
  FailedPacketRes : (Maybe RawPacket) -> FailedPacket


data Packet : Effect where
  CreatePacket : Int -> Packet () 
                               (Either (FailedPacket) (ActivePacket)) ()
  DestroyPacket : Packet (ActivePacket) () ()
  -- TODO: Inelegant, would be nice to consolidate (much like w/ SQLite)
  DestroyFailedPacket : Packet (FailedPacket) () ()

  -- Dumps packet to console. Not something we really want in the final thing...
  DumpPacket : Packet (ActivePacket) (ActivePacket) ()

  -- Wrapper around unmarshalling functions.
  -- Takes a raw pointer and constructs a packet representation
  ReadPacket : (p : PacketLang) -> RawPacket -> Length ->
               Packet () (Either (FailedPacket) (ActivePacket)) 
                         (Maybe (mkTy p))
  -- Wrapper around marshalling functions
  WritePacket : (p : PacketLang) -> (mkTy p) -> Packet (ActivePacket)
                                                       (Either (FailedPacket) 
                                                               (ActivePacket)) ()

  -- Sets a byte at the given position to the given value
  RawSetByte : Int -> Int -> Packet (ActivePacket) 
                                    (Either (FailedPacket) 
                                            (ActivePacket)) ()

  -- Sets the bits between start and end positions to the given value
  RawSetBits : Int -> Int -> Int -> Packet (ActivePacket) 
                                           (Either (FailedPacket) 
                                                   (ActivePacket)) ()

  -- Returns a raw pointer to the current packet
  GetRawPtr : Packet (ActivePacket) (ActivePacket) RawPacket

  -- TESTING ONLY. Transitions to empty state *without* freeing packet in memory
  UnsafeExit : Packet (ActivePacket) () RawPacket


PACKET : Type -> EFFECT
PACKET t = MkEff t Packet

getRawPacket : Eff IO [PACKET (ActivePacket)] RawPacket
getRawPacket = GetRawPtr

createPacket : Int -> EffM IO [PACKET ()] [PACKET (Either (FailedPacket) (ActivePacket))] ()
createPacket len = (CreatePacket len)

destroyPacket : EffM IO [PACKET (ActivePacket)] [PACKET ()] ()
destroyPacket = DestroyPacket

destroyFailedPacket : EffM IO [PACKET (FailedPacket)] [PACKET ()] ()
destroyFailedPacket = DestroyFailedPacket

dumpPacket : Eff IO [PACKET (ActivePacket)] ()
dumpPacket = DumpPacket

readPacket : (p : PacketLang) -> RawPacket -> Length ->
             EffM IO [PACKET ()] 
                     [PACKET (Either (FailedPacket) (ActivePacket))]
                     (Maybe (mkTy p))
readPacket lang pckt len = (ReadPacket lang pckt len)

writePacket : (p : PacketLang) -> (mkTy p) -> EffM IO [PACKET (ActivePacket)] 
                                                      [PACKET (Either FailedPacket ActivePacket)] ()
writePacket pl dat = (WritePacket pl dat)

rawSetByte : Int -> Int -> EffM IO [PACKET (ActivePacket)] 
                                   [PACKET (Either (FailedPacket) (ActivePacket))] ()
rawSetByte pos dat = (RawSetByte pos dat)

rawSetBits : Int -> Int -> Int -> EffM IO [PACKET (ActivePacket)] 
                                          [PACKET (Either (FailedPacket) (ActivePacket))] ()
rawSetBits start end dat = (RawSetBits start end dat)


unsafeExit : EffM IO [PACKET (ActivePacket)] [PACKET ()] RawPacket
unsafeExit = UnsafeExit

foreignDestroyPacket : RawPacket -> IO ()
foreignDestroyPacket (RawPckt pckt) = mkForeign (FFun "freePacket" [FPtr] FUnit) pckt

foreignCreatePacket : Int -> IO RawPacket
foreignCreatePacket len = map RawPckt $ mkForeign (FFun "newPacket" [FInt] FPtr) len

foreignSetByte : RawPacket -> Position -> ByteData -> IO ()
foreignSetByte (RawPckt pckt) dat pos = 
  mkForeign (FFun "setPacketByte" [FPtr, FInt, FInt] FUnit) pckt dat pos

foreignSetBits : RawPacket -> Position -> Position -> ByteData -> IO ()
foreignSetBits (RawPckt pckt) start end dat = 
  mkForeign (FFun "setPacketBits" [FPtr, FInt, FInt, FInt] FUnit) pckt start end dat

foreignSetString : RawPacket -> Position -> String -> Int -> Char -> IO ()
foreignSetString (RawPckt pckt) start dat len term =
  mkForeign (FFun "setPacketString" [FPtr, FInt, FString, FInt, FChar] FUnit) pckt start dat len term

foreignGetByte : RawPacket -> Position -> IO ByteData
foreignGetByte (RawPckt pckt) pos = 
  mkForeign (FFun "getPacketByte" [FPtr, FInt] FInt) pckt pos

foreignGetBits : RawPacket -> Position -> Position -> IO ByteData
foreignGetBits (RawPckt pckt) start end =
  mkForeign (FFun "getPacketBits" [FPtr, FInt, FInt] FInt) pckt start end

foreignDumpPacket : RawPacket -> Position -> IO ()
foreignDumpPacket (RawPckt pckt) len =
  mkForeign (FFun "dumpPacket" [FPtr, FInt] FUnit) pckt len

{- Chunk length in bits -}
chunkLength : (c : Chunk) -> chunkTy c -> Length
chunkLength (Bit w p) x1 = w
-- TODO: This doesn't take into account if there's a null character
-- within the string itself. I had something nice using span earlier,
-- but it didn't work (probably due to a library bug)
chunkLength CString str = 8 * ((strLen str) + 1) 
chunkLength (LString len) str = 8 * len 
chunkLength (Prop _) p = 0 -- Not written to the packet

{-
vectBitLength : (p : PacketLang) -> mkTy p -> Int
vectBitLength pl [] = 0
vectBitLength pl (x::xs) = ?vbl_rhs
-}

{- Marshalling code -}

{- Marshal Chunks to ByteData -}

marshalChunk : ActivePacket -> (c : Chunk) -> (chunkTy c) -> IO Length
marshalChunk (ActivePacketRes pckt pos p_len) (Bit w p) (BInt dat p2) = do
  let len = chunkLength (Bit w p) (BInt dat p2)
  foreignSetBits pckt pos (pos + w) dat
  return len
marshalChunk (ActivePacketRes pckt pos p_len) CString str = do
  let len = chunkLength CString str
  putStrLn $ "CStr length: " ++ (show len)
  foreignSetString pckt pos str len '\0'
  return len
-- TODO: This is wrong, need to set the length in there explicitly
marshalChunk (ActivePacketRes pckt pos p_len) (LString n) str = do
  let len = chunkLength (LString n) str 
  foreignSetString pckt pos str len '\0'
  return len
marshalChunk (ActivePacketRes pckt pos p_len) (Prop _) x2 = return 0 -- We're not doing anything
  
  
marshalList : ActivePacket -> (pl : PacketLang) -> List (mkTy pl) -> IO Length
marshalVect : ActivePacket -> (pl : PacketLang) -> Vect n (mkTy pl) -> IO Length

marshal : ActivePacket -> (pl : PacketLang) -> mkTy pl -> IO Length
marshal ap (CHUNK c) c_dat = marshalChunk ap c c_dat
marshal ap (IF True pl_t _) ite = marshal ap pl_t ite
marshal ap (IF False _ pl_f) ite = marshal ap pl_f ite
marshal ap (pl_1 // pl_2) x = either x (\x_l => marshal ap pl_1 x_l)
                                       (\x_r => marshal ap pl_2 x_r) 
marshal ap (LIST pl) xs = marshalList ap pl xs
marshal ap (LISTN n pl) xs = marshalVect ap pl xs
marshal ap (c >>= k) (x ** y) = do
  len <- marshal ap c x
  let (ActivePacketRes pckt pos p_len) = ap
  let ap2 = (ActivePacketRes pckt (pos + len) p_len) 
  len2 <- marshal ap2 (k x) y
  return $ len + len2


--marshalList : ActivePacket -> (pl : PacketLang) -> mkTy pl -> IO Length
--marshalList ap pl vals = ?mv --map (\(ActivePacket pckt pos) -> pos) $ foldr (\a state -> marshalList' state pl) 


{- Marshal PacketLang to ByteData -}
--marshalVect : ActivePacket -> (pl : PacketLang) -> Vect n (mkTy pl) -> IO Length
marshalVect ap pl [] = return 0
marshalVect (ActivePacketRes pckt pos p_len) pl (x::xs) = do
  len <- marshal (ActivePacketRes pckt pos p_len) pl x
  xs_len <- marshalVect (ActivePacketRes pckt (pos + len) p_len) pl xs
  return $ len + xs_len

--marshalList : ActivePacket -> (pl : PacketLang) -> List (mkTy pl) -> IO Length
marshalList ap pl [] = return 0
marshalList (ActivePacketRes pckt pos p_len) pl (x::xs) = do
  len <- marshal (ActivePacketRes pckt pos p_len) pl x
  xs_len <- marshalList (ActivePacketRes pckt (pos + len) p_len) pl xs
  return $ len + xs_len

{- Unmarshalling Code -}
unmarshal : ActivePacket -> (pl : PacketLang) -> Maybe (mkTy pl, Length)


--unmarshal : ActivePacket -> (pl : PacketLang) -> Maybe (mkTy pl, Length)
unmarshalCString' : ActivePacket ->  
                    Int -> 
                    IO (Maybe (List Char, Length))
unmarshalCString' (ActivePacketRes pckt pos p_len) i with (pos + 8 < p_len)
  -- Firstly we need to check whether we're within the bounds of the packet.
  -- If not, then the parse has failed. 
  -- If we're within bounds, we need to read the next character, and recursively
  -- call.
  | True = do
    next_byte <- foreignGetBits pckt pos (pos + 7)
    putStrLn $ "Byte read: " ++ (show next_byte)
    let char = chr next_byte
    putStrLn $ "Char: " ++ (show char)
    -- If we're up to a NULL, we've read the string
    if (char == '\0') then do
      return $ Just ([], 8)
    else do -- Otherwise, recursively call
      -- We're assuming sizeof(char) = 8 here
      rest <- unmarshalCString' (ActivePacketRes pckt (pos + 8) p_len) (i + 8)
      case rest of Just (xs, j) => return $ Just (char::xs, j + 8)
                   Nothing => return Nothing
  | False = return Nothing

unmarshalCString : ActivePacket -> IO (Maybe (String, Length))
unmarshalCString (ActivePacketRes pckt pos p_len) = do
  res <- unmarshalCString' (ActivePacketRes pckt pos p_len) 0
  case res of 
       Just (chrs, len) => return $ Just (pack chrs, len) 
       Nothing => return Nothing

-- TODO: Maybe recurse using Nat instead of Int (for sake of totality) but we need to use as an Int
unmarshalLString' : ActivePacket -> Int -> IO (List Char)
unmarshalLString' ap 0 = return []
unmarshalLString' (ActivePacketRes pckt pos p_len) n = do
  next_byte <- foreignGetBits pckt pos (pos + 8)
  let char = chr next_byte
  rest <- unmarshalLString' (ActivePacketRes pckt (pos + 8) p_len) (n - 1)
  return $ (char :: rest)

-- We've already bounds-checked the LString against the packet length,
-- meaning it's safe to just return a string.
unmarshalLString : ActivePacket -> Int -> IO String
unmarshalLString ap n = map pack (unmarshalLString' ap n)

unmarshalBits : ActivePacket -> (c : Chunk) -> IO (Maybe (chunkTy c, Length))
unmarshalBits (ActivePacketRes pckt pos p_len) (Bit width p) with ((pos + width) < p_len)
  | True = do
    res <- foreignGetBits pckt pos (pos + width)
    return $ Just $ (BInt res (believe_me oh), width) -- Have to trust it, as it's from C
  | False = return Nothing

unmarshalChunk : ActivePacket -> (c : Chunk) -> IO (Maybe (chunkTy c, Length))
unmarshalChunk ap (Bit width p) = unmarshalBits ap (Bit width p) 
unmarshalChunk ap CString = unmarshalCString ap
unmarshalChunk (ActivePacketRes pckt pos p_len) (LString n) =
  -- Do bounds checking now, if it passes then we're golden later on
  if pos + (8 * n) < p_len then do
    res <- unmarshalLString (ActivePacketRes pckt pos p_len) n
    return $ Just (res, (8 * n))
  else
    return Nothing
unmarshalChunk x (Prop P) = return Nothing 
-- TODO: There is an ambiguity problem here.
-- Consider the case where we have a packet description of LIST String, String, String, Int.
-- The packet decoding would fail: we'd include the two strings as part of the list.
-- This is a tricky one to resolve, since we're doing stream parsing as opposed to having
-- the entire list of tokens available to us. 
-- Needs some extra thought, and is a big problem. But it's not covered in the original IP DSL, 
--so we're OK just for now, I think.

--T  
unmarshalList : ActivePacket -> (pl : PacketLang) -> (List (mkTy pl), Length)
unmarshalList (ActivePacketRes pckt pos p_len) pl =
    case (unmarshal (ActivePacketRes pckt pos p_len) pl) of
      Just (item, len) => 
        let xs_tup = unmarshalList (ActivePacketRes pckt (pos + len) p_len) pl in
        let (rest, rest_len) = (fst xs_tup, snd xs_tup) in
            (item :: rest, len + rest_len)
      Nothing => ([], 0) -- Finished parsing list


unmarshalVect : ActivePacket -> 
                (pl : PacketLang) -> 
                (len : Nat) -> 
                Maybe ((Vect len (mkTy pl)), Length)
unmarshalVect _ _ Z = Just ([], 0)
unmarshalVect (ActivePacketRes pckt pos p_len) pl (S k) = do
  item_tup <- unmarshal (ActivePacketRes pckt pos p_len) pl 
  let (item, len) = (fst item_tup, snd item_tup)
  trace ("Len: " ++ (show len)) (do
    rest_tup <- unmarshalVect (ActivePacketRes pckt (pos + len) p_len) pl k
    let (rest, rest_len) = (fst rest_tup, snd rest_tup)
    return (item :: rest, len + rest_len))

-- unmarshal : ActivePacket -> (pl : PacketLang) -> Maybe (mkTy pl, Length)
unmarshal ap (CHUNK c) = unsafePerformIO $ unmarshalChunk ap c
unmarshal ap (IF False yes no) = unmarshal ap no
unmarshal ap (IF True yes no) = unmarshal ap yes
-- Attempt x, if correct then return x.
-- If not, try y. If correct, return y. 
-- If neither correct, return Nothing.
unmarshal ap (x // y) = do
  let x_res = unmarshal ap x
  let y_res = unmarshal ap y
  (maybe (maybe Nothing (\(y_res', len) => Just $ (Right y_res', len)) y_res)
         (\(x_res', len) => Just $ (Left x_res', len)) x_res)
unmarshal ap (LIST pl) = Just (unmarshalList ap pl)
unmarshal ap (LISTN n pl) = unmarshalVect ap pl n
unmarshal (ActivePacketRes pckt pos p_len) (c >>= k) = do
  res1_tup <- unmarshal (ActivePacketRes pckt pos p_len) c 
  -- Hack hack hack around the TC resolution bug...
  let (res, res_len) = (fst res1_tup, snd res1_tup)
  res2_tup <- unmarshal (ActivePacketRes pckt (pos + res_len) p_len) (k res) 
  let (res2, res2_len) = (fst res2_tup, snd res2_tup)
  return ((res ** res2), res_len + res2_len)
  

instance Handler Packet IO where
  handle () (CreatePacket len) k = do
    pckt <- foreignCreatePacket len
    k (Right $ ActivePacketRes pckt 0 len) ()

  handle () (ReadPacket pl pckt len) k = do
    let res_tup = unmarshal (ActivePacketRes pckt 0 len) pl
    case res_tup of
         Just (res, res_len) => 
           k (Right $ ActivePacketRes pckt res_len len) (Just res)
         Nothing => 
           k (Left $ FailedPacketRes (Just pckt)) Nothing
--    let (res, len) = (fst res_tup, snd res_tup)
--    let output_res = either res (const $ FailedPacketRes (Just pckt))
  --                              (const $ ActivePacketRes 
                                
  handle (ActivePacketRes pckt pos p_len) (WritePacket lang dat) k = do
    len <- marshal (ActivePacketRes pckt pos p_len) lang dat
    putStrLn $ "Len: " ++ (show len)
    k (Right $ ActivePacketRes pckt (pos + len) p_len) ()

  handle (ActivePacketRes pckt pos p_len) (DestroyPacket) k = do
    foreignDestroyPacket pckt
    k () ()

  handle (FailedPacketRes (Just pckt)) (DestroyFailedPacket) k = do
    foreignDestroyPacket pckt
    k () ()

  handle (FailedPacketRes Nothing) (DestroyFailedPacket) k = 
    k () ()

  handle (ActivePacketRes pckt p_pos p_len) (RawSetByte pos val) k = do
    foreignSetByte pckt pos val
    k (Right $ ActivePacketRes pckt p_pos p_len) ()

  handle (ActivePacketRes pckt p_pos p_len) (RawSetBits start end val) k = do
    foreignSetBits pckt start end val
    k (Right $ ActivePacketRes pckt p_pos p_len) ()

  handle (ActivePacketRes pckt p_pos p_len) (GetRawPtr) k =
    k (ActivePacketRes pckt p_pos p_len) pckt

  handle (ActivePacketRes pckt p_pos p_len) (DumpPacket) k = do
    foreignDumpPacket pckt p_pos
    k (ActivePacketRes pckt p_pos p_len) ()

  handle (ActivePacketRes pckt p_pos p_len) (UnsafeExit) k = k () pckt
