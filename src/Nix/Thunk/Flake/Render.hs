-- | This module renders a 'FlattenedFlake' as @flake.nix@ source. It also
-- renders the two simple flakes that need no flattening.
module Nix.Thunk.Flake.Render where

import Data.Foldable (fold, toList)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Nix.Thunk.Flake.Flatten
import Nix.Thunk.Flake.Name
import Nix.Thunk.Flake.Ref

--------------------------------------------------------------------------------
-- The generated flake
--------------------------------------------------------------------------------

-- | The @flake.nix@ of a packed thunk whose upstream is itself a flake.
renderFlakeNix :: FlattenedFlake -> Text
renderFlakeNix flake =
  T.unlines $
    fold @[]
      [
        [ doNotEditLine
        , "{"
        , "  inputs = {"
        ]
      , renderRefEntry
          flake.flattenedFlake_sourceName
          -- The thunk's source is always a flake here, so this entry needs no
          -- `flake = false`.
          (unFetchableRef flake.flattenedFlake_sourceRefs.nodeRefs_original)
          flake.flattenedFlake_sourceEdges
      , fold $ Map.mapWithKey renderInputEntry flake.flattenedFlake_inputs
      ,
        [ "  };"
        , -- `src` is the fetched source, which a consumer needs when it reads a
          -- path inside the repository. A thunk of a repository without a flake
          -- exposes the same name.
          "  outputs = inputs: inputs."
            <> source
            <> ".outputs // { src = inputs."
            <> source
            <> "; };"
        , "}"
        ]
      ]
  where
    source = renderName flake.flattenedFlake_sourceName

renderInputEntry :: FlakeId -> FlattenedInput -> [Text]
renderInputEntry name input = case input.flattenedInput_ref of
  -- An input that carries a `follows` cannot also carry a flake reference, so
  -- this branch emits the alias alone.
  Left followsPath -> renderAliasEntry name followsPath
  Right refs ->
    renderRefEntry
      name
      (withFlakeAttr input.flattenedInput_isFlake refs.nodeRefs_original)
      input.flattenedInput_edges

-- | Nix treats an input as a flake by default, so this function records only
-- the false case.
--
-- @flake@ is not a fetchable attribute, because it says how to read the tree,
-- and not where to fetch the tree. A flake input carries @flake@, and a lock
-- entry does not carry it. The lock records @flake@ as a field of the node
-- instead.
withFlakeAttr :: Bool -> FetchableRef -> FlakeRef
withFlakeAttr isFlake (FetchableRef flakeRef)
  | isFlake = flakeRef
  | otherwise = FlakeRef $ Map.insert (AttrName "flake") (FlakeRefValue_Bool False) $ unFlakeRef flakeRef

renderRefEntry :: IsInputName name => name -> FlakeRef -> Map InputName FlakeId -> [Text]
renderRefEntry name flakeRef inputEdges =
  fold @[]
    [ ["    " <> renderName name <> " = {"]
    , toList $ Map.mapWithKey renderAttr $ unFlakeRef flakeRef
    , renderEdges inputEdges
    , ["    };"]
    ]

renderAliasEntry :: IsInputName name => name -> FollowsPath FlakeId -> [Text]
renderAliasEntry name followsPath =
  [ "    " <> renderName name <> " = {"
  , "      follows = " <> nixString (renderFollowsPath followsPath) <> ";"
  , "    };"
  ]

renderEdges :: Map InputName FlakeId -> [Text]
renderEdges inputEdges
  | Map.null inputEdges = []
  | otherwise =
      fold @[]
        [ ["      inputs = {"]
        , toList $ Map.mapWithKey renderEdge inputEdges
        , ["      };"]
        ]

-- | One override. Upstream's name goes on the left, because the override must
-- name it. Our name goes on the right, because Nix follows it.
renderEdge :: (IsInputName from, IsInputName to) => from -> to -> Text
renderEdge name target =
  "        "
    <> renderName name
    <> " = { follows = "
    <> renderName target
    <> "; };"

renderAttr :: AttrName -> FlakeRefValue -> Text
renderAttr name value = "      " <> unAttrName name <> " = " <> renderRefValue value <> ";"

