{- git-annex "URL" backend
 - -}

module Backend.URL (backend) where

import Control.Monad.State (liftIO)
import Data.String.Utils
import System.Cmd
import System.Exit

import TypeInternals
import Core

backend = Backend {
	name = "URL",
	getKey = keyValue,
	storeFileKey = dummyStore,
	retrieveKeyFile = downloadUrl,
	removeKey = dummyOk,
	hasKey = dummyOk
}

-- cannot generate url from filename
keyValue :: FilePath -> Annex (Maybe Key)
keyValue file = return Nothing

-- cannot change url contents
dummyStore :: FilePath -> Key -> Annex Bool
dummyStore file url = return False

-- allow keys to be removed; presumably they can always be downloaded again
dummyOk :: Key -> Annex Bool
dummyOk url = return True

downloadUrl :: Key -> FilePath -> Annex Bool
downloadUrl key file = do
	showNote "downloading"
	liftIO $ putStrLn "" -- make way for curl progress bar
	result <- liftIO $ rawSystem "curl" ["-#", "-o", file, url]
	if (result == ExitSuccess)
		then return True
		else return False
	where
		url = join ":" $ drop 1 $ split ":" $ show key 
