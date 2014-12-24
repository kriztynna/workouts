{-# LANGUAGE OverloadedStrings #-}

-- sudo apt-get install libmysqlclient-dev
-- cabal install mysql-simple
-- cabal install happstack
-- cabal install wreq
-- cabal install jwt

import Control.Applicative ((<$>), (<*>))
import Control.Lens ((^.), (^..))
import Control.Monad (msum,mzero)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson ((.:))
import Data.Aeson hiding (decode)
import qualified Data.Aeson as JSON (decode, FromJSON(..), Object(..))
import Data.Aeson.Lens (key, _String, values)
import qualified Data.ByteString.Char8 as C8 (pack,unpack,ByteString,length,append)
import qualified Data.ByteString.Lazy.Char8 as C8L (fromStrict)
import qualified Data.ByteString as BS (unpack)
import qualified Data.ByteString.Base64 as BS64 (decode, decodeLenient)
import Data.Int (Int64)
import Data.List (reverse, sort, findIndex)
import Data.Monoid (mconcat)
import qualified Data.Text as Text (splitOn, pack, unpack, Text)
import qualified Data.Text.Lazy as TL (unpack)
import qualified Data.Text.Encoding as TextEnc (encodeUtf8, decodeUtf8)
import Data.Time.Calendar (Day, fromGregorianValid, fromGregorian, diffDays)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, FormatTime)
import Data.Time.LocalTime (LocalTime, utcToLocalTime, getCurrentTimeZone, localDay)
import Database.MySQL.Simple
import Database.MySQL.Simple.QueryResults (QueryResults, convertResults)
import Database.MySQL.Simple.Result (convert)
import Happstack.Server (dir, nullConf, simpleHTTP, toResponse, ok, Response, ServerPartT, look, body, decodeBody, defaultBodyPolicy, queryString, seeOther, nullDir)
--import Network.HTTP.Conduit (parseUrl, newManager, httpLbs, method, conduitManagerSettings)
import Network.Wreq (post, responseBody, FormParam((:=)))
import System.Environment (getArgs)
import System.Locale (defaultTimeLocale)
import Text.Blaze (toValue)
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Data.Text.Lazy.Encoding (encodeUtf8, decodeUtf8)
import Text.Printf (printf)
import Text.Read (readMaybe)
import Web.JWT (decode, claims, header, signature)

main:: IO()
main = do
  args <- getArgs
  googleClientId <- return $ head args
  googleClientSecret <- return $ head $ tail args
  putStrLn $ "Using google client id: " ++ googleClientId
  putStrLn $ "Using google client secret: " ++ googleClientSecret
  simpleHTTP nullConf $ allPages googleClientId googleClientSecret

--
-- Data types
--

data RunMeta = RunMeta { daysOff :: Integer
                       , scoreRank :: Int
                       , paceRank :: Int }

data Run = Run { distance :: Float
               , duration :: Int
               , date :: Day
               , incline :: Float
               , comment :: String
               , runid :: Int
               } deriving (Show)

data MutationKind = Create | Modify | Delete deriving (Read, Show)

--
-- Routing / handlers
--

allPages :: String -> String -> ServerPartT IO Response
allPages googleClientId googleClientSecret = do
  decodeBody (defaultBodyPolicy "/tmp" 0 10240 10240)
  msum [ mkTablePage
       , dropTablePage
       , runDataPage
       , editRunFormPage
       , newRunFormPage
       , handleMutateRunPage
       , handleLoginPage googleClientId googleClientSecret
       , landingPage googleClientId
       ]

handleLoginPage :: String -> String -> ServerPartT IO Response
handleLoginPage clientid secret = dir "handlelogin" $ do
  code <- look "code"
  id <- liftIO $ getGoogleId clientid secret code
  ok $ toResponse $ simpleMessageHtml (code ++ " " ++ id)

landingPage :: String -> ServerPartT IO Response
landingPage googleClientId= do
  nullDir
  ok $ toResponse $ landingPageHtml (googleLoginUrl googleClientId "http://localhost:8000/handlelogin" "")

mkTablePage :: ServerPartT IO Response
mkTablePage = dir "admin" $ dir "mktable" $ do
  i <- liftIO mkTable
  ok (toResponse (executeSqlHtml "create table"i))