--------------------------------------------------------------------------------
-- Nix syntax
--------------------------------------------------------------------------------

-- | A reference as a standalone attribute set, for a call to
-- @builtins.fetchTree@.
--
-- This call fetches the repository in the same way as the generated flake. So
-- the call also proves at pack time that the reference resolves.
renderFlakeRefExpr :: FlakeRef -> Text
renderFlakeRefExpr flakeRef = "{ " <> fold (Map.mapWithKey attr $ unFlakeRef flakeRef) <> "}"
  where
    attr name value = unAttrName name <> " = " <> renderRefValue value <> "; "

renderFollowsPath :: IsInputName name => FollowsPath name -> Text
renderFollowsPath = T.intercalate "/" . fmap nameText . unFollowsPath

-- | A name as Nix source. Both kinds of name need the same quoting.
renderName :: IsInputName name => name -> Text
renderName = nixString . nameText

renderRefValue :: FlakeRefValue -> Text
renderRefValue = \case
  FlakeRefValue_String s -> nixString s
  FlakeRefValue_Bool b -> if b then "true" else "false"
  FlakeRefValue_Int n -> T.pack $ show n

nixString :: Text -> Text
nixString t = "\"" <> T.concatMap escapeNixChar t <> "\""

escapeNixChar :: Char -> Text
escapeNixChar = \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '$' -> "\\$"
  '\n' -> "\\n"
  '\r' -> "\\r"
  '\t' -> "\\t"
  c -> T.singleton c

--------------------------------------------------------------------------------
-- Source-only flakes
--------------------------------------------------------------------------------

-- | The @flake.nix@ of a packed thunk whose upstream is not a flake. Such a
-- thunk has no inputs to expose, so this flake exposes only the fetched source.
--
-- This flake declares the source as an input, and it does not reuse
-- @.\/thunk.nix@ to fetch the source. That loader calls
-- @(import nixpkgs {}).fetchgit@ on its common path. An import of nixpkgs needs
-- @builtins.currentSystem@, and that value does not exist in the pure
-- evaluation that Nix uses for a flake.
renderSourceOnlyFlakeNix :: FlakeRef -> Text
renderSourceOnlyFlakeNix srcRef =
  T.unlines $
    fold @[]
      [
        [ doNotEditLine
        , "{"
        , "  description = \"nix-thunk packed thunk\";"
        , "  inputs = {"
        ]
      , renderRefEntry
          sourceOnlyInputName
          (withFlakeAttr False $ fetchableRef srcRef)
          Map.empty
      ,
        [ "  };"
        , "  outputs = { self, src }: { inherit src; };"
        , "}"
        ]
      ]

-- | The @flake.nix@ that we write into an unpacked checkout of a repository
-- that is not itself a flake. The file keeps a consumer working when that
-- consumer uses the thunk as a flake input. The checkout is the source, so this
-- flake fetches nothing, and 'renderSourceOnlyFlakeNix' does fetch.
--
-- @src@ holds @sourceInfo@, and it does not hold @outPath@. The packed thunk's
-- @src@ holds the same value: there @src@ is a @flake = false@ input. Nix binds
-- such an input to the attributes of the fetched tree. A consumer can
-- read @src.outPath@ or @src.narHash@, and both must keep working across a pack
-- and an unpack.
--
-- @default.nix@ must recognise this text byte for byte, so @thunkSource@ can
-- keep the file out of an unpacked dependency's source. If you change one,
-- change the other.
unpackedSourceFlakeNix :: Text
unpackedSourceFlakeNix =
  """
  # DO NOT HAND-EDIT THIS FILE
  {
    description = "nix-thunk unpacked thunk";
    outputs = { self }: { src = self.sourceInfo; };
  }
  """

-- | The header of every generated @flake.nix@. 'unpackedSourceFlakeNix' repeats
-- this line inside its literal, because @default.nix@ must match that literal
-- byte for byte. So the literal cannot refer to this binding. If you change
-- one, change the other.
doNotEditLine :: Text
doNotEditLine = "# DO NOT HAND-EDIT THIS FILE"
