{- Using bup as a remote.
 -
 - Copyright 2011-2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remote.Bup (remote) where

import qualified Data.Map as M
import Data.ByteString.Lazy.UTF8 (fromString)

import Common.Annex
import qualified Annex
import Types.Remote
import Types.Key
import Types.Creds
import qualified Git
import qualified Git.Command
import qualified Git.Config
import qualified Git.Construct
import qualified Git.Ref
import Config
import Config.Cost
import qualified Remote.Helper.Ssh as Ssh
import Remote.Helper.Special
import Remote.Helper.ChunkedEncryptable
import Remote.Helper.Messages
import Utility.Hash
import Utility.UserInfo
import Annex.UUID
import Utility.Metered

type BupRepo = String

remote :: RemoteType
remote = RemoteType {
	typename = "bup",
	enumerate = findSpecialRemotes "buprepo",
	generate = gen,
	setup = bupSetup
}

gen :: Git.Repo -> UUID -> RemoteConfig -> RemoteGitConfig -> Annex (Maybe Remote)
gen r u c gc = do
	bupr <- liftIO $ bup2GitRemote buprepo
	cst <- remoteCost gc $
		if bupLocal buprepo
			then nearlyCheapRemoteCost
			else expensiveRemoteCost
	(u', bupr') <- getBupUUID bupr u
	
	let this = Remote
		{ uuid = u'
		, cost = cst
		, name = Git.repoDescribe r
		, storeKey = storeKeyDummy
		, retrieveKeyFile = retreiveKeyFileDummy
		, retrieveKeyFileCheap = retrieveCheap buprepo
		, removeKey = remove buprepo
		, hasKey = checkPresent r bupr'
		, hasKeyCheap = bupLocal buprepo
		, whereisKey = Nothing
		, remoteFsck = Nothing
		, repairRepo = Nothing
		, config = c
		, repo = r
		, gitconfig = gc
		, localpath = if bupLocal buprepo && not (null buprepo)
			then Just buprepo
			else Nothing
		, remotetype = remote
		, availability = if bupLocal buprepo then LocallyAvailable else GloballyAvailable
		, readonly = False
		}
	return $ Just $ encryptableRemote c
		(simplyPrepare $ store this buprepo)
		(simplyPrepare $ retrieve buprepo)
		this
  where
	buprepo = fromMaybe (error "missing buprepo") $ remoteAnnexBupRepo gc

bupSetup :: Maybe UUID -> Maybe CredPair -> RemoteConfig -> Annex (RemoteConfig, UUID)
bupSetup mu _ c = do
	u <- maybe (liftIO genUUID) return mu

	-- verify configuration is sane
	let buprepo = fromMaybe (error "Specify buprepo=") $
		M.lookup "buprepo" c
	c' <- encryptionSetup c

	-- bup init will create the repository.
	-- (If the repository already exists, bup init again appears safe.)
	showAction "bup init"
	unlessM (bup "init" buprepo []) $ error "bup init failed"

	storeBupUUID u buprepo

	-- The buprepo is stored in git config, as well as this repo's
	-- persistant state, so it can vary between hosts.
	gitConfigSpecialRemote u c' "buprepo" buprepo

	return (c', u)

bupParams :: String -> BupRepo -> [CommandParam] -> [CommandParam]
bupParams command buprepo params = 
	Param command : [Param "-r", Param buprepo] ++ params

bup :: String -> BupRepo -> [CommandParam] -> Annex Bool
bup command buprepo params = do
	showOutput -- make way for bup output
	liftIO $ boolSystem "bup" $ bupParams command buprepo params

bupSplitParams :: Remote -> BupRepo -> Key -> [CommandParam] -> Annex [CommandParam]
bupSplitParams r buprepo k src = do
	let os = map Param $ remoteAnnexBupSplitOptions $ gitconfig r
	showOutput -- make way for bup output
	return $ bupParams "split" buprepo 
		(os ++ [Param "-q", Param "-n", Param (bupRef k)] ++ src)

store :: Remote -> BupRepo -> Storer
store r buprepo = byteStorer $ \k b p -> do
	params <- bupSplitParams r buprepo k []
	let cmd = proc "bup" (toCommand params)
	liftIO $ withHandle StdinHandle createProcessSuccess cmd $ \h -> do
		meteredWrite p h b
		return True

retrieve :: BupRepo -> Retriever
retrieve buprepo = fileRetriever $ \d k _p ->
	liftIO $ withFile d WriteMode $ \h -> do
		let params = bupParams "join" buprepo [Param $ bupRef k]
		let p = proc "bup" (toCommand params)
		(_, _, _, pid) <- createProcess $ p { std_out = UseHandle h }
		forceSuccessProcess p pid

retrieveCheap :: BupRepo -> Key -> FilePath -> Annex Bool
retrieveCheap _ _ _ = return False

{- Cannot revert having stored a key in bup, but at least the data for the
 - key will be used for deltaing data of other keys stored later.
 -
 - We can, however, remove the git branch that bup created for the key.
 -}
remove :: BupRepo -> Key -> Annex Bool
remove buprepo k = do
	go =<< liftIO (bup2GitRemote buprepo)
	warning "content cannot be completely removed from bup remote"
	return True
  where
	go r
		| Git.repoIsUrl r = void $ onBupRemote r boolSystem "git" params
		| otherwise = void $ liftIO $ catchMaybeIO $ do
			r' <- Git.Config.read r
			boolSystem "git" $ Git.Command.gitCommandLine params r'
	params = [ Params "branch -q -D", Param (bupRef k) ]

{- Bup does not provide a way to tell if a given dataset is present
 - in a bup repository. One way it to check if the git repository has
 - a branch matching the name (as created by bup split -n).
 -}
checkPresent :: Git.Repo -> Git.Repo -> Key -> Annex (Either String Bool)
checkPresent r bupr k
	| Git.repoIsUrl bupr = do
		showChecking r
		ok <- onBupRemote bupr boolSystem "git" params
		return $ Right ok
	| otherwise = liftIO $ catchMsgIO $
		boolSystem "git" $ Git.Command.gitCommandLine params bupr
  where
	params = 
		[ Params "show-ref --quiet --verify"
		, Param $ "refs/heads/" ++ bupRef k
		]

{- Store UUID in the annex.uuid setting of the bup repository. -}
storeBupUUID :: UUID -> BupRepo -> Annex ()
storeBupUUID u buprepo = do
	r <- liftIO $ bup2GitRemote buprepo
	if Git.repoIsUrl r
		then do
			showAction "storing uuid"
			unlessM (onBupRemote r boolSystem "git"
				[Params $ "config annex.uuid " ++ v]) $
					error "ssh failed"
		else liftIO $ do
			r' <- Git.Config.read r
			let olduuid = Git.Config.get "annex.uuid" "" r'
			when (olduuid == "") $
				Git.Command.run
					[ Param "config"
					, Param "annex.uuid"
					, Param v
					] r'
  where
	v = fromUUID u

onBupRemote :: Git.Repo -> (FilePath -> [CommandParam] -> IO a) -> FilePath -> [CommandParam] -> Annex a
onBupRemote r a command params = do
	c <- Annex.getRemoteGitConfig r
	sshparams <- Ssh.toRepo r c [Param $
			"cd " ++ dir ++ " && " ++ unwords (command : toCommand params)]
	liftIO $ a "ssh" sshparams
  where
	path = Git.repoPath r
	base = fromMaybe path (stripPrefix "/~/" path)
	dir = shellEscape base

{- Allow for bup repositories on removable media by checking
 - local bup repositories to see if they are available, and getting their
 - uuid (which may be different from the stored uuid for the bup remote).
 -
 - If a bup repository is not available, returns NoUUID.
 - This will cause checkPresent to indicate nothing from the bup remote
 - is known to be present.
 -
 - Also, returns a version of the repo with config read, if it is local.
 -}
getBupUUID :: Git.Repo -> UUID -> Annex (UUID, Git.Repo)
getBupUUID r u
	| Git.repoIsUrl r = return (u, r)
	| otherwise = liftIO $ do
		ret <- tryIO $ Git.Config.read r
		case ret of
			Right r' -> return (toUUID $ Git.Config.get "annex.uuid" "" r', r')
			Left _ -> return (NoUUID, r)

{- Converts a bup remote path spec into a Git.Repo. There are some
 - differences in path representation between git and bup. -}
bup2GitRemote :: BupRepo -> IO Git.Repo
bup2GitRemote "" = do
	-- bup -r "" operates on ~/.bup
	h <- myHomeDir
	Git.Construct.fromAbsPath $ h </> ".bup"
bup2GitRemote r
	| bupLocal r = 
		if "/" `isPrefixOf` r
			then Git.Construct.fromAbsPath r
			else error "please specify an absolute path"
	| otherwise = Git.Construct.fromUrl $ "ssh://" ++ host ++ slash dir
  where
	bits = split ":" r
	host = Prelude.head bits
	dir = intercalate ":" $ drop 1 bits
	-- "host:~user/dir" is not supported specially by bup;
	-- "host:dir" is relative to the home directory;
	-- "host:" goes in ~/.bup
	slash d
		| null d = "/~/.bup"
		| "/" `isPrefixOf` d = d
		| otherwise = "/~/" ++ d

{- Converts a key into a git ref name, which bup-split -n will use to point
 - to it. -}
bupRef :: Key -> String
bupRef k
	| Git.Ref.legal True shown = shown
	| otherwise = "git-annex-" ++ show (sha256 (fromString shown))
  where
	shown = key2file k

bupLocal :: BupRepo -> Bool
bupLocal = notElem ':'