dropTablePage :: ServerPartT IO Response
dropTablePage = dir "admin" $ dir "droptable" $ do
  i <- liftIO dropTable
  ok (toResponse (executeSqlHtml "drop table" i))

runDataPage :: ServerPartT IO Response
runDataPage = dir "rundata" $ do
  conn <- liftIO dbConnect
  runs <- liftIO $ query conn "SELECT miles, duration_sec, date, incline, comment, id FROM happstack.runs ORDER BY date ASC" ()
  ok (toResponse (dataTableHtml (annotate runs)))

newRunFormPage :: ServerPartT IO Response
newRunFormPage = dir "newrun" $ do
  tz <- liftIO $ getCurrentTimeZone
  utcNow <- liftIO $ getCurrentTime
  today <- return $ localDay $ utcToLocalTime tz utcNow
  ok $ toResponse $ runDataHtml Nothing today Create

editRunFormPage :: ServerPartT IO Response
editRunFormPage = dir "editrun" $ do
  id <- queryString $ look "id"
  conn <- liftIO dbConnect
  runs <- liftIO $ (query conn "SELECT miles, duration_sec, date, incline, comment, id FROM happstack.runs WHERE id = (?)" [id])
  ok $ toResponse $ runDataHtml (Just (head runs)) (fromGregorian 2014 1 1) Modify

handleMutateRunPage :: ServerPartT IO Response
handleMutateRunPage = dir "handlemutaterun" $ do
  mutationKindS <- body $ look "button"
  distanceS <- body $ look "distance"
  timeS <- body $ look "time"
  dateS <- body $ look "date"
  inclineS <- body $ look "incline"
  commentS <- body $ look "comment"
  mutationKind <- return $ readMaybe mutationKindS
  idS <- body $ look "id"
  run <- return $ (parseRun distanceS timeS dateS inclineS commentS idS)
  conn <- liftIO dbConnect
  n <- liftIO $ storeRun conn run mutationKind
  case n of
    1 -> seeOther ("/rundata" :: String) (toResponse ("Redirecting to run list" :: String))
    0 -> ok $ toResponse $ simpleMessageHtml "error"

--
-- Misc business logic
--

googleLoginUrl :: String -> String -> String -> String
googleLoginUrl clientid redirect state =
  printf "https://accounts.google.com/o/oauth2/auth?client_id=%s&response_type=code&scope=openid%%20email&redirect_uri=%s&state=%s" clientid redirect state

getGoogleIdUrl :: String
getGoogleIdUrl = "https://www.googleapis.com/oauth2/v3/token"

--getGoogleIdPostBody :: String -> String -> String -> IO String
--getGoogleIdPostBody clientid secret code =
--  printf "code=%s&client_id=%s&client_secret=%s&redirect_uri=%s&grant_type=authorization_code" code clientid secret "http://localhost:8000/handlelogin"


data JWTHeader = JWTHeader { alg :: String, kid :: String } deriving (Show)

instance JSON.FromJSON JWTHeader where
  parseJSON (Object o) = JWTHeader <$>
                              o .: "alg" <*>
                              o .: "kid"
  parseJSON _ = mzero

data JWTPayload = JWTPayload { iss :: String
                             , at_has :: String
                             , email_verified :: Bool
                             , sub :: String
                             , azp :: String
                             , email :: String
                             , aud :: String
                             , iat :: Int
                             , exp :: Int } deriving (Show)

instance JSON.FromJSON JWTPayload where
  parseJSON (Object o) = JWTPayload <$>
                         o .: "iss" <*>
                         o .: "at_hash" <*>
                         o .: "email_verified" <*>
                         o .: "sub" <*>
                         o .: "azp" <*>
                         o .: "email" <*>
                         o .: "aud" <*>
                         o .: "iat" <*>
                         o .: "exp"

jwtDecode :: FromJSON a => Text.Text -> Maybe a
jwtDecode inTxt =
  JSON.decode (C8L.fromStrict (BS64.decodeLenient (TextEnc.encodeUtf8 inTxt)))

decodeToString :: Text.Text -> String
decodeToString inTxt = 
  Text.unpack (TextEnc.decodeUtf8 (BS64.decodeLenient (TextEnc.encodeUtf8 inTxt)))
  
