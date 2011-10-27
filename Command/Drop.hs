{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Drop where

import Common.Annex
import Command
import qualified Remote
import qualified Annex
import Logs.Location
import Logs.Trust
import Annex.Content
import Config

command :: [Command]
command = [Command "drop" paramPaths defaultChecks seek
	"indicate content of files not currently wanted"]

seek :: [CommandSeek]
seek = [withNumCopies start]

start :: FilePath -> Maybe Int -> CommandStart
start file numcopies = isAnnexed file $ \(key, _) -> do
	present <- inAnnex key
	if present
		then autoCopies key (>) numcopies $ do
			showStart "drop" file
			next $ perform key numcopies
		else stop

perform :: Key -> Maybe Int -> CommandPerform
perform key numcopies = do
	success <- canDropKey key numcopies
	if success
		then next $ cleanup key
		else stop

cleanup :: Key -> CommandCleanup
cleanup key = do
	whenM (inAnnex key) $ removeAnnex key
	logStatus key InfoMissing
	return True

{- Checks remotes to verify that enough copies of a key exist to allow
 - for a key to be safely removed (with no data loss). -}
canDropKey :: Key -> Maybe Int -> Annex Bool
canDropKey key numcopiesM = do
	force <- Annex.getState Annex.force
	if force || numcopiesM == Just 0
		then return True
		else do
			(remotes, trusteduuids) <- Remote.keyPossibilitiesTrusted key
			untrusteduuids <- trustGet UnTrusted
			let tocheck = Remote.remotesWithoutUUID remotes (trusteduuids++untrusteduuids)
			numcopies <- getNumCopies numcopiesM
			findcopies numcopies trusteduuids tocheck []
	where
		findcopies need have [] bad
			| length have >= need = return True
			| otherwise = notEnoughCopies need have bad
		findcopies need have (r:rs) bad
			| length have >= need = return True
			| otherwise = do
				let u = Remote.uuid r
				let duplicate = u `elem` have
				haskey <- Remote.hasKey r key
				case (duplicate, haskey) of
					(False, Right True)	-> findcopies need (u:have) rs bad
					(False, Left _)		-> findcopies need have rs (r:bad)
					_			-> findcopies need have rs bad
		notEnoughCopies need have bad = do
			unsafe
			showLongNote $
				"Could only verify the existence of " ++
				show (length have) ++ " out of " ++ show need ++ 
				" necessary copies"
			Remote.showTriedRemotes bad
			Remote.showLocations key have
			hint
			return False
		unsafe = showNote "unsafe"
		hint = showLongNote "(Use --force to override this check, or adjust annex.numcopies.)"
