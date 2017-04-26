{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}

module Core.Types where

import Control.Applicative
import Control.Monad.Except
import Control.Monad.State
import Data.Data
import Data.Generics.Uniplate.Data
import Data.HashMap as HM
import Data.IORef
import qualified Data.Text as T
import Data.Vector as V hiding ((++))
import System.IO

type Symbol = T.Text
type ErrorMsg = T.Text
type ParamList = [Symbol]

data SExpr = Lit !Atom
           | Sym {-# UNPACK #-} !Symbol
           | Freeze !SExpr
           | Let !Symbol !SExpr !SExpr
           | Lambda {-# UNPACK #-} !Symbol !SExpr
           | If !SExpr !SExpr !SExpr
           | And !SExpr !SExpr
           | Or !SExpr !SExpr
           | Cond ![(SExpr,SExpr)]
           | Appl ![SExpr]
           | TrapError !SExpr !SExpr
           | EmptyList
             deriving (Data, Show, Typeable)

type DeBruijn = Int
type Bindings = [(DeBruijn, KLValue)]

data RSExpr = RLit !Atom
            | RDeBruijn {-# UNPACK #-} !DeBruijn
            | RFreeze !RSExpr
            | RLambda {-# UNPACK #-} !DeBruijn !RSExpr
            | RIf !RSExpr !RSExpr !RSExpr
            | RApplDir !(IORef ApplContext) ![RSExpr]
            | RApplForm !RSExpr ![RSExpr]
            | RTrapError !RSExpr !RSExpr
            | REmptyList

data KLNumber = KI !Integer
              | KD {-# UNPACK #-} !Double
                deriving (Data, Show, Typeable)

instance Eq KLNumber where
    (KI n1) == (KI n2) = n1 == n2
    (KI n1) == (KD n2) = realToFrac n1 == n2
    (KD n1) == (KI n2) = n1 == realToFrac n2
    (KD n1) == (KD n2) = n1 == n2

instance Ord KLNumber where
    compare (KI n1) (KI n2) = compare n1 n2
    compare (KI n1) (KD n2) = compare (realToFrac n1) n2
    compare (KD n1) (KI n2) = compare n1 (realToFrac n2)
    compare (KD n1) (KD n2) = compare n1 n2

instance Num KLNumber where
    (KI n1) + (KI n2) = KI $ n1 + n2
    (KD n1) + (KD n2) = KD $ n1 + n2
    (KD n1) + (KI n2) = KD $ n1 + realToFrac n2
    (KI n1) + (KD n2) = KD $ realToFrac n1 + n2

    (KI n1) * (KI n2) = KI $ n1 * n2
    (KD n1) * (KD n2) = KD $ n1 * n2
    (KD n1) * (KI n2) = KD $ n1 * realToFrac n2
    (KI n1) * (KD n2) = KD $ realToFrac n1 * n2

    (KI n1) - (KI n2) = KI $ n1 - n2
    (KD n1) - (KD n2) = KD $ n1 - n2
    (KD n1) - (KI n2) = KD $ n1 - realToFrac n2
    (KI n1) - (KD n2) = KD $ realToFrac n1 - n2

    abs (KI n) = KI $ abs n
    abs (KD n) = KD $ abs n

    signum (KI n) = KI $ signum n
    signum (KD n) = KD $ signum n

    fromInteger = KI

instance Fractional KLNumber where
    (KI n1) / (KI n2) = KD $ realToFrac n1 / realToFrac n2
    (KD n1) / (KD n2) = KD $ n1 / n2
    (KD n1) / (KI n2) = KD $ n1 / realToFrac n2
    (KI n1) / (KD n2) = KD $ realToFrac n1 / n2

    fromRational r = KD $ fromRational r    
                                   
data Atom = UnboundSym {-# UNPACK #-} !Symbol
          | B !Bool
          | Nil
          | N !KLNumber
          | Str {-# UNPACK #-} !T.Text
            deriving (Data, Eq, Show, Typeable)
 
data TopLevel = Defun {-# UNPACK #-} !Symbol !ParamList !SExpr
              | SE !SExpr
                deriving Show

data KLValue = Atom !Atom
             | Cons !KLValue !KLValue
             | Excep {-# UNPACK #-} !ErrorMsg
             | ApplC !ApplContext
             | InStream !Handle
             | OutStream !Handle
             | Vec {-# UNPACK #-} !(Vector KLValue)
             deriving (Show)

data ApplContext = Func Symbol Function
                 | PL Symbol (KLContext Env KLValue)
                 | Malformed ErrorMsg

instance Show ApplContext where
    show (Func name _) = "<function " ++ T.unpack name ++ ">"
    show (PL name _) = "<function " ++ T.unpack name ++ ">"
    show (Malformed e) = "<function, malformed, message : " ++ T.unpack e ++ ">"

data Function = Context (KLValue -> KLContext Env KLValue)
              | PartialApp (KLValue -> Function)

data Env = Env {  symbolTable :: Map Symbol KLValue
                , functionTable :: Map Symbol (IORef ApplContext) }

newtype KLContext s a = KLContext {
      runKLC :: forall r. (a -> s -> IO r)
             -> (ErrorMsg -> s -> IO r)
             -> s
             -> IO r
    }

instance Monad (KLContext s) where
    (>>=)  = klcBind
    return = klcReturn

klcBind :: KLContext s a -> (a -> KLContext s b) -> KLContext s b
klcBind m f = KLContext go
  where go sk fk s = runKLC m (\a s' -> runKLC (f a) sk fk s') fk s
        
klcReturn :: a -> KLContext s a
klcReturn a = KLContext go
  where go sk _ s = sk a s
        
instance Applicative (KLContext s) where
    pure = return
    (<*>) = ap

instance Functor (KLContext s) where
    fmap f (KLContext m) = KLContext (\sk fk s -> m (sk . f) fk s)

instance MonadState s (KLContext s) where
    get = KLContext (\sk _ s -> sk s s)
    put s = KLContext (\sk _ _ -> sk () s)

liftIO' m = KLContext $ \sk fk s -> do
              x <- m
              sk x s
{-# INLINE liftIO' #-}

instance MonadIO (KLContext s) where
    liftIO = liftIO'

instance MonadError ErrorMsg (KLContext s) where
    throwError e = KLContext (\_ fk s -> fk e s)
    catchError m h = KLContext (\sk fk s -> runKLC m sk (h' sk fk) s)
        where h' sk fk e s = let KLContext m = h e in m sk fk s