getGoogleId :: String -> String -> String -> IO String
getGoogleId clientid secret code = do
  r <- post getGoogleIdUrl [ "code" := code
                           , "client_id" := clientid
                           , "client_secret" := secret
                           , "redirect_uri" := ("http://localhost:8000/handlelogin" :: String)
                           , "grant_type" := ("authorization_code" :: String)
                           ]
--  return $ TL.unpack $ decodeUtf8 $ r ^. responseBody
--  encodedId <- return $ unpack $ r ^. responseBody . key "id_token" . _String
  putStrLn $ TL.unpack $ decodeUtf8 $ r ^. responseBody
  encodedIdTxt <- return $ r ^. responseBody .key "id_token" . _String
  putStrLn ("Decoding: "  ++ (show encodedIdTxt))
  elems <- return $ Text.splitOn "." encodedIdTxt
  putStrLn $ show elems
--  firstJsonTxt <- return $ (TextEnc.decodeUtf8 (BS64.decodeLenient (TextEnc.encodeUtf8 (head elems))))
--  firstJsonC8 <- return $ C8L.fromStrict (TextEnc.encodeUtf8 firstJsonTxt)
--  putStrLn $ ("c8: " ++ (show firstJsonC8))
--  firstJson <- return $ (JSON.decode firstJsonC8 :: Maybe Header)
--  putStrLn $ ("JSON" ++ (show firstJson))
  jwtHeader <- return $ (jwtDecode (head elems) :: Maybe JWTHeader)
  putStrLn $ show jwtHeader
  putStrLn $ "payload: " ++ (decodeToString (head (tail elems)))
  jwtPayload <- return $ (jwtDecode (head (tail elems)) :: Maybe JWTPayload)
  putStrLn $ show jwtPayload
  return $ case jwtPayload of
    Nothing -> "ERROR couldn't parse payload"
    Just payload -> email payload


--  encodedIdString <- return $ ( (Text.unpack $ r ^. responseBody . key "id_token" . _String) :: String )
--  encodedIdBS <- return $ (C8.pack encodedIdString :: C8.ByteString)
--  len <- return $ C8.length encodedIdBS
--  putStrLn $ show len
--  missingN <- return $ (4 - (mod len 4) - 1)
--  missingStr <- return $ take missingN (repeat '=')
--  paddedIdBS <- return (C8.append encodedIdBS (C8.pack missingStr))
--  putStrLn (C8.unpack paddedIdBS)
--  case (BS64.decode paddedIdBS) of
--    Left string -> return $ "ERROR: " ++ string
--    Right bytestring -> return $ C8.unpack bytestring

--  initReq <- parseUrl getGoogleIdUrl
--  manager <- newManager conduitManagerSettings
--  let request = initReq { method = "POST" } in
--    response <- httpLbs request manager
      
      

annotate :: [Run] -> [(Run, RunMeta)]
annotate rs = zip rs (annotate2 rs)

annotate2 :: [Run] -> [RunMeta]
annotate2 rs = map buildMeta
               (zip3
                (computeRest (map date rs))
                (rankDesc (map scoreRun rs))
                (rankAsc (map pace rs)))

buildMeta :: (Integer, Maybe Int, Maybe Int) -> RunMeta
buildMeta (rest, mscore, mpace) =
  let score = case mscore of
        Just s -> s + 1
        Nothing -> 0
      pace = case mpace of
        Just p -> p + 1
        Nothing -> 0
  in RunMeta rest score pace

computeRest :: [Day] -> [Integer]
computeRest ds =
  let shifted = take (length ds) ((head ds):ds) :: [Day]
  in map (uncurry diffDays) (zip ds shifted)

rankAsc :: Ord a => [a] -> [Maybe Int]
rankAsc = rank id

rankDesc :: Ord a => [a] -> [Maybe Int]
rankDesc = rank reverse

rank :: Ord a => ([a] -> [a]) -> [a] -> [Maybe Int]
rank order ins =
  let sorted = order (sort ins)
  in map (\x -> findIndex ((==) x) sorted) ins

-- 1000 * 4 * (distance^1.06)/(time_minutes)
scoreRun :: Run -> Float
scoreRun r =
  let time_minutes = (fromIntegral (duration r)) / 60
  in 1000 * 4 * ((distance r) ** (1.06)) / time_minutes

parseRun :: String -> String -> String -> String -> String -> String -> Maybe Run
parseRun distanceS durationS dateS inclineS commentS idS = do
  distance <- readMaybe distanceS :: Maybe Float
  incline <- readMaybe inclineS :: Maybe Float
  duration <- parseDuration durationS
  date <- parseDate dateS
  id <- readMaybe idS :: Maybe Int
  Just (Run distance duration date incline commentS id)

parseDuration :: String -> Maybe Int
parseDuration input = do
  parts <- Just (Text.splitOn (Text.pack ":") (Text.pack input))
  case parts of
    [minS,secS] -> do
      min <- readMaybe (Text.unpack minS) :: Maybe Int
      sec <- readMaybe (Text.unpack secS) :: Maybe Int
      Just (min * 60 + sec)
    _ -> Nothing

parseDate :: String -> Maybe Day
parseDate input = do
  parts <- Just (Text.splitOn (Text.pack "-") (Text.pack input))
  case parts of
    [yearS,monthS,dayS] -> do
      year <- readMaybe (Text.unpack yearS) :: Maybe Integer
      month <- readMaybe (Text.unpack monthS) :: Maybe Int
      day <- readMaybe (Text.unpack dayS) :: Maybe Int
      fromGregorianValid year month day
    _ -> Nothing

formatTimeForInput :: FormatTime t => t -> String
formatTimeForInput time = formatTime defaultTimeLocale "%Y-%m-%d" time

pace :: Run -> Float
pace r = (fromIntegral (duration r)) / (distance r)

mph :: Run -> Float
mph r = 60 * 60 * (distance r) / (fromIntegral (duration r))

printDuration :: Int -> String
printDuration secs = printf "%d:%02d" (div secs 60) (mod secs 60)

-- TODO(mrjones): push the maybes up to a higher level
storeRun :: Connection -> Maybe Run -> Maybe MutationKind -> IO Int64
storeRun conn mrun mkind =
  case mrun of
    Just run -> case mkind of
      Just kind -> storeRun2 conn run kind
      Nothing -> return 0
    Nothing -> return 0

--
-- Database logic
--

dbConnect :: IO Connection
dbConnect = connect defaultConnectInfo
    { connectUser = "happstack"
    , connectPassword = "happstack"
    , connectDatabase = "happstack"
    }

instance QueryResults Run where
  convertResults [f_dist,f_dur,f_date,f_incl,f_comm,f_id] [v_dist,v_dur,v_date,v_incl,v_comm,v_id] =
    Run (convert f_dist v_dist) (convert f_dur v_dur) (convert f_date v_date) (convert f_incl v_incl) (convert f_comm v_comm) (convert f_id v_id)

storeRun2 :: Connection -> Run -> MutationKind -> IO Int64
storeRun2 conn r kind =
    case kind of
      Create -> execute conn
                "INSERT INTO happstack.runs (date, miles, duration_sec, incline, comment) VALUES (?, ?, ?, ?, ?)"
                (date r, distance r, duration r, incline r, comment r)
      Modify -> execute conn
                "UPDATE happstack.runs SET date=?, miles=?, duration_sec=?, incline=?, comment=? WHERE id=?"
                (date r, distance r, duration r, incline r, comment r, runid r)
      Delete -> execute conn
                "DELETE FROM happstack.runs WHERE id = (?)"
                [runid r]

--
-- Database Admin
--

dropTable :: IO Int64
dropTable = do
  conn <- dbConnect
  execute conn "DROP TABLE happstack.runs" ()

mkTable :: IO Int64
mkTable = do
  conn <- dbConnect
  execute conn "CREATE TABLE happstack.runs (\
               \ id INT NOT NULL AUTO_INCREMENT,\
               \ date DATE,\
               \ miles DECIMAL(5,2),\
               \ duration_sec INT,\
               \ incline DECIMAL(2,1),\
               \ comment VARCHAR(255),\
               \ PRIMARY KEY (id))" ()
--
-- HTML Templates
--
  
executeSqlHtml :: String -> Int64 -> H.Html
executeSqlHtml opname _ =
  H.html $ do
    H.head $ do
      H.title $ "executed database op"
    H.body $ H.toHtml opname

simpleMessageHtml :: String -> H.Html
simpleMessageHtml msg =
  H.html $ do
    H.head $ do
      H.title $ "Hello, world!"
    H.body $ do
      H.toHtml msg

landingPageHtml :: String -> H.Html
landingPageHtml googleUrl =
  H.html $ do
    H.head $ do
      H.title $ "Workout Database"
    H.body $ do
      H.div $ H.a ! A.href (toValue googleUrl) $ "Login"
      H.div $ H.a ! A.href "/newrun" $ H.html "New run"
      H.div $ H.a ! A.href "/rundata" $ H.html "View runs"

dataTableHtml :: [(Run, RunMeta)] -> H.Html
dataTableHtml rs =
  H.html $ do
    H.head $ do
      H.title $ "Data"
    H.body $ do
      H.table $ do
        dataTableHeader
        mapM_ dataTableRow rs
      H.a ! A.href "/newrun" $ "New run"

dataTableHeader :: H.Html
dataTableHeader =
  H.thead $ H.tr $ do
    mconcat $ map (H.td . H.b)
      ["Date", "Dist", "Time", "Incline", "Pace", "MpH", "Rest", "Score", "Score Rank", "Pace Rank", "Comment", "Edit"]

dataTableRow :: (Run, RunMeta) -> H.Html
dataTableRow (r,meta) = H.tr $ do
  H.td $ H.toHtml $ show $ date r
  H.td $ H.toHtml $ show $ distance r
  H.td $ H.toHtml $ printDuration $ duration r
  H.td $ H.toHtml $ show $ incline r
  H.td $ H.toHtml $ printDuration $ round (pace r)
  H.td $ H.toHtml (printf "%.2f" (mph r) :: String)
  H.td $ H.toHtml $ show $ daysOff meta
  H.td $ H.toHtml $ show $ round (scoreRun r)
  H.td $ H.toHtml $ show $ scoreRank meta
  H.td $ H.toHtml $ show $ paceRank meta
  H.td $ H.toHtml $ comment r
  H.td $ do
    "["
    H.a ! A.href (toValue ("/editrun?id=" ++ (show (runid r)))) $ "Edit"
    "]"

runDataHtml :: Maybe Run -> Day -> MutationKind -> H.Html
runDataHtml run today mutationKind =
  H.html $ do
    H.head $ do
      H.title "New Run"
    H.body $ do
      H.form ! A.method "post" ! A.action "/handlemutaterun" $ do
        H.input ! A.type_ "hidden"
                ! A.name "id"
                ! A.value (case run of
                              Just r -> toValue (show (runid r))
                              Nothing -> "0")
        H.table $ do
          mconcat $ map (runDataFormRow run)
                   [ ("Distance", "distance", "text", "", (show . distance), [])
                   , ("Time", "time", "text", "", (printDuration . duration), [])
                   , ("Incline", "incline", "text", "", (show . incline), [])
                   , ("Date", "date", "date", formatTimeForInput today, (formatTimeForInput . date), [])
                   , ("Comment", "comment", "text", "", comment, [
                         (A.size (toValue (75 :: Int)))])
                   ]
        case run of
          Just _ -> do
            H.input ! A.type_ "submit" ! A.name "button" ! A.value (toValue $ show Modify)
            H.input ! A.type_ "submit" ! A.name "button" ! A.value (toValue $ show Delete)
          Nothing -> H.input ! A.type_ "submit" ! A.name "button" ! A.value (toValue $ show Create)


runDataFormRow :: Maybe Run -> (String, String, String, String, (Run -> String), [H.Attribute]) -> H.Html
runDataFormRow mrun (name, id, formType, defaultValue, extractValue, extraAs) =
  let defaultAs = 
        [ A.type_ (toValue formType)
        , A.id (toValue id)
        , A.name (toValue id)
        , case mrun of
             Just run -> A.value $ toValue $ extractValue run
             Nothing -> A.value $ toValue defaultValue
        ] in
  H.tr $ do
    H.td $
      H.label ! A.for (toValue id) $ H.toHtml name
    H.td $
      foldr (flip (!)) H.input (defaultAs ++ extraAs)
